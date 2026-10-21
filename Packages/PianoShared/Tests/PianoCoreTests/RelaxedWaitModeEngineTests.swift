import XCTest
@testable import PianoCore

final class RelaxedWaitModeEngineTests: XCTestCase {
    private func note(_ id: Int, _ pitch: Int, _ start: Double, duration: Double = 1,
                      track: Int = 0, channel: Int = 0) -> PianoNote {
        PianoNote(id: id, pitch: pitch, start: start, duration: duration, track: track, channel: channel)
    }

    private func engine(_ notes: [PianoNote], now: Double = 0) -> WaitModeEngine {
        WaitModeEngine(notes: notes, inputTolerance: .relaxed, now: now)
    }

    func testPolicyDefaultsAndExplicitWindowsRemainCompatible() {
        let strict = WaitModeEngine(notes: [])
        let relaxed = engine([])
        XCTAssertEqual(strict.inputTolerance, .strict)
        XCTAssertEqual(strict.earlyInputWindow, 0.15)
        XCTAssertEqual(relaxed.earlyInputWindow, 0.8)
        let explicit = WaitModeEngine(notes: [], earlyInputWindow: 0.25, inputTolerance: .relaxed)
        XCTAssertEqual(explicit.earlyInputWindow, 0.25)
    }

    func testStrictZeroGroupingToleranceStaysExactlyZero() {
        var strict = WaitModeEngine(notes: [note(1, 60, 1), note(2, 64, 1.0000000001)], now: 0)
        strict.play(at: 0)
        XCTAssertEqual(strict.requiredPitches, [60])
    }

    func testLeftHandCanRemainHeldForSecondsUntilRightHandArrives() {
        var sut = engine([note(1, 48, 0), note(2, 64, 0), note(3, 67, 0)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 48, timestamp: 0.1, receivedAt: 0.1, pressedPitches: [48]).disposition, .accepted)
        _ = sut.update(at: 2)
        XCTAssertFalse(sut.needsRetry)
        XCTAssertEqual(sut.matchedPitches, [48])
        _ = sut.noteOn(pitch: 64, timestamp: 2.1, receivedAt: 2.1, pressedPitches: [48, 64])
        _ = sut.update(at: 4)
        XCTAssertEqual(sut.matchedPitches, [48, 64])
        XCTAssertEqual(sut.noteOn(pitch: 67, timestamp: 4.1, receivedAt: 4.1, pressedPitches: [48, 64, 67]).disposition, .completed)
        XCTAssertEqual(sut.completedNoteIDs, [1, 2, 3])
    }

    func testSevenHundredMillisecondEarlyHeldChordIsAccepted() {
        var sut = engine([note(1, 48, 1), note(2, 64, 1)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 48, timestamp: 0.3, receivedAt: 0.3, pressedPitches: [48]).disposition, .accepted)
        _ = sut.update(at: 0.7)
        XCTAssertEqual(sut.matchedPitches, [48])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 0.8, receivedAt: 0.8, pressedPitches: [48, 64]).disposition, .accepted)
        XCTAssertEqual(sut.completedGroupCount, 0)
        XCTAssertEqual(sut.update(at: 1)?.completedNoteIDs, [1, 2])
    }

    func testReleasedLeftHandRemainsCountedWhileCompletingCurrentArpeggio() {
        var sut = engine([note(1, 48, 0), note(2, 64, 0)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 48, timestamp: 0.1, receivedAt: 0.1, pressedPitches: [48])
        _ = sut.noteOff(pitch: 48, timestamp: 0.2, receivedAt: 0.2, pressedPitches: [])
        XCTAssertEqual(sut.matchedPitches, [48])
        XCTAssertEqual(sut.matchedNoteIDs, [1])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1, receivedAt: 1, pressedPitches: [64]).disposition, .completed)
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertEqual(sut.completedNoteIDs, [1, 2])
    }

    func testHumanizedSameTrackChordAcceptsOneUSBPacketTimestamp() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.01), note(3, 67, 1.02)])
        sut.play(at: 0)
        XCTAssertEqual(sut.requiredPitches, [60, 64, 67])
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1.02, pressedPitches: [60])
        _ = sut.noteOn(pitch: 64, timestamp: 1, receivedAt: 1.021, pressedPitches: [60, 64])
        XCTAssertEqual(sut.noteOn(pitch: 67, timestamp: 1, receivedAt: 1.022, pressedPitches: [60, 64, 67]).disposition, .completed)
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertEqual(sut.completedNoteIDs, [1, 2, 3])
    }

    func testApproximateGroupsAnchorToFirstOnsetAndRequirePositiveOverlap() {
        var anchored = engine([note(1, 60, 1), note(2, 64, 1.02), note(3, 67, 1.04)])
        anchored.play(at: 0)
        XCTAssertEqual(anchored.requiredPitches, [60, 64])
        var detached = engine([note(1, 60, 1, duration: 0.01), note(2, 64, 1.02)])
        detached.play(at: 0)
        XCTAssertEqual(detached.requiredPitches, [60])
        var explicit = WaitModeEngine(notes: [note(1, 60, 1), note(2, 64, 1.01)],
                                      groupingTolerance: 0, inputTolerance: .relaxed, now: 0)
        explicit.play(at: 0)
        XCTAssertEqual(explicit.requiredPitches, [60])
    }

    func testCrossTrackOrChannelUnisonDoublingIsOnePhysicalTarget() {
        for alternate in [note(2, 60, 1.01, track: 1), note(2, 60, 1.01, channel: 1)] {
            var sut = engine([note(1, 60, 1), alternate])
            sut.play(at: 0)
            let result = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1, pressedPitches: [60])
            XCTAssertEqual(result.completedNotes.count, 1)
            XCTAssertEqual(sut.completedNoteIDs, [1, 2])
            XCTAssertEqual(sut.completedGroupCount, 1)
            XCTAssertTrue(sut.requiredPitches.isEmpty)
        }
    }

    func testSameLaneRepeatedPitchIsNeverMergedOrSatisfiedByLongHold() {
        var sut = engine([note(1, 60, 1), note(2, 60, 1.01)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1.02, pressedPitches: [60])
        _ = sut.update(at: 2)
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertEqual(sut.requiredPitches, [60])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 2, receivedAt: 2, pressedPitches: [60]).disposition, .ignored)
        _ = sut.noteOff(pitch: 60, timestamp: 2.1, receivedAt: 2.1, pressedPitches: [])
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 2.2, receivedAt: 2.2, pressedPitches: [60]).disposition, .completed)
    }

    func testWiFiArrivalDelayDoesNotInvalidateFollowingSourceOnset() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0.1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1.3, pressedPitches: [60])
        let following = sut.noteOn(pitch: 64, timestamp: 1.1, receivedAt: 1.31, pressedPitches: [60, 64])
        XCTAssertEqual(following.disposition, .accepted)
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertEqual(sut.update(at: 1.41)?.completedNoteIDs, [2])
    }

    func testClockOffsetRegressionAcrossCompletedGroupsDoesNotDiscardFreshOnset() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0.1)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1.05, receivedAt: 1.05, pressedPitches: [60]).disposition, .completed)
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.04, receivedAt: 1.10, pressedPitches: [60, 64]).disposition, .accepted)
        XCTAssertEqual(sut.matchedPitches, [64])
        XCTAssertEqual(sut.update(at: 1.2)?.completedNoteIDs, [2])
        XCTAssertEqual(sut.completedGroupCount, 2)
    }

    func testSeekBoundaryStillRejectsOldSourceAfterACompletedGroup() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0.1)], now: 10)
        sut.play(at: 10)
        _ = sut.noteOn(pitch: 60, timestamp: 10.2, receivedAt: 10.3, pressedPitches: [60])
        sut.seek(to: 0.1, at: 11)
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 10.99, receivedAt: 11.1, pressedPitches: [60, 64]).disposition, .ignored)
        XCTAssertEqual(sut.completedGroupCount, 0)
        _ = sut.noteOff(pitch: 64, timestamp: 11.11, receivedAt: 11.11, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 11.12, receivedAt: 11.12, pressedPitches: [60, 64]).disposition, .completed)
    }

    func testNearOneSecondWiFiDelayStillAcceptsCurrentAndFutureOnsets() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.1), note(3, 67, 1.2)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1.9, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.1, receivedAt: 1.91, pressedPitches: [60, 64]).disposition, .accepted)
        XCTAssertEqual(sut.noteOn(pitch: 67, timestamp: 1.2, receivedAt: 1.92, pressedPitches: [60, 64, 67]).disposition, .accepted)
        XCTAssertEqual(sut.update(at: 2.11)?.completedNoteIDs, [2, 3])
        XCTAssertEqual(sut.completedGroupCount, 3)
    }

    func testThreeSeparatedGroupsAcceptDistinctFreshKeysInOneTimestampedPacket() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.1), note(3, 67, 1.2)])
        sut.play(at: 0)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1.3, pressedPitches: [60]).disposition, .completed)
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1, receivedAt: 1.301, pressedPitches: [60, 64]).disposition, .accepted)
        XCTAssertEqual(sut.noteOn(pitch: 67, timestamp: 1, receivedAt: 1.302, pressedPitches: [60, 64, 67]).disposition, .accepted)
        let completion = sut.update(at: 1.51)
        XCTAssertEqual(completion?.completedNoteIDs, [2, 3])
        XCTAssertEqual(sut.completedGroupCount, 3)
        XCTAssertNil(sut.update(at: 1.52))
    }

    func testFutureOtherHandOnsetSurvivesLaterCurrentChordCompletion() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1), note(3, 62, 1.2)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 62, timestamp: 1, receivedAt: 1, pressedPitches: [60, 62]).disposition, .accepted)
        let current = sut.noteOn(pitch: 64, timestamp: 1.05, receivedAt: 1.05, pressedPitches: [60, 62, 64])
        XCTAssertEqual(current.completedNoteIDs, [1, 2])
        XCTAssertEqual(sut.matchedPitches, [62], "Already assigned fresh input survives a newer consumed-group source epoch")
        XCTAssertEqual(sut.update(at: 1.3)?.completedNoteIDs, [3])
        XCTAssertEqual(sut.completedGroupCount, 2)
    }

    func testFutureInputReleasedBeforeItsTargetCannotComplete() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1), note(3, 62, 1.2)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        _ = sut.noteOn(pitch: 62, timestamp: 1, receivedAt: 1, pressedPitches: [60, 62])
        _ = sut.noteOff(pitch: 62, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [60])
        _ = sut.noteOn(pitch: 64, timestamp: 1.05, receivedAt: 1.05, pressedPitches: [60, 64])
        XCTAssertNil(sut.update(at: 1.3))
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertEqual(sut.requiredPitches, [62])
        XCTAssertTrue(sut.matchedPitches.isEmpty)
    }

    func testOneCachedOnsetCannotFillTwoFutureRepeatedPitches() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1), note(3, 62, 1.2), note(4, 62, 1.3)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        _ = sut.noteOn(pitch: 62, timestamp: 1, receivedAt: 1, pressedPitches: [60, 62])
        _ = sut.noteOn(pitch: 64, timestamp: 1.05, receivedAt: 1.05, pressedPitches: [60, 62, 64])
        _ = sut.update(at: 1.5)
        XCTAssertEqual(sut.completedGroupCount, 2)
        XCTAssertEqual(sut.requiredPitches, [62])
        XCTAssertTrue(sut.matchedPitches.isEmpty)
        XCTAssertEqual(sut.noteOn(pitch: 62, timestamp: 1.5, receivedAt: 1.5, pressedPitches: [60, 62, 64]).disposition, .ignored)
        _ = sut.noteOff(pitch: 62, timestamp: 1.51, receivedAt: 1.51, pressedPitches: [60, 64])
        XCTAssertEqual(sut.noteOn(pitch: 62, timestamp: 1.52, receivedAt: 1.52, pressedPitches: [60, 62, 64]).disposition, .completed)
    }

    func testPauseSeekAndResetDiscardBothCurrentAndFutureAssignments() {
        for operation in ["pause", "seek", "reset"] {
            var sut = engine([note(1, 60, 1), note(2, 64, 1), note(3, 62, 1.2)])
            sut.play(at: 0)
            _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
            _ = sut.noteOn(pitch: 62, timestamp: 1, receivedAt: 1, pressedPitches: [60, 62])
            switch operation {
            case "pause": sut.pause(at: 1.01); sut.play(at: 1.02)
            case "seek": sut.seek(to: 1, at: 1.01)
            default: sut.resetInput(at: 1.01, pressedPitches: [60, 62])
            }
            XCTAssertTrue(sut.matchedPitches.isEmpty)
            _ = sut.noteOff(pitch: 60, timestamp: 1.03, receivedAt: 1.03, pressedPitches: [62])
            _ = sut.noteOn(pitch: 60, timestamp: 1.04, receivedAt: 1.04, pressedPitches: [60, 62])
            _ = sut.noteOn(pitch: 64, timestamp: 1.05, receivedAt: 1.05, pressedPitches: [60, 62, 64])
            _ = sut.update(at: 1.5)
            XCTAssertEqual(sut.completedGroupCount, 1, operation)
            XCTAssertEqual(sut.requiredPitches, [62], operation)
            XCTAssertTrue(sut.matchedPitches.isEmpty, operation)
        }
    }

    func testFutureCacheIsBoundedEvenWhenCurrentGroupWaitsForSeconds() {
        var sut = engine([note(1, 60, 0), note(2, 64, 0), note(3, 72, 3)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.1, receivedAt: 0.1, pressedPitches: [60])
        XCTAssertEqual(sut.noteOn(pitch: 72, timestamp: 10, receivedAt: 10, pressedPitches: [60, 72]).disposition, .wrong)
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testPlayAndResetEpochsStillRejectOldSourceData() {
        var sut = engine([note(1, 60, 0)], now: 10)
        sut.play(at: 10)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 9.9, receivedAt: 10.1, pressedPitches: [60]).disposition, .ignored)
        sut.resetInput(at: 11)
        XCTAssertEqual(sut.noteOn(pitch: 60, timestamp: 10.9, receivedAt: 11.1, pressedPitches: [60]).disposition, .ignored)
        XCTAssertEqual(sut.completedGroupCount, 0)
    }

    func testLateReleaseSettlesAllDueCachedGroupsBeforeRemovingPhysicalKey() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.1), note(3, 67, 1.2)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 1, receivedAt: 1.3, pressedPitches: [60])
        _ = sut.noteOn(pitch: 64, timestamp: 1, receivedAt: 1.301, pressedPitches: [60, 64])
        _ = sut.noteOn(pitch: 67, timestamp: 1, receivedAt: 1.302, pressedPitches: [60, 64, 67])
        let released = sut.noteOff(pitch: 67, timestamp: 1.51, receivedAt: 1.6, pressedPitches: [60, 64])
        XCTAssertEqual(released?.completedNoteIDs, [2, 3])
        XCTAssertEqual(sut.completedGroupCount, 3)
    }
}
