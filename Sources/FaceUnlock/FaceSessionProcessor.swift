import CoreVideo
import FaceUnlockCore
import Foundation

/// Live per-frame numbers for the UI (test window). No images.
struct LiveReadout: Sendable {
    var snapshot: UnlockEvaluator.Snapshot
    var eyeOpenness: (left: Double, right: Double)?
    var yaw: Double?
    var pitch: Double?
}

/// Runs the recognition + liveness evaluator over camera frames on the
/// camera's video queue. Shared by the real unlock attempt and the test
/// window so both behave identically.
final class FaceSessionProcessor: @unchecked Sendable {
    private let analyzer: FaceAnalyzer
    private let template: FaceTemplate
    private let policy: MatchPolicy
    private let liveness: LivenessMode
    /// Receives a diagnostics summary line about every 0.5 s.
    private let onDiagnostics: (@Sendable (String) -> Void)?
    private let onReadout: (@Sendable (LiveReadout) -> Void)?
    private let onPass: @Sendable () -> Void
    /// Real attempts stop at the first pass; the test window keeps going.
    private let stopsOnPass: Bool

    // Touched only on the video queue.
    private var evaluator: UnlockEvaluator
    private var resetRequested = false

    // Shared with the main thread.
    private let lock = NSLock()
    private var finished = false
    private var _sawFace = false
    private var _diagnostics = AttemptDiagnostics()
    private var _firstCameraFrameAt: TimeInterval?
    private var _passPose: PoseBaseline?
    private var _passEmbedding: [Float]?
    private var _passScore: Float?
    /// Embeddings and scores of the current attentive run (video queue only).
    private var attentiveEmbeddings: [[Float]] = []
    private var attentiveScores: [Float] = []
    private var summarizer: DiagnosticsSummarizer?

    /// Frames with an earlier timestamp (system uptime) are dropped unseen.
    private let ignoreFramesBefore: TimeInterval
    private let attentionBaseline: PoseBaseline?

    init(analyzer: FaceAnalyzer, template: FaceTemplate, policy: MatchPolicy, liveness: LivenessMode,
         ignoreFramesBefore: TimeInterval = 0,
         attentionBaseline: PoseBaseline?,
         onReadout: (@Sendable (LiveReadout) -> Void)? = nil,
         onDiagnostics: (@Sendable (String) -> Void)? = nil,
         stopsOnPass: Bool = true,
         onPass: @escaping @Sendable () -> Void) {
        self.analyzer = analyzer
        self.template = template
        self.policy = policy
        self.liveness = liveness
        self.ignoreFramesBefore = ignoreFramesBefore
        self.attentionBaseline = attentionBaseline
        self.onDiagnostics = onDiagnostics
        self.onReadout = onReadout
        self.onPass = onPass
        self.stopsOnPass = stopsOnPass
        self.evaluator = UnlockEvaluator(policy: policy, liveness: liveness, attentionBaseline: attentionBaseline)
    }

    /// Emits the last partial diagnostics window (call when the attempt ends).
    func flushDiagnostics() {
        let now = ProcessInfo.processInfo.systemUptime
        if let line = lock.withLock({ summarizer?.flush(at: now) }) { onDiagnostics?(line) }
    }

    var sawFace: Bool { lock.withLock { _sawFace } }
    /// Uptime of the first frame the camera delivered (even if discarded).
    var firstCameraFrameAt: TimeInterval? { lock.withLock { _firstCameraFrameAt } }
    /// Median pose of the attentive frames that produced the pass.
    var passPose: PoseBaseline? { lock.withLock { _passPose } }
    /// Coordinate-wise median embedding of the attentive frames that passed,
    /// and the lowest score among them (for template adaptation).
    var passEmbedding: [Float]? { lock.withLock { _passEmbedding } }
    var passScore: Float? { lock.withLock { _passScore } }
    /// Whole-attempt summary used to explain a failure.
    var diagnostics: AttemptDiagnostics { lock.withLock { _diagnostics } }

    /// Stops reporting a pass. Idempotent.
    func finish() { lock.withLock { finished = true } }

    /// Test window only: start a fresh evaluation.
    func requestReset() {
        lock.withLock {
            resetRequested = true
            finished = false
        }
    }

    static func medianEmbedding(_ list: [[Float]]) -> [Float]? {
        guard let first = list.first, list.allSatisfy({ $0.count == first.count }) else { return nil }
        var out = [Float](repeating: 0, count: first.count)
        for i in 0..<first.count {
            let v = list.map { $0[i] }.sorted()
            out[i] = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        }
        return VectorMath.l2Normalized(out)
    }

    func process(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        lock.withLock { if _firstCameraFrameAt == nil { _firstCameraFrameAt = time } }
        guard time >= ignoreFramesBefore else { return }
        let shouldReset: Bool = lock.withLock {
            let r = resetRequested
            resetRequested = false
            return r
        }
        if shouldReset { evaluator = UnlockEvaluator(policy: policy, liveness: liveness, attentionBaseline: attentionBaseline) }
        if lock.withLock({ finished }) { return }

        // No capture-quality request here: it cost ~25 % of the frame rate,
        // and size, angle and landmarks are enough to judge non-matches.
        let analysis = analyzer.analyze(pixelBuffer: pixelBuffer)
        let score = analysis.embedding.map { MatchScore.score($0, against: template) }
        var observation = FrameObservation(
            time: time,
            faceCount: analysis.faceCount,
            score: analysis.faceCount == 1 ? score : nil,
            eyes: analysis.eyeSample(at: time),
            yawDegrees: analysis.yawDegrees,
            pitchDegrees: analysis.pitchDegrees,
            landmarks: analysis.landmarks,
            interocular: analysis.interocular,
            usable: analysis.isUsable,
            unusableReason: FrameQualityGate.problem(analysis)
        )
        observation.poseEstimated = analysis.poseEstimated
        let snapshot = evaluator.observe(observation)
        let eyeMean: Double? = {
            guard let l = analysis.leftEyeOpenness, let r = analysis.rightEyeOpenness else { return nil }
            return (l + r) / 2
        }()
        let line: String? = lock.withLock {
            if analysis.faceCount > 0 { _sawFace = true }
            _diagnostics.observe(snapshot)
            guard onDiagnostics != nil else { return nil }
            if summarizer == nil { summarizer = DiagnosticsSummarizer(threshold: policy.threshold, start: time) }
            return summarizer?.observe(snapshot, eyeOpenness: eyeMean, at: time)
        }
        if let line { onDiagnostics?(line) }

        if let onReadout {
            var eyes: (Double, Double)?
            if let l = analysis.leftEyeOpenness, let r = analysis.rightEyeOpenness { eyes = (l, r) }
            onReadout(LiveReadout(snapshot: snapshot, eyeOpenness: eyes,
                                  yaw: analysis.yawDegrees, pitch: analysis.pitchDegrees))
        }

        if snapshot.frameMatched, snapshot.attentionProblem == nil, let e = analysis.embedding, let sc = snapshot.score {
            attentiveEmbeddings.append(e)
            attentiveScores.append(sc.value)
            if attentiveEmbeddings.count > 5 {
                attentiveEmbeddings.removeFirst()
                attentiveScores.removeFirst()
            }
        } else if analysis.faceCount > 0 {
            attentiveEmbeddings.removeAll()
            attentiveScores.removeAll()
        }
        if snapshot.shouldUnlock {
            let median = Self.medianEmbedding(attentiveEmbeddings)
            let minScore = attentiveScores.min()
            lock.withLock {
                if let pose = snapshot.attentivePose { _passPose = pose }
                _passEmbedding = median
                _passScore = minScore
            }
        }
        if snapshot.shouldUnlock && !stopsOnPass {
            onPass()
        } else if snapshot.shouldUnlock {
            let first: Bool = lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
            if first { onPass() }
        }
    }
}
