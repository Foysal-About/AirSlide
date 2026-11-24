import SwiftUI
import AppKit

@MainActor
protocol ArrivalPresenting: AnyObject {
    func present(_ transfer: Transfer)
}

/// Floating card in the top-right corner when a file lands, auto-hides after 6 s.
@MainActor
final class ArrivalOverlayController: ArrivalPresenting {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func present(_ transfer: Transfer) {
        guard case .done(let url?) = transfer.state else { return }
        hideTask?.cancel()
        panel?.orderOut(nil)

        let view = ArrivalOverlayView(name: transfer.name, url: url) { [weak self] in self?.hide() }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 84)
        let p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let f = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.maxX - host.frame.width - 16, y: f.maxY - host.frame.height - 16))
        }
        p.orderFrontRegardless()
        panel = p
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.hide() }
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct ArrivalOverlayView: View {
    let name: String
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("It's on your Mac.").font(.headline)
                Text(name).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                dismiss()
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}
