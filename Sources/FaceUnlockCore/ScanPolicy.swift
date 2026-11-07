import Foundation

/// When scanning starts at the lock screen.
public enum ScanStartMode: String, Codable, CaseIterable, Sendable {
    /// Continuously while the lock screen is showing (iPhone-like). Default.
    case automatic
    /// Only after the user moves the mouse or presses a key.
    case onInput

    public var title: String {
        switch self {
        case .automatic: return "Automatically when the lock screen shows"
        case .onInput: return "Only after I move the mouse or press a key"
        }
    }
}

/// Things that can (re)start scanning.
public enum ScanTrigger: String, Sendable {
    /// Periodic check while locked (covers "the lock screen is showing").
    case tick
    case userInput = "input"
    case displayWake = "wake"
    case lidOpened = "lid"
}

/// Decides whether a trigger should start the camera, given the start mode
/// and whether scanning was paused for lack of faces. Lockout and
/// lock-session checks are separate (`AttemptLockout`).
public struct ScanGate: Equatable, Sendable {
    public var mode: ScanStartMode
    /// Paused after a long time with no face (battery); input or a wake resumes.
    public private(set) var pausedForNoFace = false

    public init(mode: ScanStartMode) { self.mode = mode }

    public func shouldStart(on trigger: ScanTrigger) -> Bool {
        switch trigger {
        case .tick:
            return mode == .automatic && !pausedForNoFace
        case .userInput, .lidOpened:
            return true
        case .displayWake:
            return mode == .automatic
        }
    }

    /// Call when a trigger actually started scanning.
    public mutating func started(on trigger: ScanTrigger) {
        pausedForNoFace = false
    }

    public mutating func pauseForNoFace() { pausedForNoFace = true }

    public mutating func reset() { pausedForNoFace = false }
}

/// Watches the frame stream of one scanning period: detects "failed looks"
/// (a single face in view that keeps not matching), whether the HUD should
/// be visible, and when to pause because nobody is there.
public struct ScanMonitor: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        /// Continuous non-matching single-face time that counts as a failure.
        public var failedLookDuration: TimeInterval = 2
        /// Hide the HUD after this long without any face.
        public var hudHideAfterNoFace: TimeInterval = 3
        /// Pause the camera after this long without any face.
        public var facelessPause: TimeInterval = 60

        public init() {}
    }

    public enum Event: Equatable, Sendable {
        case failedLook
    }

    public let config: Config
    private var lastFaceAt: TimeInterval
    private var nonMatchSince: TimeInterval?

    public init(start: TimeInterval, config: Config = Config()) {
        self.config = config
        self.lastFaceAt = start
    }

    @discardableResult
    public mutating func observe(time: TimeInterval, faceCount: Int, matched: Bool) -> Event? {
        if faceCount > 0 { lastFaceAt = time }
        guard faceCount == 1, !matched else {
            // No face, several faces, or a match: not a failed look.
            nonMatchSince = nil
            return nil
        }
        guard let since = nonMatchSince else {
            nonMatchSince = time
            return nil
        }
        if time - since >= config.failedLookDuration {
            nonMatchSince = nil // the next failed look needs another full period
            return .failedLook
        }
        return nil
    }

    public func hudVisible(at time: TimeInterval) -> Bool {
        time - lastFaceAt < config.hudHideAfterNoFace
    }

    public func shouldPauseForNoFace(at time: TimeInterval) -> Bool {
        time - lastFaceAt >= config.facelessPause
    }
}
