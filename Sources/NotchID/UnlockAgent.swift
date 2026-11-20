import AppKit

/// Watches the macOS lock screen. When the Mac is locked and the display is awake, it scans for the
/// enrolled face and, on a match, unlocks the real lock screen by typing the Keychain-stored password.
@MainActor
final class UnlockAgent {
    static let shared = UnlockAgent()

    private var attempt: Task<Void, Never>?
    private var lastAttemptEnd = Date.distantPast
    private var poll: Timer?
    private var displayAsleep = false
    private var submitting = false
    private(set) var locked = MacSession.isLocked

    enum Readiness { case ready, notEnrolled, noPassword, noCamera, noAccessibility, disabled }

    var readiness: Readiness {
        let store = Store.shared
        if !store.unlockEnabled { return .disabled }
        if !store.isEnrolled { return .notEnrolled }
        if !store.hasPassword { return .noPassword }
        if !FaceEngine.cameraAuthorized { return .noCamera }
        if !Accessibility.granted { return .noAccessibility }
        return .ready
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                let me = UnlockAgent.shared
                me.locked = true
                try? await Task.sleep(for: .seconds(0.8))
                if me.locked && !me.displayAsleep { me.trigger() }
            }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                let me = UnlockAgent.shared
                me.locked = false
                if !me.submitting { me.cancel() } // unlocked by hand → stop scanning
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let me = UnlockAgent.shared
                me.displayAsleep = false
                me.locked = MacSession.isLocked
                if me.locked { me.trigger() }
            }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    UnlockAgent.shared.displayAsleep = true
                    UnlockAgent.shared.cancel()
                }
            }
        }
        // Like raising an iPhone: any mouse/keyboard activity on the lock screen starts a new scan.
        poll = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            Task { @MainActor in
                let me = UnlockAgent.shared
                guard me.locked, !me.displayAsleep, me.attempt == nil,
                      Date().timeIntervalSince(me.lastAttemptEnd) > 2.5,
                      MacSession.secondsSinceAnyInput < 1.0 else { return }
                me.trigger()
            }
        }
    }

    func cancel() {
        attempt?.cancel()
    }

    func trigger() {
        guard attempt == nil, readiness == .ready, !NotchController.shared.isRunning,
              let password = Keychain.read() else { return }
        attempt = Task {
            await run(password: password)
            FaceEngine.shared.stop()
            attempt = nil
            lastAttemptEnd = Date()
        }
    }

    private func run(password: String) async {
        let store = Store.shared
        let prints = store.prints, threshold = Float(store.threshold), blink = store.requireBlink
        let mode = store.afterUnlock

        await NotchController.shared.run(verify: {
            let deadline = Date().addingTimeInterval(12)
            while !Task.isCancelled && Date() < deadline {
                switch await FaceEngine.shared.verify(prints: prints, threshold: threshold,
                                                      requireBlink: blink, timeout: 4) {
                case .matched: return true
                case .cancelled: return false
                case .noFace: continue
                case .noMatch: await NotchController.shared.flashFailure()
                }
            }
            return false
        }, afterRecognized: { [weak self] in
            guard let self else { return false }
            FaceEngine.shared.stop()
            guard self.locked else { return true } // already unlocked (e.g. demo while unlocked)

            if mode == .stayOnLockScreen {
                // Recognised: show the open padlock and wait — like iPhone — for a key press or swipe.
                NotchController.shared.model.phase = .unlocked
                let shownAt = Date()
                while true {
                    if Task.isCancelled || !self.locked { return false }
                    if Date().timeIntervalSince(shownAt) > 60 { return false }
                    let since = MacSession.secondsSinceIntentInput
                    if since < Date().timeIntervalSince(shownAt) - 0.3 { break } // input after padlock appeared
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }

            self.submitting = true
            defer { self.submitting = false }
            await KeyTyper.submitPassword(password)
            // Wait for macOS to confirm.
            for _ in 0..<30 where self.locked {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return !self.locked
        })
    }
}
