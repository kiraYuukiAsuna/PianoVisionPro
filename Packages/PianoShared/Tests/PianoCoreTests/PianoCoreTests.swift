import Foundation
import XCTest
@testable import PianoCore

final class SMFParserTests: XCTestCase {
    func testBundledFirstStepsExerciseHasTwoHandsAndItsAuthoredTempoChange() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "FirstSteps", withExtension: "mid", subdirectory: "Fixtures"))
        let song = try SMFParser.parse(data: Data(contentsOf: url), title: "First Steps")
        XCTAssertEqual(song.notes.count, 28)
        XCTAssertEqual(song.tracks.map(\.name), ["MVP right hand", "MVP left hand"])
        XCTAssertEqual(song.notes.filter { $0.track == 0 }.count, 16)
        XCTAssertEqual(song.notes.filter { $0.track == 1 }.count, 12)
        XCTAssertEqual(song.notes.filter { $0.start == 1 }.count, 4)
        let afterTempoChange = try XCTUnwrap(song.notes.first { $0.pitch == 71 && abs($0.start - 4) < 0.000_001 })
        XCTAssertEqual(afterTempoChange.duration, 400.0 / 480 * 0.666667, accuracy: 0.000_001)
        XCTAssertEqual(song.duration, 4 + 4720.0 / 480 * 0.666667, accuracy: 0.000_001)
    }

    func testFormatOneTempoMapAppliesAcrossTracksAndInsideHeldNotes() throws {
        let conductor = event(0, [0xFF, 0x03, 4] + Array("Time".utf8))
            + event(0, [0xFF, 0x51, 3, 0x07, 0xA1, 0x20])
            + event(480, [0xFF, 0x51, 3, 0x0F, 0x42, 0x40])
            + endTrack(delta: 480)
        let piano = event(0, [0xFF, 0x03, 5] + Array("Piano".utf8))
            + event(0, [0x90, 60, 100])
            + event(480, [0x90, 64, 90])
            + event(480, [0x80, 60, 0])
            + event(0, [0x80, 64, 0])
            + endTrack()
        let song = try parse([conductor, piano], format: 1)
        XCTAssertEqual(song.tracks.map(\.name), ["Time", "Piano"])
        XCTAssertEqual(song.notes.count, 2)
        XCTAssertEqual(song.notes[0].duration, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(song.notes[1].start, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(song.notes[1].duration, 1, accuracy: 0.000_001)
        XCTAssertEqual(song.notes[1].track, 1)
        XCTAssertEqual(song.duration, 1.5, accuracy: 0.000_001)
    }

    func testRunningStatusVelocityZeroAndFIFORepeatedNotes() throws {
        let track = event(0, [0x92, 60, 100])
            + event(120, [60, 80])
            + event(120, [60, 0])
            + event(120, [60, 0])
            + endTrack()
        let song = try parse([track])
        XCTAssertEqual(song.notes.map(\.channel), [2, 2])
        XCTAssertEqual(song.notes.map(\.velocity), [100, 80])
        XCTAssertEqual(song.notes[0].start, 0)
        XCTAssertEqual(song.notes[0].duration, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(song.notes[1].start, 0.125, accuracy: 0.000_001)
        XCTAssertEqual(song.notes[1].duration, 0.25, accuracy: 0.000_001)
    }

    func testChannelsDoNotConsumeEachOthersNoteOffsAndOpenNotesCloseAtTrackEnd() throws {
        let track = event(0, [0x90, 60, 100])
            + event(120, [0x91, 60, 90])
            + event(120, [0x81, 60, 0])
            + endTrack(delta: 240)
        let song = try parse([track])
        XCTAssertEqual(song.notes[0].channel, 0)
        XCTAssertEqual(song.notes[0].duration, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(song.notes[1].channel, 1)
        XCTAssertEqual(song.notes[1].duration, 0.125, accuracy: 0.000_001)
    }

    func testChannelModeNoteTerminationUsesEventTimeInsteadOfTrackEnd() throws {
        for controller: UInt8 in [120, 123, 124, 125, 126, 127] {
            let track = event(0, [0x90, 60, 100])
                + event(480, [0xB0, controller, 0])
                + endTrack(delta: 480)
            let song = try parse([track])
            XCTAssertEqual(song.notes.count, 1)
            XCTAssertEqual(song.notes[0].duration, 0.5, accuracy: 0.000_001, "CC \(controller)")
            XCTAssertEqual(song.duration, 1, accuracy: 0.000_001)
        }
    }

    func testChannelModeClosesOnlyItsChannelAndClearsRepeatedNoteQueue() throws {
        let track = event(0, [0x90, 60, 100])
            + event(0, [0x91, 60, 90])
            + event(120, [0x90, 60, 80])
            + event(360, [0xB0, 123, 0])
            + event(0, [0x90, 60, 70])
            + event(240, [0x80, 60, 0])
            + event(240, [0x81, 60, 0])
            + endTrack()
        let song = try parse([track])
        XCTAssertEqual(song.notes.count, 4)
        let byID = Dictionary(uniqueKeysWithValues: song.notes.map { ($0.id, $0) })
        XCTAssertEqual(try XCTUnwrap(byID[0]).duration, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(byID[1]).duration, 1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(byID[2]).duration, 0.375, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(byID[3]).start, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(byID[3]).duration, 0.25, accuracy: 0.000_001)
    }

    func testFormatOneChannelModeDoesNotCloseNotesInAnotherTrack() throws {
        let first = event(0, [0x90, 60, 100])
            + event(480, [0xB0, 120, 0])
            + endTrack(delta: 480)
        let second = event(0, [0x90, 64, 90])
            + event(960, [0x80, 64, 0])
            + endTrack()
        let song = try parse([first, second], format: 1)
        XCTAssertEqual(song.notes.count, 2)
        XCTAssertEqual(try XCTUnwrap(song.notes.first { $0.track == 0 }).duration, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(song.notes.first { $0.track == 1 }).duration, 1, accuracy: 0.000_001)
    }

    func testSustainAndControllerResetDoNotExtendOrTerminateRawKeyDuration() throws {
        let track = event(0, [0xB0, 64, 127])
            + event(0, [0x90, 60, 100])
            + event(240, [0xB0, 121, 0])
            + event(240, [0x80, 60, 0])
            + event(480, [0xB0, 64, 0])
            + endTrack()
        let song = try parse([track])
        XCTAssertEqual(song.notes.count, 1)
        XCTAssertEqual(song.notes[0].duration, 0.5, accuracy: 0.000_001)
    }

    func testSkipsSysexAndOneByteChannelMessages() throws {
        let track = event(0, [0xF0, 3, 0x7D, 0x01, 0xF7])
            + event(0, [0xC0, 1])
            + event(0, [2])
            + event(0, [0xD0, 80])
            + event(0, [90])
            + event(0, [0x90, 60, 100])
            + event(480, [0x80, 60, 0])
            + endTrack()
        let song = try parse([track])
        XCTAssertEqual(song.notes.count, 1)
        XCTAssertEqual(song.notes[0].duration, 0.5, accuracy: 0.000_001)
    }

    func testExtensionChunksAndHeaderExtensionsAreSkipped() throws {
        let track = event(0, [0x90, 60, 80]) + event(480, [0x80, 60, 0]) + endTrack()
        let header = Array("MThd".utf8) + be32(8) + be16(0) + be16(1) + be16(480) + [0, 0]
        let file = header + chunk("JUNK", [1, 2, 3]) + chunk("MTrk", track)
        let song = try SMFParser.parse(data: Data(file), title: "Extension")
        XCTAssertEqual(song.title, "Extension")
        XCTAssertEqual(song.notes.count, 1)
    }

    func testInvalidSMFFailsWithBoundedErrors() {
        let cases: [([UInt8], SMFError)] = [
            ([0x81, 0x80, 0x80, 0x80, 0, 0x90, 60, 100], .invalidVariableLengthQuantity),
            (event(0, [60, 100]) + endTrack(), .invalidRunningStatus),
            (event(0, [0x90, 60, 0xFF]) + endTrack(), .invalidDataByte(0xFF)),
            (event(0, [0xFF, 0x51, 3, 0, 0, 0]) + endTrack(), .invalidTempo),
            (event(0, [0xFF, 0x51, 2, 0, 1]) + endTrack(), .invalidTempo),
            (event(0, [0x90, 60, 100]), .missingEndOfTrack),
            (endTrack() + [0], .eventAfterEndOfTrack),
            (event(0, [0xF1, 0]) + endTrack(), .invalidStatus(0xF1)),
            (event(0, [0xFF, 0x03, 127, 1]), .truncated),
            (event(0, [0x90, 60, 100]) + event(0, [0xFF, 0x01, 0]) + event(0, [60, 0]) + endTrack(), .invalidRunningStatus)
        ]
        for (track, expected) in cases {
            XCTAssertThrowsError(try parse([track])) { error in
                XCTAssertEqual(error as? SMFError, expected)
            }
        }
    }

    func testTruncationAndUnsupportedHeaders() {
        let valid = smf([endTrack()])
        for size in 0..<valid.count {
            XCTAssertThrowsError(try SMFParser.parse(data: Data(valid.prefix(size)), title: "Broken"))
        }
        XCTAssertThrowsError(try parse([endTrack()], format: 2)) { XCTAssertEqual($0 as? SMFError, .unsupportedFormat(2)) }
        XCTAssertThrowsError(try parse([endTrack()], division: 0xE728)) { XCTAssertEqual($0 as? SMFError, .unsupportedTimeDivision) }
        XCTAssertThrowsError(try parse([endTrack()], division: 0)) { XCTAssertEqual($0 as? SMFError, .unsupportedTimeDivision) }
        XCTAssertThrowsError(try parse([endTrack(), endTrack()], format: 0)) { XCTAssertEqual($0 as? SMFError, .invalidTrackCount) }
    }

    private func parse(_ tracks: [[UInt8]], format: UInt16 = 0, division: UInt16 = 480) throws -> PianoSong {
        try SMFParser.parse(data: Data(smf(tracks, format: format, division: division)), title: "Test")
    }

    private func smf(_ tracks: [[UInt8]], format: UInt16 = 0, division: UInt16 = 480) -> [UInt8] {
        Array("MThd".utf8) + be32(6) + be16(format) + be16(UInt16(tracks.count)) + be16(division) + tracks.flatMap { chunk("MTrk", $0) }
    }

    private func chunk(_ id: String, _ bytes: [UInt8]) -> [UInt8] { Array(id.utf8) + be32(UInt32(bytes.count)) + bytes }
    private func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    private func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    private func event(_ delta: UInt32, _ bytes: [UInt8]) -> [UInt8] { vlq(delta) + bytes }
    private func endTrack(delta: UInt32 = 0) -> [UInt8] { event(delta, [0xFF, 0x2F, 0]) }
    private func vlq(_ value: UInt32) -> [UInt8] {
        var remainder = value
        var encoded = [UInt8(remainder & 0x7F)]
        remainder >>= 7
        while remainder > 0 { encoded.insert(UInt8(remainder & 0x7F) | 0x80, at: 0); remainder >>= 7 }
        return encoded
    }
}

final class KeyboardLayoutTests: XCTestCase {
    func testEightyEightKeysUsePhysicalWhiteAndBlackLayout() throws {
        let keyboard = KeyboardLayout()
        XCTAssertEqual(keyboard.keys.count, 88)
        XCTAssertEqual(keyboard.keys.filter { !$0.isBlack }.count, 52)
        XCTAssertEqual(keyboard.width, 52 * keyboard.whiteKeyWidth, accuracy: 0.000_01)
        let a0 = try XCTUnwrap(keyboard.key(for: 21))
        let aSharp0 = try XCTUnwrap(keyboard.key(for: 22))
        let b0 = try XCTUnwrap(keyboard.key(for: 23))
        let c1 = try XCTUnwrap(keyboard.key(for: 24))
        XCTAssertEqual(a0.centerX, keyboard.whiteKeyWidth / 2, accuracy: 0.000_001)
        XCTAssertEqual(aSharp0.centerX, keyboard.whiteKeyWidth, accuracy: 0.000_001)
        XCTAssertEqual(b0.centerX - a0.centerX, keyboard.whiteKeyWidth, accuracy: 0.000_001)
        XCTAssertEqual(c1.centerX - b0.centerX, keyboard.whiteKeyWidth, accuracy: 0.000_001)
        XCTAssertEqual(a0.height, 0)
        XCTAssertEqual(a0.centerZ + a0.depth / 2, 0, accuracy: 0.000_001)
        XCTAssertEqual(aSharp0.centerZ - aSharp0.depth / 2, -keyboard.whiteKeyDepth, accuracy: 0.000_001)
        XCTAssertEqual(aSharp0.height, keyboard.blackKeyHeight)
        XCTAssertNil(keyboard.key(for: 20))
        XCTAssertNil(keyboard.key(for: 109))
    }

    func testPartialRangeAndEmptyRangesStayBounded() {
        let keyboard = KeyboardLayout(minMIDINote: 61, keyCount: 12)
        XCTAssertEqual(keyboard.keys.first?.note, 61)
        XCTAssertEqual(keyboard.keys.last?.note, 72)
        for key in keyboard.keys {
            XCTAssertGreaterThanOrEqual(key.centerX - key.width / 2, -0.000_001)
            XCTAssertLessThanOrEqual(key.centerX + key.width / 2, keyboard.width + 0.000_001)
        }
        XCTAssertEqual(KeyboardLayout(keyCount: 0).width, 0)
        XCTAssertEqual(KeyboardLayout(minMIDINote: 127, keyCount: 88).keyCount, 1)
    }
}

final class PlaybackClockTests: XCTestCase {
    func testPauseRateChangeAndSeekRebaseWithoutAccumulation() {
        var clock = PlaybackClock(now: 100)
        clock.play(at: 100)
        XCTAssertEqual(clock.position(at: 102), 2)
        clock.setRate(0.5, at: 102)
        XCTAssertEqual(clock.position(at: 104), 3)
        clock.pause(at: 104)
        XCTAssertEqual(clock.position(at: 200), 3)
        clock.play(at: 200)
        clock.play(at: 201) // Repeated play must not reset elapsed playback.
        XCTAssertEqual(clock.position(at: 202), 4)
        clock.seek(to: 10, at: 202)
        XCTAssertEqual(clock.position(at: 204), 11)
        clock.stop(at: 204)
        XCTAssertFalse(clock.isPlaying)
        XCTAssertEqual(clock.position(at: 300), 0)
    }

    func testInvalidInputsDoNotPoisonClock() {
        var clock = PlaybackClock(position: -.infinity, rate: .nan, now: 10)
        clock.play(at: 10)
        clock.setRate(.nan, at: 12)
        clock.seek(to: .infinity, at: 12)
        XCTAssertEqual(clock.position(at: 12), 2)
        XCTAssertEqual(clock.position(at: 9), 0)
        clock.seek(to: -5, at: 12)
        XCTAssertEqual(clock.position(at: 12), 0)
    }
}

final class MIDIKeyStateTests: XCTestCase {
    func testChannelModeChangesReleaseOnlyTheirChannelAndPreserveSustain() {
        for controller in 124...127 {
            var state = MIDIKeyState()
            state.noteOn(pitch: 60, velocity: 100, channel: 0)
            state.noteOn(pitch: 64, velocity: 100, channel: 1)
            state.controlChange(controller: 64, value: 127, channel: 0)
            state.controlChange(controller: controller, value: 0, channel: 0)
            XCTAssertEqual(state.pressedPitches, [64], "CC\(controller)")
            XCTAssertEqual(state.soundingPitches, [60, 64], "CC\(controller)")
            XCTAssertTrue(state.isSustainDown(channel: 0), "CC\(controller)")
            state.controlChange(controller: 64, value: 0, channel: 0)
            XCTAssertEqual(state.soundingPitches, [64], "CC\(controller)")
        }
    }

    func testSustainAndChannelsHaveIndependentHeldAndSoundingStates() {
        var state = MIDIKeyState()
        state.controlChange(controller: 64, value: 127, channel: 0)
        state.noteOn(pitch: 60, velocity: 100, channel: 0)
        state.noteOn(pitch: 60, velocity: 100, channel: 1)
        state.noteOff(pitch: 60, channel: 0)
        XCTAssertEqual(state.pressedPitches, [60])
        XCTAssertEqual(state.pressedPitches(channel: 0), [])
        XCTAssertEqual(state.soundingPitches(channel: 0), [60])
        state.controlChange(controller: 64, value: 0, channel: 0)
        XCTAssertEqual(state.soundingPitches(channel: 0), [])
        XCTAssertEqual(state.soundingPitches, [60])
        state.noteOn(pitch: 60, velocity: 0, channel: 1)
        XCTAssertTrue(state.pressedPitches.isEmpty)
        XCTAssertTrue(state.soundingPitches.isEmpty)
    }

    func testPanicControllersAndDisconnectClearStateCorrectly() {
        var state = MIDIKeyState()
        state.controlChange(controller: 64, value: 127)
        state.noteOn(pitch: 60, velocity: 100)
        state.controlChange(controller: 123, value: 0)
        XCTAssertEqual(state.pressedPitches, [])
        XCTAssertEqual(state.soundingPitches, [60])
        state.controlChange(controller: 120, value: 0)
        XCTAssertEqual(state.soundingPitches, [])
        state.noteOn(pitch: 64, velocity: 100)
        state.noteOff(pitch: 64)
        state.controlChange(controller: 121, value: 0)
        XCTAssertFalse(state.isSustainDown(channel: 0))
        XCTAssertTrue(state.soundingPitches.isEmpty)
        state.noteOn(pitch: 67, velocity: 100)
        state.reset()
        XCTAssertTrue(state.pressedPitches.isEmpty)
    }
}

final class PerformanceMatcherTests: XCTestCase {
    private let notes = [
        PianoNote(id: 0, pitch: 60, start: 1, duration: 0.3),
        PianoNote(id: 1, pitch: 64, start: 1, duration: 0.3),
        PianoNote(id: 2, pitch: 67, start: 1, duration: 0.3),
        PianoNote(id: 3, pitch: 60, start: 2, duration: 0.3)
    ]

    func testChordOnsetsMatchOnceWithTimingFeedback() {
        var matcher = PerformanceMatcher(notes: notes)
        let early = matcher.noteOn(pitch: 60, songTime: 0.85)
        XCTAssertEqual(early.noteID, 0)
        XCTAssertEqual(early.judgement, .early)
        XCTAssertTrue(early.isMatched)
        XCTAssertEqual(matcher.noteOn(pitch: 64, songTime: 1.01).judgement, .hit)
        XCTAssertEqual(matcher.noteOn(pitch: 67, songTime: 1.15).judgement, .late)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 1.05).judgement, .wrong)
        XCTAssertEqual(matcher.noteOn(pitch: 61, songTime: 1.05).judgement, .wrong)
        XCTAssertEqual(matcher.matchedNoteIDs, [0, 1, 2])
        XCTAssertTrue(matcher.advance(to: 1.5).isEmpty)
    }

    func testMissesEmittedOnceAndSeekSkipsPastTargets() {
        var matcher = PerformanceMatcher(notes: notes)
        XCTAssertEqual(matcher.advance(to: 1.25).count, 0)
        XCTAssertEqual(matcher.advance(to: 1.251).map(\.noteID), [0, 1, 2])
        XCTAssertTrue(matcher.advance(to: 1.5).isEmpty)
        XCTAssertEqual(matcher.missedNoteIDs, [0, 1, 2])
        matcher.reset(startingAt: 1.8)
        XCTAssertTrue(matcher.missedNoteIDs.isEmpty)
        XCTAssertTrue(matcher.advance(to: 1.9).isEmpty)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 2).noteID, 3)
    }

    func testSamePitchChoosesNearestUnmatchedTargetAndIgnoresZeroVelocity() {
        var matcher = PerformanceMatcher(notes: [
            PianoNote(id: 10, pitch: 60, start: 1, duration: 0.1),
            PianoNote(id: 11, pitch: 60, start: 1.1, duration: 0.1)
        ])
        XCTAssertEqual(matcher.noteOn(pitch: 60, velocity: 0, songTime: 1.08).judgement, .ignored)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 1.08).noteID, 11)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 1.09).noteID, 10)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 1.1).judgement, .wrong)
    }

    func testDelayedTimestampCorrectedInputRecoversProvisionalMissExactlyOnce() {
        var matcher = PerformanceMatcher(notes: notes)
        // The display has advanced to 1.4s before the input played at 1.1s arrives.
        XCTAssertEqual(matcher.advance(to: 1.4).count, 3)
        let delayed = matcher.noteOn(pitch: 60, songTime: 1.1)
        XCTAssertEqual(delayed.noteID, 0)
        XCTAssertEqual(delayed.judgement, .late)
        XCTAssertTrue(delayed.recoveredMiss)
        XCTAssertEqual(matcher.missedNoteIDs, [1, 2])
        XCTAssertEqual(matcher.matchedNoteIDs, [0])
        XCTAssertTrue(matcher.advance(to: 1.5).isEmpty)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 1.1).judgement, .wrong)
        XCTAssertFalse(matcher.noteOn(pitch: 61, songTime: 1.1).recoveredMiss)
    }

    func testSeekSkippedTargetsCannotBeRecoveredAsDelayedInputs() {
        var matcher = PerformanceMatcher(notes: notes)
        matcher.reset(startingAt: 1.8)
        let stale = matcher.noteOn(pitch: 60, songTime: 1.1)
        XCTAssertEqual(stale.judgement, .wrong)
        XCTAssertFalse(stale.recoveredMiss)
        XCTAssertTrue(matcher.missedNoteIDs.isEmpty)
        XCTAssertEqual(matcher.noteOn(pitch: 60, songTime: 2).noteID, 3)
    }

    func testSeekSkipsRecentOnsetsEvenWithinLateToleranceAndPreservesBoundary() {
        var matcher = PerformanceMatcher(notes: [
            PianoNote(id: 10, pitch: 60, start: 9.8, duration: 0.05),
            PianoNote(id: 11, pitch: 64, start: 10, duration: 0.3)
        ])
        matcher.reset(startingAt: 10)
        XCTAssertTrue(matcher.advance(to: 10.1).isEmpty)
        XCTAssertTrue(matcher.missedNoteIDs.isEmpty)
        let delayed = matcher.noteOn(pitch: 60, songTime: 9.9)
        XCTAssertEqual(delayed.judgement, .wrong)
        XCTAssertFalse(delayed.recoveredMiss)
        XCTAssertTrue(matcher.matchedNoteIDs.isEmpty)
        XCTAssertEqual(matcher.noteOn(pitch: 64, songTime: 10).noteID, 11)
    }
}
