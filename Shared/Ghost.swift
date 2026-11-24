import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A file "in flight" across a shared screen edge, drawn on the device it is entering (or leaving).
struct Ghost: Equatable {
    enum Stage { case approaching, active, done, leaving }
    static let cardW: CGFloat = 148
    static let cardH: CGFloat = 176

    var name: String
    var kind: String
    var preview: Data?
    var pos: Double          // 0...1 along the edge (top-to-bottom, or left-to-right)
    var depth: Double        // 0 off-screen ... 1 docked at the edge
    var edge: AirEdge        // edge of THIS screen the card sits on
    var progress: Double = 0
    var stage: Stage = .approaching
    /// How far the card slides back out when leaving (0 = it just fades).
    var leaveSlide: Double = 0
    /// When set, a finished card flies here (screen coordinates) and shrinks into the app's list.
    var target: CGPoint?

    /// 0 = docked, 1 = fully outside the screen.
    var slide: Double {
        switch stage {
        case .approaching: 1 - depth
        case .active, .done: 0
        case .leaving: leaveSlide
        }
    }
}

extension Image {
    init?(previewData: Data?) {
        guard let d = previewData else { return nil }
        #if canImport(UIKit)
        guard let i = UIImage(data: d) else { return nil }
        self.init(uiImage: i)
        #else
        guard let i = NSImage(data: d) else { return nil }
        self.init(nsImage: i)
        #endif
    }
}

struct GhostCard: View {
    let ghost: Ghost

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                if let img = Image(previewData: ghost.preview) {
                    img.resizable().scaledToFill()
                } else {
                    Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.gradient)
                }
                if ghost.stage == .active {
                    Color.black.opacity(0.3)
                    ProgressRing(fraction: ghost.progress, color: .white).frame(width: 40, height: 40)
                }
                if ghost.stage == .done || ghost.stage == .leaving {
                    Color.black.opacity(0.3)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 46)).foregroundStyle(.white)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(width: Ghost.cardW - 20, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(ghost.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(10)
        .frame(width: Ghost.cardW)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.25)))
        .overlay { if ghost.stage == .done { SuccessBurst() } }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var icon: String {
        switch ghost.kind {
        case "image": "photo"
        case "video": "film"
        default: "doc.fill"
        }
    }
}

/// Ring that expands and fades once, when a transfer completes.
struct SuccessBurst: View {
    @State private var go = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22)
            .stroke(Theme.good, lineWidth: 3)
            .scaleEffect(go ? 1.35 : 1)
            .opacity(go ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 0.75)) { go = true } }
            .allowsHitTesting(false)
    }
}

struct ProgressRing: View {
    let fraction: Double
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 4)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: fraction)
        }
    }
}

/// Places the ghost on whichever edge it belongs to and slides it in with a springy overshoot.
struct GhostLayer: View {
    let ghost: Ghost?
    var insets = EdgeInsets()

    var body: some View {
        GeometryReader { geo in
            if let g = ghost {
                let w = geo.size.width, h = geo.size.height
                let cw = Ghost.cardW, ch = Ghost.cardH
                let gap: CGFloat = 14
                let along = CGFloat(g.pos)
                let cx = min(max(along * w, cw / 2 + 20), w - cw / 2 - 20)
                let cy = min(max(along * h, ch / 2 + 60), h - ch / 2 - 60)
                let slide = CGFloat(g.slide)
                let pt: CGPoint = {
                    switch g.edge {
                    case .left:
                        let d = insets.leading + gap + cw / 2, o = -cw / 2 - 24
                        return CGPoint(x: d + (o - d) * slide, y: cy)
                    case .right:
                        let d = w - insets.trailing - gap - cw / 2, o = w + cw / 2 + 24
                        return CGPoint(x: d + (o - d) * slide, y: cy)
                    case .top:
                        let d = insets.top + gap + ch / 2, o = -ch / 2 - 24
                        return CGPoint(x: cx, y: d + (o - d) * slide)
                    case .bottom:
                        let d = h - insets.bottom - gap - ch / 2, o = h + ch / 2 + 24
                        return CGPoint(x: cx, y: d + (o - d) * slide)
                    }
                }()
                let dir: Double = (g.edge == .right || g.edge == .bottom) ? 1 : -1
                let peek = g.stage == .approaching
                let landing = g.stage == .leaving && g.target != nil
                let fade = g.stage == .leaving && g.leaveSlide == 0 && !landing
                GhostCard(ghost: g)
                    .rotationEffect(.degrees(g.slide * 10 * dir))
                    .scaleEffect(landing ? 0.42 : fade ? 0.7 : (peek ? 0.8 + 0.2 * g.depth : 1))
                    .opacity(landing ? 0.15 : fade ? 0 : (peek ? 0.35 + 0.65 * g.depth : 1))
                    .blur(radius: peek ? (1 - g.depth) * 5 : 0)
                    .position(landing ? g.target! : pt)
                    .animation(.spring(response: 0.5, dampingFraction: 0.62), value: g.slide)
                    .animation(.spring(response: 0.6, dampingFraction: 0.84), value: g.stage)
                    .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.85), value: g.pos)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Soft glow on a screen edge that follows the file along the edge and swells as it gets closer.
struct EdgeGlow: View {
    let depth: Double
    let edge: AirEdge
    var pos: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let thick = 36 + 170 * depth
            let span = 320 + 140 * depth
            let vertical = edge == .left || edge == .right
            Ellipse()
                .fill(Theme.gradient)
                .frame(width: vertical ? thick * 2 : span, height: vertical ? span : thick * 2)
                .blur(radius: 34)
                .opacity(depth > 0.001 ? 0.3 + 0.5 * depth : 0)
                .position(x: edge == .left ? 0 : edge == .right ? w : min(max(pos * w, 0), w),
                          y: edge == .top ? 0 : edge == .bottom ? h : min(max(pos * h, 0), h))
                .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.9), value: pos)
                .animation(.easeOut(duration: 0.25), value: depth)
        }
        .allowsHitTesting(false)
    }
}
