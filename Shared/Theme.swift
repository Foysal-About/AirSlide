import SwiftUI

enum Theme {
    static let accent = Color(red: 0.18, green: 0.52, blue: 1.0)
    static let accent2 = Color(red: 0.42, green: 0.36, blue: 1.0)
    static let good = Color(red: 0.2, green: 0.78, blue: 0.45)

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var backdrop: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [accent.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 420)
        }
    }
}
