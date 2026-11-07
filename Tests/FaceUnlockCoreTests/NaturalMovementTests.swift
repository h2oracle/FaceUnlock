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

    @Test func realHeadTurningOnlyAboutThreeDegreesPasses() throws {
        // Small sway: the two ends of the movement differ by only ~3–4°.
        let pose: (Double) -> SyntheticFace.Pose = { t in
            SyntheticFace.Pose(yaw: 2.0 * sin(2 * .pi * 0.7 * t), pitch: 0.8 * sin(2 * .pi * 0.5 * t))
        }
        for seed in 1...5 {
            var face = SyntheticFace(flat: false, seed: UInt64(seed))
            let r = run(&face, seconds: 6, pose: pose)
            let t = try #require(r.unlockAt, "seed \(seed): rot \(r.last?.motionRotation ?? -1) par \(r.last?.motionParallax ?? -1)")
            #expect(t <= 3.0, "seed \(seed): passed at \(t)s")
        }
    }

    @Test func photoWithSmallTremorFails() {
        // The same small-rotation regime, but flat.
        let pose: (Double) -> SyntheticFace.Pose = { t in
            SyntheticFace.Pose(yaw: 2.0 * sin(2 * .pi * 0.7 * t), pitch: 0.8 * sin(2 * .pi * 0.5 * t))
        }
        for seed in 1...5 {
            var face = SyntheticFace(flat: true, seed: UInt64(seed))
            #expect(run(&face, seconds: 10, pose: pose).unlockAt == nil, "seed \(seed)")
        }
    }

    @Test func parallaxIsSmoothedAndDoesNotFlipToZero() {
        var face = SyntheticFace(flat: false, seed: 4)
        var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .off) // keep observing
        var m = NaturalMovementCheck()
        var sawValue = false
        var droppedToZero = false
        for i in 0..<90 {
            let t = Double(i) / fps
            let f = face.frame(time: t, pose: normalHead(t))
            _ = e.observe(f)
            m.observe(time: t, yawDegrees: f.yawDegrees, pitchDegrees: f.pitchDegrees,
                      landmarks: f.landmarks, interocular: f.interocular)
            if m.parallax > 0 { sawValue = true } else if sawValue { droppedToZero = true }
        }
        #expect(sawValue)
        #expect(!droppedToZero)
    }

    @Test func naturalBlinkWithSlightMovementPassesQuickly() throws {
        // Small sway that alone is slow for parallax, plus one natural blink
        // (≈150 ms) at 0.5 s.
        let pose: (Double) -> SyntheticFace.Pose = { t in
            SyntheticFace.Pose(yaw: 2.0 * sin(2 * .pi * 0.7 * t), pitch: 0.8 * sin(2 * .pi * 0.5 * t))
        }
        for seed in 1...5 {
            var face = SyntheticFace(flat: false, seed: UInt64(seed))
            face.blink = { t in (0.5..<0.65).contains(t) ? 0.1 : 1 }
            let r = run(&face, seconds: 4, pose: pose)
            let t = try #require(r.unlockAt, "seed \(seed)")
            #expect(t <= 1.3, "seed \(seed): passed at \(t)s, blinked \(r.last?.blinked ?? false)")
            #expect(r.last?.blinked == true)
        }
    }

    @Test func aPhotoCannotBlink() {
        // A flat photo tilted hard towards/away from the camera squashes the
        // eyes, but the whole face squashes with them: never a blink, never a pass.
        let pose: (Double) -> SyntheticFace.Pose = { t in
            SyntheticFace.Pose(yaw: 3 * sin(2 * .pi * 0.7 * t), pitch: 65 * max(0, sin(2 * .pi * 1.5 * t)))
        }
        for seed in 1...5 {
            var face = SyntheticFace(flat: true, seed: UInt64(seed))
            face.blink = { _ in 0.1 } // ignored: a photo's eyes can't change
            var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .naturalMovement)
            var passed = false
            var blinked = false
            for i in 0..<300 {
                let t = Double(i) / fps
                let snap = e.observe(face.frame(time: t, pose: pose(t)))
                if snap.shouldUnlock { passed = true }
                if snap.blinked { blinked = true }
            }
            #expect(!passed, "seed \(seed)")
            #expect(!blinked, "seed \(seed)")
        }
    }

    @Test func clippedButMatchingFaceUnlocksAsFastAsUnclipped() throws {
        // 16:08 on the real lock screen: the owner sat close, the face box ran
        // past the top edge and every frame was classed unusable ("cut off")
        // although it matched. Matching frames must count regardless.
        func firstUnlock(usable: Bool) -> Double? {
            var face = SyntheticFace(flat: false, seed: 2)
            var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .naturalMovement)
            for i in 0..<150 {
                let t = Double(i) / fps
                var f = face.frame(time: t, pose: normalHead(t), score: 0.85)
                f.usable = usable
                f.unusableReason = usable ? nil : "cut off"
                if e.observe(f).shouldUnlock { return t }
            }
            return nil
        }
        let clipped = try #require(firstUnlock(usable: false))
        let unclipped = try #require(firstUnlock(usable: true))
        #expect(clipped == unclipped)
    }

    @Test func unusableNonMatchingFramesAreAGap() {
        var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .naturalMovement)
        var face = SyntheticFace(flat: false)
        for i in 0..<10 { e.observe(face.frame(time: Double(i) / fps, pose: normalHead(Double(i) / fps))) }
        let run = e.snapshot.consecutiveMatches
        var f = face.frame(time: 0.4, pose: normalHead(0.4), score: 0.2)
        f.usable = false
        let s = e.observe(f)
        #expect(!s.frameMatched && s.resetReason == nil)
        #expect(s.consecutiveMatches == run)
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
        // Needs 5 attentive frames at the end, not just 3 matches (the first
        // frame can't be judged yet: no open-eye level calibrated).
        #expect(at == 5)
    }

    // MARK: Attention (the 16:17 lock-screen incident)

    @Test func ownerTurnedAwayNeverUnlocksEvenAboveThreshold() {
        // The owner's face, turned 20–40° (score above the threshold), moving.
        for seed in 1...5 {
            var face = SyntheticFace(flat: false, seed: UInt64(seed))
            let r = run(&face, seconds: 10, pose: { t in
                SyntheticFace.Pose(yaw: 30 + 10 * sin(2 * .pi * 0.5 * t), pitch: 3 * sin(t))
            })
            #expect(r.unlockAt == nil, "seed \(seed)")
            #expect(r.last?.attentionProblem == "not facing the screen")
        }
    }

    @Test func closedEyesNeverUnlock() {
        for seed in 1...3 {
            var face = SyntheticFace(flat: false, seed: UInt64(seed))
            face.blink = { _ in 0.15 } // eyes (nearly) shut the whole time
            #expect(run(&face, seconds: 10, pose: normalHead).unlockAt == nil, "seed \(seed)")
        }
    }

    @Test func turningAwayAfterLivenessDoesNotUnlock() {
        // Frontal briefly (too short to finish), then the head turns away to
        // 30°: the turn produces plenty of parallax, but the final state is
        // turned, so it must not unlock while turned away.
        var face = SyntheticFace(flat: false, seed: 7)
        var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .naturalMovement)
        var unlockedYaw: Double?
        for i in 0..<240 where unlockedYaw == nil {
            let t = Double(i) / fps
            let yaw = t < 0.2 ? 0 : min(30, (t - 0.2) * 40)
            let snap = e.observe(face.frame(time: t, pose: SyntheticFace.Pose(yaw: yaw, pitch: 1)))
            if snap.shouldUnlock { unlockedYaw = yaw }
        }
        #expect(unlockedYaw == nil || unlockedYaw! <= 12, "unlocked at yaw \(unlockedYaw ?? -1)")
    }

    @Test func borderlineScoresNeverUnlock() {
        var face = SyntheticFace(flat: false, seed: 3)
        var e = UnlockEvaluator(policy: MatchPolicy(threshold: 0.55), liveness: .naturalMovement)
        for i in 0..<150 {
            let t = Double(i) / fps
            #expect(!e.observe(face.frame(time: t, pose: normalHead(t), score: 0.58)).shouldUnlock)
        }
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
        // No face for longer than the 0.7 s gap allowance resets the evidence.
        for k in 0..<12 {
            let t = 0.4 + Double(k) / 15
            let none = FrameObservation(time: t, faceCount: 0, score: nil, eyes: nil, yawDegrees: nil, pitchDegrees: nil)
            _ = summarizer.observe(e.observe(none), eyeOpenness: nil, at: t)
        }
        let line = summarizer.flush(at: 1.2)
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
