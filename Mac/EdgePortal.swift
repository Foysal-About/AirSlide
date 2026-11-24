import SwiftUI
import AppKit

/// Watches for file drags anywhere on screen. When one nears any screen edge it tells the iPhone how close
/// the file is (so the iPhone can slide it in from the opposite edge) and accepts the drop on thin edge strips.
/// A separate click-through, full-screen layer draws the glow and the file card.
@MainActor
final class EdgePortal: NSObject {
    static let zone: CGFloat = 110          // thickness of the drop strip on each edge
    private let approach: CGFloat = 380     // distance from an edge where the iPhone starts to react
    private let service: ReceiverService
    private let visual: NSPanel
    private var strips: [AirEdge: NSPanel] = [:]
    private var screen: NSScreen
    private var lastCount = NSPasteboard(name: .drag).changeCount

    private var dragActive = false, announced = false, dropped = false, previewSent = false
    private var activeEdge: AirEdge = .right
    private var urls: [URL] = []
    private var preview: Data?
    private var token = ""
    private var lastSend = Date.distantPast

    init(service: ReceiverService) {
        self.service = service
        screen = NSScreen.main ?? NSScreen.screens[0]
        visual = Self.makePanel()
        super.init()

        visual.contentView = NSHostingView(rootView: PortalView(model: service.portal))
        visual.orderFrontRegardless()

        for edge in AirEdge.allCases {
            let p = Self.makePanel()
            let v = PortalDropView(edge: edge)
            v.onDrop = { [weak self] urls, pos in self?.drop(urls, edge: edge, pos: pos) }
            p.contentView = v
            p.orderFrontRegardless()
            strips[edge] = p
        }
        layout()

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            let t = e.type
            MainActor.assumeIsolated { self?.handle(t) }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            let t = e.type
            MainActor.assumeIsolated { self?.handle(t) }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return p
    }

    private func layout() {
        let f = screen.frame, z = Self.zone
        visual.setFrame(f, display: true)
        strips[.left]?.setFrame(NSRect(x: f.minX, y: f.minY, width: z, height: f.height), display: true)
        strips[.right]?.setFrame(NSRect(x: f.maxX - z, y: f.minY, width: z, height: f.height), display: true)
        strips[.top]?.setFrame(NSRect(x: f.minX, y: f.maxY - z, width: f.width, height: z), display: true)
        strips[.bottom]?.setFrame(NSRect(x: f.minX, y: f.minY, width: f.width, height: z), display: true)
    }

    /// An edge is usable unless another display touches it or the Dock lives there.
    private func isUsable(_ edge: AirEdge, on s: NSScreen) -> Bool {
        let f = s.frame, v = s.visibleFrame
        let others = NSScreen.screens.filter { $0 != s }.map(\.frame)
        switch edge {
        case .left: return v.minX - f.minX < 4 && !others.contains { abs($0.maxX - f.minX) < 2 }
        case .right: return f.maxX - v.maxX < 4 && !others.contains { abs($0.minX - f.maxX) < 2 }
        case .bottom: return v.minY - f.minY < 4 && !others.contains { abs($0.maxY - f.minY) < 2 }
        case .top: return !others.contains { abs($0.minY - f.maxY) < 2 }
        }
    }

    private var title: String { urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files" }

    private func distance(_ edge: AirEdge, _ p: NSPoint, _ f: NSRect) -> CGFloat {
        switch edge {
        case .left: p.x - f.minX
        case .right: f.maxX - p.x
        case .top: f.maxY - p.y
        case .bottom: p.y - f.minY
        }
    }

    private func pos(_ edge: AirEdge, _ p: NSPoint, _ f: NSRect) -> Double {
        switch edge {
        case .left, .right: 1 - (p.y - f.minY) / f.height
        case .top, .bottom: (p.x - f.minX) / f.width
        }
    }

    private func handle(_ type: NSEvent.EventType) {
        if type == .leftMouseUp { finish(); return }
        let pb = NSPasteboard(name: .drag)
        if !dragActive {
            guard pb.changeCount != lastCount else { return }
            lastCount = pb.changeCount
            let found = (pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !found.isEmpty else { return }
            urls = found
            dragActive = true; announced = false; dropped = false; previewSent = false
            token = UUID().uuidString
            preview = nil
            Task { preview = await Thumbnailer.jpeg(for: found[0]) }
            service.portal.dragActive = service.portal.peerConnected
        }
        guard service.portal.peerConnected, let s = service.session else { return }

        let p = NSEvent.mouseLocation
        if let cur = NSScreen.screens.first(where: { $0.frame.contains(p) }), cur != screen {
            screen = cur
            layout()
        }
        let f = screen.frame
        let usable = AirEdge.allCases.filter { isUsable($0, on: screen) }
        for e in AirEdge.allCases { strips[e]?.ignoresMouseEvents = !usable.contains(e) }
        guard let best = usable.min(by: { distance($0, p, f) < distance($1, p, f) }) else { return }

        let depth = max(0, min(1, (approach - distance(best, p, f)) / (approach - 60)))
        let along = pos(best, p, f)
        activeEdge = best
        service.portal.dragEdge = best
        service.portal.dragPos = along
        service.portal.dragDepth = depth
        guard depth > 0 || announced else { return }
        guard Date().timeIntervalSince(lastSend) > 1.0 / 30 else { return }
        lastSend = Date()

        let phase = announced ? "move" : "begin"
        announced = true
        let pv = previewSent ? nil : preview
        if pv != nil { previewSent = true }
        s.drag(.drag(phase: phase, token: token, name: title, kind: Thumbnailer.kind(of: urls[0]),
                     pos: along, depth: depth, edge: best, preview: pv))
    }

    private func drop(_ urls: [URL], edge: AirEdge, pos: Double) {
        dropped = true
        service.sendFiles(urls, edge: edge, pos: pos, preview: urls.count == 1 ? preview : nil)
    }

    private func finish() {
        guard dragActive else { return }
        // Give the drop callback a moment to land before deciding it was cancelled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            if announced && !dropped {
                service.session?.drag(.drag(phase: "cancel", token: token, name: title, kind: "doc",
                                            pos: 0, depth: 0, edge: activeEdge, preview: nil))
            }
            dragActive = false; announced = false
            for e in AirEdge.allCases { strips[e]?.ignoresMouseEvents = true }
            service.portal.dragActive = false
            service.portal.dragDepth = 0
        }
    }
}

/// Transparent drop target for one screen edge.
final class PortalDropView: NSView {
    let edge: AirEdge
    var onDrop: (([URL], Double) -> Void)?

    init(edge: AirEdge) {
        self.edge = edge
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        let l = sender.draggingLocation
        let pos: Double = (edge == .left || edge == .right)
            ? 1 - l.y / max(bounds.height, 1)
            : l.x / max(bounds.width, 1)
        onDrop?(urls, pos)
        return true
    }
}

struct PortalView: View {
    @ObservedObject var model: PortalModel

    var body: some View {
        ZStack {
            if model.dragActive, model.peerConnected, let e = model.dragEdge {
                EdgeGlow(depth: max(0.12, model.dragDepth), edge: e, pos: model.dragPos)
            }
            if let g = model.ghost {
                EdgeGlow(depth: g.stage == .approaching ? g.depth : 0.6, edge: g.edge, pos: g.pos)
            }
            GhostLayer(ghost: model.ghost, insets: EdgeInsets(top: 34, leading: 0, bottom: 0, trailing: 0))
        }
    }
}
