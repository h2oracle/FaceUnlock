import Foundation

/// Collects good-quality embeddings during enrolment, walking the user
/// through a few gentle head poses.
public struct EnrolmentCollector: Sendable {
    public struct Step: Equatable, Sendable {
        public var instruction: String
        public var samples: Int
    }

    public static let steps: [Step] = [
        Step(instruction: "Look straight at the screen", samples: 6),
        Step(instruction: "Sit back a little", samples: 4),
        Step(instruction: "Lean in a little", samples: 4),
        Step(instruction: "Look slightly left", samples: 4),
        Step(instruction: "Look slightly right", samples: 4),
        Step(instruction: "Look slightly up", samples: 4),
        Step(instruction: "Look slightly down", samples: 4),
    ]

    /// VNDetectFaceCaptureQualityRequest score below which frames are rejected.
    public var minimumQuality: Float = 0.35
    /// Minimum seconds between accepted frames, so samples aren't near-duplicates.
    public var minimumInterval: TimeInterval = 0.15
    /// Seconds after each new instruction before frames are taken, so the
    /// user has time to read it and move.
    public var stepSettleTime: TimeInterval = 0.8

    public private(set) var embeddings: [[Float]] = []
    /// Head pose of each accepted sample (when known).
    public private(set) var poses: [(yaw: Double, pitch: Double)] = []
    /// Median pose of the "look straight" step: how this owner faces the screen.
    public var baselinePose: PoseBaseline? { PoseBaseline.median(straightPoses) }
    private var straightPoses: [(yaw: Double, pitch: Double)] = []
    public private(set) var stepIndex = 0
    private var acceptedInStep = 0
    private var lastAccepted: TimeInterval = -.infinity
    private var stepStartedAt: TimeInterval?
    public private(set) var lastRejection: String?

    public init() {}

    public var totalRequired: Int { Self.steps.reduce(0) { $0 + $1.samples } }
    public var isComplete: Bool { stepIndex >= Self.steps.count }
    public var currentInstruction: String {
        isComplete ? "Done" : Self.steps[stepIndex].instruction
    }
    public var progress: Double { Double(embeddings.count) / Double(totalRequired) }

    /// Returns true if the frame was accepted.
    @discardableResult
    public mutating func offer(_ frame: FrameAnalysis, at time: TimeInterval) -> Bool {
        guard !isComplete else { return false }
        if stepStartedAt == nil { stepStartedAt = time }
        guard let started = stepStartedAt, time - started >= stepSettleTime else { return false }
        if frame.faceCount == 0 { lastRejection = "No face found"; return false }
        if frame.faceCount > 1 { lastRejection = "More than one face in view"; return false }
        guard let quality = frame.captureQuality, quality >= minimumQuality else {
            lastRejection = "Image quality too low – improve lighting, hold still"
            return false
        }
        guard let embedding = frame.embedding else { lastRejection = "Couldn't read face landmarks"; return false }
        guard time - lastAccepted >= minimumInterval else { return false }

        lastRejection = nil
        lastAccepted = time
        embeddings.append(embedding)
        if let y = frame.yawDegrees, let p = frame.pitchDegrees {
            poses.append((y, p))
            if stepIndex == 0 { straightPoses.append((y, p)) }
        }
        acceptedInStep += 1
        if acceptedInStep >= Self.steps[stepIndex].samples {
            stepIndex += 1
            acceptedInStep = 0
            stepStartedAt = time
        }
        return true
    }
}
