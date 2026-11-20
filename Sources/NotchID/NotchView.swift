import AppKit
import SwiftUI

enum Palette {
    static let purple = Color(red: 0.56, green: 0.45, blue: 1.0)
    static let blue = Color(red: 0.38, green: 0.55, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.47, blue: 0.62)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.38)
    static let green = Color(red: 0.25, green: 0.86, blue: 0.48)
    static let red = Color(red: 1.0, green: 0.36, blue: 0.38)
    static let lavender = Color(red: 0.86, green: 0.84, blue: 1.0)
}

// MARK: - Model

@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable { case closed, avatar, scanning, success, failed, unlocked, welcome, notice(String) }

    @Published var phase: Phase = .closed
    @Published var name = ""
    @Published var avatar: NSImage?
    @Published var failCount = 0
    var notch = CGSize(width: 185, height: 32)
    var hasRealNotch = true

    static let welcomeFont = NSFont.systemFont(ofSize: 17, weight: .medium)

    static let hint = "Press any key or swipe up to open"
    static let hintFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static var hintWidth: CGFloat {
        ceil(NSAttributedString(string: hint, attributes: [.font: hintFont]).size().width)
    }

    static let noticeFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static func noticeWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: noticeFont]).size().width)
    }

    var welcomeTextWidth: CGFloat {
        ceil(NSAttributedString(string: "Welcome back, \(name)", attributes: [.font: Self.welcomeFont]).size().width)
    }

    /// Size of the black body (excluding the curved "ears").
    var bodySize: CGSize {
        switch phase {
        case .closed: return notch
        case .welcome: return CGSize(width: max(notch.width + 120, welcomeTextWidth + 72), height: notch.height + 54)
        case .unlocked: return CGSize(width: max(notch.width + 120, Self.hintWidth + 84), height: notch.height + 54)
        case .notice(let text): return CGSize(width: max(notch.width + 120, Self.noticeWidth(text) + 84), height: notch.height + 54)
        default: return CGSize(width: notch.width + 96, height: notch.height + 76)
        }
    }
    var earRadius: CGFloat { phase == .closed ? 6 : 16 }
    var bottomRadius: CGFloat {
        switch phase {
        case .closed: return 10
        case .welcome, .unlocked, .notice: return 26
        default: return 30
        }
    }
}

// MARK: - Shape

/// The notch silhouette: concave "ears" flowing out of the top edge, rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let e = min(ear, r.height / 2), b = min(bottom, r.height - e, (r.width - 2 * e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + b, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - b), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root view

struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let s = model.bodySize
        let open = model.phase != .closed
        let shape = NotchShape(ear: model.earRadius, bottom: model.bottomRadius)

        ZStack(alignment: .top) {
            // Soft light spill around the island.
            Ellipse()
                .fill(LinearGradient(colors: [Palette.purple, Palette.blue], startPoint: .leading, endPoint: .trailing))
                .frame(width: s.width * 1.05, height: s.height * 0.9)
                .blur(radius: 34)
                .offset(y: s.height * 0.25)
                .opacity(open ? (model.phase == .failed ? 0.25 : 0.5) : 0)

            ZStack(alignment: .top) {
                shape.fill(Color.black)
                if open {
                    SparkleField().clipShape(shape).transition(.opacity)
                }
                VStack(spacing: 0) {
                    Color.clear.frame(height: model.notch.height)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: s.width + 2 * model.earRadius, height: s.height)
            .opacity(open || model.hasRealNotch ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.52, dampingFraction: 0.76), value: model.phase)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            switch model.phase {
            case .closed:
                EmptyView()
            case .avatar:
                AvatarView(image: model.avatar, name: model.name, size: 52)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            case .scanning:
                FaceIDGlyph(color: .white)
                    .frame(width: 42, height: 42)
                    .transition(.blurReplace.combined(with: ScaleTransition(0.6)))
            case .failed:
                FaceIDGlyph(color: Palette.red, animate: false)
                    .frame(width: 42, height: 42)
                    .modifier(Shake(trigger: model.failCount))
                    .transition(.opacity)
            case .success:
                CheckGlyph()
                    .frame(width: 42, height: 42)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .unlocked:
                HStack(spacing: 10) {
                    UnlockPadlock()
                    Text(NotchModel.hint)
                        .font(Font(NotchModel.hintFont))
                        .foregroundColor(Palette.lavender)
                        .fixedSize()
                }
                .padding(.bottom, 4)
                .transition(.blurReplace.combined(with: ScaleTransition(0.85)))
            case .notice(let text):
                NoticeView(text: text)
                    .transition(.blurReplace.combined(with: ScaleTransition(0.85)))
            case .welcome:
                (Text("Welcome back, ").foregroundColor(Palette.lavender)
                 + Text(model.name).foregroundColor(Palette.pink))
                    .font(Font(NotchModel.welcomeFont))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.bottom, 4)
                    .transition(.blurReplace.combined(with: ScaleTransition(0.85)))
            }
        }
    }
}

// MARK: - Pieces

/// Why Face ID did not run: a still glyph and one line.
struct NoticeView: View {
    var text: String
    var body: some View {
        HStack(spacing: 10) {
            FaceIDGlyph(color: Palette.orange, animate: false)
                .frame(width: 22, height: 22)
            Text(text)
                .font(Font(NotchModel.noticeFont))
                .foregroundColor(Palette.lavender)
                .fixedSize()
        }
        .padding(.bottom, 4)
    }
}

struct AvatarView: View {
    var image: NSImage?
    var name: String
    var size: CGFloat
    var glow = true

    var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Palette.purple, Palette.pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(initials.isEmpty ? "🙂" : initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(
                AngularGradient(colors: [Palette.purple, Palette.blue, Palette.pink, Palette.orange, Palette.purple],
                                center: .center),
                lineWidth: max(1.5, size * 0.04))
        )
        .shadow(color: Palette.purple.opacity(glow ? 0.9 : 0), radius: size * 0.28)
    }
}

/// Face ID glyph: corner brackets + a face that subtly "looks around" while scanning.
struct FaceIDGlyph: View {
    var color: Color
    var animate = true

    var body: some View {
        TimelineView(.animation(paused: !animate)) { tl in
            let t = animate ? tl.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in
                let w = min(size.width, size.height)
                let lw = w * 0.07
                let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
                let breathe = 1 - 0.05 * (0.5 + 0.5 * sin(t * 3.2))
                let inset = lw / 2 + w * (1 - breathe) / 2
                let span = w - 2 * inset
                func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: inset + x * span, y: inset + y * span) }

                var brackets = Path()
                brackets.move(to: P(0, 0.28)); brackets.addLine(to: P(0, 0.14))
                brackets.addQuadCurve(to: P(0.14, 0), control: P(0, 0)); brackets.addLine(to: P(0.28, 0))
                brackets.move(to: P(0.72, 0)); brackets.addLine(to: P(0.86, 0))
                brackets.addQuadCurve(to: P(1, 0.14), control: P(1, 0)); brackets.addLine(to: P(1, 0.28))
                brackets.move(to: P(1, 0.72)); brackets.addLine(to: P(1, 0.86))
                brackets.addQuadCurve(to: P(0.86, 1), control: P(1, 1)); brackets.addLine(to: P(0.72, 1))
                brackets.move(to: P(0.28, 1)); brackets.addLine(to: P(0.14, 1))
                brackets.addQuadCurve(to: P(0, 0.86), control: P(0, 1)); brackets.addLine(to: P(0, 0.72))
                ctx.stroke(brackets, with: .color(color), style: style)

                let dx = CGFloat(sin(t * 1.9)) * 0.05, dy = CGFloat(cos(t * 1.4)) * 0.03
                func F(_ x: CGFloat, _ y: CGFloat) -> CGPoint { P(x + dx, y + dy) }
                var face = Path()
                face.move(to: F(0.34, 0.35)); face.addLine(to: F(0.34, 0.45))          // left eye
                face.move(to: F(0.66, 0.35)); face.addLine(to: F(0.66, 0.45))          // right eye
                face.move(to: F(0.51, 0.35)); face.addLine(to: F(0.51, 0.58))          // nose
                face.addLine(to: F(0.45, 0.58))
                face.move(to: F(0.35, 0.69))                                           // smile
                face.addQuadCurve(to: F(0.65, 0.69), control: F(0.5, 0.8))
                ctx.stroke(face, with: .color(color), style: style)
            }
        }
    }
}

/// `@State` replacement (the Command Line Tools SDK can't expand SwiftUI's @State macro).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

struct CheckGlyph: View {
    @StateObject private var p = Box<CGFloat>(0)
    private var progress: CGFloat { p.value }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Palette.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckPath()
                .trim(from: 0, to: progress)
                .stroke(Palette.green, style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: Palette.green.opacity(0.6), radius: 8)
        .onAppear { withAnimation(.easeOut(duration: 0.45).delay(0.05)) { p.value = 1 } }
    }

    struct CheckPath: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX + r.width * 0.29, y: r.minY + r.height * 0.52))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.67))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.36))
            return p
        }
    }
}

struct Shake: ViewModifier {
    var trigger: Int
    @StateObject private var t = Box<CGFloat>(0)
    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(t: t.value))
            .onAppear { t.value = 0; withAnimation(.linear(duration: 0.5)) { t.value = 1 } }
            .onChange(of: trigger) { t.value = 0; withAnimation(.linear(duration: 0.5)) { t.value = 1 } }
    }
}

struct ShakeEffect: GeometryEffect {
    var t: CGFloat
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(t * .pi * 6) * 9 * (1 - t), y: 0))
    }
}

/// Twinkling particles inside the island.
struct SparkleField: View {
    struct Star { let x, y, r, phase, speed: Double }
    private static let stars: [Star] = (0..<46).map { _ in
        Star(x: .random(in: 0...1), y: .random(in: 0.25...1), r: .random(in: 0.5...1.4),
             phase: .random(in: 0...(2 * .pi)), speed: .random(in: 1.2...3.5))
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for s in Self.stars {
                    let a = 0.08 + 0.55 * (0.5 + 0.5 * sin(t * s.speed + s.phase))
                    let rect = CGRect(x: s.x * size.width, y: s.y * size.height, width: s.r * 2, height: s.r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Palette.lavender.opacity(a)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Closed padlock that springs open (iPhone lock-screen style).
struct UnlockPadlock: View {
    @StateObject private var open = Box(false)
    var body: some View {
        Image(systemName: open.value ? "lock.open.fill" : "lock.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 22)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { open.value = true }
                }
            }
    }
}
