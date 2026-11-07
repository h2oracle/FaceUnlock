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
    private var summarizer: DiagnosticsSummarizer?

    /// Frames with an earlier timestamp (system uptime) are dropped unseen.
    private let ignoreFramesBefore: TimeInterval

    init(analyzer: FaceAnalyzer, template: FaceTemplate, policy: MatchPolicy, liveness: LivenessMode,
         ignoreFramesBefore: TimeInterval = 0,
         onReadout: (@Sendable (LiveReadout) -> Void)? = nil,
         onDiagnostics: (@Sendable (String) -> Void)? = nil,
         stopsOnPass: Bool = true,
         onPass: @escaping @Sendable () -> Void) {
        self.analyzer = analyzer
        self.template = template
        self.policy = policy
        self.liveness = liveness
        self.ignoreFramesBefore = ignoreFramesBefore
        self.onDiagnostics = onDiagnostics
        self.onReadout = onReadout
        self.onPass = onPass
        self.stopsOnPass = stopsOnPass
        self.evaluator = UnlockEvaluator(policy: policy, liveness: liveness)
    }

    /// Emits the last partial diagnostics window (call when the attempt ends).
    func flushDiagnostics() {
        let now = ProcessInfo.processInfo.systemUptime
        if let line = lock.withLock({ summarizer?.flush(at: now) }) { onDiagnostics?(line) }
    }

    var sawFace: Bool { lock.withLock { _sawFace } }
    /// Uptime of the first frame the camera delivered (even if discarded).
    var firstCameraFrameAt: TimeInterval? { lock.withLock { _firstCameraFrameAt } }
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

    func process(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        lock.withLock { if _firstCameraFrameAt == nil { _firstCameraFrameAt = time } }
        guard time >= ignoreFramesBefore else { return }
        let shouldReset: Bool = lock.withLock {
            let r = resetRequested
            resetRequested = false
            return r
        }
        if shouldReset { evaluator = UnlockEvaluator(policy: policy, liveness: liveness) }
        if lock.withLock({ finished }) { return }

        // No capture-quality request here: it cost ~25 % of the frame rate,
        // and size, angle and landmarks are enough to judge non-matches.
        let analysis = analyzer.analyze(pixelBuffer: pixelBuffer)
        let score = analysis.embedding.map { MatchScore.score($0, against: template) }
        let observation = FrameObservation(
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
