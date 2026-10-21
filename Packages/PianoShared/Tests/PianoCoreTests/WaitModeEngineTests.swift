import XCTest
@testable import PianoCore

final class WaitModeEngineTests: XCTestCase {
    private func note(_ id: Int, _ pitch: Int, _ start: Double, duration: Double = 0.5, track: Int = 0) -> PianoNote {
        PianoNote(id: id, pitch: pitch, start: start, duration: duration, track: track)
    }

    private func engine(_ notes: [PianoNote], duration: Double = 10, window: Double = 0.15) -> WaitModeEngine {
        WaitModeEngine(notes: notes, duration: duration, chordWindow: window, now: 0)
    }

    func testPositionClampsBeforeFirstFrameUpdate() {
        var sut = engine([note(1, 60, 1)])
        sut.play(at: 0)
        XCTAssertEqual(sut.position(at: 20), 1)
        XCTAssertTrue(sut.isRunning)
        XCTAssertNil(sut.update(at: 20))
        XCTAssertTrue(sut.isWaiting)
        XCTAssertTrue(sut.isRunning)
    }

    func testChordCompletesImmediatelyWhenAllKeysArriveWithinWindow() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0), note(3, 67, 0)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60]).disposition, .accepted)
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.045, receivedAt: 1.045, pressedPitches: [60, 64]).disposition, .accepted)
        let result = sut.noteOn(pitch: 67, timestamp: 1.105, receivedAt: 1.105, pressedPitches: [60, 64, 67])
        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(result.completedPitches, [60, 64, 67])
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertFalse(sut.isWaiting)
        XCTAssertEqual(sut.position(at: 1.205), 0.1, accuracy: 0.000001)
    }

    func testChordWindowUsesSourceTimeDespiteDeliveryDelay() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 2, pressedPitches: [60])
        _ = sut.update(at: 2.01)
        XCTAssertTrue(sut.needsRetry)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
        let result = sut.noteOn(pitch: 64, timestamp: 1.1, receivedAt: 2.02, pressedPitches: [60, 64])
        XCTAssertEqual(result.disposition, .completed)
    }

    func testArrivalBurstCannotHideExpiredSourceWindow() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 2, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.2, receivedAt: 2, pressedPitches: [60, 64]).disposition, .accepted)
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertTrue(sut.isWaiting)
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testSmallClockSynchronizationFutureSkewDoesNotDiscardChord() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1.03, receivedAt: 1, pressedPitches: [60]).disposition, .accepted)
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.09, receivedAt: 1.06, pressedPitches: [60, 64]).disposition, .completed)
    }

    func testFutureSkewAllowanceIsBounded() {
        var sut = engine([note(1, 60, 0)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1.051, receivedAt: 1, pressedPitches: [60]).disposition, .ignored)
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testClockEstimateRefreshCanRegressSourceTimeWithoutLosingChord() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1.05, receivedAt: 1.05, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.04, receivedAt: 1.1, pressedPitches: [60, 64]).disposition, .completed)
    }

    func testCompletionEpochIncludesFutureSkewedSourceTimestamp() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0.1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1.03, receivedAt: 1, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.02, receivedAt: 1.01, pressedPitches: [60, 64]).disposition, .ignored)
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
    }

    func testLargeClockRegressionCannotBypassChordSpreadLimit() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1.3, receivedAt: 1.3, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1, receivedAt: 1.31, pressedPitches: [60, 64]).disposition, .accepted)
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testExactChordWindowBoundaryIsInclusive() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)], window: 0.08)
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.08, receivedAt: 1.08, pressedPitches: [60, 64]).disposition, .completed)
    }

    func testExpiredPartialChordRequiresFreshRestrikes() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        _ = sut.noteOn(pitch: 64, timestamp: 1.3, receivedAt: 1.3, pressedPitches: [60, 64])
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1.31, receivedAt: 1.31, pressedPitches: [60, 64]).disposition, .ignored)
        sut.noteOff(pitch: 60, timestamp: 1.32, receivedAt: 1.32, pressedPitches: [64])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1.33, receivedAt: 1.33, pressedPitches: [60, 64]).disposition, .completed)
    }

    func testReleasedKeyAndSustainDoNotCompleteChord() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        sut.noteOff(pitch: 60, timestamp: 1.05, receivedAt: 1.05, pressedPitches: [])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.1, receivedAt: 1.1, pressedPitches: [64]).disposition, .accepted)
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testEarlyChordWaitsUntilItsMusicalTime() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.9, receivedAt: 0.9, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60, 64]).disposition, .accepted)
        XCTAssertEqual(sut.completedGroupCount, 0)
        XCTAssertEqual(sut.position(at: 0.97), 0.97, accuracy: 0.000001)
        XCTAssertNil(sut.update(at: 0.99))
        XCTAssertEqual(sut.update(at: 1)?.disposition, .completed)
        XCTAssertEqual(sut.position(at: 1.5), 1.5, accuracy: 0.000001)
    }

    func testTooEarlyKeyMustBeReleasedAndRestruck() {
        var sut = engine([note(1, 60, 1)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 0.5, receivedAt: 0.5, pressedPitches: [60]).disposition, .ignored)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60]).disposition, .ignored)
        sut.noteOff(pitch: 60, timestamp: 1.1, receivedAt: 1.1, pressedPitches: [])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1.2, receivedAt: 1.2, pressedPitches: [60]).disposition, .completed)
    }

    func testEarlyReleasePreventsDeferredCompletion() {
        var sut = engine([note(1, 60, 1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.9, receivedAt: 0.9, pressedPitches: [60])
        sut.noteOff(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [])
        XCTAssertNil(sut.update(at: 1))
        XCTAssertTrue(sut.isWaiting)
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testEarlyShortNoteCompletesOnReleaseAfterTargetBeforeNextFrame() {
        var sut = engine([note(1, 60, 1, duration: 0.05)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.99, receivedAt: 0.99, pressedPitches: [60])
        let release = sut.noteOff(pitch: 60, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [])
        XCTAssertEqual(release?.disposition, .completed)
        XCTAssertEqual(release?.completedNoteIDs, [1])
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertNil(sut.update(at: 1.02), "The frame must not emit the same completion twice")
        XCTAssertFalse(sut.isWaiting)
        XCTAssertEqual(sut.position(at: 1.02), 1.02, accuracy: 0.000001)
    }

    func testSourceReleaseBeforeTargetCannotCompleteEvenWhenDeliveredAfterTarget() {
        var sut = engine([note(1, 60, 1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.9, receivedAt: 0.9, pressedPitches: [60])
        XCTAssertNil(sut.noteOff(pitch: 60, timestamp: 0.99, receivedAt: 1.02, pressedPitches: []))
        XCTAssertNil(sut.update(at: 1.03))
        XCTAssertEqual(sut.completedGroupCount, 0)
        XCTAssertTrue(sut.isWaiting)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
    }

    func testNextEarlyOnsetIsAcceptedAlongsidePriorCompletionWithoutAFrame() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        let next = sut.noteOn(pitch: 64, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [60, 64])
        XCTAssertEqual(next.disposition, .accepted)
        XCTAssertEqual(next.completedNoteIDs, [1], "Prior completion must remain available for scoring")
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertEqual(sut.completedGroupCount, 1)
        let completion = sut.update(at: 1.12)
        XCTAssertEqual(completion?.completedNoteIDs, [2])
        XCTAssertEqual(sut.completedGroupCount, 2)
    }

    func testNextInputCanCompleteNewGroupAndReportBothIndependentOnsets() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.005)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        let next = sut.noteOn(pitch: 64, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [60, 64])
        XCTAssertEqual(next.disposition, .completed)
        XCTAssertEqual(next.completedNoteIDs, [1, 2])
        XCTAssertEqual(next.completedNotes.count, 2)
        XCTAssertEqual(sut.completedGroupCount, 2)
    }

    func testWrongInputStillReportsPreviouslyCollectedChordCompletion() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        let next = sut.noteOn(pitch: 65, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [60, 65])
        XCTAssertEqual(next.disposition, .wrong)
        XCTAssertEqual(next.completedNoteIDs, [1])
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
    }

    func testCachedOnsetAtCompletionBoundaryCannotSatisfyNextGroup() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        let cached = sut.noteOn(pitch: 64, timestamp: 1, receivedAt: 1.01, pressedPitches: [60, 64])
        XCTAssertEqual(cached.disposition, .ignored)
        XCTAssertEqual(cached.completedNoteIDs, [1])
        _ = sut.update(at: 1.12)
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertTrue(sut.isWaiting)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
    }

    func testCachedOnsetBeforeCompletionBoundaryCannotSatisfyNextGroup() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        let cached = sut.noteOn(pitch: 64, timestamp: 0.99, receivedAt: 1.01, pressedPitches: [60, 64])
        XCTAssertEqual(cached.disposition, .ignored)
        XCTAssertEqual(cached.completedNoteIDs, [1])
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
    }

    func testPhysicalOnsetCannotBeReusedWhenItSettlesPreviousRepeatedPitch() {
        var sut = engine([note(1, 60, 1), note(2, 60, 1.1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        let duplicate = sut.noteOn(pitch: 60, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [60])
        XCTAssertEqual(duplicate.disposition, .ignored)
        XCTAssertEqual(duplicate.completedNoteIDs, [1])
        XCTAssertTrue(sut.matchedPitches.isEmpty)
        _ = sut.noteOff(pitch: 60, timestamp: 1.02, receivedAt: 1.02, pressedPitches: [])
        let fresh = sut.noteOn(pitch: 60, timestamp: 1.03, receivedAt: 1.03, pressedPitches: [60])
        XCTAssertEqual(fresh.disposition, .accepted)
        XCTAssertTrue(fresh.completedNotes.isEmpty)
        XCTAssertEqual(sut.update(at: 1.12)?.completedNoteIDs, [2])
    }

    func testLateFrameObservingEarlyChordPreservesItsOriginalMusicalTime() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.5)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        XCTAssertEqual(sut.update(at: 1.2)?.completedNoteIDs, [1])
        XCTAssertEqual(sut.position(at: 1.2), 1.2, accuracy: 0.000001)
        XCTAssertEqual(sut.position(at: 1.51), 1.5, accuracy: 0.000001)
        XCTAssertNil(sut.update(at: 1.51))
        XCTAssertTrue(sut.isWaiting)
    }

    func testCompletedGroupPreservesRestAndLastNoteDuration() {
        var sut = engine([note(1, 60, 1), note(2, 64, 3, duration: 2)], duration: 5)
        sut.play(at: 0)
        _ = sut.update(at: 10)
        _ = sut.noteOn(pitch: 60, timestamp: 10, receivedAt: 10, pressedPitches: [60])
        XCTAssertEqual(sut.position(at: 11), 2)
        XCTAssertEqual(sut.position(at: 20), 3)
        sut.noteOff(pitch: 60, timestamp: 20.01, receivedAt: 20.01, pressedPitches: [])
        _ = sut.noteOn(pitch: 64, timestamp: 20.1, receivedAt: 20.1, pressedPitches: [64])
        XCTAssertTrue(sut.isRunning)
        XCTAssertEqual(sut.position(at: 21.1), 4, accuracy: 0.000001)
        _ = sut.update(at: 22.1)
        XCTAssertEqual(sut.position(at: 22.1), 5)
        XCTAssertFalse(sut.isRunning)
    }

    func testBufferedEventsCannotCompleteFutureGroup() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0.1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 2, pressedPitches: [60])
        let second = sut.noteOn(pitch: 64, timestamp: 1.05, receivedAt: 2.01, pressedPitches: [60, 64])
        XCTAssertEqual(second.disposition, .ignored)
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertEqual(sut.requiredPitches, [64])
        XCTAssertEqual(sut.position(at: 10), 0.1)
    }

    func testDuplicateTimestampAndHeldKeyCannotAdvanceRepeatedNote() {
        var sut = engine([note(1, 60, 0), note(2, 60, 1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 2, receivedAt: 2, pressedPitches: [60]).disposition, .ignored)
        sut.noteOff(pitch: 60, timestamp: 2.1, receivedAt: 2.1, pressedPitches: [])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 2.2, receivedAt: 2.2, pressedPitches: [60]).disposition, .completed)
        XCTAssertEqual(sut.completedGroupCount, 2)
    }

    func testOtherChannelNoteOffDoesNotReleasePhysicalPitch() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        sut.noteOff(pitch: 60, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.1, receivedAt: 1.1, pressedPitches: [60, 64]).disposition, .completed)
    }

    func testWrongKeyNeverAdvancesAndDoesNotPoisonChord() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 61, timestamp: 1, receivedAt: 1, pressedPitches: [61]).disposition, .wrong)
        _ = sut.noteOn(pitch: 60, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [60, 61])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.05, receivedAt: 1.05, pressedPitches: [60, 61, 64]).disposition, .completed)
    }

    func testSeekSkipsStrictlyEarlierOnsetsButKeepsExactBoundary() {
        var sut = engine([note(1, 60, 1), note(2, 64, 2), note(3, 67, 3)])
        sut.play(at: 0)
        sut.seek(to: 2, at: 10)
        XCTAssertEqual(sut.requiredPitches, [64])
        XCTAssertEqual(sut.position(at: 100), 2)
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 10, receivedAt: 10, pressedPitches: [64]).disposition, .completed)
        XCTAssertEqual(sut.requiredPitches, [67])
        sut.seek(to: 2.001, at: 11)
        XCTAssertEqual(sut.requiredPitches, [67])
    }

    func testPauseResumeClearsAttemptAndRejectsHeldKey() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        sut.pause(at: 1.01)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
        sut.play(at: 2)
        _ = sut.noteOn(pitch: 64, timestamp: 2.01, receivedAt: 2.01, pressedPitches: [60, 64])
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testPauseDoesNotAdvanceClampedPosition() {
        var sut = engine([note(1, 60, 1)])
        sut.play(at: 0)
        sut.pause(at: 10)
        XCTAssertEqual(sut.position(at: 100), 1)
        XCTAssertFalse(sut.isRunning)
        XCTAssertFalse(sut.isWaiting)
    }

    func testRateChangesKeepMusicalPositionAndSourceWindowInRealSeconds() {
        var sut = engine([note(1, 60, 2), note(2, 64, 2)])
        sut.play(at: 0)
        sut.setRate(2, at: 0.5)
        XCTAssertEqual(sut.position(at: 0.5), 0.5)
        XCTAssertEqual(sut.position(at: 1.1), 1.7, accuracy: 0.000001)
        _ = sut.noteOn(pitch: 60, timestamp: 1.15, receivedAt: 1.15, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.24, receivedAt: 1.24, pressedPitches: [60, 64]).disposition, .accepted)
        XCTAssertNil(sut.update(at: 1.249))
        XCTAssertEqual(sut.update(at: 1.25)?.disposition, .completed)
        XCTAssertEqual(sut.rate, 2)
    }

    func testChangeRateWhileWaitingInvalidatesAttempt() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        sut.setRate(0.5, at: 1.01)
        _ = sut.noteOn(pitch: 64, timestamp: 1.02, receivedAt: 1.02, pressedPitches: [60, 64])
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertTrue(sut.isWaiting)
    }

    func testModeChangeClearsAttemptsAndAllowsFreePlayback() {
        var sut = engine([note(1, 60, 1), note(2, 64, 3)])
        sut.play(at: 0)
        _ = sut.update(at: 2)
        sut.setEnabled(false, at: 2)
        XCTAssertEqual(sut.position(at: 3), 2)
        sut.setEnabled(true, at: 3)
        XCTAssertEqual(sut.requiredPitches, [64])
        XCTAssertEqual(sut.position(at: 20), 3)
    }

    func testDisconnectClearsHeldKeysAndRejectsPreResetSourceEvents() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        sut.resetInput(at: 2)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.1, receivedAt: 2.1, pressedPitches: [64]).disposition, .ignored)
        _ = sut.noteOn(pitch: 60, timestamp: 2.2, receivedAt: 2.2, pressedPitches: [60])
        sut.noteOff(pitch: 64, timestamp: 2.21, receivedAt: 2.21, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 2.25, receivedAt: 2.25, pressedPitches: [60, 64]).disposition, .completed)
    }

    func testChannelResetRetainsOtherChannelsPhysicallyHeldPitches() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        sut.resetInput(at: 1.01, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1.02, receivedAt: 1.02, pressedPitches: [60]).disposition, .ignored)
        _ = sut.noteOn(pitch: 64, timestamp: 1.03, receivedAt: 1.03, pressedPitches: [60, 64])
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testDuplicateScorePitchesRequireOneKeyAndResolveAllOriginalIDs() {
        var sut = engine([note(1, 60, 0), note(2, 60, 0, track: 1)])
        sut.play(at: 0)
        let result = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(result.completedNotes.count, 1)
        XCTAssertEqual(sut.completedNoteIDs, [1, 2])
    }

    func testGroupingToleranceUsesAnchoredOnsetWithoutTransitiveChaining() {
        var sut = WaitModeEngine(notes: [note(1, 60, 0), note(2, 64, 0.01), note(3, 67, 0.02)], duration: 1, groupingTolerance: 0.015, now: 0)
        sut.play(at: 0)
        XCTAssertEqual(sut.requiredPitches, [60, 64])
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        _ = sut.noteOn(pitch: 64, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [60, 64])
        XCTAssertEqual(sut.requiredPitches, [67])
    }

    func testDefaultGroupingDoesNotMergeNearbyArpeggio() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0.01)])
        sut.play(at: 0)
        XCTAssertEqual(sut.requiredPitches, [60])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60]).disposition, .completed)
        XCTAssertEqual(sut.requiredPitches, [64])
    }

    func testSongWithoutTargetsStillPlaysThroughItsDuration() {
        var sut = engine([], duration: 3)
        sut.play(at: 0)
        XCTAssertEqual(sut.position(at: 2), 2)
        XCTAssertFalse(sut.isWaiting)
        XCTAssertEqual(sut.position(at: 10), 3)
        _ = sut.update(at: 10)
        XCTAssertFalse(sut.isRunning)
    }

    func testZeroDurationTargetAtEndRemainsEligible() {
        var sut = engine([note(1, 60, 0, duration: 0)], duration: 0)
        sut.play(at: 0)
        XCTAssertTrue(sut.isRunning)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 0, receivedAt: 0, pressedPitches: [60]).disposition, .completed)
        _ = sut.update(at: 0)
        XCTAssertFalse(sut.isRunning)
    }

    func testChordWindowClampsAndChangingItResetsPartialAttempt() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0)], window: -1)
        XCTAssertEqual(sut.chordWindow, 0.05)
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
        sut.setChordWindow(3, at: 1.01)
        XCTAssertEqual(sut.chordWindow, 2)
        XCTAssertTrue(sut.matchedPitches.isEmpty)
        sut.setChordWindow(.nan, at: 2)
        XCTAssertEqual(sut.chordWindow, 0.15)
    }

    func testInvalidInputsAndFutureSourceTimestampAreIgnored() {
        var sut = engine([note(1, 60, 1)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: -1, timestamp: 1, receivedAt: 1, pressedPitches: []).disposition, .ignored)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: .nan, receivedAt: 1, pressedPitches: [60]).disposition, .ignored)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 20, receivedAt: 1, pressedPitches: [60]).disposition, .ignored)
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testLateFrameCannotSkipTempoMappedScoreTargets() {
        // Starts represent a parser's already integrated variable-tempo map.
        var sut = engine([note(1, 60, 0.5), note(2, 62, 1), note(3, 64, 1.25), note(4, 65, 2.25)])
        sut.play(at: 0)
        _ = sut.update(at: 100)
        XCTAssertEqual(sut.position(at: 100), 0.5)
        _ = sut.noteOn(pitch: 60, timestamp: 100, receivedAt: 100, pressedPitches: [60])
        XCTAssertEqual(sut.position(at: 100.25), 0.75)
        XCTAssertEqual(sut.position(at: 100.6), 1)
        XCTAssertEqual(sut.requiredPitches, [62])
    }
}
