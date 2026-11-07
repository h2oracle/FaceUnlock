import Foundation
import Testing
@testable import FaceUnlockCore

/// Builds a 15 fps eye-openness sequence from (openness, frames) segments.
private func sequence(_ segments: [(Double, Int)], shape: (Int) -> Double = { _ in 1.2 },
                      pitch: (Int) -> Double? = { _ in 0 }) -> [EyeSample] {
    var out: [EyeSample] = []
    var i = 0
    for (value, count) in segments {
        for _ in 0..<count {
            let jitter = (i % 2 == 0 ? 1.0 : -1.0) * 0.002
            out.append(EyeSample(time: Double(i) / 15, left: value + jitter, right: value - jitter,
                                 faceShape: shape(i), pitch: pitch(i)))
            i += 1
        }
    }
    return out
}

private func run(_ samples: [EyeSample]) -> BlinkDetector {
    var d = BlinkDetector()
    for s in samples { d.observe(s) }
    return d
}

@Suite struct BlinkDetectorTests {
    @Test func naturalBlinkIsDetected() {
        let d = run(sequence([(0.10, 8), (0.02, 3), (0.10, 3)]))
        #expect(d.hasBlinked)
    }

    @Test func staticPhotoNeverBlinks() {
        #expect(!run(sequence([(0.10, 150)])).hasBlinked)
    }

    @Test func smallNoiseIsNotABlink() {
        // Dips to 75% of baseline: below "open" but above "closed".
        #expect(!run(sequence([(0.10, 8), (0.075, 3), (0.10, 5)])).hasBlinked)
    }

    @Test func closingWithoutReopeningIsNotABlink() {
        #expect(!run(sequence([(0.10, 8), (0.02, 20)])).hasBlinked)
    }

    @Test func longClosureIsRejected() {
        // ~1.3 s closed: not a natural blink.
        #expect(!run(sequence([(0.10, 8), (0.02, 20), (0.10, 5)])).hasBlinked)
    }

    @Test func blinkAfterRejectedClosureStillCounts() {
        let d = run(sequence([(0.10, 8), (0.02, 20), (0.10, 5), (0.02, 3), (0.10, 3)]))
        #expect(d.hasBlinked)
    }

    @Test func singleEyeWinkIsNotABlink() {
        var d = BlinkDetector()
        var t = 0.0
        for i in 0..<20 {
            let closedLeft = (8..<11).contains(i)
            d.observe(EyeSample(time: t, left: closedLeft ? 0.02 : 0.10, right: 0.10, faceShape: 1.2, pitch: 0))
            t += 1 / 15
        }
        #expect(!d.hasBlinked)
    }

    @Test func tiltedPhotoFakeBlinkIsRejected() {
        // Tilting a flat photo squashes the eyes *and* the whole face.
        let squashed = Set(8..<11)
        let samples = sequence([(0.10, 8), (0.03, 3), (0.10, 4)],
                               shape: { squashed.contains($0) ? 0.6 : 1.2 },
                               pitch: { _ in 0 })
        #expect(!run(samples).hasBlinked)
    }

    @Test func pitchSwingDuringClosureIsRejected() {
        let swung = Set(8..<11)
        let samples = sequence([(0.10, 8), (0.02, 3), (0.10, 4)], pitch: { swung.contains($0) ? 15 : 0 })
        #expect(!run(samples).hasBlinked)
    }

    @Test func resetClearsLatch() {
        var d = run(sequence([(0.10, 8), (0.02, 3), (0.10, 3)]))
        #expect(d.hasBlinked)
        d.reset()
        #expect(!d.hasBlinked)
        #expect(d.state == .calibrating)
    }

    @Test func garbageSamplesAreIgnored() {
        var d = BlinkDetector()
        d.observe(EyeSample(time: 0, left: .nan, right: 0.1, faceShape: 1.2))
        d.observe(EyeSample(time: 0, left: 0.1, right: 0.1, faceShape: 0))
        #expect(d.state == .calibrating)
    }
}

@Suite struct PoseVariationTests {
    private func check(_ poses: [(Double, Double)]) -> PoseVariationCheck {
        var c = PoseVariationCheck()
        for (y, p) in poses { c.observe(yawDegrees: y, pitchDegrees: p) }
        return c
    }

    @Test func staticHeadFails() {
        #expect(!check(Array(repeating: (2.0, -3.0), count: 40)).isSatisfied)
    }

    @Test func tinyJitterFails() {
        let poses = (0..<40).map { i in (Double(i % 3) * 0.5, Double(i % 2) * 0.5) }
        #expect(!check(poses).isSatisfied)
    }

    @Test func naturalMovementPasses() {
        let poses = (0..<40).map { i in (6 * sin(Double(i) / 6), 1.0) }
        let c = check(poses)
        #expect(c.isSatisfied)
        #expect(c.yawRange > 2.5)
    }

    @Test func pitchAlonePasses() {
        let poses = (0..<40).map { i in (0.0, Double(i) * 0.15) }
        #expect(check(poses).isSatisfied)
    }

    @Test func singleOutlierFrameFails() {
        var poses = Array(repeating: (0.0, 0.0), count: 40)
        poses[20] = (20, 0)
        #expect(!check(poses).isSatisfied)
    }

    @Test func implausibleSwingFails() {
        let poses = (0..<40).map { i in (i % 2 == 0 ? -40.0 : 40.0, 0.0) }
        #expect(!check(poses).isSatisfied)
    }

    @Test func tooFewSamplesFails() {
        #expect(!check([(0, 0), (5, 5), (10, 10)]).isSatisfied)
    }

    @Test func missingPoseIsIgnored() {
        var c = PoseVariationCheck()
        c.observe(yawDegrees: nil, pitchDegrees: 3)
        c.observe(yawDegrees: .nan, pitchDegrees: 3)
        #expect(c.sampleCount == 0)
    }
}

@Suite struct UnlockEvaluatorTests {
    private let policy = MatchPolicy(threshold: 0.55, requiredConsecutive: 3)

    private func frame(_ i: Int, faces: Int = 1, score: Float = 0.8, eye: Double = 0.10,
                       yaw: Double? = nil, shape: Double = 1.2) -> FrameObservation {
        let t = Double(i) / 15
        return FrameObservation(
            time: t, faceCount: faces,
            score: faces == 1 ? MatchScore(centroid: score, bestSample: score) : nil,
            eyes: EyeSample(time: t, left: eye, right: eye, faceShape: shape, pitch: 0),
            yawDegrees: yaw ?? 5 * sin(Double(i) / 5), pitchDegrees: 0)
    }

    /// 8 open, 3 closed, then open: a live owner.
    private func eye(_ i: Int) -> Double { (8..<11).contains(i) ? 0.02 : 0.10 }

    @Test func liveOwnerUnlocks() {
        var e = UnlockEvaluator(policy: policy)
        var unlockedAt: Int?
        for i in 0..<40 where unlockedAt == nil {
            if e.observe(frame(i, eye: eye(i))).shouldUnlock { unlockedAt = i }
        }
        #expect(unlockedAt != nil)
        // Blink completes at frame 11; three matched frames after it are needed.
        #expect(unlockedAt! >= 13)
    }

    @Test func nonMatchingFrameResetsAllEvidence() {
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<12 { e.observe(frame(i, eye: eye(i))) }
        #expect(e.snapshot.blinked)
        let s = e.observe(frame(12, score: 0.5))
        #expect(!s.blinked)
        #expect(s.consecutiveMatches == 0)
        #expect(s.yawRange == 0)
        #expect(!s.shouldUnlock)
    }

    @Test func failedEmbeddingResetsAllEvidence() {
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<12 { e.observe(frame(i, eye: eye(i))) }
        let noEmbedding = FrameObservation(time: 1, faceCount: 1, score: nil, eyes: nil, yawDegrees: 0, pitchDegrees: 0)
        #expect(!e.observe(noEmbedding).blinked)
    }

    @Test func blinkDuringNonMatchingFramesDoesNotCount() {
        // Owner's face matches with open eyes, but the closed-eye frames
        // don't match (e.g. someone else's eyes): never unlocks.
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<60 {
            let closed = (8..<11).contains(i)
            #expect(!e.observe(frame(i, score: closed ? 0.3 : 0.8, eye: eye(i))).shouldUnlock)
        }
    }

    @Test func needsMatchedFramesAfterTheBlink() {
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<12 { e.observe(frame(i, eye: eye(i))) }   // blink completes at 11
        #expect(e.snapshot.matchesSinceBlink == 1)
        #expect(!e.observe(frame(12)).shouldUnlock)              // 2 after blink
        #expect(e.observe(frame(13)).shouldUnlock)               // 3 after blink
    }

    @Test func photoOfOwnerNeverUnlocks() {
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<150 {
            #expect(!e.observe(frame(i, yaw: 1.0)).shouldUnlock)
        }
    }

    @Test func blinkWithoutMovementDoesNotUnlock() {
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<60 {
            #expect(!e.observe(frame(i, eye: eye(i), yaw: 0)).shouldUnlock)
        }
    }

    @Test func strangerNeverUnlocks() {
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<60 {
            #expect(!e.observe(frame(i, score: 0.5, eye: eye(i))).shouldUnlock)
        }
    }

    @Test func secondFaceBlocksAndResets() {
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<20 {
            let f = i == 15 ? frame(i, faces: 2) : frame(i, eye: eye(i))
            let s = e.observe(f)
            if i >= 15 { #expect(!s.shouldUnlock) }
        }
        #expect(e.sawMultipleFaces)
        // Liveness evidence was wiped by the second face: needs a fresh blink.
        #expect(!e.snapshot.blinked)
    }

    @Test func swappingInOwnerPhotoAfterStrangerBlinksFails() {
        var e = UnlockEvaluator(policy: policy)
        // A stranger (score 0.1) blinks and moves...
        for i in 0..<20 { e.observe(frame(i, score: 0.1, eye: eye(i))) }
        // ...then a static photo of the owner is held up.
        for i in 20..<120 {
            #expect(!e.observe(frame(i, eye: 0.10, yaw: 1)).shouldUnlock)
        }
    }

    @Test func faceLeavingFrameResetsEvidence() {
        var e = UnlockEvaluator(policy: policy)
        for i in 0..<15 { e.observe(frame(i, eye: eye(i))) }
        #expect(e.snapshot.blinked)
        e.observe(frame(15, faces: 0))
        #expect(!e.snapshot.blinked)
        #expect(e.snapshot.consecutiveMatches == 0)
    }
}
