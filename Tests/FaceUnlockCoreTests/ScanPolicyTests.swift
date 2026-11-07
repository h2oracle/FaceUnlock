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
    @Test func sustainedNonMatchIsAFailedLook() {
        var m = ScanMonitor(start: 0)
        var events: [ScanMonitor.Event] = []
        for i in 0..<70 { // a bit over 2 s at 30 fps
            if let e = m.observe(time: Double(i) / 30, faceCount: 1, matched: false) { events.append(e) }
        }
        #expect(events == [.failedLook])
    }

    @Test func noFaceNeverCounts() {
        var m = ScanMonitor(start: 0)
        for i in 0..<600 {
            #expect(m.observe(time: Double(i) / 30, faceCount: 0, matched: false) == nil)
        }
    }

    @Test func matchOrSecondFaceInterruptsTheLook() {
        var m = ScanMonitor(start: 0)
        var fired = false
        for i in 0..<120 {
            let t = Double(i) / 30
            // Every second, one matching frame (e.g. owner turning back).
            let matched = i % 30 == 29
            let faces = i == 45 ? 2 : 1
            if m.observe(time: t, faceCount: faces, matched: matched) != nil { fired = true }
        }
        #expect(!fired)
    }

    @Test func secondFailedLookNeedsAnotherFullPeriod() {
        var m = ScanMonitor(start: 0)
        var times: [Double] = []
        for i in 0..<200 {
            let t = Double(i) / 30
            if m.observe(time: t, faceCount: 1, matched: false) != nil { times.append(t) }
        }
        #expect(times.count == 3)
        if times.count >= 2 { #expect(times[1] - times[0] >= 2) }
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
