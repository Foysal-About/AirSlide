import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@main
struct AirSlideiOSApp: App {
    @StateObject private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .onOpenURL { url in
                    if let p = PairingPayload(string: url.absoluteString) { link.pair(p) }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var link: PhoneLink
    @Environment(\.scenePhase) private var phase
    @State private var scanning = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoSel: [PhotosPickerItem] = []
    @State private var pasted = ""

    var body: some View {
        ZStack {
            Theme.backdrop.ignoresSafeArea()
            if link.macs.isEmpty { pairView } else { mainView }

            // Everything below floats above the UI in full-screen coordinates.
            ZStack {
                if let d = link.drag { EdgeGlow(depth: d.depth, edge: d.edge, pos: d.pos) }
                if let g = link.ghost {
                    EdgeGlow(depth: g.stage == .approaching ? g.depth : 0.6, edge: g.edge, pos: g.pos)
                }
                GhostLayer(ghost: link.ghost, insets: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0))
                if let d = link.drag, let item = link.tray.first(where: { $0.id == d.itemID }) {
                    TrayCard(item: item, lifted: true)
                        .rotationEffect(.degrees(d.tilt))
                        .position(d.point)
                        .animation(d.flying ? .spring(response: 0.45, dampingFraction: 0.8) : nil, value: d.point)
                        .opacity(d.flying ? 0 : 1)
                        .animation(.easeIn(duration: 0.4), value: d.flying)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onPreferenceChange(ShelfFrameKey.self) { f in
            if f != .zero { link.landingTarget = CGPoint(x: f.minX + 56, y: f.midY) }
        }
        .onAppear { link.activate() }
        .onChange(of: phase) { _, p in if p == .active { link.activate() } else { link.deactivate() } }
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                if let p = PairingPayload(string: code) { link.pair(p) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoSel, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { Task { for u in urls { await link.addToTray(url: u, copy: true) } } }
        }
        .onChange(of: photoSel) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for it in items {
                    if let f = try? await it.loadTransferable(type: PickedFile.self) { await link.addToTray(url: f.url, copy: false) }
                }
                photoSel = []
            }
        }
    }

    // MARK: Main

    private var mainView: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if link.tray.isEmpty && link.received.isEmpty { emptyState }
                    if !link.tray.isEmpty { tray }
                    if !link.received.isEmpty { receivedShelf }
                }
                .padding(20)
            }
            .scrollDisabled(link.drag != nil)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AirSlide").font(.largeTitle.bold())
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Photos & Videos", systemImage: "photo.on.rectangle") { showPhotos = true }
                Button("Files", systemImage: "folder") { showFiles = true }
                Divider()
                Button("Pair another Mac", systemImage: "qrcode.viewfinder") { scanning = true }
                Button("Forget paired Macs", systemImage: "trash", role: .destructive) { link.forgetAll() }
            } label: {
                Image(systemName: "plus").font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var statusText: String {
        switch link.link {
        case .searching: "Looking for your Mac…"
        case .connected(let n): "Connected to \(n)"
        case .failed(let m): m
        }
    }

    private var statusColor: Color {
        switch link.link {
        case .searching: .orange
        case .connected: Theme.good
        case .failed: .red
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                AirDropRings(active: link.isConnected).frame(width: 220, height: 220)
                Image(systemName: "arrow.left.circle.fill").font(.system(size: 54)).foregroundStyle(Theme.gradient)
            }
            Text("Select. Slide.").font(.title2.bold())
            Text("Tap + to add files, then flick them off any edge of the screen to your Mac. Or drag a file to any edge of your Mac screen.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Slide to Mac").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], spacing: 14) {
                ForEach(link.tray) { item in
                    TrayCard(item: item, lifted: false)
                        .opacity(link.drag?.itemID == item.id ? 0.25 : 1)
                        .gesture(
                            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                                .onChanged { link.dragMoved(item, at: $0.location) }
                                .onEnded { link.dragEnded(item, at: $0.location, predicted: $0.predictedEndLocation) }
                        )
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private var receivedShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From your Mac").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(link.received) { r in
                        ShareLink(item: r.url) {
                            ReceivedCard(item: r)
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(r.landed ? 1 : 0.6)
                        .opacity(r.landed ? 1 : 0)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ShelfFrameKey.self, value: g.frame(in: .global))
                })
            }
        }
    }

    // MARK: Pairing

    private var pairView: some View {
        VStack(spacing: 18) {
            Spacer()
            if let ui = link.pairUI {
                pairProgress(ui)
            } else {
                ZStack {
                    AirDropRings().frame(width: 240, height: 240)
                    Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 64))
                        .foregroundStyle(Theme.gradient)
                }
                Text("Select. Slide.").font(.largeTitle.bold())
                if link.nearby.isEmpty {
                    HStack(spacing: 8) { ProgressView(); Text("Looking for your Mac…") }.foregroundStyle(.secondary)
                    Text("Open AirSlide on your Mac. Both need to be on the same Wi-Fi.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Text("Tap your Mac to pair").foregroundStyle(.secondary)
                    VStack(spacing: 10) {
                        ForEach(link.nearby) { mac in
                            Button { Task { await link.pairNearby(mac) } } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer").font(.title3)
                                    Text(mac.name).font(.headline)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(16).frame(maxWidth: .infinity)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                }
            }
            Spacer()
            if link.pairUI == nil {
                Button("Scan a QR code instead") { scanning = true }.font(.footnote)
            }
        }
        .padding(28)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: link.nearby)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: link.pairUI)
    }

    @ViewBuilder private func pairProgress(_ ui: PairUI) -> some View {
        switch ui {
        case .connecting(let name):
            ProgressView().controlSize(.large)
            Text("Connecting to \(name)…").font(.title3)
        case .confirming(let mac, let code):
            Text("Pair with \(mac)").font(.title3).foregroundStyle(.secondary)
            Text(code.map(String.init).joined(separator: " "))
                .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.gradient)
            Text("Check your Mac shows this code, then tap **Allow** on the Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        case .failed(let m):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text(m).multilineTextAlignment(.center)
            Button("Try again") { link.dismissPairError() }.buttonStyle(.borderedProminent)
        }
    }
}

struct ShelfFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct TrayCard: View {
    let item: TrayItem
    let lifted: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                if let img = Image(previewData: item.preview) {
                    img.resizable().scaledToFill()
                } else {
                    Image(systemName: item.kind == "video" ? "film" : item.kind == "image" ? "photo" : "doc.fill")
                        .font(.system(size: 30)).foregroundStyle(Theme.gradient)
                }
                switch item.state {
                case .sending(let f):
                    Color.black.opacity(0.3)
                    ProgressRing(fraction: f, color: .white).frame(width: 32, height: 32)
                case .sent:
                    Color.black.opacity(0.3)
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(.white)
                case .failed:
                    Color.black.opacity(0.3)
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(.white)
                case .idle: EmptyView()
                }
            }
            .frame(width: 96, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.name).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 96)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .scaleEffect(lifted ? 1.12 : 1)
        .shadow(color: .black.opacity(lifted ? 0.35 : 0.08), radius: lifted ? 20 : 6, y: lifted ? 10 : 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lifted)
    }
}

struct ReceivedCard: View {
    let item: ReceivedItem

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let img = Image(previewData: item.preview) { img.resizable().scaledToFill() }
                else { Image(systemName: "doc.fill").font(.system(size: 30)).foregroundStyle(Theme.gradient) }
            }
            .frame(width: 96, height: 84)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.name).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 96)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
