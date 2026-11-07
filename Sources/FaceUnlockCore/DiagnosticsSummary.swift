import Foundation

extension BlinkDetector.State: CustomStringConvertible {
    public var description: String {
        switch self {
        case .calibrating: return "calibrating"
        case .open: return "open"
        case .closed: return "closed"
        case .waitingForOpen: return "waiting-for-open"
        case .blinked: return "blinked"
        }
    }
}

/// Turns per-frame snapshots into one human-readable diagnostics line every
/// `interval` seconds. Contains numbers only: no images, no embeddings.
public struct DiagnosticsSummarizer: Sendable {
    public let threshold: Float
    public let interval: TimeInterval
    private let start: TimeInterval
    private var windowStart: TimeInterval

    // Whole attempt.
    public private(set) var bestScore: Float?
    public private(set) var totalFrames = 0

    // Current window.
    private var frames = 0
    private var faces = [0, 0, 0] // none, one, many
    private var latest: UnlockEvaluator.Snapshot?
    private var opennessMin: Double?
    private var opennessMax: Double?
    private var ratioMin: Double?
    private var resets: [UnlockEvaluator.ResetReason: Int] = [:]

    public init(threshold: Float, start: TimeInterval, interval: TimeInterval = 0.5) {
        self.threshold = threshold
        self.interval = interval
        self.start = start
        self.windowStart = start
    }

    /// `eyeOpenness` is the mean of both eyes' raw openness, if measured.
    /// Returns a summary line when the interval has elapsed.
    public mutating func observe(_ s: UnlockEvaluator.Snapshot, eyeOpenness: Double?, at time: TimeInterval) -> String? {
        frames += 1
        totalFrames += 1
        faces[min(s.faceCount, 2)] += 1
        latest = s
        if let score = s.score?.centroid { bestScore = max(bestScore ?? -1, score) }
        if let o = eyeOpenness {
            opennessMin = min(opennessMin ?? o, o)
            opennessMax = max(opennessMax ?? o, o)
        }
        if let r = s.eyeRatio { ratioMin = min(ratioMin ?? r, r) }
        if let reason = s.resetReason { resets[reason, default: 0] += 1 }
        guard time - windowStart >= interval else { return nil }
        return flush(at: time)
    }

    /// Emits the current window (nil if it's empty) and starts a new one.
    public mutating func flush(at time: TimeInterval) -> String? {
        guard frames > 0, let s = latest else { return nil }
        func f(_ v: Float?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
        func d(_ v: Double?, _ fmt: String = "%.3f") -> String { v.map { String(format: fmt, $0) } ?? "-" }
        var line = String(format: "t=%.1fs", time - start)
        line += " frames=\(frames) faces(0/1/many)=\(faces[0])/\(faces[1])/\(faces[2])"
        line += " score best=\(f(bestScore)) latest=\(f(s.score?.centroid)) thr=\(f(threshold))"
        line += " run=\(s.consecutiveMatches)/\(s.requiredConsecutive)"
        line += " eyes=\(d(opennessMin))..\(d(opennessMax)) ratioMin=\(d(ratioMin, "%.2f"))"
        line += " blink=\(s.blinkState) afterBlink=\(s.matchesSinceBlink)"
        line += String(format: " pose yaw=%.1f° pitch=%.1f°%@", s.yawRange, s.pitchRange, s.poseVaried ? " ok" : "")
        line += String(format: " motion=%.1fs rot=%.1f° parallax=%.2f%%", s.motionSeconds, s.motionRotation, s.motionParallax * 100)
        line += " liveness(\(s.livenessMode.rawValue))=\(s.livenessSatisfied ? "ok" : "pending")"
        if !resets.isEmpty {
            let parts = UnlockEvaluator.ResetReason.allCases.compactMap { r in resets[r].map { "\(r.rawValue)×\($0)" } }
            line += " resets: " + parts.joined(separator: ", ")
        }
        frames = 0
        faces = [0, 0, 0]
        opennessMin = nil
        opennessMax = nil
        ratioMin = nil
        resets = [:]
        windowStart = time
        return line
    }
}
