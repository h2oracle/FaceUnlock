import CoreGraphics
import Foundation
import Testing
@testable import FaceUnlockCore

@Suite struct VectorMathTests {
    @Test func cosineBasics() {
        #expect(abs(VectorMath.cosine([1, 2, 3], [1, 2, 3]) - 1) < 1e-6)
        #expect(abs(VectorMath.cosine([1, 2, 3], [2, 4, 6]) - 1) < 1e-6)
        #expect(abs(VectorMath.cosine([1, 0], [0, 1])) < 1e-6)
        #expect(abs(VectorMath.cosine([1, 0], [-1, 0]) + 1) < 1e-6)
    }

    @Test func cosineDegenerateInputsNeverMatch() {
        #expect(VectorMath.cosine([], []) == 0)
        #expect(VectorMath.cosine([1, 2], [1, 2, 3]) == 0)
        #expect(VectorMath.cosine([0, 0], [1, 1]) == 0)
    }

    @Test func normalisation() {
        let n = VectorMath.l2Normalized([3, 4])
        #expect(abs(n[0] - 0.6) < 1e-6 && abs(n[1] - 0.8) < 1e-6)
        #expect(VectorMath.l2Normalized([0, 0]) == [0, 0])
        let mean = VectorMath.normalizedMean([[1, 0], [0, 1]])!
        #expect(abs(mean[0] - mean[1]) < 1e-6)
        #expect(abs(mean[0] * mean[0] + mean[1] * mean[1] - 1) < 1e-5)
        #expect(VectorMath.normalizedMean([]) == nil)
        #expect(VectorMath.normalizedMean([[1, 0], [1, 0, 0]]) == nil)
    }
}

@Suite struct MatchPolicyTests {
    @Test func thresholdIsInclusiveAndRequiresBothScores() {
        let p = MatchPolicy(threshold: 0.6)
        #expect(p.isMatch(MatchScore(centroid: 0.6, bestSample: 0.6)))
        #expect(p.isMatch(MatchScore(centroid: 0.8, bestSample: 0.7)))
        #expect(!p.isMatch(MatchScore(centroid: 0.59, bestSample: 0.9)))
        #expect(!p.isMatch(MatchScore(centroid: 0.9, bestSample: 0.59)))
    }

    @Test func thresholdIsClamped() {
        #expect(MatchPolicy(threshold: 0.0).threshold == MatchPolicy.thresholdRange.lowerBound)
        #expect(MatchPolicy(threshold: 2.0).threshold == MatchPolicy.thresholdRange.upperBound)
        #expect(MatchPolicy().threshold == MatchPolicy.defaultThreshold)
        #expect(MatchPolicy(requiredConsecutive: 0).requiredConsecutive == 1)
    }

    @Test func consecutiveCounterResetsOnMiss() {
        var c = ConsecutiveMatchCounter(required: 3)
        c.record(matched: true); c.record(matched: true)
        #expect(!c.isSatisfied)
        c.record(matched: false)
        #expect(c.run == 0)
        c.record(matched: true); c.record(matched: true); c.record(matched: true)
        #expect(c.isSatisfied)
    }

    @Test func templateScoringAndOutliers() throws {
        let owner: [[Float]] = [[1, 0.1, 0], [1, 0, 0.1], [1, 0.05, 0.05], [0, 1, 0]]
        let template = try FaceTemplate(modelID: "m", samples: owner)
        let score = MatchScore.score([1, 0, 0], against: template)
        #expect(score.bestSample > 0.99)
        #expect(score.centroid > 0.8)

        let cleaned = try template.removingOutliers(minimumSimilarity: 0.6, minimumKept: 3)
        #expect(cleaned.samples.count == 3)
        #expect(cleaned.consistency > template.consistency)
        #expect(throws: FaceTemplateError.self) {
            try template.removingOutliers(minimumSimilarity: 0.6, minimumKept: 4)
        }
        #expect(throws: FaceTemplateError.noSamples) { try FaceTemplate(modelID: "m", samples: []) }
    }
}

@Suite struct AttemptLockoutTests {
    @Test func threeFailedLooksPauseUntilRearmed() {
        var l = AttemptLockout()
        #expect(l.canScan)
        l.recordFailure(); l.recordFailure()
        #expect(l.canScan)
        #expect(l.remainingBeforePause == 1)
        l.recordFailure()
        #expect(l.needsRearm)
        #expect(!l.canScan)
        #expect(!l.isLockedOut) // only paused, not locked out for the session
        l.rearm()
        #expect(l.canScan)
        #expect(l.totalFailures == 3)
    }

    @Test func hardCapOfFiveFailuresPerLockSession() {
        var l = AttemptLockout()
        for _ in 0..<3 { l.recordFailure() }
        l.rearm()
        l.recordFailure(); l.recordFailure()
        #expect(l.isLockedOut)
        #expect(!l.canScan)
        l.rearm() // a wake doesn't lift the hard cap
        #expect(!l.canScan)
        l.startNewLockSession()
        #expect(l.canScan)
        #expect(l.totalFailures == 0)
    }

    @Test func faceTimeCapStopsTheLockSession() {
        var l = AttemptLockout()
        for _ in 0..<1199 { l.recordFaceTime(0.1) }
        #expect(!l.isLockedOut)
        l.recordFaceTime(0.2)
        #expect(l.faceTimeExhausted)
        #expect(l.isLockedOut)
        l.rearm()
        #expect(!l.canScan)
        l.startNewLockSession()
        #expect(l.canScan)
        #expect(l.faceSeconds == 0)
    }

    @Test func rejectedPasswordLocksOutImmediately() {
        var l = AttemptLockout()
        l.recordPasswordRejected()
        #expect(l.isLockedOut)
        #expect(!l.canScan)
        l.rearm()
        #expect(!l.canScan)
        l.startNewLockSession()
        #expect(l.canScan)
    }
}

@Suite struct GeometryTests {
    @Test func similarityTransformRecoversKnownTransform() throws {
        let truth = CGAffineTransform(rotationAngle: 0.3).scaledBy(x: 1.7, y: 1.7).translatedBy(x: 12, y: -5)
        let src = [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 22), CGPoint(x: 30, y: 40), CGPoint(x: 15, y: 60), CGPoint(x: 45, y: 61)]
        let dst = src.map { $0.applying(truth) }
        let t = try #require(LandmarkGeometry.similarityTransform(from: src, to: dst))
        for (s, d) in zip(src, dst) {
            let p = s.applying(t)
            #expect(abs(p.x - d.x) < 1e-6 && abs(p.y - d.y) < 1e-6)
        }
        #expect(LandmarkGeometry.similarityTransform(from: [.zero, .zero], to: [.zero, CGPoint(x: 1, y: 1)]) == nil)
    }

    @Test func eyeOpennessShrinksWhenClosed() throws {
        func eye(height: CGFloat) -> [CGPoint] {
            [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: height), CGPoint(x: 20, y: height),
             CGPoint(x: 30, y: 0), CGPoint(x: 20, y: -height), CGPoint(x: 10, y: -height)]
        }
        let open = try #require(LandmarkGeometry.eyeOpenness(eye(height: 5)))
        let closed = try #require(LandmarkGeometry.eyeOpenness(eye(height: 0.5)))
        #expect(closed < open * 0.2)
        // Scale invariant.
        let bigger = try #require(LandmarkGeometry.eyeOpenness(eye(height: 5).map { CGPoint(x: $0.x * 3, y: $0.y * 3) }))
        #expect(abs(bigger - open) < 1e-9)
    }
}

@Suite struct IntegrityRecordTests {
    @Test func matchesOnlyWhenDigestThresholdAndLivenessAgree() {
        let r = IntegrityRecord(templateSHA256: "abc", threshold: 0.55, livenessMode: .naturalMovement)
        #expect(r.problem(templateSHA256: "abc", threshold: 0.55, livenessMode: .naturalMovement) == nil)
        #expect(r.problem(templateSHA256: "abd", threshold: 0.55, livenessMode: .naturalMovement) == .templateChanged)
        #expect(r.problem(templateSHA256: nil, threshold: 0.55, livenessMode: .naturalMovement) == .templateChanged)
        #expect(r.problem(templateSHA256: "abc", threshold: 0.45, livenessMode: .naturalMovement) == .thresholdChanged)
        #expect(r.problem(templateSHA256: "abc", threshold: 0.55, livenessMode: .off) == .livenessChanged)
        #expect(IntegrityRecord(templateSHA256: nil, threshold: 0.55, livenessMode: .off)
            .problem(templateSHA256: "abc", threshold: 0.55, livenessMode: .off) == .templateChanged)
    }

    @Test func recordsWithoutLivenessMeanBlinkAndMovement() throws {
        let legacy = Data(#"{"templateSHA256":"abc","threshold":0.55}"#.utf8)
        let r = try JSONDecoder().decode(IntegrityRecord.self, from: legacy)
        #expect(r.livenessMode == nil)
        #expect(r.effectiveLivenessMode == .blinkAndMovement)
        #expect(r.problem(templateSHA256: "abc", threshold: 0.55, livenessMode: .blinkAndMovement) == nil)
        #expect(r.problem(templateSHA256: "abc", threshold: 0.55, livenessMode: .naturalMovement) == .livenessChanged)
    }
}
