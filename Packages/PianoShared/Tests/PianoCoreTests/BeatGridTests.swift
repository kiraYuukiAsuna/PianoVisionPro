import Foundation
import XCTest
@testable import PianoCore

final class BeatGridTests: XCTestCase {
    func testDefaultTempoAndFourFourHaveOneBeatEveryHalfSecond() throws {
        let song = try parse([endTrack(delta: 4_800)])
        let beats = song.beats(in: 0...5)
        XCTAssertEqual(beats.map(\.time), (0...10).map { Double($0) / 2 })
        XCTAssertEqual(beats.filter(\.isMeasure).map(\.time), [0, 2, 4])
        XCTAssertEqual(beats.filter(\.isMeasure).map(\.measure), [1, 2, 3])
        XCTAssertTrue(beats.allSatisfy { $0.numerator == 4 && $0.denominator == 4 })
    }

    func testTempoChangeAcrossTracksAlignsBeatsAndHeldNotes() throws {
        let conductor = event(0, tempo(500_000)) + event(480, tempo(1_000_000)) + endTrack(delta: 1_440)
        let piano = event(0, [0x90, 60, 100]) + event(1_920, [0x80, 60, 0]) + endTrack()
        let song = try parse([conductor, piano])
        XCTAssertEqual(song.beats(in: 0...3.5).map(\.time), [0, 0.5, 1.5, 2.5, 3.5])
        XCTAssertEqual(song.notes[0].duration, 3.5)
        XCTAssertEqual(song.beatGrid.seconds(atQuarter: 4), song.duration)
        XCTAssertEqual(song.beats(in: 3.5...3.5).first?.measure, 2)
    }

    func testTempoChangeWithinBeatIntegratesEachPortionExactly() throws {
        let track = event(0, [0x90, 60, 100]) + event(240, tempo(1_000_000))
            + event(960, [0x80, 60, 0]) + endTrack()
        let song = try parse([track])
        XCTAssertEqual(song.duration, 2.25)
        XCTAssertEqual(song.beats(in: 0...song.duration).map(\.time), [0, 0.75, 1.75])
        XCTAssertEqual(song.beats(in: 0.75...1.75).map(\.time), [0.75, 1.75])
        XCTAssertEqual(song.beatGrid.seconds(atQuarter: 2.5), song.notes[0].end)
    }

    func testThreeFourAndSixEightUseTheirDenominatorBeats() throws {
        let threeFour = try parse([event(0, signature(3, exponent: 2)) + endTrack(delta: 2_880)])
        XCTAssertEqual(threeFour.beats(in: 0...3).filter(\.isMeasure).map(\.time), [0, 1.5, 3])
        let sixEight = try parse([event(0, signature(6, exponent: 3, clocks: 36)) + endTrack(delta: 1_440)])
        let beats = sixEight.beats(in: 0...1.5)
        XCTAssertEqual(beats.map(\.time), [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5])
        XCTAssertEqual(beats.map(\.beatInMeasure), [1, 2, 3, 4, 5, 6, 1])
        XCTAssertEqual(beats.filter(\.isMeasure).map(\.measure), [1, 2])
        XCTAssertEqual(sixEight.beatGrid.timeSignatures[0].clocksPerMetronomeClick, 36)
    }

    func testSignatureChangeBeginsNewMeasureWithoutDuplicatingBoundary() throws {
        let song = try parse([event(1_920, signature(3, exponent: 3)) + endTrack(delta: 1_440)])
        let beats = song.beats(in: 2...3.5)
        XCTAssertEqual(beats.map(\.time), [2, 2.25, 2.5, 2.75, 3, 3.25, 3.5])
        XCTAssertEqual(beats.map(\.measure), [2, 2, 2, 3, 3, 3, 4])
        XCTAssertEqual(beats.map(\.beatInMeasure), [1, 2, 3, 1, 2, 3, 1])
        XCTAssertEqual(Set(beats.map(\.id)).count, beats.count)
        let midMeasure = try parse([event(960, signature(3, exponent: 2)) + endTrack(delta: 1_920)])
        XCTAssertEqual(midMeasure.beats(in: 1...3).filter(\.isMeasure).map(\.measure), [2, 3])
        XCTAssertEqual(midMeasure.beats(in: 1...3).filter(\.isMeasure).map(\.time), [1, 2.5])
    }

    func testMetadataAcrossTracksSortsByTickAndLastSameTickEventWins() throws {
        let lateFirstTrack = event(1_920, signature(3, exponent: 2)) + endTrack(delta: 960)
        let earlySecondTrack = event(0, signature(6, exponent: 3)) + endTrack(delta: 2_880)
        let override = event(960, tempo(1_000_000)) + event(960, signature(2, exponent: 2)) + endTrack(delta: 960)
        let song = try parse([lateFirstTrack, earlySecondTrack, override])
        XCTAssertEqual(song.duration, 5)
        XCTAssertEqual(song.beatGrid.timeSignatures.map(\.quarterPosition), [0, 4])
        XCTAssertEqual(song.beatGrid.timeSignatures.map(\.numerator), [6, 2])
        let beats = song.beats(in: 3...5)
        XCTAssertEqual(beats.map(\.time), [3, 4, 5])
        XCTAssertEqual(beats.map(\.measure), [3, 3, 4])
        XCTAssertEqual(beats.map(\.beatInMeasure), [1, 2, 1])
    }

    func testSameTickTempoOverrideMatchesParserDuration() throws {
        let first = event(0, tempo(500_000)) + endTrack(delta: 480)
        let second = event(0, tempo(1_000_000)) + endTrack(delta: 480)
        let song = try parse([first, second])
        XCTAssertEqual(song.duration, 1)
        XCTAssertEqual(song.beats(in: 0...1).map(\.time), [0, 1])
        XCTAssertEqual(song.beatGrid.tempoChanges.count, 1)
    }

    func testMalformedTimeSignaturesAreRejectedWithoutUnsafeShifts() {
        for payload: [UInt8] in [[3, 2, 24], [3, 2, 24, 8, 0], [0, 2, 24, 8],
                                 [4, 31, 24, 8], [4, 255, 24, 8], [4, 2, 24, 0]] {
            let bytes = [0xFF, 0x58, UInt8(payload.count)] + payload
            XCTAssertThrowsError(try parse([event(0, bytes) + endTrack()])) {
                XCTAssertEqual($0 as? SMFError, .invalidMetaEvent(0x58))
            }
        }
    }

    func testNotatedThirtySecondUnitAffectsBeatSpacing() throws {
        let song = try parse([event(0, signature(4, exponent: 2, thirtySeconds: 4)) + endTrack(delta: 1_920)])
        XCTAssertEqual(song.beats(in: 0...2).map(\.time), [0, 1, 2])
    }

    func testLongTimelineQueriesAreBoundedAndStartDirectlyAtVisibleWindow() {
        let grid = PianoBeatGrid(duration: 1_000_000_000_000)
        XCTAssertEqual(grid.beats(in: 0...grid.duration).count, 256)
        XCTAssertEqual(grid.beats(in: 0...grid.duration, limit: Int.max).count, 4096)
        XCTAssertEqual(grid.beats(in: 999_999_999_990...grid.duration, limit: 3).map(\.time),
                       [999_999_999_990, 999_999_999_990.5, 999_999_999_991])
        XCTAssertTrue(grid.beats(in: 0...1, limit: 0).isEmpty)
        XCTAssertTrue(grid.beats(in: 0...Double.infinity).isEmpty)
        XCTAssertEqual(grid.beats(in: -1...0).map(\.time), [0])
    }

    func testLegacySongDecodesWithoutGridAndNewGridRoundTrips() throws {
        let legacy = Data(#"{"title":"Old song","notes":[],"duration":3,"tracks":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(PianoSong.self, from: legacy)
        XCTAssertEqual(decoded.beats(in: 0...3).map(\.time), [0, 0.5, 1, 1.5, 2, 2.5, 3])
        XCTAssertEqual(PianoSong(title: "Manual", notes: [], duration: 2).beats(in: 0...2).count, 5)
        let song = try parse([event(0, signature(3, exponent: 3)) + event(480, tempo(750_000)) + endTrack(delta: 960)])
        let restored = try JSONDecoder().decode(PianoSong.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(restored, song)
        XCTAssertEqual(restored.beats(in: 0...restored.duration), song.beats(in: 0...song.duration))
    }

    private func parse(_ tracks: [[UInt8]]) throws -> PianoSong {
        let header = Array("MThd".utf8) + be32(6) + be16(tracks.count == 1 ? 0 : 1) + be16(UInt16(tracks.count)) + be16(480)
        let body = tracks.flatMap { Array("MTrk".utf8) + be32(UInt32($0.count)) + $0 }
        return try SMFParser.parse(data: Data(header + body), title: "Beat grid")
    }
    private func tempo(_ microseconds: Int) -> [UInt8] {
        [0xFF, 0x51, 3, UInt8((microseconds >> 16) & 255), UInt8((microseconds >> 8) & 255), UInt8(microseconds & 255)]
    }
    private func signature(_ numerator: UInt8, exponent: UInt8, clocks: UInt8 = 24, thirtySeconds: UInt8 = 8) -> [UInt8] {
        [0xFF, 0x58, 4, numerator, exponent, clocks, thirtySeconds]
    }
    private func endTrack(delta: UInt32 = 0) -> [UInt8] { event(delta, [0xFF, 0x2F, 0]) }
    private func event(_ delta: UInt32, _ bytes: [UInt8]) -> [UInt8] {
        var value = delta
        var encoded = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 { encoded.insert(UInt8(value & 0x7F) | 0x80, at: 0); value >>= 7 }
        return encoded + bytes
    }
    private func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
    private func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
}
