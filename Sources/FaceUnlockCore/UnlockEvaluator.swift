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
    }

    public let policy: MatchPolicy
    private var counter: ConsecutiveMatchCounter
    private var blink: BlinkDetector
    private var pose: PoseVariationCheck
    private var lastFaceCount = 0
    private var lastScore: MatchScore?
    private var lastMatched = false
    private var matchesSinceBlink = 0
    private(set) public var sawFace = false
    private(set) public var sawMultipleFaces = false

    public init(policy: MatchPolicy,
                blinkConfig: BlinkDetector.Config = .init(),
                poseConfig: PoseVariationCheck.Config = .init()) {
        self.policy = policy
        self.counter = ConsecutiveMatchCounter(required: policy.requiredConsecutive)
        self.blink = BlinkDetector(config: blinkConfig)
        self.pose = PoseVariationCheck(config: poseConfig)
    }

    private mutating func resetEvidence() {
        counter.reset()
        blink.reset()
        pose.reset()
        matchesSinceBlink = 0
    }

    @discardableResult
    public mutating func observe(_ frame: FrameObservation) -> Snapshot {
        lastFaceCount = frame.faceCount
        lastScore = frame.score
        lastMatched = false

        if frame.faceCount == 0 {
            // Face left the frame: someone else could step in, so start over.
            resetEvidence()
        } else if frame.faceCount > 1 {
            sawMultipleFaces = true
            resetEvidence()
        } else {
            sawFace = true
            if let score = frame.score, policy.isMatch(score) {
                lastMatched = true
                counter.record(matched: true)
                let blinkedBefore = blink.hasBlinked
                if let eyes = frame.eyes { blink.observe(eyes) }
                if blink.hasBlinked {
                    // The re-opening frame counts as the first match after the blink.
                    matchesSinceBlink = blinkedBefore ? matchesSinceBlink + 1 : 1
                }
                pose.observe(yawDegrees: frame.yawDegrees, pitchDegrees: frame.pitchDegrees)
            } else {
                // Not the owner (or couldn't tell): start over completely.
                resetEvidence()
            }
        }
        return snapshot
    }

    public var snapshot: Snapshot {
        let unlock = lastFaceCount == 1 && lastMatched && counter.isSatisfied && blink.hasBlinked
            && matchesSinceBlink >= counter.required && pose.isSatisfied
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
            shouldUnlock: unlock
        )
    }
}
