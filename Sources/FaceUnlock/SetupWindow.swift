import AVFoundation
import AppKit
import FaceUnlockCore
import SwiftUI

/// Live state of the Setup window. Filled by `AppDelegate.refreshSetup()`
/// (every second while the window is open) and by the step actions.
@MainActor
@Observable
final class SetupModel {
    var progress = SetupProgress(conditions: [:])
    var details: [SetupStep: String] = [:]

    var passwordField = ""
    var passwordError: String?
    var passwordBusy = false
    var passwordStored = false

    /// Non-nil while the inline enrolment / test is running.
    var enrolment: EnrolmentModel?
    var test: TestModel?

    var isEnabled = false
    var launchAtLogin = true
    var launchAtLoginNote: String?

    var livenessMode: LivenessMode = .default
    /// Set when the Keychain record predates the liveness setting.
    var livenessProposal: LivenessMode?
    var scanStartMode: ScanStartMode = .automatic
    var threshold: Float = MatchPolicy.defaultThreshold
    /// Median score of the user's matching frames in the Test step.
    var typicalScore: Float?

    /// Suggests the stricter default when the user's own scores are high.
    var thresholdSuggestion: Float? {
        guard let typicalScore, typicalScore >= 0.80, threshold < MatchPolicy.defaultThreshold - 0.001 else { return nil }
        return MatchPolicy.defaultThreshold
    }

    var lockCountdown: Int?
    var lastAttempt: AttemptRecord?

    /// When the login password was last verified in this window. Lets the
    /// next gated action (enrol, enable, …) skip re-prompting for 5 minutes.
    /// Only a timestamp is kept, never the password.
    var verifiedAt: Date?

    func recentlyVerified(now: Date = Date()) -> Bool {
        guard let verifiedAt else { return false }
        return now.timeIntervalSince(verifiedAt) < 5 * 60
    }

    func state(_ step: SetupStep) -> StepState { progress.state(of: step) }
}

/// Everything the Setup window can ask the app to do.
struct SetupActions {
    var allowCamera: () -> Void
    var openAccessibility: () -> Void
    var savePassword: () -> Void
    var startEnrolment: () -> Void
    var stopEnrolment: () -> Void
    var startTest: () -> Void
    var stopTest: () -> Void
    var setEnabled: (Bool) -> Void
    var setLaunchAtLogin: (Bool) -> Void
    var setLiveness: (LivenessMode) -> Void
    var keepBlinkLiveness: () -> Void
    var setScanStart: (ScanStartMode) -> Void
    var applyThreshold: (Float) -> Void
    var lockNow: () -> Void
    var done: () -> Void
}

// MARK: - Views

struct SetupView: View {
    let model: SetupModel
    let session: AVCaptureSession
    let actions: SetupActions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ForEach(SetupStep.allCases, id: \.self) { step in
                        StepRow(step: step, state: model.state(step), detail: model.details[step] ?? "") {
                            content(for: step)
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 760)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "faceid")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up FaceUnlock").font(.title2.bold())
                Text("Unlock this Mac's lock screen by looking at the built-in camera.")
                    .foregroundStyle(.secondary)
            }
        }
        if let proposal = model.livenessProposal {
            VStack(alignment: .leading, spacing: 8) {
                Label("New: unlock without blinking", systemImage: "sparkles").font(.headline)
                Text("FaceUnlock can now check for the natural movement of a live face instead of waiting for a blink, which makes unlocking much faster. \(proposal.securityNote)")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Switch to \(proposal.title)…") { actions.setLiveness(proposal) }
                        .keyboardShortcut(.defaultAction)
                    Button("Keep Blink + movement", action: actions.keepBlinkLiveness)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        if model.progress.allComplete {
            Banner(symbol: "checkmark.seal.fill", tint: .green, text: "Setup complete ✓  Face unlock is on and has unlocked this Mac.")
        } else if model.progress.requiredComplete {
            Banner(symbol: "checkmark.circle.fill", tint: .green, text: "Face unlock is ready. Try the lock-screen test to confirm it works.")
        }
    }

    private var footer: some View {
        HStack {
            Text("Webcam face unlock is a convenience, not a security upgrade – a video of you could fool it.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: actions.done).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    @ViewBuilder private func content(for step: SetupStep) -> some View {
        let state = model.state(step)
        switch step {
        case .camera:
            if !state.isSatisfied {
                Button(state.condition == .problem ? "Open Camera Settings…" : "Allow", action: actions.allowCamera)
            }
        case .accessibility:
            if !state.isSatisfied {
                Button("Open Settings…", action: actions.openAccessibility)
            }
        case .password:
            passwordContent
        case .enrol:
            enrolContent(state)
        case .test:
            testContent(state)
        case .turnOn:
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Face unlock enabled", isOn: Binding(get: { model.isEnabled }, set: { actions.setEnabled($0) }))
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { actions.setLaunchAtLogin($0) }))
                Picker("Start scanning", selection: Binding(get: { model.scanStartMode }, set: { actions.setScanStart($0) })) {
                    ForEach(ScanStartMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 460)
                Text(model.scanStartMode == .automatic
                     ? "The camera (and its green light) is on whenever the lock screen is showing; macOS turns the display off at the lock screen after a short time."
                     : "Move the mouse or press a key at the lock screen to start the camera.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = model.launchAtLoginNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        case .lockTest:
            lockTestContent
        }
    }

    @ViewBuilder private var passwordContent: some View {
        HStack {
            SecureField(model.passwordStored ? "Change password" : "Mac login password", text: Binding(
                get: { model.passwordField }, set: { model.passwordField = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(actions.savePassword)
            Button("Save", action: actions.savePassword)
                .disabled(model.passwordField.isEmpty || model.passwordBusy)
            if model.passwordBusy { ProgressView().controlSize(.small) }
        }
        if let error = model.passwordError {
            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
        }
    }

    @ViewBuilder private func enrolContent(_ state: StepState) -> some View {
        if let enrolment = model.enrolment {
            EnrolmentView(session: session, model: enrolment)
            Button(enrolment.finished || enrolment.failed ? "Close camera" : "Cancel", action: actions.stopEnrolment)
        } else {
            Button(state.isSatisfied ? "Re-enrol…" : "Start enrolment…", action: actions.startEnrolment)
                .disabled(model.test != nil)
        }
    }

    @ViewBuilder private func testContent(_ state: StepState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Liveness", selection: Binding(get: { model.livenessMode }, set: { actions.setLiveness($0) })) {
                ForEach(LivenessMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 420)
            Text(model.livenessMode.securityNote).font(.caption).foregroundStyle(.secondary)
            if let suggested = model.thresholdSuggestion, let typical = model.typicalScore {
                HStack {
                    Text(String(format: "Your scores are ~%.2f – a stricter threshold of %.2f is recommended (now %.2f).",
                                typical, suggested, model.threshold))
                        .font(.callout)
                    Button(String(format: "Use %.2f…", suggested)) { actions.applyThreshold(suggested) }
                }
                .padding(.top, 4)
            }
        }
        if let test = model.test {
            TestView(session: session, model: test, reset: {
                test.passed = false
                actions.startTest()
            })
            Button("Stop test", action: actions.stopTest)
        } else {
            Button(state.isSatisfied ? "Test again" : "Start test", action: actions.startTest)
                .disabled(model.enrolment != nil)
        }
    }

    @ViewBuilder private var lockTestContent: some View {
        if let record = model.lastAttempt {
            VStack(alignment: .leading, spacing: 3) {
                Label(record.outcome.summary,
                      systemImage: record.outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(record.outcome.isSuccess ? .green : .orange)
                Text(record.time, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
                if !record.outcome.advice.isEmpty {
                    Text(record.outcome.advice).font(.callout)
                }
            }
        }
        HStack {
            if let countdown = model.lockCountdown {
                Text("Locking in \(countdown)…").font(.headline)
            } else {
                Button("Lock screen now", action: actions.lockNow)
            }
        }
        Text((model.scanStartMode == .automatic
              ? "After the screen locks, just look at the camera."
              : "After the screen locks, move the mouse or press Shift and look at the camera.")
             + (model.livenessMode == .blinkAndMovement ? " Blink once." : ""))
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.headline)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(tint)
    }
}

private struct StepRow<Content: View>: View {
    let step: SetupStep
    let state: StepState
    let detail: String
    @ViewBuilder let content: () -> Content

    private static func title(_ step: SetupStep) -> String {
        switch step {
        case .camera: return "Camera access"
        case .accessibility: return "Accessibility"
        case .password: return "Login password"
        case .enrol: return "Enrol your face"
        case .test: return "Test recognition"
        case .turnOn: return "Turn on"
        case .lockTest: return "Lock-screen test"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.font(.title2).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(step.rawValue + 1). \(Self.title(step))").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.isEnabled {
                    content()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .opacity(state.isEnabled ? 1 : 0.5)
    }

    @ViewBuilder private var icon: some View {
        switch state.condition {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .notDone:
            Image(systemName: "\(step.rawValue + 1).circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Window

/// Hosts the Setup view in a normal titled window.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let onClose: () -> Void

    init(model: SetupModel, session: AVCaptureSession, actions: SetupActions, onClose: @escaping () -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        self.onClose = onClose
        super.init()
        window.title = "FaceUnlock Setup"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SetupView(model: model, session: session, actions: actions))
        // Fixed-size window: don't let SwiftUI resize it during layout (that
        // caused an AppKit layout-recursion warning).
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 640, height: 760))
        window.delegate = self
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) { onClose() }
}
