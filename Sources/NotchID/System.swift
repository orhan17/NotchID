import AppKit
import Carbon
import OpenDirectory
import Security

// MARK: - Keychain (the Mac login password, used to unlock the real lock screen)

enum Keychain {
    private static let service = "app.notchid.login-password"
    private static var account: String { NSUserName() }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var hasPassword: Bool {
        var q = baseQuery
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String) -> Bool {
        delete()
        var q = baseQuery
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "NotchID – Mac login password"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(baseQuery as CFDictionary) }

    /// Checks the password against the local account via Open Directory.
    static func verifyLoginPassword(_ password: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }
}

// MARK: - Session state / locking

enum MacSession {
    static var isLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Locks the screen immediately (same as  › Lock Screen).
    static func lockNow() {
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            typealias Fn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: Fn.self)()
        }
    }

    /// Seconds since the user last pressed a key, clicked or scrolled/swiped.
    static var secondsSinceIntentInput: Double {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// Any input incl. mouse movement (used to "raise to wake" a new scan while locked).
    static var secondsSinceAnyInput: Double {
        min(secondsSinceIntentInput, CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved))
    }
}

// MARK: - Accessibility permission (needed to type the password into the lock screen)

enum Accessibility {
    static var granted: Bool { CGPreflightPostEventAccess() }
    static func request() {
        if !CGRequestPostEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

// MARK: - Typing into the lock screen

enum KeyTyper {
    private static let kReturn: CGKeyCode = 36, kDelete: CGKeyCode = 51, kA: CGKeyCode = 0, kShift: CGKeyCode = 56

    /// Wakes the password field, clears it, types the password and presses Return.
    static func submitPassword(_ password: String) async {
        let map = keyMap()
        press(kShift, flags: .maskShift) // reveals the password field without typing anything
        try? await Task.sleep(for: .milliseconds(350))
        press(kA, flags: .maskCommand)   // select anything the user already typed…
        press(kDelete)                    // …and clear it
        try? await Task.sleep(for: .milliseconds(60))
        for ch in password {
            if let (code, flags) = map[ch] {
                press(code, flags: flags)
            } else {
                typeUnicode(ch)
            }
            try? await Task.sleep(for: .milliseconds(12))
        }
        try? await Task.sleep(for: .milliseconds(60))
        press(kReturn)
    }

    private static func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func typeUnicode(_ ch: Character) {
        let src = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Character → (key code, modifiers) for the current keyboard layout.
    private static func keyMap() -> [Character: (CGKeyCode, CGEventFlags)] {
        var map: [Character: (CGKeyCode, CGEventFlags)] = [:]
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return map }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let states: [(UInt32, CGEventFlags)] = [(0, []), (UInt32(shiftKey >> 8), .maskShift),
                                                (UInt32(optionKey >> 8), .maskAlternate),
                                                (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for (state, flags) in states {
                for code in 0..<128 {
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), state,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &dead, 4, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let s = String(utf16CodeUnits: chars, count: length)
                    if s.count == 1, let c = s.first, map[c] == nil, !c.isNewline {
                        map[c] = (CGKeyCode(code), flags)
                    }
                }
            }
        }
        return map
    }
}

// MARK: - SkyLight: show a window above the lock screen

/// Moves a window into a private high-level space so it stays visible on the macOS lock screen
/// (the same technique notch utilities use). Silently does nothing if the private API is missing.
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
    private static func fn<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private static var space: (conn: Int32, id: Int32)? = {
        guard let main = fn("SLSMainConnectionID", as: MainConnection.self),
              let create = fn("SLSSpaceCreate", as: SpaceCreate.self),
              let level = fn("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let show = fn("SLSShowSpaces", as: ShowSpaces.self) else { return nil }
        let conn = main()
        let id = create(conn, 1, 0)
        _ = level(conn, id, 100)
        _ = show(conn, [id] as CFArray)
        return (conn, id)
    }()

    static func showOnLockScreen(_ window: NSWindow) {
        guard let space, let add = fn("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self) else { return }
        _ = add(space.conn, space.id, [window.windowNumber] as CFArray, 7)
    }
}
