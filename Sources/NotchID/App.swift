import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-phases"), i + 1 < args.count {
            MainActor.assumeIsolated { renderPhases(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--render-screenshots"), i + 1 < args.count {
            MainActor.assumeIsolated { renderScreenshots(to: args[i + 1]) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var enrollWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "NotchID")
        statusItem.autosaveName = "NotchID" // keeps the place you ⌘-drag it to
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotchController.shared.install()
        UnlockAgent.shared.start()

        if !Store.shared.isEnrolled { openEnrollment() }
        else if UnlockAgent.shared.readiness != .ready { openSettings() }
    }

    /// Opening NotchID again (Finder, Spotlight, `open`) shows Settings: on a crowded menu bar the
    /// icon can end up hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = Store.shared
        let status: String
        switch UnlockAgent.shared.readiness {
        case .ready: status = "Face ID unlock is on"
        case .disabled: status = "Face ID unlock is off"
        case .notEnrolled: status = "Face ID is not set up"
        default: status = UnlockAgent.shared.readiness.notice ?? "Finish setup in Settings"
        }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let toggle = item("Unlock with Face ID", #selector(toggleUnlock))
        toggle.state = store.unlockEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(item("Lock Screen", #selector(lockNow), key: "l"))
        menu.addItem(item("Play Unlock Animation", #selector(preview)))
        menu.addItem(.separator())
        menu.addItem(item("Set Up Face ID…", #selector(openEnrollment)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit NotchID", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func lockNow() { MacSession.lockNow() }
    @objc private func toggleUnlock() { Store.shared.unlockEnabled.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func preview() {
        Task {
            await NotchController.shared.run(verify: {
                try? await Task.sleep(for: .seconds(2.2))
                return true
            })
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(openEnrollment: { [weak self] in self?.openEnrollment() })))
            w.title = "NotchID Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            settingsWindow = w
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openEnrollment() {
        if enrollWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: EnrollView(onClose: { [weak self] in self?.enrollWindow?.close() })))
            w.title = ""
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.delegate = self
            enrollWindow = w
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        enrollWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === enrollWindow {
            enrollWindow = nil
            FaceEngine.shared.stop()
            if Store.shared.isEnrolled && UnlockAgent.shared.readiness != .ready {
                DispatchQueue.main.async { self.openSettings() }
            }
        }
        if w === settingsWindow { settingsWindow = nil }
    }
}

/// Debug helper: snapshots every notch phase to PNGs (no camera, no windows).
@MainActor
func renderPhases(to dir: String) {
    let phases: [(String, NotchModel.Phase)] = [("1-avatar", .avatar), ("2-scanning", .scanning),
        ("3-success", .success), ("4-failed", .failed), ("5-unlocked", .unlocked), ("6-welcome", .welcome),
        ("7-notice", .notice(UnlockAgent.Readiness.noPassword.notice ?? ""))]
    for (name, phase) in phases {
        let model = NotchModel()
        model.name = Store.shared.name
        model.avatar = Store.shared.avatar
        model.phase = phase
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Palette.orange, Palette.pink], startPoint: .top, endPoint: .bottom)
            NotchView(model: model)
        }.frame(width: NotchPanel.size.width, height: NotchPanel.size.height)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.cgImage {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
