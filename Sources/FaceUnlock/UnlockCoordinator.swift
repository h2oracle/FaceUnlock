import AVFoundation
import AppKit
import FaceUnlockCore
import Foundation

/// Watches for screen lock / wake and runs short, bounded face-unlock
/// attempts while the screen of this (already logged-in) session is locked.
///
/// Safety rules enforced here:
/// - Only acts on a lock of a session that this process has seen unlocked,
///   i.e. never at boot, FileVault or the login window (the app isn't even
///   running there) and never for another user's console session.
/// - Attempts start only on a wake that came with user input or a lid
///   opening, or on user input while locked; never in the first seconds
///   after locking.
/// - Camera runs at most `attemptDuration` seconds per attempt, and only the
///   built-in camera recorded at enrolment is used.
/// - After `AttemptLockout.maximumFailures` failed attempts,
///   `AttemptLockout.maximumAttempts` attempts in total, or one typed
///   password that didn't unlock, nothing is tried until a manual unlock.
/// - Typing re-checks the lock state and the lock-screen window before
///   every key and is cancelled on sleep or when the lock session ends.
@MainActor
final class UnlockCoordinator {
    static let attemptDuration: TimeInterval = 10
    /// Input right after locking (e.g. the lock shortcut itself) must not
    /// immediately unlock again.
    static let gracePeriodAfterLock: TimeInterval = 5
    /// Gap between the end of one attempt and an activity-triggered retry.
    static let retryCooldown: TimeInterval = 3
    /// How long to wait for the screen to unlock after typing.
    static let unlockConfirmTimeout: TimeInterval = 6
    /// "Recent" user input for activity triggers.
    static let recentInput: TimeInterval = 1.5
    /// Wake handling runs `wakeSettleDelay` after the wake, so the input
    /// that caused it may be that much older.
    static let wakeSettleDelay: TimeInterval = 0.7
    /// A lid opening counts as a wake trigger for this long.
    static let lidOpenWindow: TimeInterval = 5

    private let camera: CameraSession
    private let analyzer: FaceAnalyzer?
    var template: FaceTemplate?
    var isEnabled: () -> Bool = { false }
    /// nil when the Keychain integrity record matches the template file and
    /// threshold; otherwise a message for the user.
    var integrityProblem: () -> String? = { "Not set up" }
    /// The verified match policy (threshold from the Keychain record).
    var policy: () -> MatchPolicy = { MatchPolicy() }

    /// Called whenever `status` changes (for the menu).
    var onStatusChange: (() -> Void)?
    /// Called when a lock session begins (stop any camera use in windows).
    var onLockSessionBegan: (() -> Void)?
    /// Called with the outcome of each lock-screen attempt (persisted by the
    /// app for the setup window's lock-screen test).
    var onAttemptRecorded: ((AttemptRecord) -> Void)?
    /// One "didn't run" record per lock session is enough.
    private var recordedNotReadyThisSession = false
    /// Whether the camera is currently owned by an unlock attempt.
    private(set) var isAttempting = false

    private(set) var status = "Idle" {
        didSet { if status != oldValue { onStatusChange?() } }
    }

    private var lockout = AttemptLockout()
    private var inLockSession = false
    private var sawUnlockedSinceLaunch = false
    private var lockStartedAt: TimeInterval = 0
    private var lastAttemptEnded: TimeInterval = 0
    private var isSleeping = false
    private var isTyping = false
    private var typingCancellation: TypingCancellation?

    private var lidWasClosed = false
    private var lidOpenedAt: TimeInterval?

    private var processor: FaceSessionProcessor?
    private var attemptID = 0
    private var deadline: DispatchWorkItem?
    private var pollTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

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

        // Cheap 1 Hz poll: catches missed notifications, lid changes and user
        // activity at the lock screen (which can't be observed directly).
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    // MARK: - State tracking

    private func updateLidState() {
        guard let closed = Clamshell.isClosed() else { return }
        if lidWasClosed && !closed { lidOpenedAt = now }
        lidWasClosed = closed
    }

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
        maybeStartAttempt(trigger: .activity)
    }

    private var idleStatus: String {
        guard isEnabled() else { return "Disabled" }
        return integrityProblem() ?? "Ready (waiting for screen lock)"
    }

    private func record(_ outcome: AttemptOutcome) {
        onAttemptRecorded?(AttemptRecord(outcome: outcome))
    }

    /// Records why no attempt could start (once per lock session).
    private func notReady(_ reason: String) {
        status = reason
        guard !recordedNotReadyThisSession else { return }
        recordedNotReadyThisSession = true
        record(.notReady(reason))
    }

    private func beginLockSession() {
        recordedNotReadyThisSession = false
        inLockSession = true
        lockStartedAt = now
        lockout.startNewLockSession()
        status = "Screen locked"
        onLockSessionBegan?()
    }

    private func endLockSession() {
        inLockSession = false
        // Screen unlocked while (or just after) we typed: it worked.
        if isTyping { record(.unlocked) }
        cancelTyping()
        cancelAttempt(countAsFailure: false)
        lockout.startNewLockSession()
    }

    private func cancelTyping() {
        typingCancellation?.cancel()
        typingCancellation = nil
        isTyping = false
    }

    private func handleSleep() {
        // Lid closing usually comes with sleep; remember it for the wake.
        updateLidState()
        isSleeping = true
        cancelTyping()
        cancelAttempt(countAsFailure: true)
    }

    private func handleWake() {
        isSleeping = false
        // Let the lock screen settle before turning the camera on.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.maybeStartAttempt(trigger: .wake)
            }
        }
    }

    // MARK: - Attempts

    private enum Trigger { case wake, activity }

    private func maybeStartAttempt(trigger: Trigger) {
        guard inLockSession, processor == nil, !isTyping, !isSleeping else { return }
        guard lockout.canStartAttempt else {
            if !recordedNotReadyThisSession {
                recordedNotReadyThisSession = true
                record(.lockedOut)
            }
            if lockout.passwordRejected {
                status = "Stopped: password could not be typed or did not unlock. Unlock manually."
            } else if lockout.isLockedOut {
                status = "Stopped after \(lockout.failures) failed attempts. Unlock manually."
            } else {
                status = "Stopped after \(lockout.attemptsStarted) attempts. Unlock manually."
            }
            return
        }
        guard now - lockStartedAt >= Self.gracePeriodAfterLock else { return }
        let input = SessionState.secondsSinceUserInput
        switch trigger {
        case .activity:
            guard input < Self.recentInput, now - lastAttemptEnded >= Self.retryCooldown else { return }
        case .wake:
            let lidJustOpened = lidOpenedAt.map { now - $0 <= Self.lidOpenWindow } ?? false
            guard lidJustOpened || input < Self.recentInput + Self.wakeSettleDelay else { return }
        }
        let state = SessionState.current()
        guard state.screenLocked, state.onConsole, state.loginDone else { return }
        guard !SessionState.displayAsleep else { return }
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

        lidOpenedAt = nil
        lockout.recordAttemptStarted()
        attemptID += 1
        let id = attemptID
        let processor = FaceSessionProcessor(analyzer: analyzer, template: template, policy: policy()) { [weak self] in
            Task { @MainActor in self?.attemptPassed(id: id) }
        }
        self.processor = processor
        isAttempting = true
        status = "Looking for your face… (attempt \(lockout.attemptsStarted) of max \(lockout.maximumAttempts))"
        log.info("Face unlock attempt started")

        camera.start(device: device, handler: { pixelBuffer, time in
            processor.process(pixelBuffer, at: time)
        }, completion: { [weak self] error in
            guard let error else { return }
            let message = String(describing: error)
            Task { @MainActor in self?.attemptFailedToStart(id: id, message: message) }
        })

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.attemptTimedOut(id: id) }
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.attemptDuration, execute: work)
    }

    private func stopCamera() {
        deadline?.cancel()
        deadline = nil
        processor?.finish()
        processor = nil
        camera.stop()
        isAttempting = false
        lastAttemptEnded = now
    }

    /// Only attempts in which a face was seen count as failures.
    private func cancelAttempt(countAsFailure: Bool) {
        guard let processor else { return }
        let sawFace = processor.sawFace
        let diagnostics = processor.diagnostics
        stopCamera()
        if countAsFailure && sawFace {
            lockout.recordFailure()
            record(diagnostics.failureOutcome)
        }
    }

    private func attemptFailedToStart(id: Int, message: String) {
        guard id == attemptID, processor != nil else { return }
        stopCamera()
        status = "Camera error: \(message)"
        record(.cameraError(message))
    }

    private func attemptTimedOut(id: Int) {
        guard id == attemptID, let processor else { return }
        let sawFace = processor.sawFace
        let diagnostics = processor.diagnostics
        stopCamera()
        record(diagnostics.failureOutcome)
        if sawFace {
            lockout.recordFailure()
            status = lockout.canStartAttempt
                ? "Not recognised (\(lockout.remainingAttempts) attempt(s) left)"
                : "Stopped after \(lockout.failures) failed attempts. Unlock manually."
        } else {
            status = "No face seen; will retry on activity"
        }
        log.info("Face unlock attempt ended without a match (face seen: \(sawFace, privacy: .public))")
    }

    private func attemptPassed(id: Int) {
        guard id == attemptID, processor != nil else { return }
        stopCamera()

        // Re-verify everything right before typing.
        let state = SessionState.current()
        guard inLockSession, isEnabled(), !lockout.isLockedOut, integrityProblem() == nil,
              state.screenLocked, state.onConsole, state.loginDone,
              Permissions.accessibilityTrusted else {
            status = "Match ignored (state changed)"
            return
        }

        let cancellation = TypingCancellation()
        typingCancellation = cancellation
        isTyping = true
        status = "Recognised – unlocking…"
        log.info("Face matched with liveness; typing password")
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: AttemptOutcome?
            do {
                let secret = try PasswordVault.readPassword()
                defer { secret.wipe() }
                KeyTyper.wakeDisplay()
                usleep(250_000)
                try KeyTyper.typeAndSubmit(secret, cancellation: cancellation)
                failure = nil
            } catch let error as PasswordVault.VaultError {
                failure = .keychainError(error.description)
            } catch KeyTyper.TypingError.frontWindow(.otherOwner(let owner)) {
                failure = .frontWindowRefused(owner: owner)
            } catch {
                failure = .typingStopped(String(describing: error))
            }
            await MainActor.run { self?.typingFinished(id: id, failure: failure) }
        }
    }

    private func typingFinished(id: Int, failure: AttemptOutcome?) {
        guard id == attemptID, isTyping else { return }
        if let failure {
            isTyping = false
            typingCancellation = nil
            // Couldn't read or type the password: stop for this lock session.
            lockout.recordPasswordRejected()
            status = failure.summary
            record(failure)
            log.error("Typing aborted: \(failure.summary, privacy: .public)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unlockConfirmTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, id == self.attemptID, self.isTyping else { return }
                self.isTyping = false
                self.typingCancellation = nil
                if SessionState.current().screenLocked && self.inLockSession {
                    self.lockout.recordPasswordRejected()
                    self.status = "Typed password did not unlock. Check the stored password."
                    self.record(.passwordRejected)
                    log.error("Typed password did not unlock the screen; stopping for this lock session")
                }
            }
        }
    }
}
