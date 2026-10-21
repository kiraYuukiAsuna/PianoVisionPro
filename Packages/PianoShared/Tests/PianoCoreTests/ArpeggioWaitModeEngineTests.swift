import XCTest
@testable import PianoCore

final class ArpeggioWaitModeEngineTests: XCTestCase {
    private func note(_ id: Int, _ pitch: Int, _ start: Double, track: Int = 0) -> PianoNote {
        PianoNote(id: id, pitch: pitch, start: start, duration: 1, track: track)
    }

    private func engine(_ notes: [PianoNote], policy: WaitInputTolerance = .relaxed) -> WaitModeEngine {
        WaitModeEngine(notes: notes, inputTolerance: policy, now: 0)
    }

    func testWideCurrentChordAccumulatesReleasedPitchesAndIgnoresWrongNotes() {
        var sut = engine([note(1, 36, 0), note(2, 60, 0), note(3, 84, 0)])
        sut.play(at: 0)
        XCTAssertEqual(sut.currentGroupNoteIDs, [1, 2, 3])
        _ = sut.noteOn(pitch: 36, timestamp: 0.1, receivedAt: 0.1, pressedPitches: [36])
        _ = sut.noteOff(pitch: 36, timestamp: 0.2, receivedAt: 0.2, pressedPitches: [])
        XCTAssertEqual(sut.matchedPitches, [36])
        XCTAssertEqual(sut.matchedNoteIDs, [1])
        _ = sut.noteOn(pitch: 60, timestamp: 0.3, receivedAt: 0.3, pressedPitches: [60])
        _ = sut.noteOff(pitch: 60, timestamp: 0.4, receivedAt: 0.4, pressedPitches: [])
        XCTAssertEqual(sut.matchedNoteIDs, [1, 2])
        XCTAssertEqual(sut.noteOn(pitch: 61, timestamp: 0.5, receivedAt: 0.5, pressedPitches: [61]).disposition, .wrong)
        _ = sut.noteOff(pitch: 61, timestamp: 0.6, receivedAt: 0.6, pressedPitches: [])
        XCTAssertEqual(sut.matchedNoteIDs, [1, 2])
        let completion = sut.noteOn(pitch: 84, timestamp: 0.7, receivedAt: 0.7, pressedPitches: [84])
        XCTAssertEqual(completion.completedNoteIDs, [1, 2, 3])
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertTrue(sut.matchedNoteIDs.isEmpty)
    }

    func testReplayingAccumulatedPitchDoesNotCountTwiceOrPrefillNextRepeat() {
        var sut = engine([note(1, 36, 0), note(2, 84, 0), note(3, 36, 0.2)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 36, timestamp: 0.1, receivedAt: 0.1, pressedPitches: [36])
        _ = sut.noteOff(pitch: 36, timestamp: 0.2, receivedAt: 0.2, pressedPitches: [])
        let repeated = sut.noteOn(pitch: 36, timestamp: 0.3, receivedAt: 0.3, pressedPitches: [36])
        XCTAssertEqual(repeated.disposition, .ignored)
        XCTAssertEqual(sut.matchedNoteIDs, [1])
        XCTAssertEqual(sut.completedGroupCount, 0)
        let completion = sut.noteOn(pitch: 84, timestamp: 0.5, receivedAt: 0.5, pressedPitches: [36, 84])
        XCTAssertEqual(completion.completedNoteIDs, [1, 2])
        _ = sut.update(at: 0.8)
        XCTAssertEqual(sut.currentGroupNoteIDs, [3])
        XCTAssertTrue(sut.matchedNoteIDs.isEmpty)
        XCTAssertEqual(sut.noteOn(pitch: 36, timestamp: 0.8, receivedAt: 0.8, pressedPitches: [36, 84]).disposition, .ignored)
        _ = sut.noteOff(pitch: 36, timestamp: 0.9, receivedAt: 0.9, pressedPitches: [84])
        XCTAssertEqual(sut.noteOn(pitch: 36, timestamp: 1, receivedAt: 1, pressedPitches: [36, 84]).completedNoteIDs, [3])
    }

    func testStrictPolicyStillRequiresAllChordKeysToRemainHeld() {
        for policy in [WaitInputTolerance.strict, .relaxed] {
            var sut = engine([note(1, 48, 0), note(2, 72, 0)], policy: policy)
            sut.play(at: 0)
            _ = sut.noteOn(pitch: 48, timestamp: 0.1, receivedAt: 0.1, pressedPitches: [48])
            _ = sut.noteOff(pitch: 48, timestamp: 0.2, receivedAt: 0.2, pressedPitches: [])
            XCTAssertEqual(sut.matchedNoteIDs, policy == .strict ? [] : [1])
            _ = sut.noteOn(pitch: 72, timestamp: 0.25, receivedAt: 0.25, pressedPitches: [72])
            XCTAssertEqual(sut.completedGroupCount, policy == .strict ? 0 : 1)
        }
    }

    func testExactMatchedIDsCoverAllUnisonAliasesButNotUnplayedPitches() {
        var sut = engine([note(1, 60, 1), note(2, 60, 1.01, track: 1), note(3, 64, 1.02),
                          note(4, 67, 1.2), note(5, 67, 1.21, track: 1)])
        sut.play(at: 0)
        XCTAssertEqual(sut.currentGroupNoteIDs, [1, 2, 3])
        _ = sut.noteOn(pitch: 60, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60])
        XCTAssertEqual(sut.matchedNoteIDs, [1, 2])
        _ = sut.noteOn(pitch: 67, timestamp: 1, receivedAt: 1, pressedPitches: [60, 67])
        XCTAssertEqual(sut.matchedNoteIDs, [1, 2, 4, 5])
        _ = sut.noteOff(pitch: 60, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [67])
        XCTAssertEqual(sut.matchedNoteIDs, [1, 2, 4, 5])
        _ = sut.noteOff(pitch: 67, timestamp: 1.02, receivedAt: 1.02, pressedPitches: [])
        XCTAssertEqual(sut.matchedNoteIDs, [1, 2], "Released future input must not remain matched")
        let result = sut.noteOn(pitch: 64, timestamp: 1.03, receivedAt: 1.03, pressedPitches: [64])
        XCTAssertEqual(result.completedNotes.count, 2)
        XCTAssertEqual(sut.completedNoteIDs, [1, 2, 3])
        XCTAssertEqual(sut.currentGroupNoteIDs, [4, 5])
        XCTAssertTrue(sut.matchedNoteIDs.isEmpty)
    }

    func testCurrentEarlyArpeggioCanReleaseBeforeItsMusicalOnset() {
        var sut = engine([note(1, 48, 1), note(2, 72, 1)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 48, timestamp: 0.3, receivedAt: 0.3, pressedPitches: [48])
        _ = sut.noteOff(pitch: 48, timestamp: 0.4, receivedAt: 0.4, pressedPitches: [])
        _ = sut.noteOn(pitch: 72, timestamp: 0.5, receivedAt: 0.5, pressedPitches: [72])
        _ = sut.noteOff(pitch: 72, timestamp: 0.6, receivedAt: 0.6, pressedPitches: [])
        XCTAssertEqual(sut.completedGroupCount, 0)
        XCTAssertEqual(sut.matchedNoteIDs, [1, 2])
        XCTAssertEqual(sut.update(at: 1)?.completedNoteIDs, [1, 2])
    }

    func testFutureInputBecomesCumulativeOnlyAfterItsGroupIsCurrent() {
        var sut = engine([note(1, 36, 0), note(2, 48, 0), note(3, 72, 0.2), note(4, 84, 0.2)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 72, timestamp: 0.1, receivedAt: 0.1, pressedPitches: [72])
        _ = sut.noteOn(pitch: 36, timestamp: 0.11, receivedAt: 0.11, pressedPitches: [36, 72])
        _ = sut.noteOn(pitch: 48, timestamp: 0.12, receivedAt: 0.12, pressedPitches: [36, 48, 72])
        XCTAssertEqual(sut.currentGroupNoteIDs, [3, 4])
        _ = sut.noteOff(pitch: 72, timestamp: 0.13, receivedAt: 0.13, pressedPitches: [36, 48])
        XCTAssertEqual(sut.matchedNoteIDs, [3])
        _ = sut.noteOn(pitch: 84, timestamp: 0.3, receivedAt: 0.3, pressedPitches: [36, 48, 84])
        XCTAssertEqual(sut.update(at: 0.33)?.completedNoteIDs, [3, 4])
    }

    func testEveryExplicitResetClearsAccumulatedAndFutureProgress() {
        for operation in ["pause", "seek", "rate", "early", "chord", "reset"] {
            var sut = engine([note(1, 48, 0), note(2, 64, 0), note(3, 72, 0.2)])
            sut.play(at: 0)
            _ = sut.noteOn(pitch: 48, timestamp: 0.1, receivedAt: 0.1, pressedPitches: [48])
            _ = sut.noteOff(pitch: 48, timestamp: 0.2, receivedAt: 0.2, pressedPitches: [])
            _ = sut.noteOn(pitch: 72, timestamp: 0.21, receivedAt: 0.21, pressedPitches: [72])
            XCTAssertEqual(sut.matchedNoteIDs, [1, 3])
            switch operation {
            case "pause": sut.pause(at: 0.3); sut.play(at: 0.31)
            case "seek": sut.seek(to: 0, at: 0.3)
            case "rate": sut.setRate(0.5, at: 0.3)
            case "early": sut.setEarlyInputWindow(0.8, at: 0.3)
            case "chord": sut.setChordWindow(1.5, at: 0.3)
            default: sut.resetInput(at: 0.3, pressedPitches: [72])
            }
            XCTAssertTrue(sut.matchedNoteIDs.isEmpty, operation)
            _ = sut.noteOn(pitch: 64, timestamp: 0.4, receivedAt: 0.4, pressedPitches: [64, 72])
            XCTAssertEqual(sut.completedGroupCount, 0, operation)
            XCTAssertEqual(sut.matchedNoteIDs, [2], operation)
            _ = sut.noteOn(pitch: 48, timestamp: 0.5, receivedAt: 0.5, pressedPitches: [48, 64, 72])
            _ = sut.update(at: 1.1)
            XCTAssertEqual(sut.completedGroupCount, 1, operation)
            XCTAssertEqual(sut.currentGroupNoteIDs, [3], operation)
            XCTAssertTrue(sut.matchedNoteIDs.isEmpty, operation)
        }
    }

    func testLateReleaseFromBeforeFuturePromotionRevokesThatOnset() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.2)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.9, receivedAt: 0.9, pressedPitches: [60])
        _ = sut.noteOn(pitch: 64, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60, 64])
        XCTAssertEqual(sut.update(at: 1)?.completedNoteIDs, [1])
        XCTAssertEqual(sut.matchedNoteIDs, [2])
        _ = sut.noteOff(pitch: 64, timestamp: 0.98, receivedAt: 1.1, pressedPitches: [60])
        XCTAssertTrue(sut.matchedNoteIDs.isEmpty)
        XCTAssertNil(sut.update(at: 1.2))
        XCTAssertEqual(sut.completedGroupCount, 1)
        XCTAssertEqual(sut.currentGroupNoteIDs, [2])
        XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.21, receivedAt: 1.21, pressedPitches: [60, 64]).completedNoteIDs, [2])
    }

    func testPostPromotionReleaseIsCumulativeAndLaterReplayCannotRevokeIt() {
        for releaseTime in [1.0, 1.01] {
            var sut = engine([note(1, 60, 1), note(2, 64, 1.2), note(3, 67, 1.2)])
            sut.play(at: 0)
            _ = sut.noteOn(pitch: 60, timestamp: 0.9, receivedAt: 0.9, pressedPitches: [60])
            _ = sut.noteOn(pitch: 64, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60, 64])
            _ = sut.update(at: 1)
            _ = sut.noteOff(pitch: 64, timestamp: releaseTime, receivedAt: 1.02, pressedPitches: [60])
            XCTAssertEqual(sut.matchedNoteIDs, [2])
            XCTAssertEqual(sut.noteOn(pitch: 64, timestamp: 1.03, receivedAt: 1.03, pressedPitches: [60, 64]).disposition, .ignored)
            // A changed source clock estimate on this ignored replay must not
            // reopen provenance of the original, already confirmed valid onset.
            _ = sut.noteOff(pitch: 64, timestamp: 0.99, receivedAt: 1.04, pressedPitches: [60])
            XCTAssertEqual(sut.matchedNoteIDs, [2])
            _ = sut.noteOn(pitch: 67, timestamp: 1.2, receivedAt: 1.2, pressedPitches: [60, 67])
            XCTAssertEqual(sut.completedNoteIDs, [1, 2, 3])
        }
    }

    func testPromotionProvenanceDoesNotSurviveResetIntoDirectCurrentInput() {
        var sut = engine([note(1, 60, 1), note(2, 64, 1.2), note(3, 67, 1.2)])
        sut.play(at: 0)
        _ = sut.noteOn(pitch: 60, timestamp: 0.9, receivedAt: 0.9, pressedPitches: [60])
        _ = sut.noteOn(pitch: 64, timestamp: 0.95, receivedAt: 0.95, pressedPitches: [60, 64])
        _ = sut.update(at: 1)
        sut.resetInput(at: 1.005)
        _ = sut.noteOn(pitch: 64, timestamp: 1.01, receivedAt: 1.01, pressedPitches: [64])
        _ = sut.noteOff(pitch: 64, timestamp: 0.99, receivedAt: 1.02, pressedPitches: [])
        XCTAssertEqual(sut.matchedNoteIDs, [2], "A directly replayed current onset inherited stale promotion provenance")
    }
}
