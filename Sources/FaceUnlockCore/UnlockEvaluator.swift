import CoreGraphics
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
    /// All facial landmarks in image coordinates (stable order per frame),
    /// and the inter-ocular distance in the same units. Used for parallax.
    public var landmarks: [CGPoint]?
    public var interocular: Double?
    /// False when the face is too turned, too small, cut off, low quality or
    /// couldn't be embedded: such a frame is neither a match nor a non-match.
    public var usable: Bool
    /// The pose was estimated from landmarks (Vision didn't report one).
    public var poseEstimated = false
    /// Why it isn't usable (for diagnostics only).
    public var unusableReason: String?

    public init(time: TimeInterval, faceCount: Int, score: MatchScore?, eyes: EyeSample?,
                yawDegrees: Double?, pitchDegrees: Double?,
                landmarks: [CGPoint]? = nil, interocular: Double? = nil, usable: Bool = true,
                unusableReason: String? = nil) {
        self.unusableReason = unusableReason
        self.landmarks = landmarks
        self.interocular = interocular
        self.usable = usable
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
/// "Require attention", as with Face ID: the frames that finally unlock
/// must show the owner facing the screen (not turned away; tilt up/down is
/// ignored) with open eyes and a clearly
/// strong match. Liveness evidence may come from earlier frames, but turning
/// away, closing the eyes or a borderline score can never be the state that
/// unlocks.
public struct AttentionPolicy: Equatable, Sendable {
    public var requiredFrames = 5
    /// Allowed yaw deviation (degrees) from the owner's baseline pose. Head
    /// tilt (pitch) is ignored: it's accepted at any angle.
    public var maximumYaw: Double = 18
    /// How this owner faces the screen (pose relative to the camera).
    public var baseline = PoseBaseline(yaw: 0, pitch: 0)
    /// Each eye must be at least this fraction of its calibrated open level…
    public var minimumOpenRatio: Double = 0.6
    /// …and at least this open in absolute terms (area / width²; open eyes
    /// measure ≈0.14–0.19 on real data, closed ≈0.01–0.06).
    public var minimumOpenness: Double = 0.07
    /// The score must clear the threshold by this much.
    public var scoreMargin: Float = 0.05

    public init(baseline: PoseBaseline = PoseBaseline(yaw: 0, pitch: 0)) {
        self.baseline = baseline.clamped
    }

    /// nil if attentive, otherwise why not.
    public func problem(score: MatchScore, threshold: Float, yaw: Double?, pitch: Double?,
                        eyes: EyeSample?, eyeRatios: (left: Double, right: Double)?) -> String? {
        guard score.value >= threshold + scoreMargin else { return "weak match" }
        _ = pitch // tilt up/down never blocks an unlock
        guard let yaw else { return "pose unknown" }
        guard abs(yaw - baseline.yaw) <= maximumYaw else { return "not facing the screen" }
        guard let eyes, let ratios = eyeRatios else { return "eyes not measured" }
        guard eyes.left >= minimumOpenness, eyes.right >= minimumOpenness,
              ratios.left >= minimumOpenRatio, ratios.right >= minimumOpenRatio else { return "eyes closed" }
        return nil
    }
}

public struct UnlockEvaluator: Sendable {
    /// Why evidence was wiped on a frame (for diagnostics).
    public enum ResetReason: String, Sendable, CaseIterable {
        case noFace = "no face"
        case multipleFaces = "several faces"
        case noMatch = "no match"
        case unusable = "no usable face for too long"
    }

    public struct Snapshot: Equatable, Sendable {
        public var faceCount: Int
        public var score: MatchScore?
        public var frameMatched: Bool
        /// One face, good enough to judge (see `FrameQualityGate`).
        public var frameUsable: Bool = false
        public var frameUnusableReason: String?
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
        /// Natural-movement numbers (see `NaturalMovementCheck`): head-turn
        /// between the two ends of the window (degrees) and the averaged
        /// non-planar landmark residual (fraction of inter-ocular distance).
        public var motionRotation: Double = 0
        public var motionParallax: Double = 0
        public var motionSignalToNoise: Double = 0
        public var motionSeconds: Double = 0
        /// Whether the active liveness mode is satisfied right now.
        public var livenessSatisfied: Bool = false
        /// 0…1 overall evidence (for the on-screen ring).
        public var progress: Double = 0
        /// 0…1 progress of the liveness check alone.
        public var livenessProgress: Double = 0
        /// Consecutive matched frames that were also attentive.
        public var attentiveRun: Int = 0
        /// Why the latest matched frame wasn't attentive (nil if it was).
        public var attentionProblem: String?
        /// Absolute pose of the latest frame and the baseline in use.
        public var latestYaw: Double?
        public var latestPitch: Double?
        public var poseFromLandmarks = false
        public var attentionBaseline: PoseBaseline?
        /// Median pose of the current attentive run (set once it's long
        /// enough); after an unlock it refines the persisted baseline.
        public var attentivePose: PoseBaseline?
    }

    public let policy: MatchPolicy
    /// Fixed baseline (from enrolment or a saved test), or nil to learn one
    /// from the strongest matches of this session.
    private var attention: AttentionPolicy?
    private var strongPoses: [(score: Float, yaw: Double, pitch: Double)] = []
    /// Strong matches needed before a session baseline is trusted.
    public static let sessionBaselineFrames = 8
    private var latestYaw: Double?
    private var latestPitch: Double?
    private var latestPoseEstimated = false
    private var attentivePoses: [(yaw: Double, pitch: Double)] = []
    /// Session learning only uses frames within this yaw of the camera axis,
    /// so a turned pose can't become the baseline. (Pitch is not limited: it
    /// no longer affects attention.)
    public static let sessionLearningRange: Double = 20
    private var attentiveRun = 0
    private var lastAttentionProblem: String?
    public let livenessMode: LivenessMode
    private var motion: NaturalMovementCheck
    private var counter: ConsecutiveMatchCounter
    private var blink: BlinkDetector
    private var pose: PoseVariationCheck
    private var lastFaceCount = 0
    private var lastScore: MatchScore?
    private var lastMatched = false
    private var lastUsable = false
    private var lastUnusableReason: String?
    private var matchesSinceBlink = 0
    private var lastResetReason: ResetReason?
    /// Start of the current run of no-face / unusable frames.
    private var gapStart: TimeInterval?
    /// Short gaps (detector flicker, a blink-induced miss) keep the evidence.
    public static let maximumGap: TimeInterval = 0.7
    private var lastEyeRatio: Double?
    private(set) public var sawFace = false
    private(set) public var sawMultipleFaces = false

    public init(policy: MatchPolicy,
                liveness: LivenessMode = .blinkAndMovement,
                attentionBaseline: PoseBaseline? = PoseBaseline(yaw: 0, pitch: 0),
                blinkConfig: BlinkDetector.Config = .init(),
                poseConfig: PoseVariationCheck.Config = .init(),
                motionConfig: NaturalMovementCheck.Config = .init()) {
        self.policy = policy
        self.attention = attentionBaseline.map { AttentionPolicy(baseline: $0) }
        self.livenessMode = liveness
        self.motion = NaturalMovementCheck(config: motionConfig)
        self.counter = ConsecutiveMatchCounter(required: policy.requiredConsecutive)
        self.blink = BlinkDetector(config: blinkConfig)
        self.pose = PoseVariationCheck(config: poseConfig)
    }

    private var hasEvidence: Bool {
        counter.run > 0 || blink.state != .calibrating || pose.sampleCount > 0 || motion.duration > 0
    }

    /// Without an enrolled baseline: once enough strong matches have been
    /// seen, use the median pose of the best-scoring half (the most frontal
    /// frames score highest), clamped to a plausible range.
    private mutating func learnSessionBaseline(score: MatchScore, yaw: Double?, pitch: Double?) {
        guard attention == nil, let yaw, abs(yaw) <= Self.sessionLearningRange,
              score.value >= policy.threshold + AttentionPolicy().scoreMargin else { return }
        // Pitch is only stored (clamped) in the baseline; a missing one is 0.
        strongPoses.append((score.value, yaw, pitch ?? 0))
        guard strongPoses.count >= Self.sessionBaselineFrames else { return }
        let best = strongPoses.sorted { $0.score > $1.score }.prefix(max(4, strongPoses.count / 2))
        if let b = PoseBaseline.median(best.map { ($0.yaw, $0.pitch) }) {
            attention = AttentionPolicy(baseline: b)
        }
    }

    private mutating func resetEvidence(_ reason: ResetReason) {
        if hasEvidence { lastResetReason = reason }
        counter.reset()
        attentiveRun = 0
        attentivePoses.removeAll()
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
        let isMatchNow = frame.faceCount == 1 && frame.score.map(policy.isMatch) == true
        lastUsable = isMatchNow || (frame.faceCount == 1 && frame.usable && frame.score != nil)
        lastUnusableReason = frame.faceCount == 1 && !lastUsable ? (frame.unusableReason ?? "unreadable") : nil
        lastResetReason = nil
        lastEyeRatio = nil
        lastAttentionProblem = nil
        latestYaw = frame.yawDegrees
        latestPitch = frame.pitchDegrees
        latestPoseEstimated = frame.poseEstimated

        if frame.faceCount > 1 {
            sawMultipleFaces = true
            gapStart = nil
            resetEvidence(.multipleFaces)
        } else if frame.faceCount == 0 || frame.score == nil
                    || (!frame.usable && !policy.isMatch(frame.score!)) {
            // No face, or a non-matching face too poor to judge: neither a
            // match nor a non-match. (A face that matches always counts as a
            // match, whatever its quality: the gate only protects the owner
            // from failed looks, it never blocks evidence.) Evidence (which
            // only ever comes from matched frames) survives short gaps; after
            // `maximumGap` someone else could have stepped in, so start over.
            if frame.faceCount == 1 { sawFace = true }
            let start = gapStart ?? frame.time
            gapStart = start
            if frame.time - start > Self.maximumGap {
                resetEvidence(frame.faceCount == 0 ? .noFace : .unusable)
            }
        } else {
            sawFace = true
            gapStart = nil
            if let score = frame.score, policy.isMatch(score) {
                lastMatched = true
                counter.record(matched: true)
                // Attention is judged against the open-eye level calibrated so
                // far (before this frame updates it).
                let ratios = frame.eyes.flatMap { blink.ratios(for: $0) }
                learnSessionBaseline(score: score, yaw: frame.yawDegrees, pitch: frame.pitchDegrees)
                if let attention {
                    lastAttentionProblem = attention.problem(score: score, threshold: policy.threshold,
                                                             yaw: frame.yawDegrees, pitch: frame.pitchDegrees,
                                                             eyes: frame.eyes, eyeRatios: ratios)
                } else {
                    lastAttentionProblem = "learning how you face the screen"
                }
                attentiveRun = lastAttentionProblem == nil ? attentiveRun + 1 : 0
                if lastAttentionProblem == nil, let y = frame.yawDegrees, let p = frame.pitchDegrees {
                    attentivePoses.append((y, p))
                    if attentivePoses.count > 15 { attentivePoses.removeFirst() }
                } else {
                    attentivePoses.removeAll()
                }
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
                               landmarks: frame.landmarks, interocular: frame.interocular)
            } else {
                // A usable face that isn't the owner: start over completely.
                resetEvidence(.noMatch)
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
            // Either 3D parallax, or a natural blink (in matched frames, with
            // matched frames after it) plus slight head movement. A flat
            // photo can do neither.
            live = motion.isSatisfied || blinkLive
            liveProgress = live ? 1 : min(0.95, motion.progress)
        case .off:
            live = true
            liveProgress = 1
        }
        let unlock = lastFaceCount == 1 && lastMatched && counter.isSatisfied && live
            && attention != nil && attentiveRun >= AttentionPolicy().requiredFrames
        let matchProgress = min(1, Double(counter.run) / Double(counter.required))
        return Snapshot(
            faceCount: lastFaceCount,
            score: lastScore,
            frameMatched: lastMatched,
            frameUsable: lastUsable,
            frameUnusableReason: lastUnusableReason,
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
            motionRotation: motion.rotation,
            motionParallax: motion.parallax,
            motionSignalToNoise: motion.signalToNoise,
            motionSeconds: motion.duration,
            livenessSatisfied: live,
            progress: unlock ? 1 : (matchProgress + liveProgress) / 2,
            livenessProgress: liveProgress,
            attentiveRun: attentiveRun,
            attentionProblem: lastAttentionProblem,
            latestYaw: latestYaw,
            latestPitch: latestPitch,
            poseFromLandmarks: latestPoseEstimated,
            attentionBaseline: attention?.baseline,
            attentivePose: attentiveRun >= AttentionPolicy().requiredFrames ? PoseBaseline.median(attentivePoses) : nil
        )
    }
}
