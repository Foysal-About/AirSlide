import Foundation
import Network
import SwiftUI
import UIKit
import Photos
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import CryptoKit

struct TrayItem: Identifiable, Equatable {
    enum State: Equatable { case idle, sending(Double), sent, failed(String) }
    let id: UUID
    let url: URL
    let name: String
    let kind: String
    var preview: Data?
    var state: State = .idle
}

struct NearbyMac: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

enum PairUI: Equatable {
    case connecting(String)
    case confirming(mac: String, code: String)
    case failed(String)
}

struct ReceivedItem: Identifiable {
    let id = UUID()
    var landed = false
    let url: URL
    let name: String
    let preview: Data?
}

struct DragState: Equatable {
    var itemID: UUID
    var point: CGPoint
    var depth: Double
    var edge: AirEdge
    var pos: Double
    var tilt: Double = 0
    var flying = false
}

/// Photo/video picked from the library, copied to a temp file so it can be streamed.
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tray-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}

/// Keeps one live connection to the paired Mac while the app is open, and drives all iPhone-side animation.
@MainActor
final class PhoneLink: ObservableObject {
    enum LinkState: Equatable { case searching, connected(String), failed(String) }

    @Published private(set) var macs: [Peer]
    @Published private(set) var link: LinkState = .searching
    @Published var tray: [TrayItem] = []
    @Published private(set) var received: [ReceivedItem] = []
    @Published private(set) var ghost: Ghost?        // file arriving from the Mac
    @Published private(set) var drag: DragState?     // file being dragged toward the Mac
    @Published private(set) var nearby: [NearbyMac] = []
    @Published private(set) var pairUI: PairUI?
    private var browser: NWBrowser?

    private let store = PeerStore(defaultsKey: "airslide.ios.pairedMacs")
    private var session: Session?
    private var loop: Task<Void, Never>?
    private var announced = false
    var landingTarget: CGPoint?
    private var lastSend = Date.distantPast
    private var ghostGen = 0
    private let tick = UIImpactFeedbackGenerator(style: .soft)
    private let notify = UINotificationFeedbackGenerator()

    var isConnected: Bool { if case .connected = link { true } else { false } }

    private var deviceID: String {
        let d = UserDefaults.standard
        let id = d.string(forKey: "airslide.ios.id") ?? UUID().uuidString
        d.set(id, forKey: "airslide.ios.id")
        return id
    }

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    init() { macs = store.peers }

    // MARK: Pairing

    func pair(_ p: PairingPayload) {
        do {
            try store.save(Peer(id: p.macID, name: p.macName, pairedAt: Date()), secret: p.secret)
            macs = store.peers
            restart()
        } catch { link = .failed(error.localizedDescription) }
    }

    func forgetAll() {
        store.removeAll(); macs = []
        deactivate()
        activate()
    }

    // MARK: Connection loop

    func activate() {
        startDiscovery()
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.connectOnce()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func deactivate() {
        stopDiscovery()
        loop?.cancel(); loop = nil
        session?.close(); session = nil
    }

    private func restart() { deactivate(); activate() }

    private func connectOnce() async {
        guard let mac = macs.first else { link = .searching; return }
        link = .searching
        do {
            let (ch, macName) = try await open(mac)
            let s = Session(channel: ch, peerName: macName, sink: FolderSink(folder: documents))
            await s.start()
            session = s
            link = .connected(macName)
            for await e in s.events { onEvent(e) }
            if !Task.isCancelled { link = .searching }
        } catch {
            link = .failed(error.localizedDescription)
        }
        session = nil
        ghost = nil
    }

    private func open(_ mac: Peer) async throws -> (SecureChannel, String) {
        guard let secret = store.secret(for: mac.id) else { throw AirSlideError.notPaired }
        let endpoint = try await find(mac.id)
        let ch = SecureChannel(NWConnection(to: endpoint, using: .tcp), secret: secret)
        try await ch.start()
        try await ch.send(.hello(deviceID: deviceID, name: UIDevice.current.name, version: Wire.version))
        let reply = try await withTimeout(10) { try await ch.receiveMessage() }
        guard case .helloAck(let ok, let macName, let reason) = reply else { throw AirSlideError.unexpected }
        guard ok else { throw reason == "versionMismatch" ? AirSlideError.versionMismatch : AirSlideError.notPaired }
        return (ch, macName)
    }

    private func find(_ macID: String) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<NWEndpoint, Error>) in
            let q = DispatchQueue(label: "com.airslide.browser")
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.service, domain: nil), using: .tcp)
            var done = false
            func finish(_ r: Result<NWEndpoint, Error>) {
                guard !done else { return }
                done = true
                b.cancel()
                c.resume(with: r)
            }
            b.browseResultsChangedHandler = { results, _ in
                for r in results {
                    if case .bonjour(let txt) = r.metadata, txt["id"] == macID { finish(.success(r.endpoint)); return }
                }
            }
            b.stateUpdateHandler = { if case .failed(let e) = $0 { finish(.failure(e)) } }
            q.asyncAfter(deadline: .now() + 10) { finish(.failure(AirSlideError.timeout)) }
            b.start(queue: q)
        }
    }

    private func withTimeout<T: Sendable>(_ s: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: .seconds(s)); throw AirSlideError.timeout }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    // MARK: Pairing by tapping a nearby Mac

    func startDiscovery() {
        guard browser == nil, macs.isEmpty else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.service, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> NearbyMac? in
                guard case .bonjour(let txt) = r.metadata, let id = txt["id"] else { return nil }
                return NearbyMac(id: id, name: txt["name"] ?? "Mac", endpoint: r.endpoint)
            }
            Task { @MainActor in self?.nearby = list.sorted { $0.name < $1.name } }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopDiscovery() {
        browser?.cancel(); browser = nil
        nearby = []
    }

    func dismissPairError() { pairUI = nil }

    func pairNearby(_ mac: NearbyMac) async {
        guard pairUI == nil || { if case .failed = pairUI { true } else { false } }() else { return }
        pairUI = .connecting(mac.name)
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let phonePub = priv.publicKey.rawRepresentation
        let ch = SecureChannel(NWConnection(to: mac.endpoint, using: .tcp))
        defer { ch.close() }
        do {
            try await withTimeout(10) { try await ch.start() }
            try await ch.sendPlain(.pairRequest(deviceID: deviceID, name: UIDevice.current.name, pub: phonePub))
            let offer = try await withTimeout(10) { try await ch.receiveFrame(keys: [], allowPlain: true) }
            guard offer.index == -1 else { throw AirSlideError.unexpected }
            guard case .pairOffer(let macID, let macName, let macPub) = try SecureChannel.decode(offer.payload) else {
                throw AirSlideError.declined("Open AirSlide on your Mac and try again.")
            }
            let (secret, code) = try Pairing.derive(priv: priv, peerPub: macPub, phonePub: phonePub, macPub: macPub)
            pairUI = .confirming(mac: macName, code: code)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            let key = SecureChannel.deriveKey(secret)
            let reply = try await withTimeout(65) { try await ch.receiveFrame(keys: [key], allowPlain: true) }
            guard reply.index == 0, case .pairResult(true) = try SecureChannel.decode(reply.payload) else {
                throw AirSlideError.declined("Your Mac declined.")
            }
            try store.save(Peer(id: macID, name: macName, pairedAt: Date()), secret: secret)
            macs = store.peers
            pairUI = nil
            notify.notificationOccurred(.success)
            stopDiscovery()
            restart()
        } catch {
            pairUI = .failed(error.localizedDescription)
            notify.notificationOccurred(.error)
        }
    }

    // MARK: Events

    private func onEvent(_ e: SessionEvent) {
        switch e {
        case .drag(let phase, _, let name, let kind, let pos, let depth, let macEdge, let preview):
            let edge = macEdge.opposite
            switch phase {
            case "cancel": setGhost(nil)
            case "drop":
                var g = ghost ?? Ghost(name: name, kind: kind, preview: preview, pos: pos, depth: 1, edge: edge)
                g.depth = 1; g.stage = .active; g.edge = edge
                setGhost(g)
            default:
                if ghost == nil { tick.impactOccurred(intensity: 0.5) }
                var g = ghost ?? Ghost(name: name, kind: kind, preview: preview, pos: pos, depth: depth, edge: edge)
                if preview != nil { g.preview = preview }
                g.pos = pos; g.depth = depth; g.edge = edge; g.stage = .approaching
                ghostGen += 1
                setGhost(g)
            }

        case .incomingStarted(_, let name, _, let preview):
            var g = ghost ?? Ghost(name: name, kind: "doc", preview: preview, pos: 0.45, depth: 1, edge: .left)
            g.name = name; if preview != nil { g.preview = preview }
            g.depth = 1; g.stage = .active; g.progress = 0
            setGhost(g)

        case .incomingProgress(_, let f):
            ghost?.progress = f

        case .incomingFinished(_, let url):
            notify.notificationOccurred(.success)
            let item = ReceivedItem(url: url, name: url.lastPathComponent, preview: ghost?.preview)
            received.insert(item, at: 0)
            saveToPhotosIfMedia(url)
            finishGhost(landing: item.id)

        case .incomingFailed:
            notify.notificationOccurred(.error)
            setGhost(nil)

        case .outgoingStarted: break

        case .outgoingProgress(let id, let f):
            setTray(id) { $0.state = .sending(f) }

        case .outgoingFinished(let id):
            notify.notificationOccurred(.success)
            setTray(id) { $0.state = .sent }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { tray.removeAll { $0.id.uuidString == id } }
            }

        case .outgoingFailed(let id, let reason):
            notify.notificationOccurred(.error)
            setTray(id) { $0.state = .failed(reason) }
        }
    }

    private func setTray(_ id: String, _ f: (inout TrayItem) -> Void) {
        if let i = tray.firstIndex(where: { $0.id.uuidString == id }) { f(&tray[i]) }
    }

    private func setGhost(_ g: Ghost?) {
        ghostGen += 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) { ghost = g }
    }

    /// Checkmark, then the card flies onto its new spot in "From your Mac" and pops in there.
    private func finishGhost(landing id: UUID) {
        ghostGen += 1
        let gen = ghostGen
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { ghost?.stage = .done; ghost?.progress = 1 }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard gen == ghostGen else { return }
            ghost?.target = landingTarget
            withAnimation(.spring(response: 0.6, dampingFraction: 0.84)) { ghost?.stage = .leaving }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                if let i = received.firstIndex(where: { $0.id == id }) { received[i].landed = true }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            try? await Task.sleep(for: .seconds(0.2))
            guard gen == ghostGen else { return }
            withAnimation { ghost = nil }
        }
    }

    private func saveToPhotosIfMedia(_ url: URL) {
        let kind = Thumbnailer.kind(of: url)
        guard kind == "image" || kind == "video" else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: kind == "video" ? .video : .photo, fileURL: url, options: nil)
            }
        }
    }

    // MARK: Tray

    func addToTray(url: URL, copy: Bool) async {
        var file = url
        if copy {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tray-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return }
            file = dir.appendingPathComponent(url.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: url, to: file)) != nil else { return }
        }
        let pv = await Thumbnailer.jpeg(for: file)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            tray.append(TrayItem(id: UUID(), url: file, name: file.lastPathComponent,
                                 kind: Thumbnailer.kind(of: file), preview: pv))
        }
    }

    // MARK: Dragging a tray card toward the Mac (any edge)

    private var screen: CGSize { UIScreen.main.bounds.size }
    private var armed = false

    private func depth(_ edge: AirEdge, _ p: CGPoint) -> Double {
        let w = screen.width, h = screen.height
        let d: Double
        switch edge {
        case .left: d = 1 - p.x / (w * 0.5)
        case .right: d = 1 - (w - p.x) / (w * 0.5)
        case .top: d = 1 - p.y / (h * 0.28)
        case .bottom: d = 1 - (h - p.y) / (h * 0.28)
        }
        return max(0, min(1, d))
    }

    private func pos(_ edge: AirEdge, _ p: CGPoint) -> Double {
        (edge == .left || edge == .right) ? p.y / screen.height : p.x / screen.width
    }

    private func nearest(_ p: CGPoint) -> (AirEdge, Double) {
        AirEdge.allCases.map { ($0, depth($0, p)) }.max { $0.1 < $1.1 }!
    }

    func dragMoved(_ item: TrayItem, at p: CGPoint) {
        let (edge, d) = nearest(p)
        let dx = p.x - (drag?.point.x ?? p.x)
        let tilt = max(-14, min(14, (drag?.tilt ?? 0) * 0.7 + dx * 0.35))
        drag = DragState(itemID: item.id, point: p, depth: d, edge: edge, pos: pos(edge, p), tilt: tilt)
        let nowArmed = d > 0.55
        if nowArmed != armed { armed = nowArmed; UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
        guard isConnected, d > 0 || announced else { return }
        guard Date().timeIntervalSince(lastSend) > 1.0 / 30 else { return }
        lastSend = Date()
        if !announced { tick.impactOccurred(intensity: 0.6) }
        session?.drag(.drag(phase: announced ? "move" : "begin", token: item.id.uuidString, name: item.name,
                            kind: item.kind, pos: pos(edge, p), depth: d, edge: edge,
                            preview: announced ? nil : item.preview))
        announced = true
    }

    /// Returns true if the card was thrown across an edge.
    @discardableResult
    func dragEnded(_ item: TrayItem, at p: CGPoint, predicted: CGPoint) -> Bool {
        let (edge, d) = nearest(p)
        let crossed = d > 0.55 || (d > 0.12 && depth(edge, predicted) > 0.95)
        defer { announced = false; armed = false }
        guard crossed, isConnected, let s = session else {
            if announced { cancel(item, edge) }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { drag = nil }
            return false
        }
        s.drag(.drag(phase: "drop", token: item.id.uuidString, name: item.name, kind: item.kind,
                     pos: pos(edge, p), depth: 1, edge: edge, preview: announced ? nil : item.preview))
        notify.notificationOccurred(.success)
        let w = screen.width, h = screen.height
        let out: CGPoint = switch edge {
        case .left: CGPoint(x: -Ghost.cardW, y: p.y)
        case .right: CGPoint(x: w + Ghost.cardW, y: p.y)
        case .top: CGPoint(x: p.x, y: -Ghost.cardH)
        case .bottom: CGPoint(x: p.x, y: h + Ghost.cardH)
        }
        drag = DragState(itemID: item.id, point: out, depth: 1, edge: edge, pos: pos(edge, p), flying: true)
        setTray(item.id.uuidString) { $0.state = .sending(0) }
        Task { await s.send(url: item.url, id: item.id.uuidString, preview: item.preview) }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            drag = nil
        }
        return true
    }

    private func cancel(_ item: TrayItem, _ edge: AirEdge) {
        session?.drag(.drag(phase: "cancel", token: item.id.uuidString, name: item.name, kind: item.kind,
                            pos: 0, depth: 0, edge: edge, preview: nil))
    }
}
