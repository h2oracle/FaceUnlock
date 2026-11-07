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
/// lens or adding a second face, and so a badly placed owner isn't punished:
///
/// - Frames with no face or an *unusable* face (bad angle, too small, cut
///   off, low quality; see `FrameQualityGate`) are neither matches nor
///   non-matches. They add nothing to any failure count.
/// - **Not recognised**: time with one usable, non-matching face goes into a
///   bucket. No-face, unusable and multi-face frames neither fill nor empty
///   it, and matching frames drain it. 2 s in the bucket is a failed look.
/// - **Brief appearance**: an appearance (no-face gaps up to 0.7 s don't
///   split it) with at least 1 s of usable non-matching time that never
///   matched is a failed look.
/// - **Not live**: a face that matches but doesn't pass liveness for 6 s
///   (natural movement) or 8 s (blink + movement) in total, e.g. a photo of
///   the owner, is one failed look. Time only accrues while the liveness
///   evidence isn't improving: whenever it reaches a new high, the bucket
///   drains instead. A photo's evidence plateaus, so it's still bounded.
/// - At most one failed look is reported per 2 s.
///
/// It also says whether the HUD should be visible, whether to ask the user
/// to face the screen, and when to pause because nobody is there.
public struct ScanMonitor: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var failedLookDuration: TimeInterval = 2
        /// Usable non-matching time an appearance needs to count.
        public var briefAppearanceDuration: TimeInterval = 1
        /// No-face/unusable gaps up to this long don't end an appearance.
        public var appearanceGap: TimeInterval = 0.7
        public var minimumEventInterval: TimeInterval = 2
        public var notLiveDuration: TimeInterval = 6
        /// Liveness progress must beat its previous best by this much to count
        /// as "improving".
        public var progressStep = 0.01
        /// Gaps between frames longer than this only count this much.
        public var maximumFrameGap: TimeInterval = 0.2
        /// Hide the HUD after this long without any face.
        public var hudHideAfterNoFace: TimeInterval = 3
        /// Ask the user to face the screen after this long with only unusable faces.
        public var lookAtScreenAfter: TimeInterval = 0.6
        /// Pause the camera after this long without any face.
        public var facelessPause: TimeInterval = 60

        public init() {}

        /// Per-mode defaults.
        public init(liveness: LivenessMode) {
            switch liveness {
            case .naturalMovement: notLiveDuration = 6
            case .blinkAndMovement: notLiveDuration = 8
            case .off: notLiveDuration = .infinity
            }
        }
    }

    public enum Event: String, Equatable, Sendable {
        case notRecognised = "not recognised"
        case briefAppearance = "brief unrecognised appearance"
        case notLive = "matched but not verified live"
    }

    public let config: Config
    private var lastFaceAt: TimeInterval
    private var lastUsableAt: TimeInterval
    private var lastFrameAt: TimeInterval?
    private var lastEventAt: TimeInterval = -.infinity
    private var nonMatchBucket: TimeInterval = 0
    private var notLiveTime: TimeInterval = 0
    private var bestLivenessProgress = 0.0
    // Current appearance.
    private var inAppearance = false
    private var gapStart: TimeInterval?
    private var appearanceNonMatch: TimeInterval = 0
    private var appearanceMatched = false
    private var appearanceCounted = false

    public init(start: TimeInterval, config: Config = Config()) {
        self.config = config
        self.lastFaceAt = start
        self.lastUsableAt = start
    }

    /// Seconds since the previous frame (capped), for face-time accounting.
    public private(set) var lastFrameDuration: TimeInterval = 0

    @discardableResult
    public mutating func observe(time: TimeInterval, faceCount: Int, matched: Bool, live: Bool = false,
                                 usable: Bool = true, livenessProgress: Double = 0) -> Event? {
        let dt = lastFrameAt.map { min(max(0, time - $0), config.maximumFrameGap) } ?? 0
        lastFrameAt = time
        lastFrameDuration = dt
        if faceCount > 0 { lastFaceAt = time }

        if faceCount > 1 {
            // A second face ends the appearance immediately.
            return emit(endAppearance(), at: time)
        }
        if faceCount == 0 || (!usable && !matched) {
            // Neither a match nor a non-match (a matching frame always
            // counts as a match); long gaps end the appearance.
            guard inAppearance else { return nil }
            let start = gapStart ?? time
            gapStart = start
            if time - start > config.appearanceGap {
                return emit(endAppearance(), at: time)
            }
            return nil
        }

        // One usable face.
        lastUsableAt = time
        gapStart = nil
        inAppearance = true
        if matched {
            appearanceMatched = true
            nonMatchBucket = max(0, nonMatchBucket - dt)
            if !live {
                if livenessProgress >= bestLivenessProgress + config.progressStep {
                    // Evidence is improving: give time back.
                    bestLivenessProgress = livenessProgress
                    notLiveTime = max(0, notLiveTime - dt)
                } else {
                    notLiveTime += dt
                }
                if notLiveTime >= config.notLiveDuration {
                    notLiveTime = 0
                    return emit(.notLive, at: time)
                }
            }
            return nil
        }
        nonMatchBucket += dt
        appearanceNonMatch += dt
        if nonMatchBucket >= config.failedLookDuration {
            nonMatchBucket = 0
            appearanceCounted = true
            return emit(.notRecognised, at: time)
        }
        return nil
    }

    /// Call when the scan stops, to count an appearance that was still open.
    public mutating func finish() -> Event? {
        emit(endAppearance(), at: lastFrameAt ?? 0)
    }

    private mutating func emit(_ event: Event?, at time: TimeInterval) -> Event? {
        guard let event, time - lastEventAt >= config.minimumEventInterval else { return nil }
        lastEventAt = time
        return event
    }

    private mutating func endAppearance() -> Event? {
        defer {
            inAppearance = false
            gapStart = nil
            appearanceNonMatch = 0
            appearanceMatched = false
            appearanceCounted = false
        }
        if inAppearance && appearanceNonMatch >= config.briefAppearanceDuration
            && !appearanceMatched && !appearanceCounted {
            return .briefAppearance
        }
        return nil
    }

    public func hudVisible(at time: TimeInterval) -> Bool {
        time - lastFaceAt < config.hudHideAfterNoFace
    }

    /// A face is in view but hasn't been usable for a while: ask the user to
    /// look at the screen.
    public func shouldAskToFaceScreen(at time: TimeInterval) -> Bool {
        time - lastFaceAt < 0.3 && time - lastUsableAt >= config.lookAtScreenAfter
    }

    public func shouldPauseForNoFace(at time: TimeInterval) -> Bool {
        time - lastFaceAt >= config.facelessPause
    }
}
