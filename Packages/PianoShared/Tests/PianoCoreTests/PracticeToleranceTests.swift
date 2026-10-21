import XCTest
@testable import PianoCore

final class PracticeToleranceTests: XCTestCase {
    private func note(_ id: Int, _ pitch: Int, _ start: Double) -> PianoNote {
        PianoNote(id: id, pitch: pitch, start: start, duration: 1)
    }

    func testChordWindowSupportsFiftyMillisecondsThroughTwoSeconds() {
        var sut = WaitModeEngine(notes: [], chordWindow: -1, now: 0)
        XCTAssertEqual(sut.chordWindow, 0.05)
        sut.setChordWindow(20, at: 0)
        XCTAssertEqual(sut.chordWindow, 2)
        sut.setChordWindow(.nan, at: 0)
        XCTAssertEqual(sut.chordWindow, 0.15)
    }

    func testStrictChordAcceptsOneAndAHalfSecondHandSeparation() {
        var sut = WaitModeEngine(notes: [note(1, 48, 0), note(2, 64, 0)], chordWindow: 2, now: 0)
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 48, timestamp: 1, receivedAt: 1, pressedPitches: [48])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 2.5, receivedAt: 2.5, pressedPitches: [48, 64]).disposition, .completed)
        XCTAssertEqual(sut.completedNoteIDs, [1, 2])
    }

    func testStrictFiftyMillisecondChordBoundaryIsInclusive() {
        for separation in [0.05, 0.0501] {
            var sut = WaitModeEngine(notes: [note(1, 48, 0), note(2, 64, 0)], chordWindow: 0.05, now: 0)
            sut.play(at: 0)
            _ = sut.noteOn(pitch: 48, timestamp: 1, receivedAt: 1, pressedPitches: [48])
            let result = sut.noteOn(pitch: 64, timestamp: 1 + separation, receivedAt: 1 + separation, pressedPitches: [48, 64])
            XCTAssertEqual(result.disposition, separation == 0.05 ? .completed : .accepted)
            XCTAssertEqual(sut.completedGroupCount, separation == 0.05 ? 1 : 0)
        }
    }

    func testEarlyWindowBoundsKeepPolicyDefaultsAndRemainIndependentOfChordWindow() {
        XCTAssertEqual(WaitModeEngine(notes: []).earlyInputWindow, 0.15)
        XCTAssertEqual(WaitModeEngine(notes: [], inputTolerance: .relaxed).earlyInputWindow, 0.8)
        XCTAssertEqual(WaitModeEngine(notes: [], earlyInputWindow: -1).earlyInputWindow, 0.05)
        XCTAssertEqual(WaitModeEngine(notes: [], earlyInputWindow: 20).earlyInputWindow, 2)
        var sut = WaitModeEngine(notes: [], chordWindow: 1.5, now: 0)
        sut.setEarlyInputWindow(20, at: 0)
        XCTAssertEqual(sut.earlyInputWindow, 2)
        XCTAssertEqual(sut.chordWindow, 1.5)
        sut.setEarlyInputWindow(-1, at: 0)
        XCTAssertEqual(sut.earlyInputWindow, 0.05)
        sut.setEarlyInputWindow(.nan, at: 0)
        XCTAssertEqual(sut.earlyInputWindow, 0.15)
    }

    func testTwoSecondEarlyWindowCollectsWithoutAdvancingBeforeTarget() {
        var sut = WaitModeEngine(notes: [note(1, 48, 2), note(2, 64, 2)], chordWindow: 2,
                                  earlyInputWindow: 2, now: 0)
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 48, timestamp: 0, receivedAt: 0, pressedPitches: [48]).disposition, .accepted)
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.5, receivedAt: 1.5, pressedPitches: [48, 64]).disposition, .accepted)
        XCTAssertEqual(sut.completedGroupCount, 0)
        XCTAssertEqual(sut.update(at: 2)?.completedNoteIDs, [1, 2])
    }

    func testFiftyMillisecondEarlyWindowAcceptsBoundaryButRejectsEarlierInput() {
        for onset in [0.95, 0.9499] {
            var sut = WaitModeEngine(notes: [note(1, 60, 1)], earlyInputWindow: 0.05, now: 0)
            sut.play(at: 0)
            let result = sut.noteOn(pitch: 60, timestamp: onset, receivedAt: onset, pressedPitches: [60])
            XCTAssertEqual(result.disposition, onset == 0.95 ? .accepted : .ignored)
            _ = sut.update(at: 1)
            XCTAssertEqual(sut.completedGroupCount, onset == 0.95 ? 1 : 0)
        }
    }

    func testChangingEitherWaitWindowClearsCurrentAndFutureCandidatesWithoutResettingClockOrScore() {
        for changeEarly in [true, false] {
            var sut = WaitModeEngine(notes: [note(1, 60, 0), note(2, 64, 1), note(3, 67, 1), note(4, 72, 1.2)],
                                      inputTolerance: .relaxed, now: 0)
            sut.play(at: 0)
            _ = sut.noteOn(pitch: 60, timestamp: 0, receivedAt: 0, pressedPitches: [60])
            _ = sut.noteOn(pitch: 64, timestamp: 0.3, receivedAt: 0.3, pressedPitches: [60, 64])
            XCTAssertEqual(sut.noteOn(pitch: 72, timestamp: 0.4, receivedAt: 0.4, pressedPitches: [60, 64, 72]).disposition, .accepted)
            let before = sut.position(at: 0.45)
            if changeEarly { sut.setEarlyInputWindow(0.5, at: 0.45) }
            else { sut.setChordWindow(1.5, at: 0.45) }
            XCTAssertEqual(sut.position(at: 0.45), before)
            XCTAssertEqual(sut.completedNoteIDs, [1])
            XCTAssertEqual(sut.completedGroupCount, 1)
            XCTAssertTrue(sut.isRunning)
            XCTAssertTrue(sut.matchedPitches.isEmpty)
            _ = sut.noteOn(pitch: 67, timestamp: 0.5, receivedAt: 0.5, pressedPitches: [60, 64, 67, 72])
            _ = sut.noteOff(pitch: 64, timestamp: 0.55, receivedAt: 0.55, pressedPitches: [60, 67, 72])
            _ = sut.noteOn(pitch: 64, timestamp: 0.6, receivedAt: 0.6, pressedPitches: [60, 64, 67, 72])
            _ = sut.update(at: 1.3)
            XCTAssertEqual(sut.completedGroupCount, 2)
            XCTAssertEqual(sut.requiredPitches, [72])
            XCTAssertTrue(sut.matchedPitches.isEmpty, "A held future key from before the setting change was reused")
        }
    }

    func testMatcherTimingWindowAcceptsBothDirectionsAtOneAndAHalfSeconds() {
        var matcher = PerformanceMatcher(notes: [note(1, 60, 2), note(2, 64, 2), note(3, 67, 2)])
        matcher.setTimingTolerance(1.5)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 0.5).judgement, .early)
        XCTAssertEqual(matcher.noteOn(pitch: 64, songTime: 3.5).judgement, .late)
        XCTAssertEqual(matcher.noteOn(pitch: 67, songTime: 3.5001).judgement, .wrong)
        XCTAssertEqual(matcher.onTimeTolerance, 0.075)
    }

    func testMatcherWindowChangesPreserveHitsAndMissesAndCanRecoverWithinNewWindow() {
        var matcher = PerformanceMatcher(notes: [note(1, 60, 1), note(2, 64, 1), note(3, 67, 3)])
        _ = matcher.noteOn(pitch: 60, songTime: 1)
        XCTAssertEqual(matcher.advance(to: 1.3).map(\.noteID), [2])
        matcher.setTimingTolerance(1.5)
        XCTAssertEqual(matcher.matchedNoteIDs, [1])
        XCTAssertEqual(matcher.missedNoteIDs, [2])
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 1.1).judgement, .wrong)
        let recovered = matcher.noteOn(pitch: 64, songTime: 2.4)
        XCTAssertTrue(recovered.isMatched && recovered.recoveredMiss)
        XCTAssertTrue(matcher.missedNoteIDs.isEmpty)
        XCTAssertEqual(matcher.noteOn(pitch: 67, songTime: 1.5).judgement, .early)
        XCTAssertEqual(matcher.matchedNoteIDs, [1, 2, 3])
    }

    func testMatcherToleranceBoundsAndFallbackDoNotChangeOnTimeClassification() {
        var matcher = PerformanceMatcher(notes: [note(1, 60, 1)])
        matcher.setTimingTolerance(-1)
        XCTAssertEqual(matcher.earlyTolerance, 0.05)
        XCTAssertEqual(matcher.lateTolerance, 0.05)
        matcher.setTimingTolerance(20)
        XCTAssertEqual(matcher.earlyTolerance, 2)
        XCTAssertEqual(matcher.lateTolerance, 2)
        matcher.setTimingTolerance(.nan)
        XCTAssertEqual(matcher.earlyTolerance, 0.8)
        XCTAssertEqual(matcher.lateTolerance, 0.8)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 1.05).judgement, .hit)
        XCTAssertEqual(matcher.onTimeTolerance, 0.075)
    }
}
