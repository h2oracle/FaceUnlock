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

    init(analyzer: FaceAnalyzer, template: FaceTemplate, policy: MatchPolicy,
         onReadout: (@Sendable (LiveReadout) -> Void)? = nil,
         stopsOnPass: Bool = true,
         onPass: @escaping @Sendable () -> Void) {
        self.analyzer = analyzer
        self.template = template
        self.policy = policy
        self.onReadout = onReadout
        self.onPass = onPass
        self.stopsOnPass = stopsOnPass
        self.evaluator = UnlockEvaluator(policy: policy)
    }

    var sawFace: Bool { lock.withLock { _sawFace } }
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
        let shouldReset: Bool = lock.withLock {
            let r = resetRequested
            resetRequested = false
            return r
        }
        if shouldReset { evaluator = UnlockEvaluator(policy: policy) }
        if lock.withLock({ finished }) { return }

        let analysis = analyzer.analyze(pixelBuffer: pixelBuffer)
        let score = analysis.embedding.map { MatchScore.score($0, against: template) }
        let observation = FrameObservation(
            time: time,
            faceCount: analysis.faceCount,
            score: analysis.faceCount == 1 ? score : nil,
            eyes: analysis.eyeSample(at: time),
            yawDegrees: analysis.yawDegrees,
            pitchDegrees: analysis.pitchDegrees
        )
        let snapshot = evaluator.observe(observation)
        lock.withLock {
            if analysis.faceCount > 0 { _sawFace = true }
            _diagnostics.observe(snapshot)
        }

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
