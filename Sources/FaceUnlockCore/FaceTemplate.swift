import Foundation

/// The enrolled face: an averaged embedding plus the individual samples.
/// Only embeddings are stored; no images ever touch disk.
public struct FaceTemplate: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Identifies the embedding model; a template from another model is useless.
    public var modelID: String
    public var createdAt: Date
    public var centroid: [Float]
    public var samples: [[Float]]
    /// `AVCaptureDevice.uniqueID` of the camera used at enrolment. Unlock
    /// only ever uses this camera.
    public var cameraID: String?
    /// Median head pose (degrees) over the enrolment samples: how this owner
    /// faces the screen relative to the camera (on a MacBook the camera sits
    /// above the screen, so "looking at the screen" isn't pitch 0). Older
    /// templates don't have it.
    public var baselinePose: PoseBaseline?
    /// Samples added automatically after strong, attentive, live unlocks
    /// (Face ID-style adaptation; FIFO, at most `maximumAdaptiveSamples`).
    /// They never replace the enrolment samples and never move the centroid.
    public var adaptiveSamples: [[Float]]?
    public static let maximumAdaptiveSamples = 15

    /// Returns a copy with `embedding` appended to the adaptive samples.
    public func adapting(with embedding: [Float]) -> FaceTemplate {
        var t = self
        var list = adaptiveSamples ?? []
        list.append(VectorMath.l2Normalized(embedding))
        if list.count > Self.maximumAdaptiveSamples { list.removeFirst(list.count - Self.maximumAdaptiveSamples) }
        t.adaptiveSamples = list
        return t
    }

    public init(modelID: String, samples: [[Float]], cameraID: String? = nil, createdAt: Date = Date()) throws {
        let normalized = samples.map(VectorMath.l2Normalized)
        guard let centroid = VectorMath.normalizedMean(normalized) else {
            throw FaceTemplateError.noSamples
        }
        self.version = Self.currentVersion
        self.modelID = modelID
        self.createdAt = createdAt
        self.centroid = centroid
        self.samples = normalized
        self.cameraID = cameraID
    }

    /// Drops samples that disagree with the rest (e.g. a frame where the
    /// detector latched onto something odd), then rebuilds the centroid.
    /// Keeps at least `minimumKept` samples, or throws.
    public func removingOutliers(minimumSimilarity: Float, minimumKept: Int) throws -> FaceTemplate {
        let kept = samples.filter { VectorMath.cosine($0, centroid) >= minimumSimilarity }
        guard kept.count >= minimumKept else { throw FaceTemplateError.inconsistentSamples(kept: kept.count) }
        var t = try FaceTemplate(modelID: modelID, samples: kept, cameraID: cameraID, createdAt: createdAt)
        t.baselinePose = baselinePose
        t.adaptiveSamples = adaptiveSamples
        return t
    }

    /// Mean cosine of samples to the centroid: a rough "how consistent was
    /// enrolment" figure, shown to the user.
    public var consistency: Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(Float(0)) { $0 + VectorMath.cosine($1, centroid) } / Float(samples.count)
    }
}

public enum FaceTemplateError: Error, Equatable, CustomStringConvertible {
    case noSamples
    case inconsistentSamples(kept: Int)

    public var description: String {
        switch self {
        case .noSamples: return "No usable face samples were captured."
        case .inconsistentSamples(let kept): return "The captured samples were too inconsistent (only \(kept) agreed). Try again in even lighting."
        }
    }
}

/// Similarity of one probe embedding against a template.
public struct MatchScore: Equatable, Sendable {
    /// Cosine to the averaged template.
    public var centroid: Float
    /// Best cosine to any individual sample (enrolment or adaptive).
    public var bestSample: Float
    /// Mean of the top-3 sample cosines: robust to posture, because a pose
    /// can match the samples enrolled in that pose, without depending on a
    /// single lucky sample.
    public var topK: Float

    public static let k = 3

    /// `topK` defaults to `centroid` (the conservative value) when not given.
    public init(centroid: Float, bestSample: Float, topK: Float? = nil) {
        self.centroid = centroid
        self.bestSample = bestSample
        self.topK = topK ?? centroid
    }

    /// The score used for matching and the attention margin.
    public var value: Float { max(centroid, topK) }

    public static func score(_ probe: [Float], against template: FaceTemplate) -> MatchScore {
        let c = VectorMath.cosine(probe, template.centroid)
        let all = (template.samples + (template.adaptiveSamples ?? [])).map { VectorMath.cosine(probe, $0) }
            .sorted(by: >)
        let best = all.first ?? 0
        let top = all.prefix(k)
        let topMean = top.isEmpty ? 0 : top.reduce(0, +) / Float(top.count)
        return MatchScore(centroid: c, bestSample: best, topK: topMean)
    }
}

/// Decides whether a single frame matches: `MatchScore.value` (the better of
/// the averaged template and the top-3 samples) must clear the threshold.
public struct MatchPolicy: Equatable, Sendable {
    /// Allowed range for the user-configurable threshold.
    public static let thresholdRange: ClosedRange<Float> = 0.30...0.90
    /// Default for SFace embeddings. OpenCV's published single-pair SFace
    /// threshold is 0.363; comparing against an averaged template gives
    /// genuine users much higher scores (≈0.9 in practice), so 0.70 is a
    /// strict default that still leaves headroom.
    public static let defaultThreshold: Float = 0.70
    public static let defaultRequiredConsecutive = 3

    public var threshold: Float
    public var requiredConsecutive: Int

    public init(threshold: Float = MatchPolicy.defaultThreshold,
                requiredConsecutive: Int = MatchPolicy.defaultRequiredConsecutive) {
        self.threshold = min(max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        self.requiredConsecutive = max(1, requiredConsecutive)
    }

    public func isMatch(_ score: MatchScore) -> Bool {
        score.value >= threshold
    }
}

/// Counts consecutive matching frames. Any non-matching frame, a frame with
/// no face or more than one face resets the run.
public struct ConsecutiveMatchCounter: Equatable, Sendable {
    public private(set) var run = 0
    public let required: Int

    public init(required: Int) { self.required = max(1, required) }

    public mutating func record(matched: Bool) {
        run = matched ? run + 1 : 0
    }

    public mutating func reset() { run = 0 }

    public var isSatisfied: Bool { run >= required }
}

/// A reference head pose (degrees) that counts as "facing the screen".
public struct PoseBaseline: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double

    public init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }

    /// Median of a set of poses (nil if empty).
    public static func median(_ poses: [(yaw: Double, pitch: Double)]) -> PoseBaseline? {
        guard !poses.isEmpty else { return nil }
        func med(_ v: [Double]) -> Double {
            let s = v.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        return PoseBaseline(yaw: med(poses.map(\.yaw)), pitch: med(poses.map(\.pitch)))
    }

    /// A baseline further than this from the camera axis isn't plausible
    /// for someone looking at the screen, so it's clamped. Pitch can be large
    /// because the camera sits above the screen; yaw only comes from posture.
    public static let plausibleYaw: Double = 20
    public static let plausiblePitch: Double = 25

    /// Exponential moving average towards `sample` (first sample if `old` is nil).
    public static func blended(_ old: PoseBaseline?, with sample: PoseBaseline, alpha: Double = 0.2) -> PoseBaseline {
        guard let old else { return sample.clamped }
        return PoseBaseline(yaw: old.yaw + alpha * (sample.yaw - old.yaw),
                            pitch: old.pitch + alpha * (sample.pitch - old.pitch)).clamped
    }

    public var clamped: PoseBaseline {
        PoseBaseline(yaw: min(max(yaw, -Self.plausibleYaw), Self.plausibleYaw),
                     pitch: min(max(pitch, -Self.plausiblePitch), Self.plausiblePitch))
    }
}
