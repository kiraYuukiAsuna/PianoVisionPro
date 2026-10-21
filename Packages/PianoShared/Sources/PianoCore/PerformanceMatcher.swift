import Foundation

public enum MatchJudgement: String, Codable, Sendable {
    case hit, early, late, wrong, missed, ignored
}

public struct MatchResult: Codable, Sendable, Hashable {
    public let noteID: Int?
    public let pitch: Int
    public let judgement: MatchJudgement
    /// Performed song time minus the target start; negative values are early.
    public let timingError: Double?
    public let targetTime: Double?
    public let performedTime: Double
    /// The target was provisionally missed before this timestamp-corrected input arrived.
    /// Consumers should remove one previous miss when applying this successful result.
    public let recoveredMiss: Bool
    public var isMatched: Bool { judgement == .hit || judgement == .early || judgement == .late }

    public init(noteID: Int?, pitch: Int, judgement: MatchJudgement, timingError: Double?, targetTime: Double?, performedTime: Double, recoveredMiss: Bool = false) {
        self.noteID = noteID
        self.pitch = pitch
        self.judgement = judgement
        self.timingError = timingError
        self.targetTime = targetTime
        self.performedTime = performedTime
        self.recoveredMiss = recoveredMiss
    }
}

/// A pitch-specific, one-to-one onset matcher. Chord notes are independent targets.
/// Reset at a seek or loop boundary; timestamps passed here are in song seconds.
public struct PerformanceMatcher: Sendable {
    public private(set) var earlyTolerance: Double
    public private(set) var lateTolerance: Double
    public let onTimeTolerance: Double
    private let notes: [PianoNote]
    private let indicesByPitch: [Int: [Int]]
    private var resolved: Set<Int> = []
    private var missedIndices: Set<Int> = []
    private var missCursor = 0
    public private(set) var matchedNoteIDs: Set<Int> = []
    public private(set) var missedNoteIDs: Set<Int> = []

    public init(notes: [PianoNote], earlyTolerance: Double = 0.2, lateTolerance: Double = 0.25, onTimeTolerance: Double = 0.075) {
        self.notes = notes.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
        self.earlyTolerance = earlyTolerance.isFinite ? max(0, earlyTolerance) : 0.2
        self.lateTolerance = lateTolerance.isFinite ? max(0, lateTolerance) : 0.25
        self.onTimeTolerance = onTimeTolerance.isFinite ? max(0, onTimeTolerance) : 0.075
        var byPitch: [Int: [Int]] = [:]
        for (index, note) in self.notes.enumerated() {
            byPitch[note.pitch, default: []].append(index)
        }
        indicesByPitch = byPitch
    }

    public mutating func noteOn(pitch: Int, velocity: Int = 100, channel: Int = 0, songTime: Double) -> MatchResult {
        guard velocity > 0, songTime.isFinite, (0...127).contains(pitch), (0...15).contains(channel) else {
            return result(pitch: pitch, judgement: .ignored, time: songTime)
        }
        let candidates = indicesByPitch[pitch] ?? []
        let earliest = songTime - lateTolerance
        let latest = songTime + earlyTolerance
        var lower = 0
        var upper = candidates.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if notes[candidates[mid]].start < earliest { lower = mid + 1 } else { upper = mid }
        }
        var best: Int?
        var bestError = Double.infinity
        for candidate in candidates.dropFirst(lower) {
            let note = notes[candidate]
            if note.start > latest { break }
            // Network delivery time can be later than the source event timestamp.
            // A provisional miss is recoverable, while a hit or skipped target is final.
            if resolved.contains(candidate), !missedIndices.contains(candidate) { continue }
            let error = abs(songTime - note.start)
            // The earlier target wins equally close repeated notes.
            if error < bestError { best = candidate; bestError = error }
        }
        guard let index = best else { return result(pitch: pitch, judgement: .wrong, time: songTime) }
        let note = notes[index]
        let error = songTime - note.start
        let judgement: MatchJudgement = error < -onTimeTolerance ? .early : (error > onTimeTolerance ? .late : .hit)
        let recoveredMiss = missedIndices.remove(index) != nil
        if recoveredMiss { missedNoteIDs.remove(note.id) }
        resolved.insert(index)
        matchedNoteIDs.insert(note.id)
        return MatchResult(noteID: note.id, pitch: pitch, judgement: judgement, timingError: error, targetTime: note.start, performedTime: songTime, recoveredMiss: recoveredMiss)
    }

    /// Updates acceptance in both directions without resetting scoring history.
    /// Nonfinite input uses an 800ms allowance; the 75ms hit classification stays
    /// independent of the wider accepted early/late timing window.
    public mutating func setTimingTolerance(_ seconds: Double) {
        let window = seconds.isFinite ? min(2, max(0.05, seconds)) : 0.8
        earlyTolerance = window
        lateTolerance = window
    }

    /// Emits each missed target once after its late window has fully passed.
    public mutating func advance(to songTime: Double) -> [MatchResult] {
        guard songTime.isFinite else { return [] }
        var results: [MatchResult] = []
        while missCursor < notes.count, notes[missCursor].start + lateTolerance < songTime {
            let index = missCursor
            missCursor += 1
            guard !resolved.contains(index) else { continue }
            let note = notes[index]
            resolved.insert(index)
            missedIndices.insert(index)
            missedNoteIDs.insert(note.id)
            results.append(MatchResult(noteID: note.id, pitch: note.pitch, judgement: .missed, timingError: nil, targetTime: note.start, performedTime: songTime))
        }
        return results
    }

    public mutating func reset(startingAt songTime: Double = 0) {
        resolved.removeAll()
        missedIndices.removeAll()
        matchedNoteIDs.removeAll()
        missedNoteIDs.removeAll()
        missCursor = 0
        guard songTime.isFinite else { return }
        // Targets before a user-selected seek point are skipped, not scored as mistakes.
        while missCursor < notes.count, notes[missCursor].start < songTime {
            resolved.insert(missCursor)
            missCursor += 1
        }
    }

    private func result(pitch: Int, judgement: MatchJudgement, time: Double) -> MatchResult {
        MatchResult(noteID: nil, pitch: pitch, judgement: judgement, timingError: nil, targetTime: nil, performedTime: time)
    }
}
