import SwiftUI
import CoreImage.CIFilterBuiltins

struct PairingSheet: View {
    @EnvironmentObject var rx: ReceiverService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let name = rx.justPaired {
                PairedCelebration(name: name)
            } else if let req = rx.pendingPair {
                PairRequestCard(request: req)
            } else if let secret = rx.pairingSecret {
                PairingCard(macName: rx.identity.name,
                            payload: PairingPayload(macID: rx.identity.id, macName: rx.identity.name, secret: secret))
            } else {
                ProgressView()
            }
        }
        .padding(28)
        .frame(width: 400)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: rx.pendingPair?.id)
        .overlay(alignment: .topTrailing) {
            Button("Close") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary).padding(14)
        }
        .onAppear { rx.start(); rx.beginPairing() }
        .onDisappear { rx.endPairing(); rx.justPaired = nil }
        .onChange(of: rx.justPaired) { _, n in
            guard n != nil else { return }
            Task { try? await Task.sleep(for: .seconds(2)); dismiss() }
        }
    }
}

/// Default state: waiting for an iPhone to tap this Mac. QR is the fallback.
struct PairingCard: View {
    let macName: String
    let payload: PairingPayload

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair your iPhone").font(.title2.bold())
            ZStack {
                AirDropRings().frame(width: 150, height: 150)
                HStack(spacing: 30) {
                    Image(systemName: "iphone").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Image(systemName: "laptopcomputer").font(.system(size: 30)).foregroundStyle(Theme.gradient)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open AirSlide on your iPhone")
                step(2, "Tap **\(macName)**")
                step(3, "Check the code, then tap **Allow**")
            }
            DisclosureGroup("Scan a QR code instead") {
                VStack(spacing: 12) {
                    if let img = Self.qr(payload.url.absoluteString) {
                        Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 170, height: 170).padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button("Copy pairing link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(payload.url.absoluteString, forType: .string)
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 8)
            }
            .font(.footnote)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.footnote.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Theme.gradient, in: Circle())
            Text(text)
        }
    }

    static func qr(_ string: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(string.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// An iPhone tapped this Mac: show the code, the user checks it matches and allows.
struct PairRequestCard: View {
    @EnvironmentObject var rx: ReceiverService
    let request: PendingPair

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with \(request.name)?").font(.title2.bold()).multilineTextAlignment(.center)
            Text(request.code.map(String.init).joined(separator: " "))
                .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.gradient)
                .padding(.vertical, 6)
            Text("Make sure your iPhone shows the same code.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Decline") { rx.resolvePair(false) }.controlSize(.large)
                Button("Allow") { rx.resolvePair(true) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

struct PairedCelebration: View {
    let name: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.good)
            Text("Paired with").foregroundStyle(.secondary)
            Text(name).font(.title.bold())
        }
        .frame(height: 300)
    }
}
