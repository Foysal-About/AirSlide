import SwiftUI

struct MainView: View {
    @EnvironmentObject var rx: ReceiverService
    @State private var showPairing = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Theme.backdrop.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                hero
                transfers
                footer
            }
        }
        .frame(minWidth: 420, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            rx.sendFiles(urls.filter(\.isFileURL), edge: .right, pos: 0.5, preview: nil)
            return rx.session != nil
        }
        .sheet(isPresented: $showPairing) { PairingSheet() }
        .onChange(of: rx.pendingPair?.id) { _, id in if id != nil { showPairing = true } }
        .onAppear {
            rx.openMainWindow = { openWindow(id: "main") }
            rx.start()
            if rx.paired.isEmpty { showPairing = true }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AirSlide").font(.title.bold())
                Text("Select. Slide.").foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(status: rx.status)
        }
        .padding(20)
    }

    private var hero: some View {
        VStack(spacing: 12) {
            ConnectionVisual(connected: isConnected, waiting: rx.status == .listening)
                .frame(height: 150)
            Text(heroTitle).font(.title3.weight(.semibold))
            if let sub = heroSubtitle { Text(sub).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var isConnected: Bool { if case .connected = rx.status { true } else { false } }

    private var heroTitle: String {
        switch rx.status {
        case .starting: "Getting ready"
        case .listening: rx.paired.isEmpty ? "Ready to pair" : "Waiting for iPhone"
        case .connected(let n): "Connected to \(n)"
        case .failed(let m): m
        }
    }

    private var heroSubtitle: String? {
        switch rx.status {
        case .connected(let n): "Drag a file to any edge of your screen to slide it to \(n)."
        case .listening: rx.paired.isEmpty ? "Pair your iPhone to start." : "If it disconnects, it reconnects automatically."
        default: nil
        }
    }

    private var transfers: some View {
        Group {
            if rx.transfers.isEmpty {
                Text("Files you slide to this Mac appear here")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rx.transfers) {
                            TransferRow(transfer: $0)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: rx.transfers.count)
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("Encrypted on your Wi-Fi", systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Show Desktop Folder") { rx.openDesktop() }
            Button("Pair another iPhone") { showPairing = true }
        }
        .padding(16)
    }
}

struct StatusPill: View {
    let status: ReceiverService.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    private var color: Color {
        switch status {
        case .starting: .gray
        case .listening: .orange
        case .connected: Theme.good
        case .failed: .red
        }
    }

    private var label: String {
        switch status {
        case .starting: "Getting ready"
        case .listening: "Waiting for iPhone"
        case .connected: "Connected"
        case .failed: "Offline"
        }
    }
}

struct ConnectionVisual: View {
    let connected: Bool
    let waiting: Bool

    var body: some View {
        ZStack {
            AirDropRings(active: connected || waiting)
            HStack(spacing: 56) {
                glyph("iphone", highlighted: connected)
                glyph("laptopcomputer", highlighted: true)
            }
        }
    }

    private func glyph(_ name: String, highlighted: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 38))
            .foregroundStyle(highlighted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.tertiary))
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2).foregroundStyle(Theme.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var size: String { ByteCountFormatter.string(fromByteCount: transfer.size, countStyle: .file) }

    private var detail: String {
        switch transfer.state {
        case .active: transfer.direction == .incoming ? "Receiving from \(transfer.device) · \(size)" : "Sending to \(transfer.device) · \(size)"
        case .done: transfer.direction == .incoming ? "Saved to Desktop · \(size)" : "Sent to \(transfer.device) · \(size)"
        case .failed(let r): r
        }
    }

    @ViewBuilder private var trailing: some View {
        switch transfer.state {
        case .active: ProgressRing(fraction: transfer.fraction).frame(width: 26, height: 26)
        case .done(let url):
            if let url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good) }
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
