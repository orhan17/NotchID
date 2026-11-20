import AppKit
import SwiftUI

// README screenshot renderer: `NotchID --render-screenshots <dir>`.
//
// Everything here is drawn offscreen with fake data only: an illustrated cartoon face and the name
// "Alex". Nothing is read from Store.shared, the camera or ~/Library/Application Support/NotchID.

private enum Shot {
    static let name = "Alex"
}

// MARK: - Entry point

@MainActor
func renderScreenshots(to dir: String) {
    // AppKit-backed controls (settings form) need a launched, active app to draw in their active style.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let avatar = snapshot(FakeFace(turn: .zero).frame(width: 160, height: 160), scale: 2)

    // Individual notch phases + a labelled grid.
    let phases: [(String, String, NotchModel.Phase)] = [
        ("avatar", "Your avatar appears", .avatar),
        ("scanning", "Face ID scans", .scanning),
        ("success", "Recognised", .success),
        ("unlocked", "Optional: press a key or swipe", .unlocked),
        ("welcome", "Welcome back", .welcome),
        ("failed", "Not you: shake", .failed),
    ]
    for (file, _, phase) in phases {
        save(PhaseTile(phase: phase, avatar: avatar), to: out, "notch-\(file)")
    }
    save(PhaseGrid(items: phases.map { ($0.1, $0.2) }, avatar: avatar), to: out, "notch-phases")

    // Enrolment.
    save(WindowChrome(title: nil, dark: true) { EnrollScanningShot() }, to: out, "enroll-scanning")
    save(WindowChrome(title: nil, dark: true) { EnrollDoneShot() }, to: out, "enroll-done")

    // Settings (real AppKit controls, so it's rendered through an offscreen window).
    let settings = renderSettings(avatar: avatar)
    if let settings {
        save(WindowChrome(title: "NotchID Settings", dark: true) {
            Image(nsImage: settings).resizable().frame(width: settings.size.width, height: settings.size.height)
        }, to: out, "settings")
    }

    // Hero: pre-render the windows so they can be scaled as flat images.
    let enrollWin = snapshot(WindowChrome(title: nil, dark: true) { EnrollScanningShot() }.environment(\.colorScheme, .dark))
    let settingsWin = settings.flatMap { s in snapshot(WindowChrome(title: "NotchID Settings", dark: true) {
        Image(nsImage: s).resizable().frame(width: s.size.width, height: s.size.height)
    }.environment(\.colorScheme, .dark)) }
    save(Hero(avatar: avatar, enroll: enrollWin, settings: settingsWin), to: out, "hero")
    print("Rendered screenshots to \(out.path)")
}

@MainActor
private func snapshot<V: View>(_ view: V, scale: CGFloat = 2) -> NSImage? {
    let r = ImageRenderer(content: view)
    r.scale = scale
    return r.nsImage
}

@MainActor
private func save<V: View>(_ view: V, to dir: URL, _ name: String) {
    let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    r.scale = 2
    guard let cg = r.cgImage,
          let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        print("⚠️ failed to render \(name)"); return
    }
    try? data.write(to: dir.appendingPathComponent("\(name).png"))
}

// MARK: - Fake illustrated face

/// A simple cartoon person. `turn` (−1…1) shifts the features to suggest a head turned/tilted.
struct FakeFace: View {
    var turn: CGPoint
    var background = true

    private let skin = Color(red: 0.96, green: 0.78, blue: 0.62)
    private let skinShade = Color(red: 0.89, green: 0.66, blue: 0.50)
    private let hair = Color(red: 0.30, green: 0.20, blue: 0.16)
    private let shirt = Color(red: 0.36, green: 0.52, blue: 0.95)

    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height)
            let dx = turn.x * w * 0.07, dy = turn.y * w * 0.05
            ZStack {
                if background {
                    LinearGradient(colors: [Color(red: 0.55, green: 0.75, blue: 0.95), Color(red: 0.80, green: 0.70, blue: 0.95)],
                                   startPoint: .top, endPoint: .bottom)
                }
                // Shoulders
                Ellipse().fill(shirt)
                    .frame(width: w * 0.92, height: w * 0.5)
                    .offset(x: dx * 0.3, y: w * 0.47)
                // Neck
                RoundedRectangle(cornerRadius: w * 0.04).fill(skinShade)
                    .frame(width: w * 0.2, height: w * 0.2)
                    .offset(x: dx * 0.4, y: w * 0.24)
                // Hair back
                Ellipse().fill(hair)
                    .frame(width: w * 0.58, height: w * 0.6)
                    .offset(x: dx * 0.5, y: -w * 0.07 + dy * 0.5)
                // Ears
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Ellipse().fill(skinShade)
                        .frame(width: w * 0.09, height: w * 0.13)
                        .offset(x: side * w * 0.255 + dx * 0.5, y: w * 0.0 + dy * 0.6)
                }
                // Head
                Ellipse().fill(skin)
                    .frame(width: w * 0.5, height: w * 0.58)
                    .offset(x: dx * 0.6, y: dy * 0.6)
                // Fringe
                FringeShape().fill(hair)
                    .frame(width: w * 0.54, height: w * 0.26)
                    .offset(x: dx * 0.6, y: -w * 0.2 + dy * 0.6)
                // Features
                Group {
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Capsule().fill(hair.opacity(0.85))
                            .frame(width: w * 0.08, height: w * 0.018)
                            .offset(x: side * w * 0.1, y: -w * 0.075)
                        Ellipse().fill(Color(red: 0.18, green: 0.13, blue: 0.12))
                            .frame(width: w * 0.045, height: w * 0.06)
                            .offset(x: side * w * 0.1, y: -w * 0.02)
                        Circle().fill(Color.white.opacity(0.9))
                            .frame(width: w * 0.015)
                            .offset(x: side * w * 0.1 + w * 0.01, y: -w * 0.03)
                        Ellipse().fill(Color(red: 1.0, green: 0.55, blue: 0.55).opacity(0.35))
                            .frame(width: w * 0.08, height: w * 0.045)
                            .offset(x: side * w * 0.15, y: w * 0.06)
                    }
                    Capsule().fill(skinShade)
                        .frame(width: w * 0.035, height: w * 0.08)
                        .offset(y: w * 0.04)
                    SmileShape()
                        .stroke(Color(red: 0.55, green: 0.25, blue: 0.22), style: StrokeStyle(lineWidth: w * 0.022, lineCap: .round))
                        .frame(width: w * 0.16, height: w * 0.06)
                        .offset(y: w * 0.13)
                }
                .offset(x: dx, y: dy)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    struct FringeShape: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addCurve(to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + r.height * 0.2),
                       control2: CGPoint(x: r.minX + r.width * 0.2, y: r.minY))
            p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY), control1: CGPoint(x: r.maxX - r.width * 0.2, y: r.minY),
                       control2: CGPoint(x: r.maxX, y: r.minY + r.height * 0.2))
            p.addQuadCurve(to: CGPoint(x: r.midX + r.width * 0.12, y: r.minY + r.height * 0.55),
                           control: CGPoint(x: r.maxX - r.width * 0.15, y: r.minY + r.height * 0.5))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY),
                           control: CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.45))
            p.closeSubpath()
            return p
        }
    }

    struct SmileShape: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6))
            return p
        }
    }
}

// MARK: - Desktop pieces

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.10, blue: 0.30), Color(red: 0.22, green: 0.12, blue: 0.40)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                blob(Color(red: 0.45, green: 0.35, blue: 0.95), w * 0.9, x: w * 0.15, y: h * 0.05)
                blob(Color(red: 0.95, green: 0.42, blue: 0.62), w * 0.8, x: w * 0.85, y: h * 0.35)
                blob(Color(red: 1.0, green: 0.62, blue: 0.38), w * 0.7, x: w * 0.55, y: h * 1.05)
                blob(Color(red: 0.25, green: 0.55, blue: 0.98), w * 0.6, x: w * -0.05, y: h * 0.9)
            }
            .blur(radius: 60)
        }
        .clipped()
    }

    private func blob(_ c: Color, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle().fill(RadialGradient(colors: [c.opacity(0.95), c.opacity(0)], center: .center,
                                     startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .position(x: x, y: y)
    }
}

struct FakeMenuBar: View {
    var height: CGFloat = 32
    var compact = false

    var body: some View {
        HStack(spacing: 18) {
            if !compact {
                Text("Finder").fontWeight(.bold)
                ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
            }
            Spacer()
            HStack(spacing: 16) {
                Image(systemName: "faceid").font(.system(size: 15, weight: .medium))
                if !compact {
                    Image(systemName: "battery.75percent")
                    Image(systemName: "wifi")
                    Image(systemName: "magnifyingglass")
                    Image(systemName: "switch.2")
                    Text("Fri 20 Nov  9:41")
                }
            }
        }
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: height)
        .background(Color.black.opacity(0.22))
    }
}

/// Static version of NotchView for a given phase (NotchView's own glyphs animate in on appear,
/// which an offscreen renderer can't capture).
struct ShotNotch: View {
    let phase: NotchModel.Phase
    let avatar: NSImage?
    let model: NotchModel

    init(phase: NotchModel.Phase, avatar: NSImage?) {
        self.phase = phase
        self.avatar = avatar
        let m = NotchModel()
        m.phase = phase
        m.name = Shot.name
        m.avatar = avatar
        self.model = m
    }

    var body: some View {
        let s = model.bodySize
        let shape = NotchShape(ear: model.earRadius, bottom: model.bottomRadius)
        ZStack(alignment: .top) {
            Ellipse()
                .fill(LinearGradient(colors: [Palette.purple, Palette.blue], startPoint: .leading, endPoint: .trailing))
                .frame(width: s.width * 1.05, height: s.height * 0.9)
                .blur(radius: 34)
                .offset(y: s.height * 0.25)
                .opacity(phase == .failed ? 0.25 : 0.5)
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                StaticSparkles().clipShape(shape)
                VStack(spacing: 0) {
                    Color.clear.frame(height: model.notch.height)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: s.width + 2 * model.earRadius, height: s.height)
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .closed: EmptyView()
        case .avatar:
            AvatarView(image: avatar, name: Shot.name, size: 52)
        case .scanning:
            FaceIDGlyph(color: .white, animate: false).frame(width: 42, height: 42)
        case .failed:
            FaceIDGlyph(color: Palette.red, animate: false).frame(width: 42, height: 42)
        case .success:
            StaticCheck(lineWidth: 3).frame(width: 42, height: 42)
        case .unlocked:
            HStack(spacing: 10) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22)
                Text(NotchModel.hint)
                    .font(Font(NotchModel.hintFont))
                    .foregroundColor(Palette.lavender)
                    .fixedSize()
            }
            .padding(.bottom, 4)
        case .welcome:
            (Text("Welcome back, ").foregroundColor(Palette.lavender) + Text(Shot.name).foregroundColor(Palette.pink))
                .font(Font(NotchModel.welcomeFont))
                .fixedSize()
                .padding(.bottom, 4)
        }
    }
}

struct StaticCheck: View {
    var lineWidth: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(Palette.green, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            CheckGlyph.CheckPath()
                .stroke(Palette.green, style: StrokeStyle(lineWidth: lineWidth * 1.2, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: Palette.green.opacity(0.6), radius: 8)
    }
}

struct StaticSparkles: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / Double(1 << 53)
            }
            for _ in 0..<46 {
                let x = rnd(), y = 0.25 + rnd() * 0.75, r = 0.5 + rnd() * 0.9, a = 0.08 + 0.55 * rnd()
                ctx.fill(Path(ellipseIn: CGRect(x: x * size.width, y: y * size.height, width: r * 2, height: r * 2)),
                         with: .color(Palette.lavender.opacity(a)))
            }
        }
    }
}

/// A slice of desktop (wallpaper + menu bar) with the notch open in `phase`.
struct PhaseTile: View {
    let phase: NotchModel.Phase
    let avatar: NSImage?
    var width: CGFloat = 440
    var height: CGFloat = 170

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            FakeMenuBar(compact: true).opacity(0.0) // keeps the menu bar band tone consistent
            Rectangle().fill(Color.black.opacity(0.22)).frame(height: 32)
            ShotNotch(phase: phase, avatar: avatar)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct PhaseGrid: View {
    let items: [(String, NotchModel.Phase)]
    let avatar: NSImage?

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(spacing: 22) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 22) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        let i = r * 3 + c
                        VStack(spacing: 10) {
                            PhaseTile(phase: rows[r][c].1, avatar: avatar, width: 400, height: 160)
                                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(Color.white.opacity(0.15)))
                                Text(rows[r][c].0).font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }
        }
        .padding(30)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }
}

/// macOS-style window frame with traffic lights.
struct WindowChrome<Content: View>: View {
    let title: String?
    let dark: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12)
                    Spacer()
                }
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(title == nil ? Color.black : Color(red: 0.17, green: 0.17, blue: 0.18))
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .padding(36)
        .background(Color.clear)
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }
}

// MARK: - Enrolment mocks

/// Same look as ScanRing, with an illustrated face instead of the live camera.
struct ShotScanRing: View {
    let ticks: [Bool]
    var turn: CGPoint
    var diameter: CGFloat = 250

    var body: some View {
        ZStack {
            FakeFace(turn: turn)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            ForEach(0..<ticks.count, id: \.self) { i in
                let lit = ticks[i]
                Capsule()
                    .fill(lit ? Palette.green : Color.white.opacity(0.32))
                    .frame(width: 3, height: lit ? 22 : 13)
                    .offset(y: -(diameter / 2 + 14 + (lit ? 11 : 6.5)))
                    .rotationEffect(.degrees(Double(i) * 360 / Double(ticks.count)))
            }
        }
        .frame(width: diameter + 90, height: diameter + 90)
    }
}

private struct ShotButton: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Palette.blue.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
    }
}

private struct EnrollFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 44)
            .padding(.top, 36)
            .padding(.bottom, 32)
            .frame(width: 460, height: 620)
            .background(Color.black)
            .foregroundStyle(.white)
    }
}

struct EnrollScanningShot: View {
    var body: some View {
        // Lit arc from roughly 10 o'clock round to 4 o'clock: the user has rolled their head over the top.
        let n = EnrollModel.tickCount
        let ticks = (0..<n).map { i -> Bool in
            let deg = Double(i) * 360 / Double(n)
            return deg >= 290 || deg <= 125
        }
        EnrollFrame {
            VStack(spacing: 18) {
                Text("Face ID").font(.system(size: 22, weight: .bold))
                ShotScanRing(ticks: ticks, turn: CGPoint(x: 0.9, y: -0.6))
                Text("Move your head slowly to complete the circle.")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).frame(height: 44)
                Spacer(minLength: 0)
                Text("Cancel").foregroundStyle(Palette.blue).frame(height: 44)
            }
        }
    }
}

struct EnrollDoneShot: View {
    var body: some View {
        EnrollFrame {
            VStack(spacing: 22) {
                Spacer()
                StaticCheck(lineWidth: 6).frame(width: 110, height: 110)
                Text("Face ID is now set up.").font(.system(size: 26, weight: .bold))
                Text("Lock your Mac and look at it to unlock.")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                ShotButton(title: "Done")
            }
        }
    }
}

// MARK: - Settings mock

/// Mirrors SettingsView's layout with fixed fake values (SettingsView itself reads the real Store).
struct SettingsShot: View {
    let avatar: NSImage?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AvatarView(image: avatar, name: Shot.name, size: 54, glow: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Face ID is set up").font(.headline)
                        Text("Ready — lock your Mac and look at it").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Set Up Again…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor))
                }
                .padding(.vertical, 4)
            }

            Section("Unlocking") {
                Toggle("Unlock this Mac with Face ID", isOn: .constant(true))
                Picker("When Face ID recognises you", selection: .constant(AfterUnlock.openDesktop)) {
                    Text("Open the desktop").tag(AfterUnlock.openDesktop)
                    Text("Stay on Lock Screen until I press a key or swipe").tag(AfterUnlock.stayOnLockScreen)
                }
                .pickerStyle(.radioGroup)
                Toggle("Require a blink (stops photos from unlocking)", isOn: .constant(true))
                LabeledContent("Strictness") {
                    HStack {
                        Text("Loose").font(.caption).foregroundStyle(.secondary)
                        Slider(value: .constant(0.6), in: 0.2...0.85)
                        Text("Strict").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    Button("Test") {}
                } label: {
                    Text("Test recognition")
                    Text("✅ Recognised — this would unlock")
                }
            }

            Section {
                LabeledContent("Mac login password") {
                    HStack {
                        Label("Saved in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Change…") {}
                        Button("Remove") {}
                    }
                }
            } header: {
                Text("Password")
            } footer: {
                Text("macOS doesn't let apps unlock the Lock Screen directly, so after recognising you NotchID types your login password for you. It's checked against your account and kept in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                row("Camera", "To see your face")
                row("Accessibility", "To type your password on the Lock Screen")
            }

            Section("General") {
                TextField("Your name", text: .constant(Shot.name))
                Toggle("Open NotchID at login", isOn: .constant(true))
                LabeledContent("Try it") { Button("Lock Screen Now") {} }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(ActiveSwitch())
    }

    /// macOS switch drawn in its active (key window) look; offscreen windows always draw inactive.
    struct ActiveSwitch: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            LabeledContent {
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.white.opacity(0.2))
                    .frame(width: 26, height: 15)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 13).padding(1)
                            .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
                    }
            } label: { configuration.label }
        }
    }

    private func row(_ title: String, _ detail: String) -> some View {
        LabeledContent {
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// Renders the settings mock through a real (offscreen) window so AppKit-backed controls draw.
@MainActor
private func renderSettings(avatar: NSImage?) -> NSImage? {
    let size = NSSize(width: 520, height: 880)
    let host = NSHostingView(rootView: SettingsShot(avatar: avatar).frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let window = KeyableWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFrontRegardless()
    window.makeKey()
    NSApp.activate(ignoringOtherApps: true)
    for _ in 0..<5 {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    window.orderOut(nil)
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    return img
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Hero

struct Hero: View {
    let avatar: NSImage?
    let enroll: NSImage?
    let settings: NSImage?

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            FakeMenuBar(height: 32)
            ShotNotch(phase: .success, avatar: avatar)
            HStack(alignment: .center, spacing: 40) {
                window(enroll, height: 600)
                window(settings, height: 640)
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 110)
        }
        .frame(width: 1280, height: 800)
    }

    @ViewBuilder private func window(_ img: NSImage?, height: CGFloat) -> some View {
        if let img {
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: img.size.width * height / img.size.height, height: height)
        }
    }
}
