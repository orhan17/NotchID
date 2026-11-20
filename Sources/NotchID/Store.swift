import AppKit
import Vision

enum AfterUnlock: String, CaseIterable, Identifiable {
    case openDesktop, stayOnLockScreen
    var id: String { rawValue }
}

/// Persists settings (UserDefaults) and the enrolled face (Application Support, never leaves the Mac).
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    private let defaults = UserDefaults.standard

    @Published var name: String { didSet { defaults.set(name, forKey: "name") } }
    @Published var threshold: Double { didSet { defaults.set(threshold, forKey: "threshold") } }
    @Published var requireBlink: Bool { didSet { defaults.set(requireBlink, forKey: "requireBlink") } }
    @Published var unlockEnabled: Bool { didSet { defaults.set(unlockEnabled, forKey: "unlockEnabled") } }
    @Published var afterUnlock: AfterUnlock { didSet { defaults.set(afterUnlock.rawValue, forKey: "afterUnlock") } }
    @Published private(set) var prints: [VNFeaturePrintObservation] = []
    @Published private(set) var avatar: NSImage?
    @Published private(set) var hasPassword: Bool

    var isEnrolled: Bool { !prints.isEmpty }

    private var dir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchID", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var printsURL: URL { dir.appendingPathComponent("face.prints") }
    private var avatarURL: URL { dir.appendingPathComponent("avatar.png") }

    private init() {
        let fullName = NSFullUserName()
        name = defaults.string(forKey: "name") ?? (fullName.split(separator: " ").first.map(String.init) ?? fullName)
        threshold = defaults.object(forKey: "threshold") as? Double ?? 0.4
        requireBlink = defaults.bool(forKey: "requireBlink")
        unlockEnabled = defaults.object(forKey: "unlockEnabled") as? Bool ?? true
        afterUnlock = AfterUnlock(rawValue: defaults.string(forKey: "afterUnlock") ?? "") ?? .openDesktop
        hasPassword = Keychain.hasPassword
        // Feature prints archive nested dictionaries/values (e.g. timeRange), so those classes must be allowed.
        if let data = try? Data(contentsOf: printsURL),
           let arr = try? NSKeyedUnarchiver.unarchivedObject(
               ofClasses: [NSArray.self, NSDictionary.self, NSValue.self, NSNumber.self, NSString.self,
                           NSData.self, NSUUID.self, NSDate.self, VNFeaturePrintObservation.self],
               from: data) as? [VNFeaturePrintObservation] {
            prints = arr
        }
        avatar = NSImage(contentsOf: avatarURL)
    }

    func saveEnrollment(prints: [VNFeaturePrintObservation], threshold: Double, avatar cg: CGImage?) {
        self.prints = prints
        self.threshold = threshold
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: prints, requiringSecureCoding: true) {
            try? data.write(to: printsURL, options: .atomic)
        }
        if let cg {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: avatarURL)
            avatar = NSImage(cgImage: cg, size: .zero)
        }
    }

    func resetFace() {
        prints = []
        avatar = nil
        try? FileManager.default.removeItem(at: printsURL)
        try? FileManager.default.removeItem(at: avatarURL)
    }

    /// Verifies the password against the user's macOS account, then stores it in the Keychain.
    func savePassword(_ password: String) -> Bool {
        guard Keychain.verifyLoginPassword(password), Keychain.save(password) else { return false }
        hasPassword = true
        return true
    }

    func forgetPassword() {
        Keychain.delete()
        hasPassword = false
    }
}
