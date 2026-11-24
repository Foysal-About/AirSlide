import SwiftUI

/// Pulsing concentric rings, like AirDrop's radar.
struct AirDropRings: View {
    var active: Bool = true
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Theme.accent.opacity(active ? 0.35 : 0.12), lineWidth: 1.5)
                    .scaleEffect(pulse ? 1.0 + CGFloat(i) * 0.35 : 0.5 + CGFloat(i) * 0.15)
                    .opacity(pulse ? 0 : 1)
                    .animation(active ? .easeOut(duration: 2.4).repeatForever(autoreverses: false)
                                        .delay(Double(i) * 0.6) : .default, value: pulse)
            }
        }
        .onAppear { pulse = active }
        .onChange(of: active) { _, a in pulse = a }
    }
}
