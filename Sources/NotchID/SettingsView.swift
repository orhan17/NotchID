import ServiceManagement
import SwiftUI

@MainActor
final class SettingsState: ObservableObject {
    @Published var camera = FaceEngine.cameraAuthorized
    @Published var accessibility = Accessibility.granted
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    @Published var password = ""
    @Published var passwordError = false
    @Published var editingPassword = false
    @Published var testing = false
    @Published var testMessage = ""
    var testTask: Task<Void, Never>?
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.camera = FaceEngine.cameraAuthorized
                self?.accessibility = Accessibility.granted
            }
        }
    }
    deinit { timer?.invalidate() }
}

struct SettingsView: View {
    @ObservedObject var store = Store.shared
    @StateObject private var ui = SettingsState()
    var openEnrollment: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AvatarView(image: store.avatar, name: store.name, size: 54, glow: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.isEnrolled ? "Face ID is set up" : "Face ID is not set up").font(.headline)
                        Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.isEnrolled ? "Set Up Again…" : "Set Up Face ID…") { openEnrollment() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }

            Section("Unlocking") {
                Toggle("Unlock this Mac with Face ID", isOn: $store.unlockEnabled)
                Picker("When Face ID recognises you", selection: $store.afterUnlock) {
                    Text("Open the desktop").tag(AfterUnlock.openDesktop)
                    Text("Stay on Lock Screen until I press a key or swipe").tag(AfterUnlock.stayOnLockScreen)
                }
                .pickerStyle(.radioGroup)
                Toggle("Require a blink (stops photos from unlocking)", isOn: $store.requireBlink)
                LabeledContent("Strictness") {
                    HStack {
                        Text("Loose").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { 1.0 - store.threshold }, set: { store.threshold = 1.0 - $0 }),
                               in: 0.2...0.85)
                        Text("Strict").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    Button(ui.testing ? "Stop" : "Test") { toggleTest() }.disabled(!store.isEnrolled)
                } label: {
                    Text("Test recognition")
                    if !ui.testMessage.isEmpty { Text(ui.testMessage) }
                }
            }

            Section {
                if store.hasPassword && !ui.editingPassword {
                    LabeledContent("Mac login password") {
                        HStack {
                            Label("Saved in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Button("Change…") { ui.editingPassword = true }
                            Button("Remove") { store.forgetPassword() }
                        }
                    }
                } else {
                    LabeledContent("Mac login password") {
                        HStack {
                            SecureField("", text: $ui.password, prompt: Text("Password for \(NSUserName())"))
                                .frame(width: 190)
                                .onSubmit(savePassword)
                            Button("Save", action: savePassword).disabled(ui.password.isEmpty)
                        }
                    }
                    if ui.passwordError {
                        Text("That isn't your Mac login password.").foregroundStyle(.red).font(.caption)
                    }
                }
            } header: {
                Text("Password")
            } footer: {
                Text("macOS doesn't let apps unlock the Lock Screen directly, so after recognising you NotchID types your login password for you. It's checked against your account and kept in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                permissionRow("Camera", ok: ui.camera, detail: "To see your face") {
                    Task {
                        if !(await FaceEngine.authorize()) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                        }
                    }
                }
                permissionRow("Accessibility", ok: ui.accessibility, detail: "To type your password on the Lock Screen") {
                    Accessibility.request()
                }
            }

            Section("General") {
                TextField("Your name", text: $store.name)
                Toggle("Open NotchID at login", isOn: Binding(get: { ui.loginItem }, set: setLoginItem))
                LabeledContent("Try it") {
                    Button("Lock Screen Now") { MacSession.lockNow() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .onDisappear { ui.testTask?.cancel() }
    }

    private var statusLine: String {
        switch UnlockAgent.shared.readiness {
        case .ready: return "Ready — lock your Mac and look at it"
        case .disabled: return "Unlocking is turned off"
        case .notEnrolled: return "Scan your face to get started"
        case .noPassword: return "Add your Mac password below"
        case .noCamera: return "Allow camera access below"
        case .noAccessibility: return "Allow Accessibility below"
        }
    }

    private func permissionRow(_ title: String, ok: Bool, detail: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            if ok {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private func savePassword() {
        let ok = store.savePassword(ui.password)
        ui.passwordError = !ok
        if ok { ui.password = ""; ui.editingPassword = false }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        ui.loginItem = SMAppService.mainApp.status == .enabled
    }

    private func toggleTest() {
        if ui.testing {
            ui.testTask?.cancel(); ui.testTask = nil; ui.testing = false; ui.testMessage = ""
            FaceEngine.shared.stop()
            return
        }
        ui.testing = true
        ui.testMessage = "Look at the camera…"
        ui.testTask = Task {
            while !Task.isCancelled {
                let r = await FaceEngine.shared.verify(
                    prints: store.prints, threshold: Float(store.threshold),
                    requireBlink: store.requireBlink, timeout: 3
                ) { update in
                    Task { @MainActor in
                        switch update {
                        case .noFace: ui.testMessage = "No face found"
                        case .eyesClosed: ui.testMessage = "Eyes closed"
                        case .distance(let d):
                            ui.testMessage = String(format: "%@  ·  difference %.2f (unlocks below %.2f)",
                                                    d < Float(store.threshold) ? "✅ Recognised" : "❌ Not recognised",
                                                    d, store.threshold)
                        }
                    }
                }
                if r == .matched { ui.testMessage = "✅ Recognised — this would unlock" }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }
}
