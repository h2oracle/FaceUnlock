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
        return try FaceTemplate(modelID: modelID, samples: kept, cameraID: cameraID, createdAt: createdAt)
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
    /// Best cosine to any individual enrolment sample.
    public var bestSample: Float

    public init(centroid: Float, bestSample: Float) {
        self.centroid = centroid
        self.bestSample = bestSample
    }

    public static func score(_ probe: [Float], against template: FaceTemplate) -> MatchScore {
        let c = VectorMath.cosine(probe, template.centroid)
        let best = template.samples.map { VectorMath.cosine(probe, $0) }.max() ?? 0
        return MatchScore(centroid: c, bestSample: best)
    }
}

/// Decides whether a single frame matches. Strict by default: both the
/// centroid and the best individual sample must clear the threshold.
public struct MatchPolicy: Equatable, Sendable {
    /// Allowed range for the user-configurable threshold.
    public static let thresholdRange: ClosedRange<Float> = 0.30...0.90
    /// Default for SFace embeddings. OpenCV's published single-pair SFace
    /// threshold is 0.363; comparing against an averaged template gives
    /// genuine users noticeably higher scores, so 0.55 errs on the strict side.
    public static let defaultThreshold: Float = 0.55
    public static let defaultRequiredConsecutive = 3

    public var threshold: Float
    public var requiredConsecutive: Int

    public init(threshold: Float = MatchPolicy.defaultThreshold,
                requiredConsecutive: Int = MatchPolicy.defaultRequiredConsecutive) {
        self.threshold = min(max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        self.requiredConsecutive = max(1, requiredConsecutive)
    }

    public func isMatch(_ score: MatchScore) -> Bool {
        score.centroid >= threshold && score.bestSample >= threshold
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
