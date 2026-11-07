import AVFoundation
import AppKit
import FaceUnlockCore
import Foundation

/// Watches the screen-lock state and scans for the owner's face while the
/// lock screen of this (already logged-in) session is showing.
///
/// Start modes (`ScanStartMode`):
/// - automatic (default): the camera scans continuously while the session is
///   locked and the display is awake, starting 1 s after locking and on every
///   display wake / lid opening. No input needed.
/// - on input: scanning starts on a mouse move or key press and runs for at
///   most `onInputScanDuration`.
///
/// Safety rules enforced here:
/// - Only acts on a lock of a session that this process has seen unlocked,
///   i.e. never at boot, FileVault or the login window (the app isn't even
///   running there) and never for another user's console session.
/// - Nothing happens in the first second after locking, so the lock
///   keystroke itself can't start a scan.
/// - Only the built-in camera recorded at enrolment is used.
/// - A "failed look" (one face in view that keeps not matching for ~2 s) is a
///   failure. After 3, scanning stops until the display sleeps and wakes;
///   after 5 in the lock session, or one typed password that didn't unlock,
///   nothing is tried until a manual unlock. Frames without a face never
///   count. After 60 s without any face the camera pauses until input/wake.
/// - Typing re-checks the lock state and the lock-screen window before
///   every key and is cancelled on sleep or when the lock session ends.
@MainActor
final class UnlockCoordinator {
    static let gracePeriodAfterLock: TimeInterval = 1
    static let onInputScanDuration: TimeInterval = 10
    /// How long to wait for the screen to unlock after typing.
    static let unlockConfirmTimeout: TimeInterval = 6
    /// Input/tick polling interval while locked (cheap: an idle-time read).
    static let fastPollInterval: TimeInterval = 0.1
    static let wakeSettleDelay: TimeInterval = 0.25
    /// After a "not ready" check fails, re-check on ticks only this often.
    static let notReadyRecheck: TimeInterval = 2

    private let camera: CameraSession
    private let analyzer: FaceAnalyzer?
    var template: FaceTemplate?
    var isEnabled: () -> Bool = { false }
    /// nil when the Keychain integrity record matches the template file and
    /// threshold; otherwise a message for the user.
    var integrityProblem: () -> String? = { "Not set up" }
    /// The verified match policy (threshold from the Keychain record).
    var policy: () -> MatchPolicy = { MatchPolicy() }
    /// The verified liveness mode (from the Keychain record).
    var liveness: () -> LivenessMode = { .blinkAndMovement }
    var startMode: () -> ScanStartMode = { .automatic }

    /// Called whenever `status` changes (for the menu).
    var onStatusChange: (() -> Void)?
    /// Called when a lock session begins (stop any camera use in windows).
    var onLockSessionBegan: (() -> Void)?
    /// Called with the outcome of lock-screen attempts (persisted by the app
    /// for the setup window's lock-screen test).
    var onAttemptRecorded: ((AttemptRecord) -> Void)?

    /// Whether the camera is currently owned by lock-screen scanning.
    private(set) var isAttempting = false

    private(set) var status = "Idle" {
        didSet { if status != oldValue { onStatusChange?() } }
    }

    private var lockout = AttemptLockout()
    private var gate = ScanGate(mode: .automatic)
    private var monitor: ScanMonitor?
    private var inLockSession = false
    private var sawUnlockedSinceLaunch = false
    private var lockStartedAt: TimeInterval = 0
    private var displaySleeping = false
    private var displaySleptDuringLock = false
    private var isTyping = false
    /// The password was typed in full but the unlock hasn't been confirmed
    /// yet. Survives sleep/cancel so a stale password is never retyped.
    private var awaitingUnlockConfirmation = false
    private var typingCancellation: TypingCancellation?
    private var lastIdle: TimeInterval = .infinity
    private var notReadyUntil: TimeInterval = 0
    private var recordedNotReadyThisSession = false
    private var recordedLockoutThisSession = false
    private var lastBlockedReason: String?

    /// Face ID-style HUD on the lock screen (cosmetic, best effort).
    private let overlay = LockOverlay()

    private var lidWasClosed = false

    private var processor: FaceSessionProcessor?
    private var scanID = 0
    private var scanDeadline: DispatchWorkItem?
    private var pollTimer: Timer?
    private var fastTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Timing of the current scan, for the diagnostics breakdown.
    private struct Timing {
        var trigger: ScanTrigger
        var start: TimeInterval
        var inputAt: TimeInterval?
        var firstFrame: TimeInterval?
        var firstFace: TimeInterval?
        var match: TimeInterval?
        var typingDone: TimeInterval?
    }
    private var timing: Timing?

    init(camera: CameraSession, analyzer: FaceAnalyzer?) {
        self.camera = camera
        self.analyzer = analyzer
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter

        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { body() }
            }
            observers.append((center, token))
        }

        // These notifications are only hints (any same-user process can post
        // them); every decision re-reads the authoritative CGSession state.
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.refresh() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.refresh() }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { [weak self] in self?.handleWake() }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.handleSleep() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.handleSleep() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.handleWake() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.handleWake() }

        // 1 Hz: catches missed notifications and lid changes.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    // MARK: - Lock session

    private func refresh() {
        updateLidState()
        let state = SessionState.current()
        if !state.screenLocked {
            if state.onConsole && state.loginDone { sawUnlockedSinceLaunch = true }
            if inLockSession { endLockSession() }
            if status != idleStatus { status = idleStatus }
            return
        }
        if !inLockSession {
            guard sawUnlockedSinceLaunch else { return }
            beginLockSession()
        }
    }

    private var idleStatus: String {
        guard isEnabled() else { return "Disabled" }
        return integrityProblem() ?? "Ready (waiting for screen lock)"
    }

    private func beginLockSession() {
        inLockSession = true
        lockStartedAt = now
        lockout.startNewLockSession()
        awaitingUnlockConfirmation = false
        gate = ScanGate(mode: startMode())
        displaySleptDuringLock = false
        recordedNotReadyThisSession = false
        recordedLockoutThisSession = false
        lastBlockedReason = nil
        notReadyUntil = 0
        lastIdle = .infinity
        status = "Screen locked"
        diag("lock session began (enabled=\(isEnabled()), start=\(gate.mode.rawValue), liveness=\(liveness().rawValue), threshold=\(String(format: "%.2f", policy().threshold)))")
        onLockSessionBegan?()
        prepareCamera()
        startFastTimer()
    }

    private func endLockSession() {
        inLockSession = false
        stopFastTimer()
        let t = now
        diag(String(format: "lock session ended: screen unlocked after %.1fs", t - lockStartedAt))
        if isTyping || awaitingUnlockConfirmation {
            // Screen unlocked while (or just after) we typed: it worked.
            logTiming(unlockedAt: t)
            record(.unlocked)
            awaitingUnlockConfirmation = false
        } else if let processor {
            processor.flushDiagnostics()
            if processor.sawFace {
                record(.unlockedManually(lastIssue: processor.diagnostics.failureOutcome))
            }
            diag("scan ended: unlocked manually before a match")
        }
        cancelTyping()
        stopScan()
        overlay.hide()
        lockout.startNewLockSession()
    }

    private func cancelTyping() {
        typingCancellation?.cancel()
        typingCancellation = nil
        isTyping = false
    }

    private func handleSleep() {
        guard !displaySleeping else { return }
        displaySleeping = true
        updateLidState()
        if inLockSession { displaySleptDuringLock = true }
        cancelTyping()
        if processor != nil {
            diag("scan ended: display/Mac went to sleep")
            endScanRecordingOutcome()
        }
        overlay.hide()
    }

    /// Typed password, still locked, and the confirmation was interrupted:
    /// treat it as rejected so it's never typed again in this lock session.
    private func resolveUnconfirmedTyping() {
        guard awaitingUnlockConfirmation, inLockSession, SessionState.current().screenLocked else { return }
        awaitingUnlockConfirmation = false
        lockout.recordPasswordRejected()
        status = "Typed password did not unlock. Check the stored password."
        record(.passwordRejected)
        log.error("Typed password was not confirmed before sleep; stopping for this lock session")
    }

    private func handleWake() {
        let wasSleeping = displaySleeping
        displaySleeping = false
        if wasSleeping && displaySleptDuringLock {
            // A fresh set of looks after sleep → wake.
            lockout.displayWoke()
            displaySleptDuringLock = false
        }
        gate.reset()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.resolveUnconfirmedTyping()
                self.trigger(.displayWake)
            }
        }
    }

    private func updateLidState() {
        guard let closed = Clamshell.isClosed() else { return }
        let opened = lidWasClosed && !closed
        lidWasClosed = closed
        if opened && inLockSession {
            gate.reset()
            trigger(.lidOpened)
        }
    }

    // MARK: - Fast poll (input + continuous checks)

    private func startFastTimer() {
        guard fastTimer == nil else { return }
        let timer = Timer(timeInterval: Self.fastPollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.fastTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fastTimer = timer
    }

    private func stopFastTimer() {
        fastTimer?.invalidate()
        fastTimer = nil
    }

    private func fastTick() {
        guard inLockSession else { return }
        let idle = SessionState.secondsSinceUserInput
        let newInput = idle + 0.05 < lastIdle && idle < 1
        lastIdle = idle

        if let monitor, processor != nil {
            let t = now
            overlay.setVisible(monitor.hudVisible(at: t))
            if monitor.shouldPauseForNoFace(at: t) {
                diag("scan paused: no face for \(Int(monitor.config.facelessPause))s (resumes on input or wake)")
                stopScan()
                gate.pauseForNoFace()
                overlay.hide()
                status = "Paused (no face); move the mouse to resume"
            }
            return
        }
        trigger(newInput ? .userInput : .tick)
    }

    // MARK: - Starting / stopping scans

    private func record(_ outcome: AttemptOutcome) {
        diag("record: \(outcome.summary)")
        onAttemptRecorded?(AttemptRecord(outcome: outcome))
    }

    /// Writes to the diagnostics file and the persisted unified log.
    /// Never pass secrets.
    private func diag(_ message: String) {
        Diagnostics.write(message)
        log.notice("\(message, privacy: .public)")
    }

    /// Logs (once per distinct reason) why scanning is being held back.
    private func blocked(_ reason: String, detail: String = "") {
        guard reason != lastBlockedReason else { return }
        lastBlockedReason = reason
        diag("no scan: \(reason)\(detail.isEmpty ? "" : " (\(detail))")")
    }

    /// Records why scanning can't start (once per lock session).
    private func notReady(_ reason: String) {
        blocked("not ready: \(reason)")
        status = reason
        notReadyUntil = now + Self.notReadyRecheck
        guard !recordedNotReadyThisSession else { return }
        recordedNotReadyThisSession = true
        record(.notReady(reason))
    }

    private func trigger(_ trigger: ScanTrigger) {
        guard inLockSession, processor == nil, !isTyping, !awaitingUnlockConfirmation else { return }
        guard !displaySleeping else { blocked("display asleep"); return }
        guard !lockout.isLockedOut else {
            blocked("stopped until manual unlock", detail: "failures=\(lockout.totalFailures) passwordRejected=\(lockout.passwordRejected)")
            status = lockout.passwordRejected
                ? "Stopped: password could not be typed or did not unlock. Unlock manually."
                : "Stopped after \(lockout.totalFailures) failed looks. Unlock manually."
            if !recordedLockoutThisSession {
                recordedLockoutThisSession = true
                record(.lockedOut)
            }
            return
        }
        guard !lockout.needsDisplayWake else {
            blocked("paused until the display sleeps and wakes", detail: "failed looks=\(lockout.failures)")
            status = "Face not recognised – use your password"
            return
        }
        guard gate.shouldStart(on: trigger) else {
            if trigger == .tick {
                blocked(gate.pausedForNoFace ? "paused (no face), waiting for input" : "waiting for mouse/keyboard input")
            }
            return
        }
        guard now - lockStartedAt >= Self.gracePeriodAfterLock else { blocked("grace period after locking"); return }
        if trigger == .tick && now < notReadyUntil { return }
        let state = SessionState.current()
        guard state.screenLocked, state.onConsole, state.loginDone else {
            blocked("session state", detail: "locked=\(state.screenLocked) onConsole=\(state.onConsole) loginDone=\(state.loginDone)")
            return
        }
        guard !SessionState.displayAsleep else { blocked("display asleep"); return }
        guard isEnabled() else { notReady("face unlock is turned off"); return }
        guard let analyzer, let template, template.modelID == FaceEmbedder.modelID else {
            notReady("no face enrolled"); return
        }
        if let problem = integrityProblem() { notReady(problem); return }
        guard let device = CameraSession.device(uniqueID: template.cameraID), template.cameraID != nil else {
            notReady("the enrolled camera isn't available"); return
        }
        guard Permissions.cameraAuthorized else { notReady("camera permission missing"); return }
        guard Permissions.accessibilityTrusted else { notReady("Accessibility permission missing"); return }
        guard PasswordVault.passwordExists() else { notReady("no password stored"); return }

        startScan(trigger: trigger, analyzer: analyzer, template: template, device: device)
    }

    /// Configure the camera ahead of time (no light) so starting is quick.
    private func prepareCamera() {
        guard let template, template.cameraID != nil,
              let device = CameraSession.device(uniqueID: template.cameraID) else { return }
        camera.prepare(device: device)
    }

    private func startScan(trigger: ScanTrigger, analyzer: FaceAnalyzer, template: FaceTemplate, device: AVCaptureDevice) {
        gate.started(on: trigger)
        lastBlockedReason = nil
        scanID += 1
        let id = scanID
        let policy = policy()
        let liveness = liveness()
        let t = now
        let idle = SessionState.secondsSinceUserInput
        timing = Timing(trigger: trigger, start: t, inputAt: idle < 5 ? t - idle : nil)
        monitor = ScanMonitor(start: t)
        diag(String(format: "scan %d started: trigger=%@ mode=%@ sinceLock=%.1fs idle=%.1fs liveness=%@ threshold=%.2f",
                    id, trigger.rawValue, gate.mode.rawValue, t - lockStartedAt, idle, liveness.rawValue, policy.threshold))

        let processor = FaceSessionProcessor(
            analyzer: analyzer, template: template, policy: policy, liveness: liveness,
            onReadout: { [weak self] readout in
                let faces = readout.snapshot.faceCount
                let matched = readout.snapshot.frameMatched
                let live = readout.snapshot.livenessSatisfied
                Task { @MainActor in self?.frameObserved(id: id, faceCount: faces, matched: matched, live: live) }
            },
            onDiagnostics: { line in Diagnostics.write("  \(line)") }
        ) { [weak self] in
            Task { @MainActor in self?.scanPassed(id: id) }
        }
        self.processor = processor
        isAttempting = true
        status = "Looking for your face…"
        overlay.showScanning()

        camera.start(device: device, handler: { pixelBuffer, time in
            processor.process(pixelBuffer, at: time)
        }, completion: { [weak self] error in
            guard let error else { return }
            let message = String(describing: error)
            Task { @MainActor in self?.scanFailedToStart(id: id, message: message) }
        })

        if gate.mode == .onInput {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.scanTimeLimit(id: id) }
            }
            scanDeadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.onInputScanDuration, execute: work)
        }
    }

    /// Stops the camera and forgets the current scan (no recording).
    private func stopScan() {
        scanDeadline?.cancel()
        scanDeadline = nil
        processor?.finish()
        processor = nil
        // An unrecognised appearance still open when the camera stops counts too.
        if let event = monitor?.finish() {
            monitor = nil
            lockout.recordFailure()
            diag("failed look (\(event.rawValue)) at scan end; lock-session total \(lockout.totalFailures)/\(lockout.maximumTotalFailures)")
        }
        monitor = nil
        camera.stop()
        isAttempting = false
    }

    /// Ends the scan, saving what held it back if a face was seen.
    private func endScanRecordingOutcome() {
        guard let processor else { return }
        processor.flushDiagnostics()
        let sawFace = processor.sawFace
        let outcome = processor.diagnostics.failureOutcome
        stopScan()
        if sawFace { record(outcome) }
    }

    private func frameObserved(id: Int, faceCount: Int, matched: Bool, live: Bool) {
        guard id == scanID, processor != nil, var monitor else { return }
        let t = now
        if timing?.firstFrame == nil { timing?.firstFrame = t }
        if faceCount > 0, timing?.firstFace == nil { timing?.firstFace = t }
        let event = monitor.observe(time: t, faceCount: faceCount, matched: matched, live: live)
        self.monitor = monitor
        if faceCount > 0 {
            lockout.recordFaceTime(monitor.lastFrameDuration)
            if lockout.faceTimeExhausted {
                diag("scan ended: face-time limit for this lock session reached (\(Int(lockout.maximumFaceSeconds))s)")
                endScanRecordingOutcome()
                overlay.showStopped()
                status = "Stopped (time limit). Unlock manually."
                return
            }
        }
        overlay.setVisible(monitor.hudVisible(at: t))
        guard let event else { return }
        failedLook(event)
    }

    /// Counts a failed look and stops scanning when the limits are reached.
    private func failedLook(_ event: ScanMonitor.Event) {
        lockout.recordFailure()
        diag("failed look (\(event.rawValue)) \(lockout.failures)/\(lockout.maximumFailures) (lock-session total \(lockout.totalFailures)/\(lockout.maximumTotalFailures))")
        guard processor != nil else { return }
        if lockout.canScan {
            overlay.flashFailure(event == .notLive ? "Couldn't Verify\nLive Face" : "Face Not Recognised")
            status = "Not recognised (\(lockout.remainingBeforePause) look(s) left)"
        } else {
            diag("scan ended: too many failed looks")
            endScanRecordingOutcome()
            overlay.showStopped()
            status = lockout.isLockedOut
                ? "Stopped after \(lockout.totalFailures) failed looks. Unlock manually."
                : "Face not recognised – use your password"
        }
    }

    private func scanFailedToStart(id: Int, message: String) {
        guard id == scanID, processor != nil else { return }
        stopScan()
        overlay.hide()
        diag("scan ended: camera error: \(message)")
        status = "Camera error: \(message)"
        record(.cameraError(message))
        notReadyUntil = now + Self.notReadyRecheck
    }

    private func scanTimeLimit(id: Int) {
        guard id == scanID, processor != nil else { return }
        diag("scan ended: \(Int(Self.onInputScanDuration))s limit (on-input mode)")
        let sawFace = processor?.sawFace ?? false
        endScanRecordingOutcome()
        if sawFace { overlay.flashFailureAndHide() } else { overlay.hide() }
        status = "Waiting for mouse/keyboard input"
    }

    // MARK: - Unlocking

    private func scanPassed(id: Int) {
        guard id == scanID, let processor else { return }
        timing?.match = now
        processor.flushDiagnostics()
        stopScan()
        diag("scan ended: face matched with liveness")

        // Re-verify everything right before typing.
        let state = SessionState.current()
        guard inLockSession, isEnabled(), !lockout.isLockedOut, integrityProblem() == nil,
              state.screenLocked, state.onConsole, state.loginDone,
              Permissions.accessibilityTrusted else {
            status = "Match ignored (state changed)"
            diag("match ignored: state changed before typing")
            overlay.hide()
            return
        }

        let cancellation = TypingCancellation()
        typingCancellation = cancellation
        isTyping = true
        status = "Recognised – unlocking…"
        // The tick animation runs in parallel; typing doesn't wait for it.
        overlay.showSuccess()
        let wakeFirst = SessionState.displayAsleep
        Task { @MainActor [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> AttemptOutcome? in
                let failure: AttemptOutcome?
                do {
                    let secret = try PasswordVault.readPassword()
                    defer { secret.wipe() }
                    if wakeFirst {
                        KeyTyper.wakeDisplay()
                        usleep(100_000)
                    }
                    try KeyTyper.typeAndSubmit(secret, cancellation: cancellation)
                    failure = nil
                } catch let error as PasswordVault.VaultError {
                    failure = .keychainError(error.description)
                } catch KeyTyper.TypingError.frontWindow(.otherOwner(let owner)) {
                    failure = .frontWindowRefused(owner: owner)
                } catch {
                    failure = .typingStopped(String(describing: error))
                }
                return failure
            }.value
            self?.typingFinished(id: id, failure: failure)
        }
    }

    private func typingFinished(id: Int, failure: AttemptOutcome?) {
        guard id == scanID, isTyping else { return }
        timing?.typingDone = now
        if let failure {
            isTyping = false
            typingCancellation = nil
            // Couldn't read or type the password: stop for this lock session.
            lockout.recordPasswordRejected()
            status = failure.summary
            overlay.hide()
            record(failure)
            log.error("Typing aborted: \(failure.summary, privacy: .public)")
            return
        }
        diag("typing done")
        awaitingUnlockConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unlockConfirmTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, id == self.scanID, self.awaitingUnlockConfirmation else { return }
                self.isTyping = false
                self.typingCancellation = nil
                self.overlay.hide()
                self.resolveUnconfirmedTyping()
            }
        }
    }

    private func logTiming(unlockedAt: TimeInterval) {
        guard let t = timing else { return }
        func ms(_ a: TimeInterval?, _ b: TimeInterval?) -> String {
            guard let a, let b else { return "-" }
            return String(format: "%.0fms", (b - a) * 1000)
        }
        var line = "timing: trigger=\(t.trigger.rawValue)"
        line += " scanStart→firstFrame=\(ms(t.start, t.firstFrame))"
        line += " firstFace→match=\(ms(t.firstFace, t.match))"
        line += " match→typingDone=\(ms(t.match, t.typingDone))"
        line += " typingDone→unlocked=\(ms(t.typingDone, unlockedAt))"
        line += " scanStart→unlocked=\(ms(t.start, unlockedAt))"
        if let input = t.inputAt { line += " lastInput→unlocked=\(ms(input, unlockedAt))" }
        diag(line)
    }
}
