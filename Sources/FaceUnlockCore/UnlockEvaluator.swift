import Foundation

/// What the vision pipeline extracted from one camera frame.
public struct FrameObservation: Sendable {
    public var time: TimeInterval
    public var faceCount: Int
    /// nil when no single face could be embedded.
    public var score: MatchScore?
    public var eyes: EyeSample?
    public var yawDegrees: Double?
    public var pitchDegrees: Double?

    public init(time: TimeInterval, faceCount: Int, score: MatchScore?, eyes: EyeSample?,
                yawDegrees: Double?, pitchDegrees: Double?) {
        self.time = time
        self.faceCount = faceCount
        self.score = score
        self.eyes = eyes
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
    }
}

/// Combines recognition and liveness over one attempt. Pure state machine:
/// feed it frames, read `snapshot`. Used identically by the real unlock path
/// and the "Test recognition" window.
///
/// Liveness evidence (blink, head movement) is only taken from frames that
/// match the enrolled face, and any frame that doesn't match (no face, two
/// faces, a non-matching or un-embeddable face) wipes all evidence. So the
/// whole sequence – matched open eyes, matched blink, matched frames after
/// the blink – has to come from one continuous run of the owner's face.
public struct UnlockEvaluator: Sendable {
    /// Why evidence was wiped on a frame (for diagnostics).
    public enum ResetReason: String, Sendable, CaseIterable {
        case noFace = "no face"
        case multipleFaces = "several faces"
        case noMatch = "no match"
        case noEmbedding = "face unreadable"
    }

    public struct Snapshot: Equatable, Sendable {
        public var faceCount: Int
        public var score: MatchScore?
        public var frameMatched: Bool
        public var consecutiveMatches: Int
        public var requiredConsecutive: Int
        public var blinkState: BlinkDetector.State
        public var blinked: Bool
        public var matchesSinceBlink: Int
        public var yawRange: Double
        public var pitchRange: Double
        public var poseVaried: Bool
        public var sawFace: Bool
        public var sawMultipleFaces: Bool
        public var shouldUnlock: Bool
        /// Set when this frame wiped existing evidence.
        public var resetReason: ResetReason? = nil
        /// Lower of the two eyes' openness relative to their open baseline
        /// (≈1 open; a blink needs both below 0.60). nil while calibrating.
        public var eyeRatio: Double? = nil
        public var livenessMode: LivenessMode = .blinkAndMovement
        /// Natural-movement numbers (see `MicroMotionCheck`).
        public var motionPoseRange: Double = 0
        public var motionEyeJitter: Double = 0
        public var motionSeconds: Double = 0
        /// Whether the active liveness mode is satisfied right now.
        public var livenessSatisfied: Bool = false
        /// 0…1 overall evidence (for the on-screen ring).
        public var progress: Double = 0
    }

    public let policy: MatchPolicy
    public let livenessMode: LivenessMode
    private var motion: MicroMotionCheck
    private var counter: ConsecutiveMatchCounter
    private var blink: BlinkDetector
    private var pose: PoseVariationCheck
    private var lastFaceCount = 0
    private var lastScore: MatchScore?
    private var lastMatched = false
    private var matchesSinceBlink = 0
    private var lastResetReason: ResetReason?
    private var lastEyeRatio: Double?
    private(set) public var sawFace = false
    private(set) public var sawMultipleFaces = false

    public init(policy: MatchPolicy,
                liveness: LivenessMode = .blinkAndMovement,
                blinkConfig: BlinkDetector.Config = .init(),
                poseConfig: PoseVariationCheck.Config = .init(),
                motionConfig: MicroMotionCheck.Config = .init()) {
        self.policy = policy
        self.livenessMode = liveness
        self.motion = MicroMotionCheck(config: motionConfig)
        self.counter = ConsecutiveMatchCounter(required: policy.requiredConsecutive)
        self.blink = BlinkDetector(config: blinkConfig)
        self.pose = PoseVariationCheck(config: poseConfig)
    }

    private var hasEvidence: Bool {
        counter.run > 0 || blink.state != .calibrating || pose.sampleCount > 0 || motion.duration > 0
    }

    private mutating func resetEvidence(_ reason: ResetReason) {
        if hasEvidence { lastResetReason = reason }
        counter.reset()
        blink.reset()
        pose.reset()
        motion.reset()
        matchesSinceBlink = 0
    }

    @discardableResult
    public mutating func observe(_ frame: FrameObservation) -> Snapshot {
        lastFaceCount = frame.faceCount
        lastScore = frame.score
        lastMatched = false
        lastResetReason = nil
        lastEyeRatio = nil

        if frame.faceCount == 0 {
            // Face left the frame: someone else could step in, so start over.
            resetEvidence(.noFace)
        } else if frame.faceCount > 1 {
            sawMultipleFaces = true
            resetEvidence(.multipleFaces)
        } else {
            sawFace = true
            if let score = frame.score, policy.isMatch(score) {
                lastMatched = true
                counter.record(matched: true)
                let blinkedBefore = blink.hasBlinked
                if let eyes = frame.eyes {
                    if let r = blink.ratios(for: eyes) { lastEyeRatio = min(r.left, r.right) }
                    blink.observe(eyes)
                }
                if blink.hasBlinked {
                    // The re-opening frame counts as the first match after the blink.
                    matchesSinceBlink = blinkedBefore ? matchesSinceBlink + 1 : 1
                }
                pose.observe(yawDegrees: frame.yawDegrees, pitchDegrees: frame.pitchDegrees)
                motion.observe(time: frame.time, yawDegrees: frame.yawDegrees, pitchDegrees: frame.pitchDegrees,
                               eyeOpenness: frame.eyes.map { ($0.left + $0.right) / 2 })
            } else {
                // Not the owner (or couldn't tell): start over completely.
                resetEvidence(frame.score == nil ? .noEmbedding : .noMatch)
            }
        }
        return snapshot
    }

    public var snapshot: Snapshot {
        let blinkLive = blink.hasBlinked && matchesSinceBlink >= counter.required && pose.isSatisfied
        let live: Bool
        let liveProgress: Double
        switch livenessMode {
        case .blinkAndMovement:
            live = blinkLive
            liveProgress = (blink.hasBlinked ? 0.5 : 0) + (pose.isSatisfied ? 0.5 : 0)
        case .naturalMovement:
            live = motion.isSatisfied
            liveProgress = live ? 1 : min(0.95, motion.progress)
        case .off:
            live = true
            liveProgress = 1
        }
        let unlock = lastFaceCount == 1 && lastMatched && counter.isSatisfied && live
        let matchProgress = min(1, Double(counter.run) / Double(counter.required))
        return Snapshot(
            faceCount: lastFaceCount,
            score: lastScore,
            frameMatched: lastMatched,
            consecutiveMatches: counter.run,
            requiredConsecutive: counter.required,
            blinkState: blink.state,
            blinked: blink.hasBlinked,
            matchesSinceBlink: matchesSinceBlink,
            yawRange: pose.yawRange,
            pitchRange: pose.pitchRange,
            poseVaried: pose.isSatisfied,
            sawFace: sawFace,
            sawMultipleFaces: sawMultipleFaces,
            shouldUnlock: unlock,
            resetReason: lastResetReason,
            eyeRatio: lastEyeRatio,
            livenessMode: livenessMode,
            motionPoseRange: motion.poseRange,
            motionEyeJitter: motion.eyeJitter,
            motionSeconds: motion.duration,
            livenessSatisfied: live,
            progress: unlock ? 1 : (matchProgress + liveProgress) / 2
        )
    }
}
