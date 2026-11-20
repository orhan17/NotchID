import AppKit
import SwiftUI

extension NSScreen {
    /// Real notch size in points, or nil on displays without one.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea else { return nil }
        return CGSize(width: frame.width - l.width - r.width, height: safeAreaInsets.top)
    }
    var notchCenterX: CGFloat {
        if notchSize != nil, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea {
            return frame.minX + l.width + (frame.width - l.width - r.width) / 2
        }
        return frame.midX
    }
    static var primaryNotchScreen: NSScreen {
        screens.first { $0.notchSize != nil } ?? main ?? screens[0]
    }
}

final class NotchPanel: NSPanel {
    static let size = CGSize(width: 820, height: 280)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func position(on screen: NSScreen) {
        let s = Self.size
        setFrame(NSRect(x: screen.notchCenterX - s.width / 2, y: screen.frame.maxY - s.height,
                        width: s.width, height: s.height), display: true)
    }
}

/// Tells other apps that draw in the notch when NotchID is using it, so they can step aside
/// instead of drawing over or under the animation.
enum NotchActivity {
    static let began = Notification.Name("app.notchid.notch.began")
    static let ended = Notification.Name("app.notchid.notch.ended")

    static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default()
            .postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// Drives the Dynamic-Island-style unlock sequence in the notch. The panel lives permanently in a
/// lock-screen-level space (transparent while idle), so it also shows on top of the macOS lock screen.
@MainActor
final class NotchController {
    static let shared = NotchController()
    let model = NotchModel()
    private var installed = false
    private lazy var panel: NotchPanel = {
        let p = NotchPanel()
        let host = NSHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []
        p.contentView = host
        return p
    }()
    private(set) var isRunning = false

    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    func install() {
        let screen = NSScreen.primaryNotchScreen
        if let n = screen.notchSize {
            model.notch = n; model.hasRealNotch = true
        } else {
            model.notch = CGSize(width: 180, height: NSStatusBar.system.thickness); model.hasRealNotch = false
        }
        panel.position(on: screen)
        panel.orderFrontRegardless()
        // Re-assert every time: macOS can move the window out of the space when the screen locks.
        SkyLight.showOnLockScreen(panel)
        installed = true
    }

    /// avatar → Face ID scan (until `verify` returns) → ✓ → `afterRecognized` → "Welcome back" → collapse.
    /// `afterRecognized` returns false if unlocking didn't complete (shows the failure shake instead).
    @discardableResult
    func run(verify: @escaping @MainActor () async -> Bool,
             afterRecognized: (@MainActor () async -> Bool)? = nil) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        NotchActivity.post(NotchActivity.began)
        defer {
            isRunning = false
            NotchActivity.post(NotchActivity.ended)
        }

        install()
        model.name = Store.shared.name
        model.avatar = Store.shared.avatar
        model.phase = .closed

        await pause(0.08)
        model.phase = .avatar
        await pause(0.8)
        model.phase = .scanning
        var ok = await verify()
        if ok {
            model.phase = .success
            await pause(0.8)
            if let afterRecognized { ok = await afterRecognized() }
        }
        if ok {
            model.phase = .welcome
            await pause(2.0)
        } else {
            model.failCount += 1
            model.phase = .failed
            await pause(0.9)
        }
        model.phase = .closed
        await pause(0.6)
        return ok
    }

    /// Short red shake while scanning continues (wrong face).
    func flashFailure() async {
        guard model.phase == .scanning else { return }
        model.failCount += 1
        model.phase = .failed
        await pause(0.9)
        if model.phase == .failed { model.phase = .scanning }
    }
}
