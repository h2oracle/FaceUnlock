import Foundation
import Testing
@testable import FaceUnlockCore

/// 15 fps frame generator for the natural-movement mode.
private func frame(_ i: Int, score: Float = 0.8, faces: Int = 1,
                   yaw: (Double) -> Double, pitch: (Double) -> Double, eye: (Int) -> Double) -> FrameObservation {
    let t = Double(i) / 15
    let e = eye(i)
    return FrameObservation(
        time: t, faceCount: faces,
        score: faces == 1 ? MatchScore(centroid: score, bestSample: score) : nil,
        eyes: EyeSample(time: t, left: e, right: e, faceShape: 1.2, pitch: pitch(t)),
        yawDegrees: yaw(t), pitchDegrees: pitch(t))
}

/// A person sitting normally: slow sway of ~±1° and small eye-region changes.
private func live(_ i: Int) -> FrameObservation {
    frame(i, yaw: { 1.0 * sin($0 * 2.1) }, pitch: { 0.6 * sin($0 * 1.3) },
          eye: { 0.10 * (1 + 0.04 * sin(Double($0) * 1.7) + 0.02 * cos(Double($0) * 4.3)) })
}

/// A printed photo held still: only tiny estimation noise.
private func stillPhoto(_ i: Int) -> FrameObservation {
    frame(i, yaw: { t in 0.1 * (Double(Int(t * 15) % 2) - 0.5) }, pitch: { _ in 0 },
          eye: { 0.10 * (1 + 0.003 * (Double($0 % 2) - 0.5)) })
}

/// A photo moved around in a hand: rigid pose changes, eyes unchanged.
private func movingPhoto(_ i: Int) -> FrameObservation {
    frame(i, yaw: { 4 * sin($0 * 2) }, pitch: { 2 * sin($0 * 1.5) },
          eye: { 0.10 * (1 + 0.003 * (Double($0 % 2) - 0.5)) })
}

@Suite struct NaturalMovementTests {
    private let policy = MatchPolicy(threshold: 0.55, requiredConsecutive: 3)

    private func firstUnlock(_ make: (Int) -> FrameObservation, mode: LivenessMode, frames: Int = 150) -> Int? {
        var e = UnlockEvaluator(policy: policy, liveness: mode)
        for i in 0..<frames where e.observe(make(i)).shouldUnlock { return i }
        return nil
    }

    @Test func personSittingNormallyPassesWithinAboutOneSecond() throws {
        let i = try #require(firstUnlock(live, mode: .naturalMovement))
        let seconds = Double(i) / 15
        #expect(seconds >= 0.5)
        #expect(seconds <= 1.2)
    }

    @Test func stillPhotoFailsEvenOverLongWindows() {
        // 10 s of a still photo, at both 15 and 30 fps.
        #expect(firstUnlock(stillPhoto, mode: .naturalMovement, frames: 150) == nil)
        var e = UnlockEvaluator(policy: policy, liveness: .naturalMovement)
        for i in 0..<300 {
            let t = Double(i) / 30
            let f = FrameObservation(time: t, faceCount: 1, score: MatchScore(centroid: 0.9, bestSample: 0.9),
                                     eyes: EyeSample(time: t, left: 0.1 + (i % 2 == 0 ? 0.0002 : -0.0002),
                                                     right: 0.1, faceShape: 1.2, pitch: 0),
                                     yawDegrees: i % 2 == 0 ? 0.05 : -0.05, pitchDegrees: 0)
            #expect(!e.observe(f).shouldUnlock)
        }
    }

    @Test func passIsTiedToDurationNotFrameCount() {
        // At 30 fps, 0.3 s of perfect movement is 9+ frames but still too short.
        var e = UnlockEvaluator(policy: policy, liveness: .naturalMovement)
        var unlockedAt: Double?
        for i in 0..<60 where unlockedAt == nil {
            let t = Double(i) / 30
            let eye = 0.10 * (1 + (i % 2 == 0 ? 0.04 : -0.04))
            let f = FrameObservation(time: t, faceCount: 1, score: MatchScore(centroid: 0.9, bestSample: 0.9),
                                     eyes: EyeSample(time: t, left: eye, right: eye, faceShape: 1.2, pitch: 0),
                                     yawDegrees: 2 * sin(t * 6), pitchDegrees: 0)
            if e.observe(f).shouldUnlock { unlockedAt = t }
        }
        #expect((unlockedAt ?? 0) >= 0.5)
    }

    @Test func stillPhotoFails() {
        #expect(firstUnlock(stillPhoto, mode: .naturalMovement) == nil)
    }

    @Test func rigidlyMovedPhotoFails() {
        #expect(firstUnlock(movingPhoto, mode: .naturalMovement) == nil)
    }

    @Test func noBlinkNeededInNaturalMode() {
        var e = UnlockEvaluator(policy: policy, liveness: .naturalMovement)
        var last: UnlockEvaluator.Snapshot?
        for i in 0..<40 { last = e.observe(live(i)) }
        #expect(last?.blinked == false)
        #expect(last?.livenessSatisfied == true)
    }

    @Test func blinkModeStillNeedsABlink() {
        #expect(firstUnlock(live, mode: .blinkAndMovement) == nil)
    }

    @Test func offModeNeedsOnlyConsecutiveMatches() {
        #expect(firstUnlock(stillPhoto, mode: .off) == 2)
    }

    @Test func nonMatchingFrameResetsMovementEvidence() {
        var e = UnlockEvaluator(policy: policy, liveness: .naturalMovement)
        for i in 0..<14 { e.observe(live(i)) }
        #expect(e.snapshot.motionSeconds > 0.5)
        let s = e.observe(frame(14, score: 0.3, yaw: { _ in 0 }, pitch: { _ in 0 }, eye: { _ in 0.1 }))
        #expect(s.motionSeconds == 0)
        #expect(s.resetReason == .noMatch)
        // Evidence has to build up again from scratch.
        var unlockedAt: Int?
        for i in 15..<80 where unlockedAt == nil {
            if e.observe(live(i)).shouldUnlock { unlockedAt = i }
        }
        #expect((unlockedAt ?? 0) >= 15 + 7)
    }

    @Test func progressRisesTowardsOne() {
        var e = UnlockEvaluator(policy: policy, liveness: .naturalMovement)
        let early = e.observe(live(0)).progress
        var late = 0.0
        for i in 1..<40 { late = e.observe(live(i)).progress }
        #expect(early < 0.5)
        #expect(late == 1)
    }

    @Test func diagnosticsExplainMissingMovement() {
        var e = UnlockEvaluator(policy: policy, liveness: .naturalMovement)
        var d = AttemptDiagnostics()
        for i in 0..<100 { d.observe(e.observe(stillPhoto(i))) }
        #expect(d.failureOutcome == .noNaturalMovement)
    }
}

@Suite struct DiagnosticsSummarizerTests {
    @Test func emitsAboutEveryHalfSecondWithNumbersOnly() {
        var e = UnlockEvaluator(policy: MatchPolicy(), liveness: .naturalMovement)
        var summarizer = DiagnosticsSummarizer(threshold: 0.55, start: 0)
        var lines: [String] = []
        for i in 0..<30 {
            let s = e.observe(live(i))
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
        for i in 0..<5 { _ = summarizer.observe(e.observe(live(i)), eyeOpenness: nil, at: Double(i) / 15) }
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
