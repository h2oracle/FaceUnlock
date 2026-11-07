import Foundation

/// One frame's worth of eye measurements.
public struct EyeSample: Equatable, Sendable {
    public var time: TimeInterval
    /// Eye openness (contour area / width², see `LandmarkGeometry.eyeOpenness`).
    /// Scale-free; roughly 0.05–0.15 for an open eye, near 0 for a closed one.
    public var left: Double
    public var right: Double
    /// Scale-free face proportion (eye-line-to-mouth distance / inter-ocular
    /// distance). Stays constant during a real blink, but shrinks if a flat
    /// photo is tilted towards/away from the camera, which also squashes the
    /// eyes. Used to reject "blinks" faked by tilting a photo.
    public var faceShape: Double
    /// Head pitch in degrees, if known.
    public var pitch: Double?

    public init(time: TimeInterval, left: Double, right: Double, faceShape: Double, pitch: Double? = nil) {
        self.time = time
        self.left = left
        self.right = right
        self.faceShape = faceShape
        self.pitch = pitch
    }
}

/// Detects a natural blink: eyes open -> both closed briefly -> open again.
///
/// Thresholds are relative to a per-eye baseline learned from the open-eye
/// frames of the current attempt, so they adapt to different eye shapes and
/// distances. Once a blink is seen the detector latches until `reset()`.
public struct BlinkDetector: Sendable {
    public struct Config: Equatable, Sendable {
        /// An eye counts as closed below this fraction of its open baseline.
        public var closedRatio: Double = 0.60
        /// Eyes count as open again above this fraction of their baseline.
        public var openRatio: Double = 0.82
        /// Open frames needed before a closure is considered.
        public var minimumOpenSamples = 3
        /// A real blink lasts ~100–400 ms. Longer closures don't count.
        public var maximumClosedDuration: TimeInterval = 0.7
        /// Allowed relative change of `faceShape` during the closure.
        public var maximumShapeDeviation: Double = 0.12
        /// Allowed pitch change (degrees) during the closure.
        public var maximumPitchDeviation: Double = 8
        /// How many recent open samples feed the baseline.
        public var baselineWindow = 15

        public init() {}
    }

    public enum State: Equatable, Sendable {
        case calibrating
        case open
        case closed(since: TimeInterval)
        /// Saw a closure that wasn't a valid blink; wait for eyes to open.
        case waitingForOpen
        case blinked
    }

    public let config: Config
    public private(set) var state: State = .calibrating
    private var leftBaseline: [Double] = []
    private var rightBaseline: [Double] = []
    private var shapeBaseline: [Double] = []
    private var closureShapeReference: Double = 0
    private var closurePitchReference: Double?

    public init(config: Config = Config()) {
        self.config = config
    }

    public var hasBlinked: Bool { state == .blinked }

    public mutating func reset() {
        state = .calibrating
        leftBaseline.removeAll()
        rightBaseline.removeAll()
        shapeBaseline.removeAll()
        closurePitchReference = nil
    }

    /// Ratio of each eye's openness to its baseline (nil while calibrating).
    public func ratios(for sample: EyeSample) -> (left: Double, right: Double)? {
        guard let l = Self.median(leftBaseline), let r = Self.median(rightBaseline), l > 0, r > 0 else { return nil }
        return (sample.left / l, sample.right / r)
    }

    @discardableResult
    public mutating func observe(_ sample: EyeSample) -> State {
        guard sample.left.isFinite, sample.right.isFinite, sample.faceShape.isFinite,
              sample.left >= 0, sample.right >= 0, sample.faceShape > 0 else { return state }

        switch state {
        case .blinked:
            return state

        case .calibrating:
            appendBaseline(sample)
            if leftBaseline.count >= config.minimumOpenSamples { state = .open }

        case .open:
            guard let (l, r) = ratios(for: sample) else { appendBaseline(sample); break }
            if l < config.closedRatio && r < config.closedRatio {
                state = .closed(since: sample.time)
                closureShapeReference = Self.median(shapeBaseline) ?? sample.faceShape
                closurePitchReference = sample.pitch
            } else if l >= config.openRatio && r >= config.openRatio {
                appendBaseline(sample)
            }
            // In between: half-closed (squint/noise); neither learn nor transition.

        case .closed(let since):
            guard let (l, r) = ratios(for: sample) else { state = .calibrating; break }
            let shapeDeviation = abs(sample.faceShape - closureShapeReference) / closureShapeReference
            let pitchDeviation: Double = {
                guard let p = sample.pitch, let ref = closurePitchReference else { return 0 }
                return abs(p - ref)
            }()
            if shapeDeviation > config.maximumShapeDeviation || pitchDeviation > config.maximumPitchDeviation {
                // Whole-face geometry changed: a tilted photo, not a blink.
                state = .waitingForOpen
            } else if sample.time - since > config.maximumClosedDuration {
                state = .waitingForOpen
            } else if l >= config.openRatio && r >= config.openRatio {
                state = .blinked
            }

        case .waitingForOpen:
            guard let (l, r) = ratios(for: sample) else { break }
            if l >= config.openRatio && r >= config.openRatio {
                state = .open
                appendBaseline(sample)
            }
        }
        return state
    }

    private mutating func appendBaseline(_ s: EyeSample) {
        leftBaseline.append(s.left)
        rightBaseline.append(s.right)
        shapeBaseline.append(s.faceShape)
        let n = config.baselineWindow
        if leftBaseline.count > n { leftBaseline.removeFirst(leftBaseline.count - n) }
        if rightBaseline.count > n { rightBaseline.removeFirst(rightBaseline.count - n) }
        if shapeBaseline.count > n { shapeBaseline.removeFirst(shapeBaseline.count - n) }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
