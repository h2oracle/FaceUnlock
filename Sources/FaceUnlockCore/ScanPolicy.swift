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

/// Watches the frame stream of one scanning period and decides when a
/// "failed look" has happened. Built so it can't be reset by covering the
/// lens or adding a second face:
///
/// - **Not recognised**: one face in view that doesn't match accumulates
///   time in a bucket. Frames with no face or several faces neither add to
///   nor empty it; matching frames drain it at the same rate. 2 s in the
///   bucket = one failed look.
/// - **Brief appearance**: a single-face appearance (a run of single-face
///   frames) that lasts at least `briefAppearanceFrames` frames and ends
///   without ever matching is one failed look, so showing a face in short
///   bursts doesn't escape the bucket.
/// - **Not live**: a face that matches but never passes liveness for 3 s in
///   total (e.g. a photo of the owner) is one failed look.
///
/// It also says whether the HUD should be visible and when to pause because
/// nobody is there.
public struct ScanMonitor: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var failedLookDuration: TimeInterval = 2
        public var briefAppearanceFrames = 6
        public var notLiveDuration: TimeInterval = 3
        /// Gaps between frames longer than this only count this much.
        public var maximumFrameGap: TimeInterval = 0.2
        /// Hide the HUD after this long without any face.
        public var hudHideAfterNoFace: TimeInterval = 3
        /// Pause the camera after this long without any face.
        public var facelessPause: TimeInterval = 60

        public init() {}
    }

    public enum Event: String, Equatable, Sendable {
        case notRecognised = "not recognised"
        case briefAppearance = "brief unrecognised appearance"
        case notLive = "matched but not verified live"
    }

    public let config: Config
    private var lastFaceAt: TimeInterval
    private var lastFrameAt: TimeInterval?
    private var nonMatchBucket: TimeInterval = 0
    private var notLiveTime: TimeInterval = 0
    private var appearanceFrames = 0
    private var appearanceMatched = false
    private var appearanceCounted = false

    public init(start: TimeInterval, config: Config = Config()) {
        self.config = config
        self.lastFaceAt = start
    }

    /// Seconds since the previous frame (capped), for face-time accounting.
    public private(set) var lastFrameDuration: TimeInterval = 0

    @discardableResult
    public mutating func observe(time: TimeInterval, faceCount: Int, matched: Bool, live: Bool = false) -> Event? {
        let dt = lastFrameAt.map { min(max(0, time - $0), config.maximumFrameGap) } ?? 0
        lastFrameAt = time
        lastFrameDuration = dt
        if faceCount > 0 { lastFaceAt = time }

        guard faceCount == 1 else {
            // The appearance ended (lens covered, face left, second face).
            return endAppearance()
        }
        appearanceFrames += 1
        if matched {
            appearanceMatched = true
            nonMatchBucket = max(0, nonMatchBucket - dt)
            if !live {
                notLiveTime += dt
                if notLiveTime >= config.notLiveDuration {
                    notLiveTime = 0
                    return .notLive
                }
            }
            return nil
        }
        nonMatchBucket += dt
        if nonMatchBucket >= config.failedLookDuration {
            nonMatchBucket = 0
            appearanceCounted = true
            return .notRecognised
        }
        return nil
    }

    /// Call when the scan stops, to count an appearance that was still open.
    public mutating func finish() -> Event? { endAppearance() }

    private mutating func endAppearance() -> Event? {
        defer {
            appearanceFrames = 0
            appearanceMatched = false
            appearanceCounted = false
        }
        if appearanceFrames >= config.briefAppearanceFrames && !appearanceMatched && !appearanceCounted {
            return .briefAppearance
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
