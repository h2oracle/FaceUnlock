import AVFoundation
import AppKit
import FaceUnlockCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let camera = CameraSession()
    private let store = TemplateStore.standard
    private var analyzer: FaceAnalyzer?
    private var modelError: String?
    private var template: FaceTemplate?
    /// SHA-256 of the template file as loaded / last saved.
    private var templateDigest: String?
    /// Integrity record from the Keychain (nil if missing or unreadable).
    private var integrity: IntegrityRecord?
    private var integrityLoaded = false
    /// False if the stored password exists but can't be read without a
    /// Keychain prompt (e.g. after the app's signing identity changed).
    private var passwordReadable = true
    private var coordinator: UnlockCoordinator!

    private var enrolmentWindow: CameraWindow?
    private var enrolmentRunner: EnrolmentRunner?
    private var testWindow: CameraWindow?
    private var testProcessor: FaceSessionProcessor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            analyzer = FaceAnalyzer(embedder: try FaceEmbedder())
        } catch {
            modelError = String(describing: error)
            log.error("Face model failed to load: \(String(describing: error), privacy: .public)")
        }
        if let loaded = store.loadWithDigest(), loaded.template.modelID == FaceEmbedder.modelID {
            template = loaded.template
            templateDigest = loaded.sha256
        }

        coordinator = UnlockCoordinator(camera: camera, analyzer: analyzer)
        coordinator.template = template
        coordinator.isEnabled = { Settings.isEnabled }
        coordinator.integrityProblem = { [weak self] in self?.integrityProblem ?? "Not set up" }
        coordinator.policy = { [weak self] in self?.verifiedPolicy ?? MatchPolicy() }
        coordinator.onStatusChange = { [weak self] in self?.updateIcon() }
        coordinator.onLockSessionBegan = { [weak self] in self?.closeCameraWindows() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        reloadKeychainState()
        coordinator.start()
    }

    private func updateIcon() {
        let name = Settings.isEnabled && readyProblems.isEmpty ? "faceid" : "face.dashed"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "FaceUnlock")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: - Integrity

    /// nil when template file and threshold match the Keychain record.
    private var integrityProblem: String? {
        guard template != nil else { return "Not enrolled" }
        guard integrityLoaded else { return "Checking Keychain…" }
        guard let integrity else { return "Template changed – re-enrol" }
        switch integrity.problem(templateSHA256: templateDigest, threshold: Settings.matchThreshold) {
        case nil: return nil
        case .templateChanged: return "Template changed – re-enrol"
        case .thresholdChanged: return "Threshold changed outside FaceUnlock – choose Match strictness again"
        }
    }

    /// Threshold as recorded in the Keychain (only used when it matches).
    private var verifiedPolicy: MatchPolicy {
        MatchPolicy(threshold: integrity?.threshold ?? Settings.matchThreshold)
    }

    /// Reads the integrity record and checks the password is readable
    /// without UI, off the main thread (each read has its own timeout).
    private func reloadKeychainState() {
        Task.detached(priority: .utility) { [weak self] in
            let record = try? PasswordVault.readIntegrity()
            var readable = true
            if PasswordVault.passwordExists() {
                do {
                    let secret = try PasswordVault.readPassword()
                    secret.wipe()
                } catch {
                    readable = false
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.integrity = record
                self.integrityLoaded = true
                self.passwordReadable = readable
                self.updateIcon()
            }
        }
    }

    private func saveIntegrity() throws {
        let record = IntegrityRecord(templateSHA256: templateDigest, threshold: Settings.matchThreshold)
        try PasswordVault.saveIntegrity(record)
        integrity = record
        integrityLoaded = true
    }

    // MARK: - Menu

    /// Things that prevent unlocking, shown at the top of the menu.
    private var readyProblems: [String] {
        var problems: [String] = []
        if let modelError { problems.append("Model error: \(modelError)") }
        if template == nil {
            problems.append("No face enrolled")
        } else if let problem = integrityProblem {
            problems.append(problem)
        }
        if !PasswordVault.passwordExists() {
            problems.append("No password stored")
        } else if !passwordReadable {
            problems.append("Stored password not readable without a prompt – use Change password…")
        }
        if !Permissions.cameraAuthorized { problems.append("Camera permission missing") }
        if !Permissions.accessibilityTrusted { problems.append("Accessibility permission missing") }
        return problems
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let problems = readyProblems

        let header = NSMenuItem(title: "FaceUnlock – \(coordinator.status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for problem in problems {
            let item = NSMenuItem(title: "⚠︎ \(problem)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let enabled = item("Enabled", #selector(toggleEnabled))
        enabled.state = Settings.isEnabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        menu.addItem(item(template == nil ? "Enrol face…" : "Re-enrol face…", #selector(enrol), enabled: analyzer != nil))
        menu.addItem(item(PasswordVault.passwordExists() ? "Change password…" : "Set password…", #selector(setPassword)))
        menu.addItem(item("Test recognition…", #selector(testRecognition), enabled: analyzer != nil && template != nil))

        let strictness = NSMenuItem(title: "Match strictness", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = Settings.matchThreshold
        for (label, value) in [("Relaxed (0.45)", Float(0.45)), ("Standard (0.55)", 0.55), ("Strict (0.65)", 0.65)] {
            let choice = item(label, #selector(setThreshold(_:)))
            choice.representedObject = NSNumber(value: value)
            choice.state = abs(current - value) < 0.001 ? .on : .off
            sub.addItem(choice)
        }
        if ![Float(0.45), 0.55, 0.65].contains(where: { abs($0 - current) < 0.001 }) {
            let custom = NSMenuItem(title: String(format: "Custom (%.2f)", current), action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            sub.addItem(custom)
        }
        strictness.submenu = sub
        menu.addItem(strictness)
        menu.addItem(.separator())

        switch Permissions.cameraStatus {
        case .authorized:
            menu.addItem(disabled("Camera: allowed ✓"))
        case .notDetermined:
            menu.addItem(item("Camera: not yet allowed – Allow…", #selector(requestCamera)))
        default:
            menu.addItem(item("Camera: denied – Open Settings…", #selector(openCameraSettings)))
        }
        if Permissions.accessibilityTrusted {
            menu.addItem(disabled("Accessibility: allowed ✓"))
        } else {
            menu.addItem(item("Accessibility: needed – Grant…", #selector(requestAccessibility)))
        }

        let login = item("Launch at login", #selector(toggleLaunchAtLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed; login.title = "Launch at login (approve in System Settings)"
        default: login.state = .off
        }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Delete face data and password…", #selector(deleteData)))
        menu.addItem(item("Quit FaceUnlock", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool = true, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.isEnabled = enabled
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: - Login password gate

    /// Asks for the Mac login password and runs `action` only if
    /// OpenDirectory accepts it. Guards every security-relevant change.
    private func requireLoginPassword(_ reason: String, then action: @escaping @MainActor () -> Void) {
        guard let password = askForPassword(title: "Confirm with your login password", text: reason) else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = PasswordVerifier.verify(password)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .valid: action()
                case .invalid: self.alert("Incorrect password", "Nothing was changed.")
                case .failed(let message): self.alert("Couldn't verify password", message)
                }
            }
        }
    }

    private func askForPassword(title: String, text: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let password = field.stringValue
        field.stringValue = ""
        return password.isEmpty ? nil : password
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        if Settings.isEnabled {
            // Turning it off never needs a password.
            Settings.isEnabled = false
            updateIcon()
            return
        }
        let problems = readyProblems
        guard problems.isEmpty else {
            alert("FaceUnlock can't be enabled yet", problems.joined(separator: "\n"))
            return
        }
        requireLoginPassword("Enter your Mac login password to turn on face unlock.") { [weak self] in
            Settings.isEnabled = true
            self?.updateIcon()
        }
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.floatValue else { return }
        requireLoginPassword("Enter your Mac login password to change the match strictness.") { [weak self] in
            guard let self else { return }
            Settings.matchThreshold = value
            do {
                try self.saveIntegrity()
            } catch {
                self.alert("Couldn't save setting", String(describing: error))
            }
            self.updateIcon()
        }
    }

    @objc private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    @objc private func openCameraSettings() {
        Permissions.openPrivacyPane("Privacy_Camera")
    }

    @objc private func requestAccessibility() {
        Permissions.promptForAccessibility()
        Permissions.openPrivacyPane("Privacy_Accessibility")
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Launch at login", "Couldn't change the setting: \(error.localizedDescription)\n\nFaceUnlock must be in /Applications or ~/Applications.")
        }
    }

    @objc private func deleteData() {
        let a = NSAlert()
        a.messageText = "Delete face data and stored password?"
        a.informativeText = "This removes the enrolled face template and the Keychain items, and disables face unlock."
        a.addButton(withTitle: "Continue…")
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        requireLoginPassword("Enter your Mac login password to delete FaceUnlock's data.") { [weak self] in
            guard let self else { return }
            Settings.isEnabled = false
            try? self.store.delete()
            PasswordVault.deleteAll()
            self.template = nil
            self.templateDigest = nil
            self.integrity = nil
            self.coordinator.template = nil
            self.updateIcon()
        }
    }

    @objc private func quit() {
        camera.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Password

    @objc private func setPassword() {
        guard let password = askForPassword(
            title: "Mac login password",
            text: "FaceUnlock types this password on the lock screen after recognising you. It is checked now and stored only in your Keychain."
        ) else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = PasswordVerifier.verify(password)
            var saveError: String?
            if result == .valid {
                do { try PasswordVault.savePassword(password) } catch { saveError = String(describing: error) }
            }
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .valid where saveError == nil:
                    self.alert("Password saved", "Verified and stored in your Keychain.")
                case .valid:
                    self.alert("Couldn't save password", saveError ?? "")
                case .invalid:
                    self.alert("Incorrect password", "That isn't the login password for \(NSUserName()). Nothing was saved.")
                case .failed(let message):
                    self.alert("Couldn't verify password", message)
                }
                self.reloadKeychainState()
            }
        }
    }

    // MARK: - Camera windows

    private func closeCameraWindows() {
        enrolmentWindow?.close()
        testWindow?.close()
    }

    /// Runs `body` once camera access is granted, asking only if undecided.
    private func withCameraAccess(_ body: @escaping @MainActor () -> Void) {
        switch Permissions.cameraStatus {
        case .authorized:
            body()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { body() }
                }
            }
        default:
            alert("Camera access needed", "Allow FaceUnlock in System Settings → Privacy & Security → Camera.")
            Permissions.openPrivacyPane("Privacy_Camera")
        }
    }

    private var cameraBusy: Bool {
        enrolmentWindow != nil || testWindow != nil || coordinator.isAttempting
    }

    @objc private func enrol() {
        guard let analyzer, !cameraBusy else { return }
        let reason = template == nil
            ? "Enter your Mac login password to enrol your face."
            : "Enter your Mac login password to replace the enrolled face."
        requireLoginPassword(reason) { [weak self] in
            self?.withCameraAccess { [weak self] in self?.startEnrolment(analyzer: analyzer) }
        }
    }

    private func startEnrolment(analyzer: FaceAnalyzer) {
        guard !cameraBusy else { return }
        guard let device = CameraSession.device(uniqueID: nil) else {
            alert("No built-in camera", "FaceUnlock only uses the Mac's built-in camera (not iPhone, external or virtual cameras).")
            return
        }
        let cameraID = device.uniqueID
        let model = EnrolmentModel()
        let runner = EnrolmentRunner(analyzer: analyzer, onUpdate: { instruction, progress, rejection in
            Task { @MainActor in
                guard !model.finished else { return }
                model.instruction = instruction
                model.progress = progress
                model.detail = rejection ?? ""
            }
        }, onComplete: { [weak self] embeddings in
            Task { @MainActor in self?.finishEnrolment(embeddings, cameraID: cameraID, model: model) }
        })
        enrolmentRunner = runner
        let window = CameraWindow(title: "Enrol face", size: NSSize(width: 520, height: 430),
                                  content: EnrolmentView(session: camera.session, model: model)) { [weak self] in
            self?.enrolmentRunner?.cancel()
            self?.enrolmentRunner = nil
            self?.enrolmentWindow = nil
            self?.camera.stop()
        }
        enrolmentWindow = window
        window.show()
        camera.start(device: device, handler: { pb, t in runner.process(pb, at: t) }, completion: { error in
            guard let error else { return }
            let message = String(describing: error)
            Task { @MainActor in model.failed = true; model.detail = message }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + EnrolmentRunner.timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enrolmentRunner === runner, !model.finished else { return }
                runner.cancel()
                self.camera.stop()
                model.failed = true
                model.instruction = "Timed out"
                model.detail = "Couldn't capture enough good frames. Try better, even lighting and keep one face in view."
            }
        }
    }

    private func finishEnrolment(_ embeddings: [[Float]], cameraID: String, model: EnrolmentModel) {
        camera.stop()
        model.finished = true
        model.progress = 1
        do {
            let raw = try FaceTemplate(modelID: FaceEmbedder.modelID, samples: embeddings, cameraID: cameraID)
            let cleaned = try raw.removingOutliers(minimumSimilarity: 0.5, minimumKept: 12)
            templateDigest = try store.save(cleaned)
            template = cleaned
            coordinator.template = cleaned
            try saveIntegrity()
            model.instruction = "Enrolled ✓"
            model.detail = String(format: "%d samples kept, consistency %.2f. Use “Test recognition…” to check it.",
                                  cleaned.samples.count, cleaned.consistency)
        } catch {
            model.failed = true
            model.instruction = "Enrolment failed"
            model.detail = String(describing: error)
        }
        updateIcon()
    }

    @objc private func testRecognition() {
        guard let analyzer, let template, !cameraBusy else { return }
        withCameraAccess { [weak self] in self?.startTest(analyzer: analyzer, template: template) }
    }

    private func startTest(analyzer: FaceAnalyzer, template: FaceTemplate) {
        guard !cameraBusy else { return }
        guard let device = CameraSession.device(uniqueID: template.cameraID), template.cameraID != nil else {
            alert("Enrolled camera not available", "Re-enrol to record which built-in camera to use.")
            return
        }
        let model = TestModel()
        let policy = verifiedPolicy
        model.threshold = policy.threshold
        let processor = FaceSessionProcessor(analyzer: analyzer, template: template, policy: policy, onReadout: { readout in
            Task { @MainActor in model.apply(readout) }
        }, stopsOnPass: false, onPass: {})
        testProcessor = processor
        let view = TestView(session: camera.session, model: model) {
            model.passed = false
            processor.requestReset()
        }
        let window = CameraWindow(title: "Test recognition", size: NSSize(width: 520, height: 480), content: view) { [weak self] in
            self?.testProcessor?.finish()
            self?.testProcessor = nil
            self?.testWindow = nil
            self?.camera.stop()
        }
        testWindow = window
        window.show()
        camera.start(device: device, handler: { pb, t in processor.process(pb, at: t) }, completion: { error in
            guard let error else { return }
            let message = String(describing: error)
            Task { @MainActor in model.lines = ["Camera error: \(message)"] }
        })
    }

    // MARK: - Helpers

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}
