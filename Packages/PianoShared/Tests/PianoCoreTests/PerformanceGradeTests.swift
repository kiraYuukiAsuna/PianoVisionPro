import XCTest
@testable import PianoCore

final class PerformanceGradeTests: XCTestCase {
    func testCompletionUsesRequestedDenominatorAndHandlesEmptyRun() {
        XCTAssertEqual(PerformanceGrade.completionPercentage(correct: 6, wrong: 2, missed: 2), 60)
        XCTAssertEqual(PerformanceGrade.completionPercentage(correct: 0, wrong: 0, missed: 0), 0)
        XCTAssertEqual(PerformanceGrade.completionPercentage(correct: 3, wrong: 0, missed: 0), 100)
    }

    func testTimingRequiresAReleaseAndWeightsBothEdgesEqually() throws {
        var grade = PerformanceGrade()
        grade.noteOn(id: 1, pitch: 60, performedAt: 10, targetAt: 10, duration: 1, committed: true)
        XCTAssertNil(grade.timingPercentage)
        grade.noteOff(pitch: 60, at: 11.29)
        XCTAssertEqual(try XCTUnwrap(grade.timingPercentage), 75, accuracy: 0.000001)
        XCTAssertEqual(grade.evaluatedNoteCount, 1)
        grade.noteOff(pitch: 60, at: 11.3)
        grade.noteOn(id: 1, pitch: 60, performedAt: 12, targetAt: 12, duration: 1, committed: true)
        XCTAssertEqual(grade.evaluatedNoteCount, 1)
    }

    func testEdgeToleranceIsSymmetricAndDoesNotUseAcceptanceWindow() {
        for error in [0.0, 0.05, 0.08] {
            XCTAssertEqual(PerformanceGrade.edgeQuality(errorSeconds: error), 1, accuracy: 0.000001)
            XCTAssertEqual(PerformanceGrade.edgeQuality(errorSeconds: -error), 1, accuracy: 0.000001)
        }
        XCTAssertEqual(PerformanceGrade.edgeQuality(errorSeconds: 0.29), 0.5, accuracy: 0.000001)
        XCTAssertEqual(PerformanceGrade.edgeQuality(errorSeconds: -0.5), 0)
        XCTAssertEqual(PerformanceGrade.edgeQuality(errorSeconds: 2), 0)
        XCTAssertEqual(PerformanceGrade.edgeQuality(errorSeconds: .nan), 0)
    }

    func testReleasedArpeggioSampleWaitsForCommitAndRevokedFutureIsDiscarded() throws {
        var grade = PerformanceGrade()
        grade.noteOn(id: 1, pitch: 60, performedAt: 10, targetAt: 10, duration: 0.2, committed: false)
        grade.noteOff(pitch: 60, at: 10.2)
        XCTAssertNil(grade.timingPercentage)
        grade.retainPending(validNoteIDs: [1])
        grade.commit(noteIDs: [1])
        XCTAssertEqual(try XCTUnwrap(grade.timingPercentage), 100, accuracy: 0.000001)
        grade.noteOn(id: 2, pitch: 64, performedAt: 10.3, targetAt: 11, duration: 0.2, committed: false)
        grade.noteOff(pitch: 64, at: 10.4)
        grade.retainPending(validNoteIDs: [])
        grade.commit(noteIDs: [2])
        XCTAssertEqual(grade.evaluatedNoteCount, 1)
        grade.noteOn(id: 2, pitch: 64, performedAt: 11, targetAt: 11, duration: 0.2, committed: true)
        grade.noteOff(pitch: 64, at: 11.2)
        XCTAssertEqual(grade.evaluatedNoteCount, 2)
        XCTAssertEqual(try XCTUnwrap(grade.timingPercentage), 100, accuracy: 0.000001)
    }

    func testOverdueHoldLosesReleasePointsButDelayedValidReleaseRecovers() throws {
        var grade = PerformanceGrade()
        grade.noteOn(id: 1, pitch: 60, performedAt: 10, targetAt: 10, duration: 1, committed: true)
        grade.advance(to: 11.6)
        XCTAssertEqual(try XCTUnwrap(grade.timingPercentage), 50, accuracy: 0.000001)
        grade.advance(to: 12)
        XCTAssertEqual(grade.evaluatedNoteCount, 1)
        grade.noteOff(pitch: 60, at: 11)
        XCTAssertEqual(try XCTUnwrap(grade.timingPercentage), 100, accuracy: 0.000001)
        XCTAssertEqual(grade.evaluatedNoteCount, 1)
    }

    func testInterruptDiscardsOpenMeasurementsButKeepsFinishedSamples() throws {
        var grade = PerformanceGrade()
        grade.noteOn(id: 1, pitch: 60, performedAt: 10, targetAt: 10, duration: 1, committed: true)
        grade.noteOff(pitch: 60, at: 11)
        grade.noteOn(id: 2, pitch: 64, performedAt: 12, targetAt: 12, duration: 2, committed: true)
        grade.noteOn(id: 3, pitch: 67, performedAt: 12, targetAt: 12, duration: 0, committed: false)
        grade.interrupt()
        grade.noteOff(pitch: 64, at: 100)
        grade.commit(noteIDs: [3])
        grade.advance(to: 100)
        XCTAssertEqual(grade.evaluatedNoteCount, 1)
        XCTAssertEqual(try XCTUnwrap(grade.timingPercentage), 100, accuracy: 0.000001)
    }

    func testZeroDurationUsesOnsetOnlyAndInvalidInputsDoNotCreateSamples() throws {
        var grade = PerformanceGrade()
        grade.noteOn(id: 1, pitch: 60, performedAt: 10.29, targetAt: 10, duration: 0, committed: true)
        XCTAssertEqual(try XCTUnwrap(grade.timingPercentage), 50, accuracy: 0.000001)
        grade.noteOn(id: 2, pitch: 64, performedAt: .nan, targetAt: 10, duration: 1, committed: true)
        grade.noteOn(id: 3, pitch: 65, performedAt: 10, targetAt: 10, duration: -1, committed: true)
        XCTAssertEqual(grade.evaluatedNoteCount, 1)
    }

    func testWaitModeExportsScheduledTimeDespiteFreezingAtChord() throws {
        let notes = [PianoNote(id: 1, pitch: 60, start: 1, duration: 1),
                     PianoNote(id: 2, pitch: 64, start: 2, duration: 1)]
        var engine = WaitModeEngine(notes: notes, earlyInputWindow: 2, inputTolerance: .relaxed, now: 10)
        engine.play(at: 10)
        _ = engine.update(at: 13)
        let late = engine.noteOn(pitch: 60, timestamp: 13, receivedAt: 13, pressedPitches: [60])
        XCTAssertEqual(late.targetHostTime, 11)
        let next = engine.noteOn(pitch: 64, timestamp: 13.1, receivedAt: 13.1, pressedPitches: [60, 64])
        XCTAssertEqual(try XCTUnwrap(next.targetHostTime), 14, accuracy: 0.000001)
    }
}
