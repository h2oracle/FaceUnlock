import Foundation
import Testing
@testable import FaceUnlockCore

@Suite struct ScanGateTests {
    @Test func automaticStartsWithoutInput() {
        let g = ScanGate(mode: .automatic)
        #expect(g.shouldStart(on: .tick))
        #expect(g.shouldStart(on: .displayWake))
        #expect(g.shouldStart(on: .lidOpened))
        #expect(g.shouldStart(on: .userInput))
    }

    @Test func onInputNeedsInputOrLid() {
        let g = ScanGate(mode: .onInput)
        #expect(!g.shouldStart(on: .tick))
        #expect(!g.shouldStart(on: .displayWake))
        #expect(g.shouldStart(on: .userInput))
        #expect(g.shouldStart(on: .lidOpened))
    }

    @Test func facelessPauseWaitsForInputOrWake() {
        var g = ScanGate(mode: .automatic)
        g.pauseForNoFace()
        #expect(!g.shouldStart(on: .tick))
        #expect(g.shouldStart(on: .userInput))
        g.started(on: .userInput)
        #expect(g.shouldStart(on: .tick))
        g.pauseForNoFace()
        g.reset() // display wake / lid open
        #expect(g.shouldStart(on: .tick))
    }
}

@Suite struct ScanMonitorTests {
    private func events(_ frames: [(faces: Int, matched: Bool, live: Bool)], fps: Double = 30) -> [ScanMonitor.Event] {
        var m = ScanMonitor(start: 0)
        var out: [ScanMonitor.Event] = []
        for (i, f) in frames.enumerated() {
            if let e = m.observe(time: Double(i) / fps, faceCount: f.faces, matched: f.matched, live: f.live) { out.append(e) }
        }
        if let e = m.finish() { out.append(e) }
        return out
    }

    private func repeated(_ n: Int, faces: Int = 1, matched: Bool = false, live: Bool = false) -> [(faces: Int, matched: Bool, live: Bool)] {
        Array(repeating: (faces, matched, live), count: n)
    }

    @Test func sustainedNonMatchIsAFailedLook() {
        #expect(events(repeated(70)) == [.notRecognised])
    }

    @Test func noFaceNeverCounts() {
        #expect(events(repeated(600, faces: 0)).isEmpty)
    }

    @Test func handOverLensDoesNotResetTheCount() {
        // Attack: 1.9 s of a stranger's face, then one frame with the lens
        // covered, repeated for 20 s.
        var frames: [(faces: Int, matched: Bool, live: Bool)] = []
        for _ in 0..<10 { frames += repeated(57) + repeated(1, faces: 0) }
        let e = events(frames)
        #expect(e.count >= 9, "only \(e.count) failed looks: \(e)")
    }

    @Test func secondFaceDoesNotResetTheCount() {
        var frames: [(faces: Int, matched: Bool, live: Bool)] = []
        for _ in 0..<10 { frames += repeated(57) + repeated(1, faces: 2) }
        #expect(events(frames).count >= 9)
    }

    @Test func shortBurstsOfAFaceEachCount() {
        // 0.3 s bursts of an unrecognised face separated by covered frames.
        var frames: [(faces: Int, matched: Bool, live: Bool)] = []
        for _ in 0..<5 { frames += repeated(9) + repeated(5, faces: 0) }
        #expect(events(frames).count == 5)
    }

    @Test func veryShortFlickersDontCount() {
        // A detector glitch of a couple of frames isn't a "look".
        var frames: [(faces: Int, matched: Bool, live: Bool)] = []
        for _ in 0..<5 { frames += repeated(2) + repeated(10, faces: 0) }
        #expect(events(frames).isEmpty)
    }

    @Test func ownerWithOccasionalMissesIsFine() {
        // Mostly matching (and live) with a non-matching frame now and then.
        var frames: [(faces: Int, matched: Bool, live: Bool)] = []
        for i in 0..<300 { frames.append((1, i % 10 != 0, true)) }
        #expect(events(frames).isEmpty)
    }

    @Test func appearanceThatMatchesDoesNotCount() {
        let frames = repeated(10) + repeated(5, matched: true, live: true) + repeated(5, faces: 0)
        #expect(events(frames).isEmpty)
    }

    @Test func matchedButNeverLiveIsAFailedLook() {
        // A photo of the owner: matches every frame, never passes liveness.
        let e = events(repeated(200, matched: true, live: false))
        #expect(e == [.notLive, .notLive])
    }

    @Test func matchedButNotLiveAccumulatesAcrossCoveredFrames() {
        var frames: [(faces: Int, matched: Bool, live: Bool)] = []
        for _ in 0..<5 { frames += repeated(25, matched: true) + repeated(1, faces: 0) }
        #expect(events(frames).contains(.notLive))
    }

    @Test func hudFadesWithoutFaceAndReturns() {
        var m = ScanMonitor(start: 0)
        #expect(m.hudVisible(at: 1))
        #expect(!m.hudVisible(at: 3.5))
        m.observe(time: 4, faceCount: 1, matched: true)
        #expect(m.hudVisible(at: 4.1))
        #expect(!m.hudVisible(at: 7.5))
    }

    @Test func pausesAfterSixtySecondsWithoutFace() {
        var m = ScanMonitor(start: 0)
        #expect(!m.shouldPauseForNoFace(at: 59))
        #expect(m.shouldPauseForNoFace(at: 60))
        m.observe(time: 59, faceCount: 1, matched: false)
        #expect(!m.shouldPauseForNoFace(at: 100))
        #expect(m.shouldPauseForNoFace(at: 119))
    }
}
