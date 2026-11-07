import Foundation
import Testing
@testable import FaceUnlockCore

private let fps = 30.0

/// Runs `seconds` of frames through a natural-movement evaluator; returns
/// the time of the first unlock (nil if never) and the last snapshot.
private func run(_ face: inout SyntheticFace, seconds: Double,
                 pose: (Double) -> SyntheticFace.Pose) -> (unlockAt: Double?, last: UnlockEvaluator.Snapshot?) {
    var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55, requiredConsecutive: 3), liveness: .naturalMovement)
    var last: UnlockEvaluator.Snapshot?
    for i in 0..<Int(seconds * fps) {
        let t = Double(i) / fps
        let s = e.observe(face.frame(time: t, pose: pose(t)))
        last = s
        if s.shouldUnlock { return (t, s) }
    }
    return (nil, last)
}

/// A person sitting normally: slow head sway of a few degrees.
private func normalHead(_ t: Double) -> SyntheticFace.Pose {
    SyntheticFace.Pose(yaw: 6 * sin(2 * .pi * 0.5 * t), pitch: 3 * sin(2 * .pi * 0.4 * t + 1),
                       roll: 1 * sin(2 * .pi * 0.3 * t), tx: 0.05 * sin(t), ty: 0.03 * cos(t))
}

/// Sitting still: only small involuntary movement.
private func stillishHead(_ t: Double) -> SyntheticFace.Pose {
    SyntheticFace.Pose(yaw: 2.5 * sin(2 * .pi * 0.6 * t) + 0.3 * sin(2 * .pi * 7 * t),
                       pitch: 1.5 * sin(2 * .pi * 0.45 * t + 2), roll: 0.5 * sin(2 * .pi * 0.5 * t))
}

/// A photo waved around: ±25° yaw/pitch/roll at 2 Hz plus translation.
private func wavedPhoto(_ t: Double) -> SyntheticFace.Pose {
    SyntheticFace.Pose(yaw: 25 * sin(2 * .pi * 2 * t), pitch: 25 * sin(2 * .pi * 2 * t + 1.3),
                       roll: 25 * sin(2 * .pi * 2 * t + 2.1), tx: 0.6 * sin(2 * .pi * 1.1 * t),
                       ty: 0.4 * cos(2 * .pi * 0.9 * t), distance: 8 + 1.5 * sin(2 * .pi * 0.7 * t))
}

/// A photo held in a hand: small tremor.
private func handHeldPhoto(_ t: Double) -> SyntheticFace.Pose {
    SyntheticFace.Pose(yaw: 4 * sin(2 * .pi * 0.8 * t), pitch: 3 * sin(2 * .pi * 0.6 * t + 1),
                       roll: 2 * sin(2 * .pi * 0.5 * t), tx: 0.1 * sin(t))
}

@Suite struct NaturalMovementTests {
    @Test func realHeadMovingNormallyPassesQuickly() throws {
        for seed in 1...5 {
            var face = SyntheticFace(flat: false, seed: UInt64(seed))
            let r = run(&face, seconds: 5, pose: normalHead)
            let t = try #require(r.unlockAt, "seed \(seed): parallax \(r.last?.motionParallax ?? -1)")
            #expect(t >= 0.5 && t <= 1.5, "seed \(seed): passed at \(t)s")
        }
    }

    @Test func realHeadSittingStillButMicroMovingPasses() throws {
        for seed in 1...5 {
            var face = SyntheticFace(flat: false, seed: UInt64(seed))
            let r = run(&face, seconds: 6, pose: stillishHead)
            let t = try #require(r.unlockAt, "seed \(seed): parallax \(r.last?.motionParallax ?? -1) rot \(r.last?.motionRotation ?? -1)")
            #expect(t <= 3, "seed \(seed): passed at \(t)s")
        }
    }

    @Test func perfectlyStillRealHeadWaits() {
        var face = SyntheticFace(flat: false)
        #expect(run(&face, seconds: 5, pose: { _ in SyntheticFace.Pose() }).unlockAt == nil)
    }

    @Test func wavedPhotoFails() {
        for seed in 1...5 {
            var face = SyntheticFace(flat: true, seed: UInt64(seed))
            let r = run(&face, seconds: 10, pose: wavedPhoto)
            #expect(r.unlockAt == nil, "seed \(seed): photo passed, parallax \(r.last?.motionParallax ?? -1)")
        }
    }

    @Test func handHeldPhotoFails() {
        for seed in 1...5 {
            var face = SyntheticFace(flat: true, seed: UInt64(seed))
            let r = run(&face, seconds: 10, pose: handHeldPhoto)
            #expect(r.unlockAt == nil, "seed \(seed): photo passed, parallax \(r.last?.motionParallax ?? -1)")
        }
    }

    @Test func stillPhotoFails() {
        var face = SyntheticFace(flat: true)
        #expect(run(&face, seconds: 10, pose: { _ in SyntheticFace.Pose() }).unlockAt == nil)
    }

    @Test func noisierLandmarksStillSeparateHeadFromPhoto() {
        var head = SyntheticFace(flat: false, noise: 0.02, seed: 9)
        var photo = SyntheticFace(flat: true, noise: 0.02, seed: 9)
        #expect(run(&head, seconds: 5, pose: normalHead).unlockAt != nil)
        #expect(run(&photo, seconds: 10, pose: wavedPhoto).unlockAt == nil)
    }

    @Test func blinkModeStillNeedsABlink() {
        var face = SyntheticFace(flat: false)
        var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .blinkAndMovement)
        for i in 0..<150 {
            let t = Double(i) / fps
            #expect(!e.observe(face.frame(time: t, pose: normalHead(t))).shouldUnlock)
        }
    }

    @Test func offModeNeedsOnlyConsecutiveMatches() {
        var face = SyntheticFace(flat: true)
        var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55, requiredConsecutive: 3), liveness: .off)
        var at: Int?
        for i in 0..<10 where at == nil {
            if e.observe(face.frame(time: Double(i) / fps, pose: SyntheticFace.Pose())).shouldUnlock { at = i }
        }
        #expect(at == 2)
    }

    @Test func nonMatchingFrameResetsMovementEvidence() {
        var face = SyntheticFace(flat: false)
        var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .naturalMovement)
        for i in 0..<20 { e.observe(face.frame(time: Double(i) / fps, pose: normalHead(Double(i) / fps))) }
        #expect(e.snapshot.motionSeconds > 0.5)
        let s = e.observe(face.frame(time: 0.7, pose: normalHead(0.7), score: 0.3))
        #expect(s.motionSeconds == 0)
        #expect(s.resetReason == .noMatch)
    }

    @Test func diagnosticsExplainMissingMovement() {
        var face = SyntheticFace(flat: true)
        var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .naturalMovement)
        var d = AttemptDiagnostics()
        for i in 0..<100 { d.observe(e.observe(face.frame(time: Double(i) / fps, pose: wavedPhoto(Double(i) / fps)))) }
        #expect(d.failureOutcome == .noNaturalMovement)
    }

    @Test func homographyIsExactForAPlane() throws {
        var src: [CGPoint] = []
        for i in 0..<20 {
            let x: Double = Double(i % 5) * 10
            let y: Double = Double(i / 5) * 7 + Double(i % 3)
            src.append(CGPoint(x: x, y: y))
        }
        // An arbitrary projective map.
        var dst: [CGPoint] = []
        for p in src {
            let w: Double = 0.001 * p.x - 0.0007 * p.y + 1
            let u: Double = (1.2 * p.x + 0.1 * p.y + 5) / w
            let v: Double = (-0.2 * p.x + 0.9 * p.y - 3) / w
            dst.append(CGPoint(x: u, y: v))
        }
        let r = try #require(Homography.residuals(from: src, to: dst))
        #expect(r.allSatisfy { abs($0.dx) < 1e-6 && abs($0.dy) < 1e-6 })
    }
}

@Suite struct DiagnosticsSummarizerTests {
    @Test func emitsAboutEveryHalfSecondWithNumbersOnly() {
        var e = UnlockEvaluator(policy: MatchPolicy(), liveness: .naturalMovement)
        var summarizer = DiagnosticsSummarizer(threshold: 0.55, start: 0)
        var lines: [String] = []
        var face = SyntheticFace(flat: false)
        for i in 0..<30 {
            let s = e.observe(face.frame(time: Double(i) / 15, pose: normalHead(Double(i) / 15)))
            if let line = summarizer.observe(s, eyeOpenness: 0.1, at: Double(i) / 15) { lines.append(line) }
        }
        #expect(lines.count >= 3 && lines.count <= 4)
        let first = lines[0]
        #expect(first.contains("frames="))
        #expect(first.contains("thr=0.550"))
        #expect(first.contains("blink="))
        #expect(first.contains("liveness(naturalMovement)"))
        #expect(summarizer.flush(at: 2.5) != nil || summarizer.totalFrames == 30)
    }

    @Test func reportsResetReasons() {
        var e = UnlockEvaluator(policy: MatchPolicy(), liveness: .naturalMovement)
        var summarizer = DiagnosticsSummarizer(threshold: 0.55, start: 0)
        var face = SyntheticFace(flat: false)
        for i in 0..<5 {
            let t = Double(i) / 15
            _ = summarizer.observe(e.observe(face.frame(time: t, pose: normalHead(t))), eyeOpenness: nil, at: t)
        }
        let none = FrameObservation(time: 0.4, faceCount: 0, score: nil, eyes: nil, yawDegrees: nil, pitchDegrees: nil)
        _ = summarizer.observe(e.observe(none), eyeOpenness: nil, at: 0.4)
        let line = summarizer.flush(at: 0.45)
        #expect(line?.contains("resets: no face×1") == true)
    }

    @Test func manualUnlockOutcomeRoundTrips() throws {
        let outcome = AttemptOutcome.unlockedManually(lastIssue: .noMatch(bestScore: 0.41))
        let record = AttemptRecord(time: Date(timeIntervalSince1970: 5), outcome: outcome)
        let decoded = try JSONDecoder().decode(AttemptRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(!outcome.isSuccess)
        #expect(outcome.summary.contains("0.41"))
        #expect(!outcome.advice.isEmpty)
    }
}
