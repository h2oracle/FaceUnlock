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
    /// Set when reading the record failed for a reason other than "not
    /// found" (then nothing may be written until it's resolved).
    private var integrityReadError: String?
    private var integrityLoaded = false
    /// False if the stored password exists but can't be read without a
    /// Keychain prompt (e.g. after the app's signing identity changed).
    private var passwordReadable = true
    private var coordinator: UnlockCoordinator!

    private var enrolmentRunner: EnrolmentRunner?
    private var testProcessor: FaceSessionProcessor?

    private let setupModel = SetupModel()
    private var setupWindow: SetupWindowController?
    private var setupTimer: Timer?
    /// Open Setup automatically once the first Keychain check has finished,
    /// if any required step is still missing.
    private var openSetupAfterFirstLoad = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let analyzer = FaceAnalyzer(embedder: try FaceEmbedder())
            self.analyzer = analyzer
            // Load Vision + Core ML now, on the camera's frame queue, so the
            // first lock-screen frame isn't slowed by lazy initialisation.
            camera.videoQueue.async { analyzer.prewarm() }
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
        coordinator.isEnabled = { [weak self] in self?.isEffectivelyEnabled ?? false }
        coordinator.startMode = { Settings.scanStartMode }
        // Note: `self?.integrityProblem ?? x` would flatten the String?? and turn
        // "no problem" (nil) into x — so unwrap self explicitly.
        coordinator.integrityProblem = { [weak self] in
            guard let self else { return "Not set up" }
            return self.integrityProblem
        }
        coordinator.policy = { [weak self] in self?.verifiedPolicy ?? MatchPolicy() }
        coordinator.liveness = { [weak self] in self?.verifiedLiveness ?? .blinkAndMovement }
        coordinator.onStatusChange = { [weak self] in self?.updateIcon() }
        coordinator.onLockSessionBegan = { [weak self] in
            // A screen lock ends any password-reuse window.
            self?.setupModel.verifiedAt = nil
            self?.stopCameraUse()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setupModel.verifiedAt = nil }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setupModel.verifiedAt = nil }
        }
        coordinator.onAttemptRecorded = { [weak self] record in
            SetupStore.lastAttempt = record
            self?.refreshSetup()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        reloadKeychainState()
        coordinator.start()
    }

    /// Opening the app again (Spotlight, Finder, `open`) shows the Setup
    /// window – the menu-bar icon can be hidden behind the notch when the
    /// menu bar is full. When setup is complete it shows the summary state.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return false
    }

    private func updateIcon() {
        let name = isEffectivelyEnabled && readyProblems.isEmpty ? "faceid" : "face.dashed"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "FaceUnlock")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: - Integrity

    /// nil when template file and threshold match the Keychain record.
    private var integrityProblem: String? {
        guard template != nil else { return "Not enrolled" }
        guard integrityLoaded else { return "Checking Keychain…" }
        if let integrityReadError { return "Couldn't read the Keychain record (\(integrityReadError))" }
        guard let integrity else { return "Template changed – re-enrol" }
        switch integrity.problem(templateSHA256: templateDigest, threshold: Settings.matchThreshold,
                                 livenessMode: Settings.livenessMode) {
        case nil: return nil
        case .templateChanged: return "Template changed – re-enrol"
        case .thresholdChanged: return "Threshold changed outside FaceUnlock – choose Match strictness again (asks for your password)"
        case .livenessChanged: return "Liveness changed outside FaceUnlock – choose Liveness again (asks for your password)"
        }
    }

    /// Liveness mode as recorded in the Keychain (only used when it matches).
    private var verifiedLiveness: LivenessMode {
        integrity?.effectiveLivenessMode ?? Settings.livenessMode
    }

    /// Threshold as recorded in the Keychain (only used when it matches).
    private var verifiedPolicy: MatchPolicy {
        MatchPolicy(threshold: integrity?.threshold ?? Settings.matchThreshold)
    }

    /// Reads the integrity record and checks the password is readable
    /// without UI, off the main thread (each read has its own timeout).
    private func reloadKeychainState() {
        Task { @MainActor [weak self] in
            let (record, readError, readable) = await Task.detached(priority: .utility) { () -> (IntegrityRecord?, String?, Bool) in
                var record: IntegrityRecord?
                var readError: String?
                do {
                    record = try PasswordVault.readIntegrity()
                } catch PasswordVault.VaultError.keychain(let status) where status == errSecItemNotFound {
                    record = nil // first set-up
                } catch {
                    readError = String(describing: error)
                }
                var readable = true
                if PasswordVault.passwordExists() {
                    do {
                        let secret = try PasswordVault.readPassword()
                        secret.wipe()
                    } catch {
                        readable = false
                    }
                }
                return (record, readError, readable)
            }.value
            do {
                guard let self else { return }
                // Records written before the liveness setting existed vouch for
                // blink + movement; keep that until the user picks another mode.
                if let record, record.livenessMode == nil, !Settings.hasLivenessMode {
                    Settings.livenessMode = .blinkAndMovement
                }
                // Keep the threshold the record vouches for: the default for new
                // set-ups changed (0.55 → 0.70) and must not silently apply here.
                if let record, !Settings.hasMatchThreshold {
                    Settings.matchThreshold = record.threshold
                }
                // Pre-liveness record: offer Natural movement (one-click,
                // password-confirmed) instead of silently weakening the check.
                self.setupModel.livenessProposal = (record != nil && record?.livenessMode == nil) ? .naturalMovement : nil
                self.integrity = record
                self.integrityReadError = readError
                self.integrityLoaded = true
                self.passwordReadable = readable
                self.updateIcon()
                self.refreshSetup()
                if self.openSetupAfterFirstLoad {
                    self.openSetupAfterFirstLoad = false
                    let loose = self.template != nil && (record?.threshold ?? 1) < MatchPolicy.defaultThreshold - 0.001
                    if !self.setupModel.progress.requiredComplete || self.setupModel.livenessProposal != nil || loose {
                        self.showSetup()
                    }
                }
            }
        }
    }

    /// On only when the preference AND the Keychain record say so, and the
    /// record matches the template and settings.
    private var isEffectivelyEnabled: Bool {
        guard let integrity, integrityProblem == nil else { return false }
        return integrity.isEffectivelyEnabled(preference: Settings.isEnabled)
    }

    enum IntegrityError: Error, CustomStringConvertible {
        case noTrustedRecord
        case templateMismatch
        case settingsMismatch(String)
        case unreadable(String)

        var description: String {
            switch self {
            case .noTrustedRecord: return "There's no Keychain record yet. Enrol your face first."
            case .templateMismatch: return "The enrolled face doesn't match the Keychain record. Re-enrol your face first."
            case .settingsMismatch(let problem): return "\(problem). Fix that first."
            case .unreadable(let detail): return "The Keychain record couldn't be read (\(detail)). Nothing was changed."
            }
        }
    }

    /// The trusted record exists and vouches for the template file on disk.
    private var templateMatchesRecord: Bool {
        guard let integrity, let templateDigest else { return false }
        return integrity.templateSHA256 == templateDigest
    }

    /// Changes fields of the *trusted* Keychain record (never re-blessing
    /// values from UserDefaults or the template file) and saves it, then
    /// resets the preferences to what the record says.
    ///
    /// - `allowSettingsRepair`: true for an explicit, password-confirmed choice
    ///   of threshold or liveness. It's allowed when only those preferences were
    ///   changed outside the app, as long as the template still matches.
    ///   Otherwise everything must match.
    /// Only enrolment writes a new template hash (`saveIntegrityAfterEnrolment`).
    private func updateIntegrity(allowSettingsRepair: Bool = false, _ change: (inout IntegrityRecord) -> Void) throws {
        if let integrityReadError { throw IntegrityError.unreadable(integrityReadError) }
        guard var record = integrity else { throw IntegrityError.noTrustedRecord }
        guard templateMatchesRecord else { throw IntegrityError.templateMismatch }
        if !allowSettingsRepair, let problem = integrityProblem { throw IntegrityError.settingsMismatch(problem) }
        change(&record)
        try PasswordVault.saveIntegrity(record)
        integrity = record
        integrityLoaded = true
        Settings.matchThreshold = record.threshold
        Settings.livenessMode = record.effectiveLivenessMode
        Settings.isEnabled = record.enabled == true
    }

    /// Turning face unlock off always reaches the trusted record (whatever
    /// else is wrong), changing only `enabled`. The preference goes off
    /// even if the Keychain write fails.
    private func disableFaceUnlock() {
        Settings.isEnabled = false
        if var record = integrity, record.enabled != false {
            record.enabled = false
            do {
                try PasswordVault.saveIntegrity(record)
                integrity = record
            } catch {
                alert("Face unlock is off", "It's turned off, but the Keychain record couldn't be updated: \(error)")
            }
        }
        updateIcon()
        refreshSetup()
    }

    /// Enrolment is the only place a new template hash is written.
    /// - Existing trusted record: threshold and liveness carry over. It stays
    ///   enabled only if it was effectively enabled before (`keepEnabled`).
    /// - No record ("not found"): defaults (`LivenessMode.default`,
    ///   `MatchPolicy.defaultThreshold`), off, never values from UserDefaults.
    /// - Unreadable record: refuses.
    /// It never turns face unlock on.
    private func saveIntegrityAfterEnrolment(templateSHA256: String, keepEnabled: Bool) throws {
        if let integrityReadError { throw IntegrityError.unreadable(integrityReadError) }
        let record: IntegrityRecord
        if let old = integrity {
            record = IntegrityRecord(templateSHA256: templateSHA256, threshold: old.threshold,
                                     livenessMode: old.effectiveLivenessMode,
                                     enabled: keepEnabled && old.enabled == true)
        } else {
            record = IntegrityRecord(templateSHA256: templateSHA256, threshold: MatchPolicy.defaultThreshold,
                                     livenessMode: .default, enabled: false)
        }
        try PasswordVault.saveIntegrity(record)
        integrity = record
        integrityLoaded = true
        Settings.matchThreshold = record.threshold
        Settings.livenessMode = record.effectiveLivenessMode
        if record.enabled != true { Settings.isEnabled = false }
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

        menu.addItem(item("Setup…", #selector(openSetup)))
        menu.addItem(.separator())

        if template != nil, verifiedPolicy.threshold < MatchPolicy.defaultThreshold - 0.001 {
            let loose = item(String(format: "⚠︎ Match threshold %.2f is loose – Use the recommended %.2f…",
                                    verifiedPolicy.threshold, MatchPolicy.defaultThreshold),
                             #selector(useRecommendedThreshold))
            menu.addItem(loose)
            menu.addItem(.separator())
        }
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
        enabled.state = isEffectivelyEnabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        menu.addItem(item(template == nil ? "Enrol face…" : "Re-enrol face…", #selector(enrol), enabled: analyzer != nil))
        menu.addItem(item(PasswordVault.passwordExists() ? "Change password…" : "Set password…", #selector(setPassword)))
        menu.addItem(item("Test recognition…", #selector(testRecognition), enabled: analyzer != nil && template != nil))

        let strictness = NSMenuItem(title: "Match strictness", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = Settings.matchThreshold
        for (label, value) in [("Relaxed (0.55)", Float(0.55)), ("Standard (0.70)", 0.70), ("Strict (0.80)", 0.80)] {
            let choice = item(label, #selector(setThreshold(_:)))
            choice.representedObject = NSNumber(value: value)
            choice.state = abs(current - value) < 0.001 ? .on : .off
            sub.addItem(choice)
        }
        if ![Float(0.55), 0.70, 0.80].contains(where: { abs($0 - current) < 0.001 }) {
            let custom = NSMenuItem(title: String(format: "Custom (%.2f)", current), action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            sub.addItem(custom)
        }
        strictness.submenu = sub
        menu.addItem(strictness)

        let livenessItem = NSMenuItem(title: "Liveness", action: nil, keyEquivalent: "")
        let livenessMenu = NSMenu()
        for mode in LivenessMode.allCases {
            let choice = item(mode.title, #selector(chooseLiveness(_:)))
            choice.representedObject = mode.rawValue
            choice.state = Settings.livenessMode == mode ? .on : .off
            choice.toolTip = mode.securityNote
            livenessMenu.addItem(choice)
        }
        livenessItem.submenu = livenessMenu
        menu.addItem(livenessItem)

        let scanItem = NSMenuItem(title: "Start scanning", action: nil, keyEquivalent: "")
        let scanMenu = NSMenu()
        for mode in ScanStartMode.allCases {
            let choice = item(mode.title, #selector(chooseScanStart(_:)))
            choice.representedObject = mode.rawValue
            choice.state = Settings.scanStartMode == mode ? .on : .off
            scanMenu.addItem(choice)
        }
        scanItem.submenu = scanMenu
        menu.addItem(scanItem)
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
    ///
    /// `allowReuse`: within a Setup session, a password verified in the last
    /// 5 minutes (and not interrupted by a screen lock or sleep) may stand in
    /// for a new prompt. Only a timestamp is kept. Enrolment, turning
    /// liveness off and deleting data always prompt.
    private func requireLoginPassword(_ reason: String, allowReuse: Bool = false,
                                      then action: @escaping @MainActor () -> Void) {
        if allowReuse && setupWindow != nil && setupModel.recentlyVerified() {
            action()
            return
        }
        guard let password = askForPassword(title: "Confirm with your login password", text: reason) else { return }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> PasswordVerifier.Result in
                let result = PasswordVerifier.verify(password)
                return result
            }.value
            do {
                guard let self else { return }
                switch result {
                case .valid:
                    if self.setupWindow != nil { self.setupModel.verifiedAt = Date() }
                    action()
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
        if isEffectivelyEnabled {
            // Turning it off never needs a password.
            disableFaceUnlock()
            return
        }
        let problems = readyProblems
        guard problems.isEmpty else {
            alert("FaceUnlock can't be enabled yet", problems.joined(separator: "\n"))
            return
        }
        requireLoginPassword("Enter your Mac login password to turn on face unlock.", allowReuse: true) { [weak self] in
            guard let self else { return }
            do {
                try self.updateIntegrity { $0.enabled = true }
            } catch {
                self.alert("Couldn't turn on face unlock", String(describing: error))
                return
            }
            self.applyLaunchAtLoginDefault()
            self.updateIcon()
            self.refreshSetup()
        }
    }

    @objc private func chooseLiveness(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = LivenessMode(rawValue: raw) else { return }
        setLiveness(mode)
    }

    /// Password-gated, and recorded in the Keychain integrity item.
    private func setLiveness(_ mode: LivenessMode) {
        requireLoginPassword("Enter your Mac login password to set the liveness check to “\(mode.title)”.",
                             allowReuse: mode != .off) { [weak self] in
            guard let self else { return }
            do {
                try self.updateIntegrity(allowSettingsRepair: true) { $0.livenessMode = mode }
            } catch {
                self.alert("Couldn't save setting", String(describing: error))
                return
            }
            self.setupModel.livenessProposal = nil
            // The test result was for the old mode; a running test uses it too.
            SetupStore.testPassedForDigest = nil
            self.stopTest()
            self.updateIcon()
            self.refreshSetup()
        }
    }

    @objc private func chooseScanStart(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ScanStartMode(rawValue: raw) else { return }
        setScanStart(mode)
    }

    /// Not password-gated: it changes when the camera runs, not how strict
    /// matching is. Takes effect at the next screen lock.
    private func setScanStart(_ mode: ScanStartMode) {
        Settings.scanStartMode = mode
        refreshSetup()
    }

    @objc private func useRecommendedThreshold() {
        applyThreshold(MatchPolicy.defaultThreshold)
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.floatValue else { return }
        applyThreshold(value)
    }

    /// Password-gated, and recorded in the Keychain integrity item.
    private func applyThreshold(_ value: Float) {
        requireLoginPassword(String(format: "Enter your Mac login password to change the match threshold to %.2f.", value),
                             allowReuse: true) { [weak self] in
            guard let self else { return }
            do {
                try self.updateIntegrity(allowSettingsRepair: true) { $0.threshold = MatchPolicy(threshold: value).threshold }
            } catch {
                self.alert("Couldn't save setting", String(describing: error))
                return
            }
            // A running test uses the old threshold.
            self.stopTest()
            self.updateIcon()
            self.refreshSetup()
        }
    }

    /// Keeps Blink + movement and writes it explicitly into the Keychain record.
    private func keepBlinkLiveness() {
        requireLoginPassword("Enter your Mac login password to keep the Blink + movement check.", allowReuse: true) { [weak self] in
            guard let self else { return }
            do {
                try self.updateIntegrity(allowSettingsRepair: true) { $0.livenessMode = .blinkAndMovement }
                self.setupModel.livenessProposal = nil
            } catch {
                self.alert("Couldn't save setting", String(describing: error))
            }
            self.refreshSetup()
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
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        SetupStore.launchAtLoginChosen = true
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            setupModel.launchAtLoginNote = nil
        } catch {
            setupModel.launchAtLoginNote = "Couldn't change Launch at login: \(error.localizedDescription)"
        }
        refreshSetup()
    }

    /// Launch at login defaults to on when face unlock is first turned on,
    /// unless the user has chosen otherwise.
    private func applyLaunchAtLoginDefault() {
        guard !SetupStore.launchAtLoginChosen, SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            setupModel.launchAtLoginNote = "Couldn't turn on Launch at login: \(error.localizedDescription)"
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
            SetupStore.testPassedForDigest = nil
            self.updateIcon()
            self.refreshSetup()
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

        Task { @MainActor [weak self] in
            let (result, saveError) = await Task.detached(priority: .userInitiated) { () -> (PasswordVerifier.Result, String?) in
                let result = PasswordVerifier.verify(password)
                var saveError: String?
                if result == .valid {
                    do { try PasswordVault.savePassword(password) } catch { saveError = String(describing: error) }
                }
                return (result, saveError)
            }.value
            do {
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

    /// Step 3: verifies and stores the password typed into the Setup window.
    private func savePasswordFromSetup() {
        let password = setupModel.passwordField
        setupModel.passwordField = ""
        guard !password.isEmpty, !setupModel.passwordBusy else { return }
        setupModel.passwordBusy = true
        setupModel.passwordError = nil
        Task { @MainActor [weak self] in
            let (result, saveError) = await Task.detached(priority: .userInitiated) { () -> (PasswordVerifier.Result, String?) in
                let result = PasswordVerifier.verify(password)
                var saveError: String?
                if result == .valid {
                    do { try PasswordVault.savePassword(password) } catch { saveError = String(describing: error) }
                }
                return (result, saveError)
            }.value
            do {
                guard let self else { return }
                let model = self.setupModel
                model.passwordBusy = false
                switch result {
                case .valid where saveError == nil:
                    model.verifiedAt = Date()
                case .valid:
                    model.passwordError = "Couldn't save to the Keychain: \(saveError ?? "")"
                case .invalid:
                    model.passwordError = "That isn't the login password for \(NSUserName())."
                case .failed(let message):
                    model.passwordError = "Couldn't verify the password: \(message)"
                }
                self.reloadKeychainState()
            }
        }
    }

    // MARK: - Setup window

    @objc private func openSetup() { showSetup() }

    private func showSetup() {
        if setupWindow == nil {
            let controller = SetupWindowController(model: setupModel, session: camera.session, actions: setupActions) { [weak self] in
                self?.setupWindowClosed()
            }
            setupWindow = controller
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.refreshSetup() }
            }
            RunLoop.main.add(timer, forMode: .common)
            setupTimer = timer
        }
        refreshSetup()
        setupWindow?.show()
    }

    private func setupWindowClosed() {
        stopCameraUse()
        setupTimer?.invalidate()
        setupTimer = nil
        setupWindow = nil
        setupModel.verifiedAt = nil
        setupModel.passwordField = ""
        setupModel.passwordError = nil
        setupModel.lockCountdown = nil
    }

    private var setupActions: SetupActions {
        SetupActions(
            allowCamera: { [weak self] in
                if Permissions.cameraStatus == .notDetermined {
                    self?.requestCamera()
                } else {
                    Permissions.openPrivacyPane("Privacy_Camera")
                }
            },
            openAccessibility: { [weak self] in self?.requestAccessibility() },
            savePassword: { [weak self] in self?.savePasswordFromSetup() },
            startEnrolment: { [weak self] in self?.enrol() },
            stopEnrolment: { [weak self] in self?.stopEnrolment() },
            startTest: { [weak self] in self?.testRecognition() },
            stopTest: { [weak self] in self?.stopTest() },
            setEnabled: { [weak self] on in
                guard let self else { return }
                if !on {
                    self.disableFaceUnlock()
                } else if !self.isEffectivelyEnabled {
                    self.toggleEnabled()
                }
            },
            setLaunchAtLogin: { [weak self] on in self?.setLaunchAtLogin(on) },
            setLiveness: { [weak self] mode in self?.setLiveness(mode) },
            keepBlinkLiveness: { [weak self] in self?.keepBlinkLiveness() },
            setScanStart: { [weak self] mode in self?.setScanStart(mode) },
            applyThreshold: { [weak self] value in self?.applyThreshold(value) },
            lockNow: { [weak self] in self?.lockScreenWithCountdown() },
            done: { [weak self] in self?.setupWindow?.close() }
        )
    }

    /// Recomputes every step's state. Runs every second while Setup is open.
    private func refreshSetup() {
        let m = setupModel
        var conditions: [SetupStep: StepCondition] = [:]
        var details: [SetupStep: String] = [:]

        switch Permissions.cameraStatus {
        case .authorized:
            conditions[.camera] = .done
            details[.camera] = "Allowed. Only the Mac's built-in camera is used, and frames never leave this Mac."
        case .notDetermined:
            conditions[.camera] = .notDone
            details[.camera] = "FaceUnlock needs the built-in camera to see your face."
        default:
            conditions[.camera] = .problem
            details[.camera] = "Camera access was denied. Turn FaceUnlock on in System Settings › Privacy & Security › Camera."
        }

        if Permissions.accessibilityTrusted {
            conditions[.accessibility] = .done
            details[.accessibility] = "Allowed. Needed to type your password on the lock screen."
        } else {
            conditions[.accessibility] = .notDone
            details[.accessibility] = "Turn FaceUnlock on in System Settings › Privacy & Security › Accessibility so it can type your password on the lock screen."
        }

        let stored = PasswordVault.passwordExists()
        m.passwordStored = stored
        if stored && passwordReadable {
            conditions[.password] = .done
            details[.password] = "Saved in your Keychain. Enter it again here if your login password changes."
        } else if stored {
            conditions[.password] = .problem
            details[.password] = "The stored password can't be read without a prompt. Save it again."
        } else {
            conditions[.password] = .notDone
            details[.password] = "Your Mac login password. It's checked now and stored only in your Keychain."
        }

        if let modelError {
            conditions[.enrol] = .problem
            details[.enrol] = "The face model failed to load: \(modelError)"
        } else if template == nil {
            conditions[.enrol] = .notDone
            details[.enrol] = "Look at the camera and follow the prompts. Only numbers describing your face are saved, never images."
        } else if let problem = integrityProblem {
            conditions[.enrol] = integrityLoaded ? .problem : .notDone
            details[.enrol] = problem
        } else {
            conditions[.enrol] = .done
            details[.enrol] = "Enrolled. Re-enrol if you change your look or it struggles in some lighting."
        }

        m.livenessMode = Settings.livenessMode
        m.scanStartMode = Settings.scanStartMode
        m.threshold = verifiedPolicy.threshold
        m.hasTemplate = template != nil
        let threshold = String(format: "%.2f", verifiedPolicy.threshold)
        if let digest = templateDigest, SetupStore.testPassedForDigest == digest {
            conditions[.test] = .done
            details[.test] = "Passed with liveness “\(verifiedLiveness.title)” (threshold \(threshold))."
        } else {
            conditions[.test] = .notDone
            let how: String
            switch verifiedLiveness {
            case .naturalMovement: how = "look at the camera naturally for a second or two"
            case .blinkAndMovement: how = "blink once and move your head a little"
            case .off: how = "look at the camera"
            }
            details[.test] = "Check that it recognises you live: \(how) until it says PASS (threshold \(threshold))."
        }

        let enabled = isEffectivelyEnabled
        conditions[.turnOn] = enabled ? .done : .notDone
        details[.turnOn] = enabled
            ? "Face unlock is on."
            : "Turn face unlock on. You'll be asked for your login password."
        m.isEnabled = enabled
        switch SMAppService.mainApp.status {
        case .enabled:
            m.launchAtLogin = true
            m.launchAtLoginNote = nil
        case .requiresApproval:
            m.launchAtLogin = true
            m.launchAtLoginNote = "Approve FaceUnlock in System Settings › General › Login Items."
        default:
            // Defaults to on until the user decides or face unlock is turned on.
            m.launchAtLogin = !SetupStore.launchAtLoginChosen && !enabled
        }

        let last = SetupStore.lastAttempt
        m.lastAttempt = last
        if last?.outcome.isSuccess == true {
            conditions[.lockTest] = .done
            details[.lockTest] = "Face unlock worked at the real lock screen."
        } else {
            conditions[.lockTest] = last == nil ? .notDone : .problem
            details[.lockTest] = "Lock the screen and let FaceUnlock unlock it, to confirm everything works end to end."
        }

        m.progress = SetupProgress(conditions: conditions)
        m.details = details
    }

    private func lockScreenWithCountdown() {
        guard setupModel.lockCountdown == nil else { return }
        stopCameraUse()
        setupModel.lockCountdown = 3
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let count = self.setupModel.lockCountdown else { return }
                    if count > 1 {
                        self.setupModel.lockCountdown = count - 1
                        tick()
                    } else {
                        self.setupModel.lockCountdown = nil
                        ScreenLocker.lockNow()
                    }
                }
            }
        }
        tick()
    }

    // MARK: - Inline camera steps (enrolment, test)

    /// Stops any camera use by the Setup window (e.g. when the screen locks).
    private func stopCameraUse() {
        stopEnrolment()
        stopTest()
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
        enrolmentRunner != nil || testProcessor != nil || coordinator.isAttempting
    }

    @objc private func enrol() {
        showSetup()
        guard let analyzer, !cameraBusy else { return }
        guard integrityLoaded else { alert("Please wait", "FaceUnlock is still reading its Keychain record."); return }
        if let integrityReadError {
            alert("Can't enrol right now", "The Keychain record couldn't be read (\(integrityReadError)). Unlock your login keychain or restart FaceUnlock, then try again.")
            return
        }
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
        }, onComplete: { [weak self] embeddings, baseline in
            Task { @MainActor in self?.finishEnrolment(embeddings, baseline: baseline, cameraID: cameraID, model: model) }
        })
        enrolmentRunner = runner
        setupModel.enrolment = model
        camera.start(device: device, handler: { pb, t in runner.process(pb, at: t) }, completion: { error in
            guard let error else { return }
            let message = String(describing: error)
            Task { @MainActor in model.failed = true; model.detail = message }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + EnrolmentRunner.timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enrolmentRunner === runner, !model.finished else { return }
                runner.cancel()
                self.enrolmentRunner = nil
                self.camera.stop()
                model.failed = true
                model.instruction = "Timed out"
                model.detail = "Couldn't capture enough good frames. Try better, even lighting and keep one face in view."
            }
        }
    }

    /// Stops the camera and hides the inline enrolment.
    private func stopEnrolment() {
        guard enrolmentRunner != nil || setupModel.enrolment != nil else { return }
        enrolmentRunner?.cancel()
        enrolmentRunner = nil
        setupModel.enrolment = nil
        camera.stop()
    }

    private func finishEnrolment(_ embeddings: [[Float]], baseline: PoseBaseline?, cameraID: String, model: EnrolmentModel) {
        enrolmentRunner = nil
        camera.stop()
        model.finished = true
        model.progress = 1
        do {
            var raw = try FaceTemplate(modelID: FaceEmbedder.modelID, samples: embeddings, cameraID: cameraID)
            raw.baselinePose = baseline?.clamped
            let cleaned = try raw.removingOutliers(minimumSimilarity: 0.5, minimumKept: 12)
            if let integrityReadError { throw IntegrityError.unreadable(integrityReadError) }
            let keepEnabled = isEffectivelyEnabled
            let digest = try store.save(cleaned)
            templateDigest = digest
            template = cleaned
            coordinator.template = cleaned
            try saveIntegrityAfterEnrolment(templateSHA256: digest, keepEnabled: keepEnabled)
            model.instruction = "Enrolled ✓"
            model.detail = String(format: "%d samples kept, consistency %.2f. Now test recognition below.",
                                  cleaned.samples.count, cleaned.consistency)
        } catch {
            model.failed = true
            model.instruction = "Enrolment failed"
            model.detail = String(describing: error)
        }
        updateIcon()
        refreshSetup()
    }

    @objc private func testRecognition() {
        showSetup()
        if let testProcessor {
            // Already running: start a fresh evaluation.
            setupModel.test?.passed = false
            testProcessor.requestReset()
            return
        }
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
        let digest = templateDigest
        let processor = FaceSessionProcessor(analyzer: analyzer, template: template, policy: policy,
                                             liveness: verifiedLiveness,
                                             attentionBaseline: template.baselinePose ?? SetupStore.learnedBaselinePose,
                                             onReadout: { [weak self] readout in
            Task { @MainActor in
                let wasPassed = model.passed
                model.apply(readout)
                // Once per PASS: refine the learned baseline from this test.
                if !wasPassed, readout.snapshot.shouldUnlock, template.baselinePose == nil,
                   let b = readout.snapshot.attentivePose ?? model.strongPoseMedian {
                    SetupStore.refineLearnedBaseline(with: b)
                }
                if let typical = model.typicalScore { self?.setupModel.typicalScore = typical }
                if readout.snapshot.shouldUnlock, let digest, SetupStore.testPassedForDigest != digest {
                    SetupStore.testPassedForDigest = digest
                    self?.refreshSetup()
                }
            }
        }, stopsOnPass: false, onPass: {})
        testProcessor = processor
        setupModel.test = model
        camera.start(device: device, handler: { pb, t in processor.process(pb, at: t) }, completion: { error in
            guard let error else { return }
            let message = String(describing: error)
            Task { @MainActor in model.lines = ["Camera error: \(message)"] }
        })
    }

    private func stopTest() {
        guard testProcessor != nil || setupModel.test != nil else { return }
        testProcessor?.finish()
        testProcessor = nil
        setupModel.test = nil
        camera.stop()
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
