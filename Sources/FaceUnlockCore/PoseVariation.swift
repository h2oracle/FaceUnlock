import Foundation

/// Checks that the head moved a little in 3D (yaw or pitch) during the
/// attempt. In-plane rotation (roll) is deliberately ignored: wobbling a
/// photo in front of the camera produces roll, not yaw/pitch.
///
/// Ranges use the 10th–90th percentile so a single noisy frame can't pass the
/// check, and implausibly large swings are rejected as tracking noise.
public struct PoseVariationCheck: Sendable {
    public struct Config: Equatable, Sendable {
        /// Minimum robust range (degrees) in yaw or pitch.
        public var minimumRangeDegrees: Double = 2.5
        /// Above this the pose estimate is unreliable (or the face left the frame).
        public var maximumRangeDegrees: Double = 40
        public var minimumSamples = 6
        /// Oldest samples beyond this are dropped.
        public var window = 120

        public init() {}
    }

    public let config: Config
    private var yaws: [Double] = []
    private var pitches: [Double] = []

    public init(config: Config = Config()) { self.config = config }

    public mutating func reset() {
        yaws.removeAll()
        pitches.removeAll()
    }

    public mutating func observe(yawDegrees: Double?, pitchDegrees: Double?) {
        guard let y = yawDegrees, let p = pitchDegrees, y.isFinite, p.isFinite else { return }
        yaws.append(y)
        pitches.append(p)
        if yaws.count > config.window {
            yaws.removeFirst(yaws.count - config.window)
            pitches.removeFirst(pitches.count - config.window)
        }
    }

    public var sampleCount: Int { yaws.count }
    public var yawRange: Double { Self.robustRange(yaws) }
    public var pitchRange: Double { Self.robustRange(pitches) }

    public var isSatisfied: Bool {
        guard yaws.count >= config.minimumSamples else { return false }
        let ranges = [yawRange, pitchRange]
        guard ranges.allSatisfy({ $0 <= config.maximumRangeDegrees }) else { return false }
        return ranges.contains { $0 >= config.minimumRangeDegrees }
    }

    /// 90th minus 10th percentile (nearest-rank).
    static func robustRange(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let s = values.sorted()
        func pct(_ q: Double) -> Double {
            let idx = Int((q * Double(s.count - 1)).rounded())
            return s[min(max(idx, 0), s.count - 1)]
        }
        return pct(0.9) - pct(0.1)
    }
}
