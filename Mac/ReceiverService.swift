import Foundation
import Network
import CryptoKit
import SwiftUI
import AppKit

struct Transfer: Identifiable {
    enum Direction { case incoming, outgoing }
    enum State { case active, done(URL?), failed(String) }
    let id: String
    var name: String
    var size: Int64
    var fraction: Double = 0
    var device: String
    var direction: Direction
    var state: State = .active
    var date = Date()
}

struct PendingPair: Identifiable {
    let id = UUID()
    let name: String
    let code: String
}

struct MacIdentity {
    let id: String
    let name: String

    static func load() -> MacIdentity {
        let d = UserDefaults.standard
        let id = d.string(forKey: "airslide.mac.id") ?? UUID().uuidString
        d.set(id, forKey: "airslide.mac.id")
        return MacIdentity(id: id, name: Host.current().localizedName ?? "Mac")
    }
}

/// State the screen-edge portal draws: the glow while you drag, and the file card in flight.
@MainActor
final class PortalModel: ObservableObject {
    @Published var ghost: Ghost?
    @Published var dragActive = false
    @Published var dragDepth: Double = 0
    @Published var peerConnected = false
    @Published var dragEdge: AirEdge?
    @Published var dragPos: Double = 0.5
}

@MainActor
final class ReceiverService: ObservableObject {
    enum Status: Equatable { case starting, listening, connected(String), failed(String) }

    @Published private(set) var listening = false
    @Published private(set) var listenerError: String?
    @Published private(set) var connected: [String] = []
    @Published private(set) var paired: [Peer]
    @Published private(set) var transfers: [Transfer] = []
    /// Non-nil only while the pairing sheet is open.
    @Published private(set) var pairingSecret: Data?
    @Published var justPaired: String?
    /// An iPhone asking to pair; the user compares `code` with the iPhone and taps Allow.
    @Published private(set) var pendingPair: PendingPair?
    private var pairDecision: CheckedContinuation<Bool, Never>?

    let identity = MacIdentity.load()
    let portal = PortalModel()
    var presenter: ArrivalPresenting = ArrivalOverlayController()
    let desktopFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

    private let peers = PeerStore(defaultsKey: "airslide.mac.pairedDevices")
    private var listener: NWListener?
    private var activity: NSObjectProtocol?
    private var sessions: [Session] = []
    private var edge: EdgePortal?
    private var ghostGen = 0
    /// Set by the main window so a finished file can bring it back if it was closed.
    var openMainWindow: (() -> Void)?

    var session: Session? { sessions.last }

    var status: Status {
        if let e = listenerError { return .failed(e) }
        if let n = connected.first { return .connected(n) }
        return listening ? .listening : .starting
    }

    init() { paired = peers.peers }

    func start() {
        guard listener == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "AirSlide is listening for files from paired iPhones")
        edge = edge ?? EdgePortal(service: self)
        do {
            let l = try NWListener(using: Wire.params)
            l.service = NWListener.Service(name: identity.id, type: Wire.service,
                                           txtRecord: NWTXTRecord(["id": identity.id, "name": identity.name]))
            l.stateUpdateHandler = { [weak self] s in Task { @MainActor in self?.listenerChanged(s) } }
            l.newConnectionHandler = { [weak self] c in Task { await self?.handle(c) } }
            l.start(queue: DispatchQueue(label: "com.airslide.listener"))
            listener = l
        } catch {
            listenerError = "AirSlide can't listen right now: \(error.localizedDescription)"
        }
    }

    private func listenerChanged(_ s: NWListener.State) {
        switch s {
        case .ready: listening = true; listenerError = nil
        case .failed(let e):
            listening = false
            listenerError = "AirSlide can't listen right now: \(e.localizedDescription)"
            listener = nil
        default: break
        }
    }

    // MARK: Pairing

    func beginPairing() { pairingSecret = try? PairingPayload.randomSecret() }
    func endPairing() { pairingSecret = nil }

    func forgetAll() {
        peers.removeAll()
        paired = []
    }

    func resolvePair(_ ok: Bool) {
        pairDecision?.resume(returning: ok)
        pairDecision = nil
        pendingPair = nil
    }

    private func requestApproval(name: String, code: String) async -> Bool {
        guard pendingPair == nil else { return false }
        let p = PendingPair(name: name, code: code)
        pendingPair = p
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { c in
            pairDecision = c
            Task {
                try? await Task.sleep(for: .seconds(60))
                if pendingPair?.id == p.id { resolvePair(false) }
            }
        }
    }

    private func completePairing(deviceID: String, name: String, secret: Data) {
        guard (try? peers.save(Peer(id: deviceID, name: name, pairedAt: Date()), secret: secret)) != nil else { return }
        paired = peers.peers
        pairingSecret = nil
        justPaired = name
    }

    func openDesktop() { NSWorkspace.shared.open(desktopFolder) }

    // MARK: Sending (Mac -> iPhone)

    /// Starts sending dropped files. The card appears at the edge immediately, before bytes move.
    func sendFiles(_ urls: [URL], edge: AirEdge, pos: Double, preview: Data?) {
        guard let s = session, !urls.isEmpty else { return }
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        s.drag(.drag(phase: "drop", token: "mac", name: name, kind: Thumbnailer.kind(of: urls[0]),
                     pos: pos, depth: 1, edge: edge, preview: preview))
        Task {
            for u in urls {
                let pv = urls.count == 1 && preview != nil ? preview : await Thumbnailer.jpeg(for: u)
                await s.send(url: u, id: UUID().uuidString, preview: pv)
            }
        }
        lastDropPos = pos
        lastDropEdge = edge
        lastDropPreview = preview
    }

    private var lastDropPos = 0.5
    private var lastDropEdge: AirEdge = .right
    private var lastDropPreview: Data?

    // MARK: Connection handling (runs off the main actor; hops back for state)

    private struct Candidate { let secret: Data; let peerID: String? }

    private func candidates() -> [Candidate] {
        var all = paired.compactMap { p in peers.secret(for: p.id).map { Candidate(secret: $0, peerID: p.id) } }
        if let s = pairingSecret { all.append(Candidate(secret: s, peerID: nil)) }
        return all
    }

    private func register(deviceID: String, name: String, via c: Candidate) {
        if c.peerID == nil {
            let peer = Peer(id: deviceID, name: name, pairedAt: Date())
            guard (try? peers.save(peer, secret: c.secret)) != nil else { return }
            paired = peers.peers
            pairingSecret = nil
            justPaired = name
        }
    }

    private func attach(_ s: Session, name: String) {
        sessions.append(s)
        connected.append(name)
        portal.peerConnected = true
    }

    private func detach(_ s: Session, name: String) {
        sessions.removeAll { $0 === s }
        if let i = connected.firstIndex(of: name) { connected.remove(at: i) }
        portal.peerConnected = !sessions.isEmpty
        if sessions.isEmpty { portal.ghost = nil }
    }

    nonisolated private func handle(_ conn: NWConnection) async {
        let ch = SecureChannel(conn)
        var attached: (Session, String)?
        do {
            try await ch.start()
            let watchdog = Task { try await Task.sleep(for: .seconds(20)); ch.close() }
            let cands = await candidates()
            let first = try await ch.receiveFrame(keys: cands.map { SecureChannel.deriveKey($0.secret) }, allowPlain: true)
            watchdog.cancel()

            if first.index == -1 {
                // Pairing by code: exchange public keys, let the user confirm the code, then switch to the shared secret.
                guard case .pairRequest(let did, let name, let phonePub) = try SecureChannel.decode(first.payload)
                else { throw AirSlideError.unexpected }
                let mine = Curve25519.KeyAgreement.PrivateKey()
                let macPub = mine.publicKey.rawRepresentation
                let (secret, code) = try Pairing.derive(priv: mine, peerPub: phonePub, phonePub: phonePub, macPub: macPub)
                try await ch.sendPlain(.pairOffer(macID: await identity.id, macName: await identity.name, pub: macPub))
                if await requestApproval(name: name, code: code) {
                    ch.setSecret(secret)
                    try await ch.send(.pairResult(accepted: true))
                    await completePairing(deviceID: did, name: name, secret: secret)
                } else {
                    try? await ch.sendPlain(.pairResult(accepted: false))
                }
                ch.close()
                return
            }
            guard first.kind == Wire.kindMessage,
                  case .hello(let deviceID, let deviceName, let version) = try SecureChannel.decode(first.payload)
            else { throw AirSlideError.unexpected }
            let macName = await identity.name
            guard version == Wire.version else {
                try? await ch.send(.helloAck(accepted: false, macName: macName, reason: "versionMismatch"))
                throw AirSlideError.versionMismatch
            }
            await register(deviceID: deviceID, name: deviceName, via: cands[first.index])
            try await ch.send(.helloAck(accepted: true, macName: macName, reason: nil))

            let s = Session(channel: ch, peerName: deviceName, sink: FolderSink(folder: await desktopFolder))
            await s.start()
            attached = (s, deviceName)
            await attach(s, name: deviceName)
            for await e in s.events { await onEvent(e, device: deviceName) }
        } catch {
            // Handshake failed or connection dropped; nothing else to report.
        }
        ch.close()
        if let (s, name) = attached { await detach(s, name: name) }
    }

    // MARK: Events

    private func onEvent(_ e: SessionEvent, device: String) {
        switch e {
        case .drag(let phase, _, let name, let kind, let pos, let depth, let senderEdge, let preview):
            let edge = senderEdge.opposite
            switch phase {
            case "cancel": setGhost(nil)
            case "drop":
                var g = portal.ghost ?? Ghost(name: name, kind: kind, preview: preview, pos: pos, depth: 1, edge: edge)
                g.depth = 1; g.stage = .active; g.edge = edge
                setGhost(g)
            default:
                var g = portal.ghost ?? Ghost(name: name, kind: kind, preview: preview, pos: pos, depth: depth, edge: edge)
                if preview != nil { g.preview = preview }
                g.pos = pos; g.depth = depth; g.edge = edge; g.stage = .approaching
                ghostGen += 1
                setGhost(g)
            }

        case .incomingStarted(let id, let name, let size, let preview):
            transfers.insert(Transfer(id: id, name: name, size: size, device: device, direction: .incoming), at: 0)
            var g = portal.ghost ?? Ghost(name: name, kind: "doc", preview: preview, pos: 0.5, depth: 1, edge: .right)
            g.name = name; if preview != nil { g.preview = preview }
            g.depth = 1; g.stage = .active; g.progress = 0
            setGhost(g)

        case .incomingProgress(let id, let f):
            update(id) { $0.fraction = f }
            portal.ghost?.progress = f

        case .incomingFinished(let id, let url):
            update(id) { $0.state = .done(url); $0.fraction = 1 }
            landGhostInApp()

        case .incomingFailed(let id, let reason):
            update(id) { $0.state = .failed(reason) }
            setGhost(nil)

        case .outgoingStarted(let id, let name, let size):
            transfers.insert(Transfer(id: id, name: name, size: size, device: device, direction: .outgoing), at: 0)
            var g = portal.ghost ?? Ghost(name: name, kind: "doc", preview: lastDropPreview, pos: lastDropPos, depth: 1, edge: lastDropEdge)
            g.name = name; g.stage = .active; g.depth = 1; g.progress = 0; g.leaveSlide = 1.3
            setGhost(g)

        case .outgoingProgress(let id, let f):
            update(id) { $0.fraction = f }
            portal.ghost?.progress = f

        case .outgoingFinished(let id):
            update(id) { $0.state = .done(nil); $0.fraction = 1 }
            finishGhost()

        case .outgoingFailed(let id, let reason):
            update(id) { $0.state = .failed(reason) }
            setGhost(nil)
        }
    }

    private func update(_ id: String, _ f: (inout Transfer) -> Void) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { f(&transfers[i]) }
    }

    private func setGhost(_ g: Ghost?) {
        ghostGen += 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) { portal.ghost = g }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "AirSlide" && $0.isVisible && $0.frame.width > 300 }
    }

    /// Checkmark, then the card flies into the transfer list of the AirSlide window (opening it if needed).
    private func landGhostInApp() {
        ghostGen += 1
        let gen = ghostGen
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            portal.ghost?.stage = .done
            portal.ghost?.progress = 1
        }
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            guard gen == ghostGen else { return }
            if mainWindow == nil {
                openMainWindow?()
                try? await Task.sleep(for: .seconds(0.45))
            }
            NSApp.activate(ignoringOtherApps: true)
            if let w = mainWindow, let screen = w.screen ?? NSScreen.main {
                let f = screen.frame
                // Top-left origin, inside the full-screen portal layer. The list sits below the header and hero.
                portal.ghost?.target = CGPoint(x: w.frame.midX - f.minX, y: f.maxY - (w.frame.maxY - 350))
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.84)) { portal.ghost?.stage = .leaving }
            try? await Task.sleep(for: .seconds(0.8))
            guard gen == ghostGen else { return }
            withAnimation { portal.ghost = nil }
        }
    }

    /// Check mark, a beat, then the card leaves.
    private func finishGhost() {
        ghostGen += 1
        let gen = ghostGen
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            portal.ghost?.stage = .done
            portal.ghost?.progress = 1
        }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            guard gen == ghostGen else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { portal.ghost?.stage = .leaving }
            try? await Task.sleep(for: .seconds(0.7))
            guard gen == ghostGen else { return }
            withAnimation { portal.ghost = nil }
        }
    }
}
