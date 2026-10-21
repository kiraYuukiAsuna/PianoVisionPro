import Foundation

public enum PianoHand: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case unassigned
}

public enum HandAssignment {
    /// A suggestion, never a claim that a MIDI track contains reliable hand metadata.
    /// Empty conductor tracks and ambiguous single piano tracks are left automatic.
    public static func initialTrackAssignments(song: PianoSong) -> [Int: PianoHand] {
        let noteTracks = Dictionary(grouping: song.notes, by: \.track)
        var result: [Int: PianoHand] = [:]
        for track in song.tracks where noteTracks[track.id] != nil {
            if let hand = namedHand(track.name) { result[track.id] = hand }
        }
        var registers: [(track: Int, median: Double)] = []
        for (track, notes) in noteTracks {
            let pitches: [Int] = notes.map(\.pitch).sorted()
            let median: Double = Double(pitches[pitches.count / 2])
            registers.append((track: track, median: median))
        }
        registers.sort {
            if $0.median == $1.median { return $0.track < $1.track }
            return $0.median < $1.median
        }
        // Infer whole-track hands only when distinct registers give a useful clue.
        // Otherwise the caller can opt into per-note splitting or assign manually.
        guard registers.count > 1 else { return result }
        var largestGap = 0.0
        var boundary: Double?
        for index in 1..<registers.count {
            let gap = registers[index].median - registers[index - 1].median
            if gap > largestGap {
                largestGap = gap
                boundary = (registers[index].median + registers[index - 1].median) / 2
            }
        }
        if largestGap >= 5, let boundary {
            for register in registers where result[register.track] == nil {
                result[register.track] = register.median < boundary ? .left : .right
            }
        }
        return result
    }

    /// Explicit `.unassigned` is neutral and overrides automatic splitting.
    public static func resolve(
        notes: [PianoNote], trackHands: [Int: PianoHand], automaticSplit: Bool, splitPitch: Int = 60
    ) -> [Int: PianoHand] {
        var result: [Int: PianoHand] = [:]
        result.reserveCapacity(notes.count)
        for note in notes {
            result[note.id] = trackHands[note.track]
                ?? (automaticSplit ? (note.pitch < splitPitch ? .left : .right) : .unassigned)
        }
        return result
    }

    private static func namedHand(_ name: String) -> PianoHand? {
        let lower = name.lowercased()
        let tokens = lower.split { !$0.isLetter }.map(String.init)
        let left = lower.contains("左") || tokens.contains("left") || tokens.contains("lefthand") || tokens.contains("lh")
        let right = lower.contains("右") || tokens.contains("right") || tokens.contains("righthand") || tokens.contains("rh")
        guard left != right else { return nil }
        return left ? .left : .right
    }
}

public struct FingeringGenerationResult: Sendable, Equatable {
    public let fingers: [Int: Int]
    /// Assigned notes for which the bounded heuristic found no feasible hand posture.
    /// Unassigned notes are deliberately omitted from both collections.
    public let unsupportedNoteIDs: Set<Int>

    public init(fingers: [Int: Int], unsupportedNoteIDs: Set<Int>) {
        self.fingers = fingers
        self.unsupportedNoteIDs = unsupportedNoteIDs
    }
}

/// Offline, deterministic suggestions rather than authoritative piano pedagogy.
/// A fixed-width beam considers adjacent onsets, thumb crossings, black keys,
/// hand movement, chord spacing and fingers occupied by sustained notes.
public enum FingeringGenerator {
    private static let beamWidth = 12
    private static let chordTolerance = 0.025
    private static let maximumSpan = 12

    public static func generate(notes: [PianoNote], hands: [Int: PianoHand]) -> FingeringGenerationResult {
        var fingers: [Int: Int] = [:]
        var unsupported: Set<Int> = []
        for hand in [PianoHand.left, .right] {
            if Task.isCancelled { break }
            let selected = notes.filter { hands[$0.id] == hand }
            let result = generateHand(notes: selected, hand: hand)
            fingers.merge(result.fingers) { _, new in new }
            unsupported.formUnion(result.unsupportedNoteIDs)
        }
        return FingeringGenerationResult(fingers: fingers, unsupportedNoteIDs: unsupported)
    }

    private struct PitchNotes {
        let pitch: Int
        let notes: [PianoNote]
        var end: Double { notes.map(\.end).max() ?? 0 }
    }

    private struct Held: Hashable {
        let pitch: Int
        let finger: Int
        let end: Double
    }

    private struct Posture {
        let pitches: [Int]
        let fingers: [Int]
        let anchor: Double
        let start: Double
        let end: Double
    }

    private struct Trace {
        let previous: Int?
        let entries: [(id: Int, finger: Int)]
    }

    private struct State {
        let cost: Double
        let held: [Held]
        let posture: Posture?
        let trace: Int?
    }

    private struct StateKey: Hashable {
        let held: [Held]
        let fingers: [Int]
    }

    private struct Candidate {
        let cost: Double
        let held: [Held]
        let posture: Posture
        let previous: Int?
        let entries: [(id: Int, finger: Int)]
        let order: Int
    }

    private static func generateHand(notes: [PianoNote], hand: PianoHand) -> FingeringGenerationResult {
        let sorted = notes.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            return $0.id < $1.id
        }
        var beam = [State(cost: 0, held: [], posture: nil, trace: nil)]
        var traces: [Trace] = []
        var unsupported: Set<Int> = []
        var index = 0
        while index < sorted.count {
            if Task.isCancelled { break }
            let onset = sorted[index].start
            var endIndex = index + 1
            while endIndex < sorted.count, sorted[endIndex].start - onset <= chordTolerance { endIndex += 1 }
            let group = Array(sorted[index..<endIndex])
            index = endIndex
            guard onset.isFinite, group.allSatisfy({ (0...127).contains($0.pitch) && $0.end.isFinite }) else {
                unsupported.formUnion(group.map(\.id))
                continue
            }
            let byPitch = Dictionary(grouping: group, by: \.pitch)
            let pitches = byPitch.keys.sorted()
            let pitchNotes = pitches.map { PitchNotes(pitch: $0, notes: byPitch[$0]!) }
            guard pitches.count <= 5, pitches.last! - pitches.first! <= maximumSpan else {
                unsupported.formUnion(group.map(\.id))
                continue
            }
            let choices = fingerChoices(count: pitches.count, hand: hand)
            var candidates: [StateKey: Candidate] = [:]
            var order = 0
            for state in beam {
                let held = state.held.filter { $0.end > onset + 0.001 }
                for choice in choices {
                    defer { order += 1 }
                    guard let newHeld = mergeHeld(held, pitchNotes: pitchNotes, fingers: choice, hand: hand) else { continue }
                    let anchor = zip(pitches, choice).map { keyPosition($0.0) - fingerOffset($0.1, hand: hand) }
                        .reduce(0, +) / Double(pitches.count)
                    let posture = Posture(pitches: pitches, fingers: choice, anchor: anchor,
                                          start: onset, end: group.map(\.end).max() ?? onset)
                    let cost = state.cost + postureCost(posture, hand: hand)
                        + transitionCost(from: state.posture, to: posture, hand: hand)
                    let entries = zip(pitchNotes, choice).flatMap { item, finger in
                        item.notes.map { (id: $0.id, finger: finger) }
                    }
                    let candidate = Candidate(cost: cost, held: newHeld, posture: posture,
                                              previous: state.trace, entries: entries, order: order)
                    let key = StateKey(held: newHeld, fingers: choice)
                    if candidates[key] == nil || cost < candidates[key]!.cost { candidates[key] = candidate }
                }
            }
            let best = candidates.values.sorted {
                $0.cost == $1.cost ? $0.order < $1.order : $0.cost < $1.cost
            }.prefix(beamWidth)
            guard !best.isEmpty else {
                unsupported.formUnion(group.map(\.id))
                continue
            }
            beam = best.map { candidate in
                let traceIndex = traces.count
                traces.append(Trace(previous: candidate.previous, entries: candidate.entries))
                return State(cost: candidate.cost, held: candidate.held, posture: candidate.posture, trace: traceIndex)
            }
        }
        var fingers: [Int: Int] = [:]
        var trace = beam.first?.trace
        while let traceIndex = trace {
            for entry in traces[traceIndex].entries { fingers[entry.id] = entry.finger }
            trace = traces[traceIndex].previous
        }
        return FingeringGenerationResult(fingers: fingers, unsupportedNoteIDs: unsupported)
    }

    private static func fingerChoices(count: Int, hand: PianoHand) -> [[Int]] {
        var choices: [[Int]] = []
        func appendChoices(_ prefix: [Int], next: Int) {
            if prefix.count == count {
                choices.append(hand == .right ? prefix : prefix.reversed())
                return
            }
            let last = 5 - (count - prefix.count) + 1
            guard next <= last else { return }
            for finger in next...last { appendChoices(prefix + [finger], next: finger + 1) }
        }
        appendChoices([], next: 1)
        return choices
    }

    private static func mergeHeld(_ held: [Held], pitchNotes: [PitchNotes], fingers: [Int], hand: PianoHand) -> [Held]? {
        var merged = held
        for (item, finger) in zip(pitchNotes, fingers) {
            if held.contains(where: { ($0.finger == finger && $0.pitch != item.pitch) || ($0.pitch == item.pitch && $0.finger != finger) }) {
                return nil
            }
            merged.removeAll { $0.pitch == item.pitch }
            merged.append(Held(pitch: item.pitch, finger: finger, end: item.end))
        }
        merged.sort { $0.pitch < $1.pitch }
        guard merged.count <= 5, merged.last!.pitch - merged.first!.pitch <= maximumSpan else { return nil }
        for lowerIndex in merged.indices {
            for upperIndex in (lowerIndex + 1)..<merged.count {
                let lower = merged[lowerIndex]
                let upper = merged[upperIndex]
                let pitchGap = upper.pitch - lower.pitch
                let fingersInOrder = hand == .right ? upper.finger > lower.finger : upper.finger < lower.finger
                let involvesThumb = lower.finger == 1 || upper.finger == 1
                if !fingersInOrder {
                    // A thumb pass can briefly overlap the previous note during
                    // legato. Onset chords themselves remain ordered by
                    // fingerChoices; only fingers held from another onset can
                    // cross here. Limit the reach and avoid tucking past finger 5.
                    let otherFinger = lower.finger == 1 ? upper.finger : lower.finger
                    guard involvesThumb, (2...4).contains(otherFinger), pitchGap <= 4 else { return nil }
                } else {
                    let fingerGap = abs(upper.finger - lower.finger)
                    let permitted = [0, involvesThumb ? 7 : 5, 9, 11, 12][fingerGap]
                    guard pitchGap <= permitted else { return nil }
                }
            }
        }
        return merged
    }

    private static func postureCost(_ posture: Posture, hand: PianoHand) -> Double {
        zip(posture.pitches, posture.fingers).reduce(0) { cost, item in
            let (pitch, finger) = item
            let displacement = keyPosition(pitch) - fingerOffset(finger, hand: hand) - posture.anchor
            let blackKeyCost = isBlack(pitch) ? (finger == 1 ? 0.9 : finger == 5 ? 0.2 : 0) : 0
            let weakFingerCost = finger == 4 ? 0.08 : 0
            return cost + displacement * displacement * 0.3 + blackKeyCost + weakFingerCost
        }
    }

    private static func transitionCost(from previous: Posture?, to next: Posture, hand: PianoHand) -> Double {
        guard let previous else { return 0 }
        let movement = abs(next.anchor - previous.anchor)
        // A phrase break permits a new hand position without a false legato requirement.
        if next.start - previous.end > 0.55 || next.start - previous.start > 2 {
            return movement * 0.04
        }
        var cost = movement * 0.45 + min(movement * movement, 100) * 0.06
        if previous.pitches.count == 1, next.pitches.count == 1 {
            let pitchDelta = next.pitches[0] - previous.pitches[0]
            let fingerDelta = (next.fingers[0] - previous.fingers[0]) * (hand == .right ? 1 : -1)
            if pitchDelta == 0 {
                if next.fingers[0] != previous.fingers[0] { cost += 0.65 }
            } else if fingerDelta == 0 {
                cost += abs(pitchDelta) <= 5 ? 1.8 : 0.5
            } else if pitchDelta * fingerDelta < 0 {
                let usesThumb = next.fingers[0] == 1 || previous.fingers[0] == 1
                cost += usesThumb ? 0.75 : (abs(pitchDelta) <= 5 ? 4 : 1)
            }
        }
        return cost
    }

    private static func fingerOffset(_ finger: Int, hand: PianoHand) -> Double {
        let offset = [0.0, 1.15, 2.15, 3.1, 4.0][finger - 1]
        return hand == .right ? offset : -offset
    }

    private static func keyPosition(_ pitch: Int) -> Double {
        let positions = [0.0, 0.5, 1, 1.5, 2, 3, 3.5, 4, 4.5, 5, 5.5, 6]
        return Double(pitch / 12 * 7) + positions[pitch % 12]
    }

    private static func isBlack(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitch % 12) }
}
