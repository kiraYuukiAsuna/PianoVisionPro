import XCTest
@testable import PianoCore

final class PianoRollGeometryTests: XCTestCase {
    func testTrimmedOverlappingLongNoteCannotLeaveMarkersOnTheFollowingAttack() throws {
        let roll = PianoRollGeometry(layout: KeyboardLayout())
        let old = PianoNote(id: 0, pitch: 60, start: 0, duration: 4)
        let repeated = PianoNote(id: 1, pitch: 60, start: 1, duration: 1)
        let trimmed = try XCTUnwrap(roll.note(old, at: 1, speed: 0.22, nextSamePitchStart: 1))
        XCTAssertEqual(trimmed.length, 0)
        XCTAssertFalse(trimmed.hasVisibleContent, "Old checks and hold meters must disappear with the trimmed tail")
        let target = try XCTUnwrap(roll.note(repeated, at: 1, speed: 0.22, isWaitingTarget: true))
        XCTAssertTrue(target.hasVisibleContent)
        let short = PianoNote(id: 2, pitch: 60, start: 0, duration: 0.001)
        let headOnly = try XCTUnwrap(roll.note(short, at: 0, speed: 0.22,
                                             gapMillimeters: 10, nextSamePitchStart: 0.002))
        XCTAssertEqual(headOnly.length, 0)
        XCTAssertTrue(headOnly.hasVisibleContent, "A fresh attack survives even when the visual gap trims its whole body")
    }

    private let layout = KeyboardLayout()

    func testHitLineUsesWholeKeyboardRearEdgeForWhiteAndBlackKeys() {
        let geometry = PianoRollGeometry(layout: layout)
        XCTAssertEqual(geometry.hitLineZ, -layout.whiteKeyDepth - 0.02, accuracy: 0.000001)
        for pitch in [60, 61] {
            let segment = geometry.note(PianoNote(id: pitch, pitch: pitch, start: 1, duration: 1), at: 1, speed: 0.2)
            XCTAssertEqual(segment?.frontZ ?? 0, geometry.hitLineZ, accuracy: 0.000001)
            XCTAssertLessThan(segment?.frontZ ?? 0, -layout.whiteKeyDepth)
            XCTAssertEqual(segment?.surfaceY ?? 0, geometry.surfaceY)
        }
    }

    func testNotesMoveTowardPlayerAlongPositiveZ() throws {
        let geometry = PianoRollGeometry(layout: layout)
        let note = PianoNote(id: 1, pitch: 60, start: 2, duration: 1)
        let earlier = try XCTUnwrap(geometry.note(note, at: 0, speed: 0.2))
        let later = try XCTUnwrap(geometry.note(note, at: 1, speed: 0.2))
        XCTAssertGreaterThan(later.frontZ, earlier.frontZ)
        XCTAssertEqual(later.frontZ - earlier.frontZ, 0.2, accuracy: 0.000001)
        XCTAssertEqual(later.surfaceY, earlier.surfaceY)
    }

    func testBackToBackRepeatedNotesHaveThreeMillimeterVisualGap() throws {
        let geometry = PianoRollGeometry(layout: layout)
        let first = PianoNote(id: 1, pitch: 60, start: 0, duration: 1)
        let second = PianoNote(id: 2, pitch: 60, start: 1, duration: 1)
        let a = try XCTUnwrap(geometry.note(first, at: 0, speed: 0.2, nextSamePitchStart: 1))
        let b = try XCTUnwrap(geometry.note(second, at: 0, speed: 0.2))
        XCTAssertEqual((a.frontZ - a.length) - b.frontZ, 0.003, accuracy: 0.000001)
        XCTAssertEqual(first.duration, 1)
        XCTAssertEqual(first.end, second.start)
        XCTAssertTrue(a.showsOnset)
        XCTAssertTrue(b.showsOnset)
    }

    func testOverlappingRepeatIsVisuallyTrimmedWithoutChangingScore() throws {
        let geometry = PianoRollGeometry(layout: layout)
        let note = PianoNote(id: 1, pitch: 60, start: 0, duration: 2)
        let segment = try XCTUnwrap(geometry.note(note, at: 0, speed: 0.2, nextSamePitchStart: 1))
        XCTAssertEqual(segment.length, 0.197, accuracy: 0.000001)
        XCTAssertEqual(note.duration, 2)
    }

    func testIndependentOnsetSurvivesExtremelyShortBody() throws {
        let geometry = PianoRollGeometry(layout: layout)
        let segment = try XCTUnwrap(geometry.note(PianoNote(id: 1, pitch: 60, start: 1, duration: 0.001),
                                                 at: 0, speed: 0.2, nextSamePitchStart: 1.001))
        XCTAssertEqual(segment.length, 0, accuracy: 0.000001)
        XCTAssertTrue(segment.showsOnset)
    }

    func testZeroDurationWaitingTargetAndFutureOnsetRemainVisible() throws {
        let geometry = PianoRollGeometry(layout: layout)
        let note = PianoNote(id: 1, pitch: 60, start: 1, duration: 0)
        let future = try XCTUnwrap(geometry.note(note, at: 0, speed: 0.2))
        let waiting = try XCTUnwrap(geometry.note(note, at: 1, speed: 0.2, isWaitingTarget: true))
        XCTAssertGreaterThan(future.length, 0)
        XCTAssertGreaterThan(waiting.length, 0)
        XCTAssertEqual(waiting.frontZ, geometry.hitLineZ)
        XCTAssertTrue(waiting.showsOnset)
        XCTAssertNil(geometry.note(note, at: 1.01, speed: 0.2))
    }

    func testTailOfLongNoteClampsAtHitLineAfterItsOnset() throws {
        let geometry = PianoRollGeometry(layout: layout)
        let segment = try XCTUnwrap(geometry.note(PianoNote(id: 1, pitch: 60, start: 0, duration: 2), at: 1, speed: 0.2))
        XCTAssertEqual(segment.frontZ, geometry.hitLineZ)
        XCTAssertEqual(segment.length, 0.2, accuracy: 0.000001)
        XCTAssertFalse(segment.showsOnset)
    }

    func testDuplicateOnsetsShareFollowingDistinctPitchOnset() {
        let notes = [PianoNote(id: 1, pitch: 60, start: 0, duration: 1),
                     PianoNote(id: 2, pitch: 60, start: 0, duration: 1, track: 1),
                     PianoNote(id: 3, pitch: 60, start: 1, duration: 1),
                     PianoNote(id: 4, pitch: 64, start: 0.5, duration: 1)]
        let next = PianoRollGeometry.nextOnsets(for: notes)
        XCTAssertEqual(next[1], 1)
        XCTAssertEqual(next[2], 1)
        XCTAssertNil(next[3])
        XCTAssertNil(next[4])
    }

    func testConfigurableGapRearOffsetAndHeightHaveFiniteFallbacks() throws {
        let geometry = PianoRollGeometry(layout: layout, rearOffsetMeters: .nan, surfaceHeightMeters: -.infinity)
        XCTAssertEqual(geometry.hitLineZ, -layout.whiteKeyDepth - 0.02, accuracy: 0.000001)
        XCTAssertGreaterThan(geometry.surfaceY, layout.blackKeyHeight)
        let note = PianoNote(id: 1, pitch: 60, start: 0, duration: 1)
        let withoutGap = try XCTUnwrap(geometry.note(note, at: 0, speed: 0.2, gapMillimeters: 0, nextSamePitchStart: 1))
        XCTAssertEqual(withoutGap.length, 0.2, accuracy: 0.000001)
        XCTAssertNil(geometry.note(note, at: .nan, speed: 0.2))
        XCTAssertNil(geometry.note(note, at: 0, speed: .nan))
        XCTAssertNil(geometry.note(note, at: 0, speed: 0))
    }

    func testRealTimePreviewAndPhysicalLengthAreStableAcrossPlaybackRates() throws {
        let settings = PianoDisplaySettings()
        let geometry = PianoRollGeometry(layout: layout)
        for rate in [0.5, 1.0, 1.2] {
            let timing = PianoRollTiming(settings: settings, playbackRate: rate)
            XCTAssertEqual(timing.horizonSeconds / rate, 5, accuracy: 0.000001)
            XCTAssertEqual(Double(timing.speedMetersPerScoreSecond) * timing.horizonSeconds, 1.5, accuracy: 0.000001)
            XCTAssertEqual(Double(timing.speedMetersPerScoreSecond) * rate, 1.5 / 5, accuracy: 0.000001)
            let note = PianoNote(id: 1, pitch: 60, start: timing.horizonSeconds, duration: 1)
            let segment = try XCTUnwrap(geometry.note(note, at: 0, speed: timing.speedMetersPerScoreSecond,
                                                     horizon: timing.horizonSeconds))
            XCTAssertEqual(geometry.hitLineZ - segment.frontZ, timing.lengthMeters, accuracy: 0.000001)
        }
    }

    func testTimingHandlesCorruptSettingsAndExtremeRatesWithoutInvalidGeometry() {
        var settings = PianoDisplaySettings()
        settings.lookAheadSeconds = .nan
        settings.rollLengthMeters = -.infinity
        for rate in [Double.nan, .infinity, -.infinity, -1, 0] {
            let timing = PianoRollTiming(settings: settings, playbackRate: rate)
            XCTAssertEqual(timing.playbackRate, 1)
            XCTAssertEqual(timing.horizonSeconds, 5)
            XCTAssertEqual(timing.lengthMeters, 1.5)
        }
        for rate in [Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude] {
            let timing = PianoRollTiming(settings: settings, playbackRate: rate)
            XCTAssertTrue(timing.horizonSeconds.isFinite)
            XCTAssertTrue(timing.speedMetersPerScoreSecond.isFinite)
            XCTAssertGreaterThan(timing.horizonSeconds, 0)
            XCTAssertGreaterThan(timing.speedMetersPerScoreSecond, 0)
            XCTAssertEqual(Double(timing.speedMetersPerScoreSecond) * timing.horizonSeconds, 1.5, accuracy: 0.000001)
        }
    }

    func testDistantNotesFadeContinuouslyFromZeroAtHorizon() {
        var settings = PianoDisplaySettings()
        let timing = PianoRollTiming(settings: settings, playbackRate: 1.2)
        XCTAssertEqual(timing.distanceOpacity(forScoreOffset: -1, settings: settings), 1)
        XCTAssertEqual(timing.distanceOpacity(forScoreOffset: timing.horizonSeconds * 0.8, settings: settings), 1)
        XCTAssertEqual(timing.distanceOpacity(forScoreOffset: timing.horizonSeconds, settings: settings), 0)
        XCTAssertLessThan(timing.distanceOpacity(forScoreOffset: timing.horizonSeconds * 0.999, settings: settings), 0.001)
        let samples = (0...100).map { timing.distanceOpacity(forScoreOffset: timing.horizonSeconds * Double($0) / 100, settings: settings) }
        for pair in zip(samples, samples.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.0, pair.1) }
        settings.farFadeStrength = 0
        let weak = timing.distanceOpacity(forScoreOffset: timing.horizonSeconds * 0.9, settings: settings)
        settings.farFadeStrength = 1
        XCTAssertLessThan(timing.distanceOpacity(forScoreOffset: timing.horizonSeconds * 0.9, settings: settings), weak)
        XCTAssertEqual(timing.distanceOpacity(forScoreOffset: timing.horizonSeconds, settings: settings), 0)
        settings.fadesDistantNotes = false
        XCTAssertEqual(timing.distanceOpacity(forScoreOffset: timing.horizonSeconds, settings: settings), 1)
    }

    func testZeroDurationWaitTargetKeepsAVisibleBody() throws {
        let geometry = PianoRollGeometry(layout: layout)
        let segment = try XCTUnwrap(geometry.note(PianoNote(id: 1, pitch: 60, start: 1, duration: 0),
                                                 at: 1, speed: 0.2, isWaitingTarget: true))
        XCTAssertGreaterThan(segment.length, 0)
    }
}
