import XCTest
@testable import PianoCore

final class HandAssignmentTests: XCTestCase {
    func testNamesTakePrecedenceAndConductorTracksAreNotAssigned() {
        let song = PianoSong(title: "Hands", notes: [
            note(17, 75, track: 1), note(31, 48, track: 2), note(92, 80, track: 3)
        ], tracks: [
            SongTrack(id: 0, name: "Conductor RH"), SongTrack(id: 1, name: "左手"),
            SongTrack(id: 2, name: "Piano RH"), SongTrack(id: 3, name: "Melody")
        ])
        let hands = HandAssignment.initialTrackAssignments(song: song)
        XCTAssertNil(hands[0])
        XCTAssertEqual(hands[1], .left)
        XCTAssertEqual(hands[2], .right)
        XCTAssertEqual(hands[3], .right)
    }

    func testAnonymousSingleTrackAndSimilarRegistersRemainAutomatic() {
        let single = PianoSong(title: "Piano", notes: [note(0, 48), note(1, 72)])
        XCTAssertTrue(HandAssignment.initialTrackAssignments(song: single).isEmpty)
        let bright = PianoSong(title: "Piano", notes: [note(0, 48)], tracks: [SongTrack(id: 0, name: "Bright Piano")])
        XCTAssertTrue(HandAssignment.initialTrackAssignments(song: bright).isEmpty)
        let similar = PianoSong(title: "Piano", notes: [note(0, 60), note(1, 62, track: 1)])
        XCTAssertTrue(HandAssignment.initialTrackAssignments(song: similar).isEmpty)
        let distinct = PianoSong(title: "Piano", notes: [note(0, 48), note(1, 72, track: 1)])
        XCTAssertEqual(HandAssignment.initialTrackAssignments(song: distinct), [0: .left, 1: .right])
    }

    func testManualUnassignedAndCrossedHandsOverrideSplitAndPreserveNoteIDs() {
        let notes = [note(46, 80, track: 0), note(29, 40, track: 1), note(88, 64, track: 2), note(91, 60, track: 3)]
        let result = HandAssignment.resolve(notes: notes, trackHands: [0: .left, 1: .right, 2: .unassigned], automaticSplit: true, splitPitch: 61)
        XCTAssertEqual(result, [46: .left, 29: .right, 88: .unassigned, 91: .left])
        XCTAssertEqual(HandAssignment.resolve(notes: notes, trackHands: [:], automaticSplit: false).values.filter { $0 == .unassigned }.count, 4)
    }

    private func note(_ id: Int, _ pitch: Int, track: Int = 0) -> PianoNote {
        PianoNote(id: id, pitch: pitch, start: 0, duration: 0.5, track: track)
    }
}

final class FingeringGeneratorTests: XCTestCase {
    func testEachHandChordUsesOrderedDistinctPhysicalFingers() throws {
        let left = chord([48, 52, 55], baseID: 11)
        let right = chord([72, 76, 79], baseID: 31)
        let hands = Dictionary(uniqueKeysWithValues: left.map { ($0.id, PianoHand.left) } + right.map { ($0.id, PianoHand.right) })
        let result = FingeringGenerator.generate(notes: left + right, hands: hands)
        XCTAssertTrue(result.unsupportedNoteIDs.isEmpty)
        let leftFingers = try left.map { try XCTUnwrap(result.fingers[$0.id]) }
        let rightFingers = try right.map { try XCTUnwrap(result.fingers[$0.id]) }
        XCTAssertEqual(leftFingers, leftFingers.sorted(by: >))
        XCTAssertEqual(rightFingers, rightFingers.sorted())
        XCTAssertEqual(Set(leftFingers).count, 3)
        XCTAssertEqual(Set(rightFingers).count, 3)
        XCTAssertTrue(result.fingers.values.allSatisfy { (1...5).contains($0) })
    }

    func testRepeatedNotesAreConsistentAndDoNotDependOnPitchClassMapping() throws {
        let notes = (0..<6).map { PianoNote(id: 50 + $0, pitch: 60, start: Double($0) * 0.3, duration: 0.2) }
        let hands = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, PianoHand.right) })
        let result = FingeringGenerator.generate(notes: notes, hands: hands)
        XCTAssertEqual(result.fingers.count, notes.count)
        XCTAssertEqual(Set(result.fingers.values).count, 1)

        // The same C must use different fingers in a five-note chord and in its
        // adjacent phrase; a pitch-class lookup cannot satisfy both contexts.
        let lowC = chord([60, 62, 64, 65, 67], baseID: 1)
        let highC = chord([53, 55, 57, 59, 60], baseID: 10)
        let low = FingeringGenerator.generate(notes: lowC, hands: Dictionary(uniqueKeysWithValues: lowC.map { ($0.id, .right) }))
        let high = FingeringGenerator.generate(notes: highC, hands: Dictionary(uniqueKeysWithValues: highC.map { ($0.id, .right) }))
        XCTAssertEqual(low.fingers[1], 1)
        XCTAssertEqual(high.fingers[14], 5)
    }

    func testDuplicatePitchAtSameOnsetSharesFingerButHandsRemainIndependent() {
        let notes = [PianoNote(id: 101, pitch: 60, start: 0, duration: 1),
                     PianoNote(id: 102, pitch: 60, start: 0, duration: 0.5),
                     PianoNote(id: 103, pitch: 60, start: 0, duration: 0.5)]
        let result = FingeringGenerator.generate(notes: notes, hands: [101: .right, 102: .right, 103: .left])
        XCTAssertEqual(result.fingers.count, 3)
        XCTAssertEqual(result.fingers[101], result.fingers[102])
        XCTAssertTrue(result.unsupportedNoteIDs.isEmpty)
    }

    func testUnassignedNotesAreOmittedAndUnsupportedChordsDoNotInventDigits() {
        let excessive = chord([60, 62, 64, 65, 67, 69], baseID: 10)
        let tooWide = chord([36, 60], baseID: 30)
        let neutral = PianoNote(id: 99, pitch: 70, start: 0, duration: 1)
        var hands = Dictionary(uniqueKeysWithValues: excessive.map { ($0.id, PianoHand.right) } + tooWide.map { ($0.id, PianoHand.left) })
        hands[99] = .unassigned
        let result = FingeringGenerator.generate(notes: excessive + tooWide + [neutral], hands: hands)
        XCTAssertTrue(result.fingers.isEmpty)
        XCTAssertEqual(result.unsupportedNoteIDs, Set((excessive + tooWide).map(\.id)))
        XCTAssertFalse(result.unsupportedNoteIDs.contains(99))
    }

    func testSustainedChordKeepsFingerReservedUntilReleaseAndPhraseCanReposition() throws {
        let held = PianoNote(id: 0, pitch: 60, start: 0, duration: 1)
        let next = PianoNote(id: 1, pitch: 64, start: 0.5, duration: 0.25)
        let later = PianoNote(id: 2, pitch: 90, start: 2, duration: 0.25)
        let result = FingeringGenerator.generate(notes: [held, next, later], hands: [0: .right, 1: .right, 2: .right])
        XCTAssertEqual(result.fingers.count, 3)
        XCTAssertLessThan(try XCTUnwrap(result.fingers[0]), try XCTUnwrap(result.fingers[1]))
        XCTAssertTrue(result.unsupportedNoteIDs.isEmpty)
    }

    func testRightHandLegatoScalesAllowThumbPassesInBothDirections() throws {
        try checkLegatoScales(hand: .right, pitches: [60, 62, 64, 65, 67, 69, 71, 72])
    }

    func testLeftHandLegatoScalesAllowThumbPassesInBothDirections() throws {
        try checkLegatoScales(hand: .left, pitches: [48, 50, 52, 53, 55, 57, 59, 60])
    }

    func testThumbPassDoesNotReuseOccupiedFingersOrExceedHandSpan() {
        for hand in [PianoHand.left, .right] {
            let heldChord = [60, 62, 64, 65, 67].enumerated().map {
                PianoNote(id: $0.offset, pitch: $0.element, start: 0, duration: 2)
            }
            let sixth = PianoNote(id: 5, pitch: 69, start: 0.5, duration: 0.5)
            let full = FingeringGenerator.generate(notes: heldChord + [sixth], hands:
                Dictionary(uniqueKeysWithValues: (heldChord + [sixth]).map { ($0.id, hand) }))
            XCTAssertEqual(Set(full.fingers.values).count, 5)
            XCTAssertNil(full.fingers[sixth.id], "A sixth key cannot reuse one of five held fingers")
            XCTAssertEqual(full.unsupportedNoteIDs, [sixth.id])

            let tooWide = [PianoNote(id: 10, pitch: 60, start: 0, duration: 2),
                           PianoNote(id: 11, pitch: 73, start: 0.5, duration: 0.5)]
            let span = FingeringGenerator.generate(notes: tooWide, hands: [10: hand, 11: hand])
            XCTAssertNotNil(span.fingers[10])
            XCTAssertNil(span.fingers[11], "Thumb passes must retain the maximum simultaneous span")
            XCTAssertEqual(span.unsupportedNoteIDs, [11])
        }
    }

    func testLongSongHasBoundedWorkDeterministicOutputAndStableIDs() {
        let notes = (0..<2_000).map { index in
            PianoNote(id: index * 7 + 13, pitch: 60 + [0, 2, 4, 5, 7, 9, 11, 12][index % 8],
                      start: Double(index) * 0.25, duration: 0.2)
        }
        let hands = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, PianoHand.right) })
        let clock = ContinuousClock()
        let start = clock.now
        let result = FingeringGenerator.generate(notes: notes, hands: hands)
        // A broad regression bound catches accidental full-history copying or
        // exponential search while leaving room for debug/CI hardware variation.
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(15))
        XCTAssertEqual(result.fingers.count, notes.count)
        XCTAssertEqual(Set(result.fingers.keys), Set(notes.map(\.id)))
        XCTAssertTrue(result.fingers.values.allSatisfy { (1...5).contains($0) })
        XCTAssertEqual(result, FingeringGenerator.generate(notes: notes.reversed(), hands: hands))
    }

    private func chord(_ pitches: [Int], baseID: Int) -> [PianoNote] {
        pitches.enumerated().map { PianoNote(id: baseID + $0.offset, pitch: $0.element, start: 0, duration: 0.5) }
    }

    private func checkLegatoScales(hand: PianoHand, pitches: [Int]) throws {
        for sequence in [pitches, Array(pitches.reversed())] {
            for duration in [0.51, 0.8] {
                let notes = sequence.enumerated().map {
                    PianoNote(id: 1_000 + $0.offset * 3, pitch: $0.element,
                              start: Double($0.offset) * 0.5, duration: duration)
                }
                let result = FingeringGenerator.generate(notes: notes, hands:
                    Dictionary(uniqueKeysWithValues: notes.map { ($0.id, hand) }))
                let context = "\(hand) scale \(sequence), duration \(duration)"
                XCTAssertTrue(result.unsupportedNoteIDs.isEmpty, context)
                XCTAssertEqual(result.fingers.count, notes.count, context)
                let fingers = try notes.map { try XCTUnwrap(result.fingers[$0.id], context) }
                XCTAssertTrue(fingers.allSatisfy { (1...5).contains($0) }, context)
                var crossedThumb = false
                for index in 1..<notes.count {
                    // Adjacent notes overlap: a thumb pass still needs two
                    // distinct fingers until the preceding key is released.
                    XCTAssertNotEqual(fingers[index], fingers[index - 1], context)
                    let pitchDelta = notes[index].pitch - notes[index - 1].pitch
                    let fingerDelta = (fingers[index] - fingers[index - 1]) * (hand == .right ? 1 : -1)
                    if pitchDelta * fingerDelta < 0 {
                        crossedThumb = true
                        XCTAssertTrue(fingers[index] == 1 || fingers[index - 1] == 1, context)
                    }
                }
                XCTAssertTrue(crossedThumb, "A legato octave scale needs a thumb pass: \(context)")
            }
        }
    }
}
