import AVFoundation
import AppKit
import FaceUnlockCore
import SwiftUI

// MARK: - Preview

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Enrolment

@MainActor
@Observable
final class EnrolmentModel {
    var instruction = "Get ready – position your face in the frame"
    var progress = 0.0
    var detail = ""
    var finished = false
    var failed = false
}

struct EnrolmentView: View {
    let session: AVCaptureSession
    let model: EnrolmentModel

    var body: some View {
        VStack(spacing: 12) {
            CameraPreview(session: session)
                .frame(width: 480, height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(model.instruction).font(.title3.bold())
            ProgressView(value: model.progress)
            Text(model.detail).font(.callout).foregroundStyle(model.failed ? .red : .secondary)
                .multilineTextAlignment(.center)
            Text("Only numeric face embeddings are saved – never images.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(width: 480)
    }
}

/// Drives enrolment on the camera's video queue.
final class EnrolmentRunner: @unchecked Sendable {
    static let timeout: TimeInterval = 45

    private let analyzer: FaceAnalyzer
    private var collector = EnrolmentCollector() // video queue only
    private let lock = NSLock()
    private var done = false
    private let onUpdate: @Sendable (String, Double, String?) -> Void
    private let onComplete: @Sendable ([[Float]], PoseBaseline?) -> Void

    init(analyzer: FaceAnalyzer,
         onUpdate: @escaping @Sendable (String, Double, String?) -> Void,
         onComplete: @escaping @Sendable ([[Float]], PoseBaseline?) -> Void) {
        self.analyzer = analyzer
        self.onUpdate = onUpdate
        self.onComplete = onComplete
    }

    func cancel() { lock.withLock { done = true } }

    func process(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        if lock.withLock({ done }) { return }
        let analysis = analyzer.analyze(pixelBuffer: pixelBuffer, wantQuality: true)
        collector.offer(analysis, at: time)
        onUpdate(collector.currentInstruction, collector.progress, collector.lastRejection)
        if collector.isComplete {
            let first: Bool = lock.withLock {
                guard !done else { return false }
                done = true
                return true
            }
            if first { onComplete(collector.embeddings, collector.baselinePose) }
        }
    }
}

// MARK: - Test recognition

@MainActor
@Observable
final class TestModel {
    var lines: [String] = ["Starting camera…"]
    var passed = false
    var threshold: Float = MatchPolicy.defaultThreshold
    private var recentScores: [Float] = []
    private var strongPoses: [(yaw: Double, pitch: Double)] = []

    /// Median pose of strongly matching frames in this test (for templates
    /// that predate the enrolled baseline).
    var strongPoseMedian: PoseBaseline? { strongPoses.count >= 8 ? PoseBaseline.median(strongPoses) : nil }

    /// Median centroid score of recent frames with a single, matching face.
    var typicalScore: Float? {
        guard recentScores.count >= 10 else { return nil }
        let sorted = recentScores.sorted()
        return sorted[sorted.count / 2]
    }

    func noteScore(_ score: Float) {
        recentScores.append(score)
        if recentScores.count > 60 { recentScores.removeFirst(recentScores.count - 60) }
    }
}

struct TestView: View {
    let session: AVCaptureSession
    let model: TestModel
    let reset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            CameraPreview(session: session)
                .frame(width: 480, height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    Text(model.passed ? "PASS – would unlock" : "Not yet")
                        .font(.headline)
                        .padding(6)
                        .background(model.passed ? Color.green.opacity(0.85) : Color.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.body, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text("Look at the camera as you normally would. Nothing is typed here.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset", action: reset)
            }
        }
        .frame(width: 480)
    }
}

extension TestModel {
    func apply(_ r: LiveReadout) {
        let s = r.snapshot
        if s.faceCount == 1, s.frameMatched, let score = s.score {
            noteScore(score.value)
            if score.value >= threshold + 0.05, let y = s.latestYaw, let p = s.latestPitch {
                strongPoses.append((y, p))
                if strongPoses.count > 90 { strongPoses.removeFirst(strongPoses.count - 90) }
            }
        }
        var lines: [String] = []
        lines.append("Faces in frame:     \(s.faceCount)\(s.faceCount > 1 ? "  (only one allowed)" : "")")
        if let score = s.score {
            let verdict = s.frameMatched ? "match" : "no match"
            lines.append(String(format: "Match %.3f (avg %.3f, top-3 %.3f)  vs %.2f  %@",
                                score.value, score.centroid, score.topK, threshold, verdict))
        } else {
            lines.append("Match:              –")
        }
        lines.append("Consecutive match:  \(s.consecutiveMatches)/\(s.requiredConsecutive)\(s.consecutiveMatches >= s.requiredConsecutive ? "  ✓" : "")")
        let eyes = r.eyeOpenness.map { String(format: "L %.3f R %.3f", $0.left, $0.right) } ?? "–"
        let ratio = s.eyeRatio.map { String(format: "  (%.0f%% of open)", $0 * 100) } ?? ""
        lines.append("Eye openness:       \(eyes)\(ratio)")
        let blinkNote = s.livenessMode == .blinkAndMovement ? "" : "  (not required)"
        lines.append("Blink:              \(s.blinked ? "seen ✓" : Self.describe(s.blinkState))\(blinkNote)")
        lines.append(String(format: "Head pose range:    yaw %.1f° pitch %.1f°", s.yawRange, s.pitchRange))
        lines.append(String(format: "Natural movement:   %.1fs, turn %.1f° (need 3), parallax %.2f%%, S/N %.1f (need 2.2)",
                            s.motionSeconds, s.motionRotation, s.motionParallax * 100, s.motionSignalToNoise))
        if s.faceCount == 1 && !s.frameUsable { lines.append("Face not usable:    look straight at the screen") }
        lines.append("Liveness (\(s.livenessMode.title)): \(s.livenessSatisfied ? "✓" : "waiting")")
        lines.append("Attention:          \(s.attentionProblem ?? (s.frameMatched ? "facing screen, eyes open ✓" : "–"))  (\(s.attentiveRun)/5)")
        let base = s.attentionBaseline.map { String(format: "%.1f° / %.1f°", $0.yaw, $0.pitch) } ?? "learning"
        lines.append(String(format: "Pose (yaw/pitch):   %@ / %@  [%@]  baseline %@",
                            s.latestYaw.map { String(format: "%.1f°", $0) } ?? "–",
                            s.latestPitch.map { String(format: "%.1f°", $0) } ?? "–",
                            s.poseFromLandmarks ? "landmarks" : "Vision", base))
        self.lines = lines
        if s.shouldUnlock { passed = true }
    }

    private static func describe(_ state: BlinkDetector.State) -> String {
        switch state {
        case .calibrating: return "calibrating"
        case .open: return "waiting (eyes open)"
        case .closed: return "eyes closed…"
        case .waitingForOpen: return "waiting for eyes to open"
        case .blinked: return "seen"
        }
    }
}
