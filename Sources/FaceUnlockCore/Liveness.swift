import Foundation

/// How much proof of a live person an unlock needs (on top of a matching face).
public enum LivenessMode: String, Codable, CaseIterable, Sendable {
    /// Passive: the small, natural head motion and facial micro-movement of a
    /// live person over ~1–2 s. No blink needed. Default.
    case naturalMovement
    /// A natural blink plus slight head movement.
    case blinkAndMovement
    /// Face match only.
    case off

    public static let `default`: LivenessMode = .naturalMovement

    public var title: String {
        switch self {
        case .naturalMovement: return "Natural movement"
        case .blinkAndMovement: return "Blink + movement"
        case .off: return "Off"
        }
    }

    /// One-line security note shown next to the option.
    public var securityNote: String {
        switch self {
        case .naturalMovement:
            return "No blink needed. Designed to reject a still photo; a moving photo or a video may pass."
        case .blinkAndMovement:
            return "Strongest webcam check: stops photos, including moved ones; a video of you can still pass."
        case .off:
            return "Face match only: a photo of you can unlock this Mac. Not recommended."
        }
    }
}

/// Passive liveness for `.naturalMovement`: over at least `minimumDuration`
/// of continuously matched frames, the head must move a little in 3D
/// (yaw/pitch) AND the eye region must show frame-to-frame micro-movement.
/// A printed photo held still shows neither; held in a hand it shows rigid
/// pose changes but almost no change in eye openness.
///
/// Thresholds are deliberately low so a person sitting normally passes in
/// about 1–2 s. They are estimates, not calibrated on a dataset; the Test
/// step shows the live numbers.
public struct MicroMotionCheck: Sendable {
    public struct Config: Equatable, Sendable {
        /// Matched-frame time span needed before deciding.
        public var minimumDuration: TimeInterval = 1.0
        public var minimumSamples = 12
        /// Robust (p10–p90) range in yaw or pitch, degrees.
        public var minimumPoseRange: Double = 0.8
        /// Above this the pose estimate is noise / the face left.
        public var maximumPoseRange: Double = 40
        /// Mean absolute frame-to-frame change of eye openness, relative to
        /// its mean (0.025 = 2.5 %).
        public var minimumEyeJitter: Double = 0.025
        public var window = 60

        public init() {}
    }

    public let config: Config
    private var times: [TimeInterval] = []
    private var yaws: [Double] = []
    private var pitches: [Double] = []
    private var eyes: [Double] = []

    public init(config: Config = Config()) { self.config = config }

    public mutating func reset() {
        times.removeAll(); yaws.removeAll(); pitches.removeAll(); eyes.removeAll()
    }

    public mutating func observe(time: TimeInterval, yawDegrees: Double?, pitchDegrees: Double?, eyeOpenness: Double?) {
        guard let y = yawDegrees, let p = pitchDegrees, let e = eyeOpenness,
              y.isFinite, p.isFinite, e.isFinite, e >= 0 else { return }
        times.append(time); yaws.append(y); pitches.append(p); eyes.append(e)
        if times.count > config.window {
            let drop = times.count - config.window
            times.removeFirst(drop); yaws.removeFirst(drop); pitches.removeFirst(drop); eyes.removeFirst(drop)
        }
    }

    public var duration: TimeInterval { (times.last ?? 0) - (times.first ?? 0) }
    public var poseRange: Double {
        max(PoseVariationCheck.robustRange(yaws), PoseVariationCheck.robustRange(pitches))
    }

    /// Mean |Δ openness| between consecutive frames / mean openness.
    public var eyeJitter: Double {
        guard eyes.count >= 2 else { return 0 }
        let mean = eyes.reduce(0, +) / Double(eyes.count)
        guard mean > 0 else { return 0 }
        var total = 0.0
        for i in 1..<eyes.count { total += abs(eyes[i] - eyes[i - 1]) }
        return total / Double(eyes.count - 1) / mean
    }

    /// 0…1, how close to passing (for the on-screen ring).
    public var progress: Double {
        guard !times.isEmpty else { return 0 }
        let timePart = min(1, duration / config.minimumDuration)
        let posePart = min(1, poseRange / config.minimumPoseRange)
        let eyePart = min(1, eyeJitter / config.minimumEyeJitter)
        return (timePart + posePart + eyePart) / 3
    }

    public var isSatisfied: Bool {
        guard times.count >= config.minimumSamples, duration >= config.minimumDuration else { return false }
        let range = poseRange
        return range >= config.minimumPoseRange && range <= config.maximumPoseRange
            && eyeJitter >= config.minimumEyeJitter
    }
}
