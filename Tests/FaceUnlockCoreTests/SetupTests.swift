import Foundation
import Testing
@testable import FaceUnlockCore

@Suite struct SetupProgressTests {
    private func progress(doneThrough last: SetupStep?, extra: [SetupStep: StepCondition] = [:]) -> SetupProgress {
        var c: [SetupStep: StepCondition] = [:]
        for step in SetupStep.allCases { c[step] = (last.map { step <= $0 } ?? false) ? .done : .notDone }
        for (k, v) in extra { c[k] = v }
        return SetupProgress(conditions: c)
    }

    @Test func onlyFirstStepEnabledInitially() {
        let p = SetupProgress(conditions: [:])
        #expect(p.state(of: .camera).isEnabled)
        for step in SetupStep.allCases.dropFirst() {
            #expect(!p.state(of: step).isEnabled)
        }
        #expect(p.currentStep == .camera)
        #expect(!p.requiredComplete)
    }

    @Test func stepUnlocksWhenAllEarlierStepsDone() {
        let p = progress(doneThrough: .password)
        #expect(p.state(of: .enrol).isEnabled)
        #expect(!p.state(of: .test).isEnabled)
        #expect(p.currentStep == .enrol)
    }

    @Test func problemEarlierBlocksLaterSteps() {
        let p = progress(doneThrough: .turnOn, extra: [.camera: .problem])
        #expect(p.state(of: .camera).condition == .problem)
        #expect(p.state(of: .camera).isEnabled)
        #expect(!p.state(of: .accessibility).isEnabled)
        // Later steps still show as satisfied, just not usable.
        #expect(p.state(of: .turnOn).isSatisfied)
        #expect(!p.requiredComplete)
    }

    @Test func requiredVersusAllComplete() {
        let ready = progress(doneThrough: .turnOn)
        #expect(ready.requiredComplete)
        #expect(!ready.allComplete)
        #expect(ready.currentStep == .lockTest)
        #expect(ready.state(of: .lockTest).isEnabled)

        let failedLockTest = progress(doneThrough: .turnOn, extra: [.lockTest: .problem])
        #expect(failedLockTest.requiredComplete)
        #expect(!failedLockTest.allComplete)

        let all = progress(doneThrough: .lockTest)
        #expect(all.allComplete)
        #expect(all.currentStep == nil)
    }

    @Test func lockTestIsTheOnlyOptionalStep() {
        #expect(SetupStep.allCases.filter { !$0.isRequired } == [.lockTest])
    }
}

@Suite struct AttemptRecordTests {
    private func snapshot(faces: Int = 1, score: Float? = 0.8, matched: Bool = true,
                          blinked: Bool = false, pose: Bool = false) -> UnlockEvaluator.Snapshot {
        UnlockEvaluator.Snapshot(
            faceCount: faces, score: score.map { MatchScore(centroid: $0, bestSample: $0) },
            frameMatched: matched, consecutiveMatches: matched ? 1 : 0, requiredConsecutive: 3,
            blinkState: blinked ? .blinked : .open, blinked: blinked, matchesSinceBlink: 0,
            yawRange: 0, pitchRange: 0, poseVaried: pose, sawFace: faces > 0,
            sawMultipleFaces: faces > 1, shouldUnlock: false)
    }

    @Test func noFace() {
        var d = AttemptDiagnostics()
        d.observe(snapshot(faces: 0, score: nil, matched: false))
        #expect(d.failureOutcome == .noFace)
    }

    @Test func noMatchReportsBestScore() {
        var d = AttemptDiagnostics()
        d.observe(snapshot(score: 0.31, matched: false))
        d.observe(snapshot(score: 0.42, matched: false))
        d.observe(snapshot(score: 0.12, matched: false))
        #expect(d.failureOutcome == .noMatch(bestScore: 0.42))
    }

    @Test func onlyMultipleFaces() {
        var d = AttemptDiagnostics()
        d.observe(snapshot(faces: 2, score: nil, matched: false))
        #expect(d.failureOutcome == .multipleFaces)
    }

    @Test func noBlinkThenNoHeadMovementThenNotSteady() {
        var d = AttemptDiagnostics()
        d.observe(snapshot())
        #expect(d.failureOutcome == .noBlink)
        d.observe(snapshot(blinked: true))
        #expect(d.failureOutcome == .noHeadMovement)
        d.observe(snapshot(pose: true))
        #expect(d.failureOutcome == .notSteady)
    }

    @Test func recordRoundTripsThroughJSON() throws {
        let outcomes: [AttemptOutcome] = [
            .unlocked, .noFace, .noMatch(bestScore: 0.4), .noBlink, .noHeadMovement, .notSteady,
            .multipleFaces, .frontWindowRefused(owner: "SomeApp"), .passwordRejected, .lockedOut,
            .keychainError("Keychain error -25308"), .typingStopped("cancelled"),
            .cameraError("busy"), .notReady("no password stored"),
        ]
        for outcome in outcomes {
            let record = AttemptRecord(time: Date(timeIntervalSince1970: 1_000), outcome: outcome)
            let decoded = try JSONDecoder().decode(AttemptRecord.self, from: JSONEncoder().encode(record))
            #expect(decoded == record)
            #expect(!outcome.summary.isEmpty)
            #expect(outcome.advice.isEmpty == outcome.isSuccess)
        }
    }

    @Test func summariesAreSpecific() {
        #expect(AttemptOutcome.noMatch(bestScore: 0.4123).summary.contains("0.41"))
        #expect(AttemptOutcome.frontWindowRefused(owner: "Overlay").summary.contains("Overlay"))
    }
}
