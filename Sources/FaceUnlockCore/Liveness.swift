import CoreGraphics
import Foundation

/// How much proof of a live person an unlock needs (on top of a matching face).
public enum LivenessMode: String, Codable, CaseIterable, Sendable {
    /// Passive: either the landmarks move the way only a 3D face can as the
    /// head turns a little (parallax), or a natural blink is seen. No blink
    /// is *required*. Default.
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
            return "No blink needed. Designed to reject flat photos; validated on simulated data only, so test with a printed photo in the Test step. Curved or bent prints, videos and masks may pass."
        case .blinkAndMovement:
            return "Strongest webcam check: stops photos, including moved ones; a video of you can still pass."
        case .off:
            return "Face match only: a photo of you can unlock this Mac. Not recommended."
        }
    }
}

/// Passive liveness for `.naturalMovement`, based on **parallax**.
///
/// Any picture of a face on a flat surface (print, phone, tablet) maps from
/// one camera frame to the next by a single 2D homography, however it's
/// tilted, turned or moved. A real head is 3D: when it turns even a few
/// degrees, the nose tip and the jaw outline shift relative to the eye/mouth
/// plane in a way no homography can reproduce.
///
/// Over the matched window the check takes the frames at both ends of the
/// head-turn range (yaw or pitch, whichever varied more), pairs them up, fits
/// a homography from each "low" frame's landmarks to a "high" frame's, and
/// averages the per-landmark residual vectors over all pairs. Landmark noise
/// is random and averages out; parallax is systematic and doesn't. It passes
/// when the averaged residual (RMS, as a fraction of the inter-ocular
/// distance) is large enough AND the two ends differ by a real rotation.
///
/// A perfectly still real head simply waits until it moves slightly.
public struct NaturalMovementCheck: Sendable {
    public struct Config: Equatable, Sendable {
        /// Matched-frame time span needed before deciding (time, not frames,
        /// so it doesn't depend on the frame rate).
        public var minimumDuration: TimeInterval = 0.5
        public var minimumSamples = 8
        /// Minimum difference (degrees) between the mean pose of the two ends.
        public var minimumRotation: Double = 3
        /// Above this the estimate is noise / a different situation.
        public var maximumPoseRange: Double = 60
        /// Absolute floor for the averaged non-planar residual, as a fraction
        /// of the inter-ocular distance.
        public var minimumParallax: Double = 0.006
        /// Parallax grows roughly with sin(rotation), so the main criterion is
        /// rotation-normalised: parallax / sin(rotation) must reach this.
        /// Calibrated on the synthetic 3D-head model (≈0.2 at 3–5°) and real
        /// owner data (0.10–0.20); flat photos stay near noise level.
        public var minimumParallaxPerSine: Double = 0.06
        /// The decision uses the median of the most recent valid evaluations
        /// (rotation ≥ minimum), so one noisy snapshot neither passes nor
        /// zeroes it.
        public var smoothingEvaluations = 7
        public var minimumEvaluations = 3
        /// The averaged residual must also stand out from landmark noise:
        /// its RMS divided by the standard error of the mean (estimated from
        /// the spread across pairs). Pure noise gives ≈1 (flat photos in the
        /// tests: 0.7–1.3). 2.2 lets a real head turning only ~3° pass within
        /// ~3 s at 1.5 % landmark noise; 2.5 took 3.5–4 s or longer.
        public var minimumSignalToNoise: Double = 2.2
        public var minimumPairs = 4
        /// Frames kept (≈3 s at 30 fps).
        public var window = 90
        /// Fraction of frames at each end of the pose range used for pairs.
        public var endFraction = 0.35

        public init() {}
    }

    struct Sample: Sendable {
        var time: TimeInterval
        var yaw: Double
        var pitch: Double
        var points: [CGPoint]
        var interocular: Double
        /// Mean squared homography residual (per landmark, in IOD units)
        /// against the previous sample: an estimate of landmark noise that
        /// settles quickly because every frame contributes.
        var adjacentNoise: Double?
    }

    public let config: Config
    private var samples: [Sample] = []
    /// Cached result of the last evaluation.
    public private(set) var rotation: Double = 0
    public private(set) var parallax: Double = 0
    /// Parallax divided by its own noise estimate.
    public private(set) var signalToNoise: Double = 0
    /// Recent valid evaluations (rotation, parallax, signal-to-noise).
    private var recent: [(rotation: Double, parallax: Double, snr: Double)] = []
    private var pairCount = 0
    private var observedCount = 0

    public init(config: Config = Config()) { self.config = config }

    public mutating func reset() {
        samples.removeAll()
        rotation = 0
        parallax = 0
        signalToNoise = 0
        pairCount = 0
        observedCount = 0
        recent.removeAll()
    }

    public mutating func observe(time: TimeInterval, yawDegrees: Double?, pitchDegrees: Double?,
                                 landmarks: [CGPoint]?, interocular: Double?) {
        guard let y = yawDegrees, let p = pitchDegrees, let pts = landmarks, let iod = interocular,
              y.isFinite, p.isFinite, iod > 0, pts.count >= 8 else { return }
        if let first = samples.first, first.points.count != pts.count {
            // Different landmark layout: can't compare; start again.
            samples.removeAll()
        }
        var adjacent: Double?
        if let prev = samples.last, let r = Homography.residuals(from: prev.points, to: pts) {
            let scale = 1 / iod
            adjacent = r.reduce(0) { $0 + ($1.dx * $1.dx + $1.dy * $1.dy) * scale * scale } / Double(r.count)
        }
        samples.append(Sample(time: time, yaw: y, pitch: p, points: pts, interocular: iod, adjacentNoise: adjacent))
        if samples.count > config.window { samples.removeFirst(samples.count - config.window) }
        // Re-evaluate every other frame: ample resolution, half the cost.
        observedCount += 1
        if observedCount % 2 == 0 || samples.count == config.minimumSamples { evaluate() }
    }

    public var duration: TimeInterval { (samples.last?.time ?? 0) - (samples.first?.time ?? 0) }

    /// 0…1, how close to passing (for the on-screen indicator).
    public var progress: Double {
        guard !samples.isEmpty else { return 0 }
        let t = min(1, duration / config.minimumDuration)
        let r = min(1, rotation / config.minimumRotation)
        let p = min(1, parallaxPerSine / config.minimumParallaxPerSine, signalToNoise / config.minimumSignalToNoise)
        return (t + r + p) / 3
    }

    /// Smoothed parallax divided by sin(smoothed rotation).
    public var parallaxPerSine: Double {
        let s = sin(rotation * .pi / 180)
        return s > 0 ? parallax / s : 0
    }

    public var isSatisfied: Bool {
        samples.count >= config.minimumSamples
            && duration >= config.minimumDuration
            && rotation >= config.minimumRotation
            && rotation <= config.maximumPoseRange
            && recent.count >= config.minimumEvaluations
            && parallax >= config.minimumParallax
            && parallaxPerSine >= config.minimumParallaxPerSine
            && signalToNoise >= config.minimumSignalToNoise
    }

    private mutating func evaluate() {
        let (rot, par, snr, pairs) = evaluateInstant()
        pairCount = pairs
        if rot >= config.minimumRotation && pairs >= config.minimumPairs {
            recent.append((rot, par, snr))
            if recent.count > config.smoothingEvaluations { recent.removeFirst(recent.count - config.smoothingEvaluations) }
        }
        guard !recent.isEmpty else {
            rotation = rot
            parallax = 0
            signalToNoise = 0
            return
        }
        func median(_ v: [Double]) -> Double {
            let s = v.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        rotation = median(recent.map(\.rotation))
        parallax = median(recent.map(\.parallax))
        signalToNoise = median(recent.map(\.snr))
    }

    /// One evaluation over the current window: (rotation, parallax, SNR, pairs).
    private func evaluateInstant() -> (Double, Double, Double, Int) {
        guard samples.count >= config.minimumSamples else { return (0, 0, 0, 0) }
        // Use whichever axis varied more.
        let yawSpan = (samples.map(\.yaw).max() ?? 0) - (samples.map(\.yaw).min() ?? 0)
        let pitchSpan = (samples.map(\.pitch).max() ?? 0) - (samples.map(\.pitch).min() ?? 0)
        let angle: (Sample) -> Double = yawSpan >= pitchSpan ? { $0.yaw } : { $0.pitch }
        let sorted = samples.sorted { angle($0) < angle($1) }
        let k = max(2, Int(Double(sorted.count) * config.endFraction))
        guard sorted.count >= 2 * k else { return (0, 0, 0, 0) }
        let low = Array(sorted.prefix(k))
        let high = Array(sorted.suffix(k).reversed())
        let lowMean = low.map(angle).reduce(0, +) / Double(k)
        let highMean = high.map(angle).reduce(0, +) / Double(k)
        let rotation = highMean - lowMean
        guard rotation >= config.minimumRotation else { return (rotation, 0, 0, 0) }

        // Average residual vectors over pairs (k-th lowest with k-th highest).
        let n = low[0].points.count
        var sum = [CGVector](repeating: .zero, count: n)
        var sumSq = [CGVector](repeating: .zero, count: n)
        var pairs = 0
        for (a, b) in zip(low, high) {
            guard let r = Homography.residuals(from: a.points, to: b.points) else { continue }
            let scale = 1 / b.interocular
            for i in 0..<n {
                let dx = r[i].dx * scale, dy = r[i].dy * scale
                sum[i].dx += dx; sum[i].dy += dy
                sumSq[i].dx += dx * dx; sumSq[i].dy += dy * dy
            }
            pairs += 1
        }
        guard pairs >= 2 else { return (rotation, 0, 0, pairs) }
        let kp = Double(pairs)
        var signal = 0.0, spreadNoise = 0.0
        for i in 0..<n {
            let mx = sum[i].dx / kp, my = sum[i].dy / kp
            signal += mx * mx + my * my
            // Sample variance across pairs → squared standard error of the mean.
            let vx = max(0, (sumSq[i].dx / kp - mx * mx) * kp / (kp - 1))
            let vy = max(0, (sumSq[i].dy / kp - my * my) * kp / (kp - 1))
            spreadNoise += (vx + vy) / kp
        }
        let parallax = (signal / Double(n)).squareRoot()
        // Noise of the mean residual. The frame-to-frame estimate uses every
        // frame in the window, so it settles much faster than the spread of
        // a handful of pairs; the spread is the fallback early on.
        let adjacent = samples.compactMap(\.adjacentNoise)
        let noiseSquared: Double
        if adjacent.count >= 8 {
            noiseSquared = adjacent.reduce(0, +) / Double(adjacent.count) / kp
        } else {
            noiseSquared = spreadNoise / Double(n)
        }
        let noiseRMS = noiseSquared.squareRoot()
        let snr = noiseRMS > 0 ? parallax / noiseRMS : (parallax > 0 ? .infinity : 0)
        return (rotation, parallax, snr, pairs)
    }
}

/// Least-squares 2D homography (DLT with h33 = 1 and Hartley normalisation),
/// solved with plain Gaussian elimination; enough for ~70 landmarks.
public enum Homography {
    /// Residual vectors (actual − predicted) of `to` after mapping `from`
    /// through the best-fitting homography. nil if degenerate.
    public static func residuals(from src: [CGPoint], to dst: [CGPoint]) -> [CGVector]? {
        guard src.count == dst.count, src.count >= 5,
              let (ns, _) = normalize(src), let (nd, td) = normalize(dst) else { return nil }
        // Normal equations AᵀA h = Aᵀb for h = (h11 h12 h13 h21 h22 h23 h31 h32).
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        var row = [Double](repeating: 0, count: 8)
        func add(_ rhs: Double) {
            for i in 0..<8 where row[i] != 0 {
                atb[i] += row[i] * rhs
                for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
            }
        }
        for (p, q) in zip(ns, nd) {
            row[0] = p.x; row[1] = p.y; row[2] = 1; row[3] = 0; row[4] = 0; row[5] = 0
            row[6] = -q.x * p.x; row[7] = -q.x * p.y
            add(q.x)
            row[0] = 0; row[1] = 0; row[2] = 0; row[3] = p.x; row[4] = p.y; row[5] = 1
            row[6] = -q.y * p.x; row[7] = -q.y * p.y
            add(q.y)
        }
        guard let h = solve(ata, atb) else { return nil }
        var out: [CGVector] = []
        out.reserveCapacity(src.count)
        for (p, q) in zip(ns, nd) {
            let w = h[6] * p.x + h[7] * p.y + 1
            guard abs(w) > 1e-9 else { return nil }
            let u = (h[0] * p.x + h[1] * p.y + h[2]) / w
            let v = (h[3] * p.x + h[4] * p.y + h[5]) / w
            // Back to the destination's pixel units.
            out.append(CGVector(dx: (q.x - u) / td, dy: (q.y - v) / td))
        }
        return out
    }

    /// Centre on the centroid and scale so the mean distance is √2.
    private static func normalize(_ pts: [CGPoint]) -> ([CGPoint], Double)? {
        let n = Double(pts.count)
        let cx = pts.map(\.x).reduce(0, +) / n
        let cy = pts.map(\.y).reduce(0, +) / n
        let mean = pts.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / n
        guard mean > 1e-9 else { return nil }
        let s = 2.0.squareRoot() / mean
        return (pts.map { CGPoint(x: ($0.x - cx) * s, y: ($0.y - cy) * s) }, s)
    }

    /// Gaussian elimination with partial pivoting on a row-major n×n matrix.
    static func solve(_ a: [Double], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var r = b
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<n where abs(m[row * n + col]) > abs(m[pivot * n + col]) { pivot = row }
            guard abs(m[pivot * n + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<n { m.swapAt(col * n + k, pivot * n + k) }
                r.swapAt(col, pivot)
            }
            for row in (col + 1)..<n {
                let f = m[row * n + col] / m[col * n + col]
                if f == 0 { continue }
                for k in col..<n { m[row * n + k] -= f * m[col * n + k] }
                r[row] -= f * r[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var acc = r[i]
            for k in (i + 1)..<n { acc -= m[i * n + k] * x[k] }
            x[i] = acc / m[i * n + i]
        }
        return x
    }
}
