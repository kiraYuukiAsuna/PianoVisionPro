import Foundation

public enum WaitInputDisposition: String, Sendable {
    case accepted, completed, wrong, ignored
}

public enum WaitInputTolerance: String, Codable, Sendable, CaseIterable {
    case strict, relaxed
}

public struct WaitInputResult: Sendable {
    public let disposition: WaitInputDisposition
    /// Completed notes, independently of this input's disposition. A callback may
    /// settle an earlier chord and then accept, reject, or complete a new onset.
    /// Contains one representative per pitch within each completed score group.
    public let completedNotes: [PianoNote]
    public let groupTime: Double?
    /// Scheduled host onset, retained when waiting freezes the score clock.
    public let targetHostTime: Double?

    public init(disposition: WaitInputDisposition, completedNotes: [PianoNote], groupTime: Double?, targetHostTime: Double? = nil) {
        self.disposition = disposition
        self.completedNotes = completedNotes
        self.groupTime = groupTime
        self.targetHostTime = targetHostTime
    }

    public var completedNoteIDs: Set<Int> { Set(completedNotes.map(\.id)) }
    public var completedPitches: Set<Int> { Set(completedNotes.map(\.pitch)) }
}

/// A musical clock gated by fresh MIDI note onsets. Strict chords require keys
/// to remain held; relaxed current chords accumulate played pitches for arpeggios.
///
/// MIDI timestamps must already be converted into the receiver's monotonic host
/// clock. `receivedAt` advances playback; source timestamps measure chord spread.
/// Supplying physical key state (without sustain) also handles duplicate pitches
/// arriving on several MIDI channels.
public struct WaitModeEngine: Sendable {
    private struct Group: Sendable {
        let start: Double
        let notes: [PianoNote]
        let allNoteIDs: Set<Int>
        let noteIDsByPitch: [Int: Set<Int>]
        var pitches: Set<Int> { Set(notes.map(\.pitch)) }
    }

    private let groups: [Group]
    public let songDuration: Double
    public private(set) var earlyInputWindow: Double
    public let inputTolerance: WaitInputTolerance
    public private(set) var chordWindow: Double
    public private(set) var isEnabled: Bool
    /// Playback intent remains true while the musical clock waits for a chord.
    public private(set) var isRunning = false
    public private(set) var isWaiting = false
    public private(set) var needsRetry = false
    public private(set) var completedGroupCount = 0
    public private(set) var completedNoteIDs: Set<Int> = []

    private var clock: PlaybackClock
    private var groupIndex = 0
    private var heldPitches: Set<Int> = []
    private var onsets: [Int: Double] = [:]
    /// A promoted future onset was valid only if its key remained down until
    /// this host time. Keep provenance until its first physical release arrives.
    private var promotedAt: [Int: Double] = [:]
    /// Each fresh onset belongs to at most one future group. Holding a pitch
    /// never copies that onset into another group when the score advances.
    private var futureOnsets: [Int: [Int: Double]] = [:]
    private var inputEpoch: Double
    private var epochIsExclusive = false
    private var latestSourceTimestamp: Double?
    private var groupDueAt: Double?

    public var rate: Double { clock.rate }
    public var requiredPitches: Set<Int> { currentGroup?.pitches ?? [] }
    public var matchedPitches: Set<Int> { needsRetry ? [] : candidatePitches }
    public var targetTime: Double? { currentGroup?.start }
    public var currentGroupNoteIDs: Set<Int> { currentGroup?.allNoteIDs ?? [] }
    /// Presentation look-ahead uses the exact same anchored score groups as the
    /// gate, including score aliases and slightly humanized chord members.
    public var nextTargetTime: Double? { nextGroup?.start }
    public var nextGroupNoteIDs: Set<Int> { nextGroup?.allNoteIDs ?? [] }
    public var nextRequiredPitches: Set<Int> { nextGroup?.pitches ?? [] }
    /// Resolve an input result back to its exact score aliases without copying
    /// the gate's grouping policy into a renderer or session model.
    public func noteIDs(inGroupAt start: Double, pitch: Int) -> Set<Int> {
        guard start.isFinite else { return [] }
        var low = 0
        var high = groups.count
        while low < high {
            let middle = (low + high) / 2
            if groups[middle].start < start { low = middle + 1 } else { high = middle }
        }
        guard low < groups.count, groups[low].start == start else { return [] }
        return groups[low].noteIDsByPitch[pitch] ?? []
    }
    /// Exact score identities for current progress and still-held future input.
    /// Completed targets are exposed separately by `completedNoteIDs`.
    public var matchedNoteIDs: Set<Int> {
        var result: Set<Int> = []
        if let group = currentGroup {
            for pitch in matchedPitches { result.formUnion(group.noteIDsByPitch[pitch] ?? []) }
        }
        for (index, candidates) in futureOnsets where groups.indices.contains(index) {
            for pitch in candidates.keys where heldPitches.contains(pitch) {
                result.formUnion(groups[index].noteIDsByPitch[pitch] ?? [])
            }
        }
        return result
    }

    public init(
        notes: [PianoNote],
        duration: Double? = nil,
        chordWindow: Double = 0.15,
        earlyInputWindow: Double? = nil,
        groupingTolerance: Double? = nil,
        inputTolerance: WaitInputTolerance = .strict,
        enabled: Bool = true,
        now: Double = ProcessInfo.processInfo.systemUptime
    ) {
        let validNotes = notes.filter { $0.start.isFinite && $0.start >= 0 && (0...127).contains($0.pitch) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        let tolerance = groupingTolerance.map { $0.isFinite ? max(0, $0) : 0 }
            ?? (inputTolerance == .relaxed ? 0.03 : 0)
        let automaticallyGroup = groupingTolerance == nil && inputTolerance == .relaxed
        var grouped: [[PianoNote]] = []
        for note in validNotes {
            // Anchor to the first onset. Pairwise chaining would absorb arpeggios.
            if let members = grouped.last, let first = members.first,
               note.start - first.start <= tolerance + (tolerance > 0 ? 0.000000001 : 0),
               !automaticallyGroup || note.start == first.start
                || (note.duration > 0
                    && !members.contains(where: { $0.pitch == note.pitch && $0.track == note.track && $0.channel == note.channel })
                    && members.allSatisfy { $0.end > note.start }) {
                grouped[grouped.count - 1].append(note)
            } else {
                grouped.append([note])
            }
        }
        groups = grouped.map { notes in
            var pitches: Set<Int> = []
            let representatives = notes.filter { pitches.insert($0.pitch).inserted }
            var idsByPitch: [Int: Set<Int>] = [:]
            for note in notes { idsByPitch[note.pitch, default: []].insert(note.id) }
            return Group(start: notes[0].start, notes: representatives, allNoteIDs: Set(notes.map(\.id)),
                         noteIDsByPitch: idsByPitch)
        }
        songDuration = max(
            duration.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0,
            validNotes.map { $0.end.isFinite ? $0.end : $0.start }.max() ?? 0
        )
        self.chordWindow = Self.validatedWindow(chordWindow)
        self.inputTolerance = inputTolerance
        let early = earlyInputWindow ?? (inputTolerance == .relaxed ? 0.8 : 0.15)
        self.earlyInputWindow = Self.validatedEarlyWindow(early, inputTolerance: inputTolerance)
        isEnabled = enabled
        let host = now.isFinite ? now : ProcessInfo.processInfo.systemUptime
        clock = PlaybackClock(now: host)
        inputEpoch = host
    }

    /// Clamp before every render, including frames arriving before `update`.
    public func position(at hostTime: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        let time = min(songDuration, clock.position(at: hostTime))
        guard isEnabled, let group = currentGroup else { return time }
        return min(time, group.start)
    }

    public mutating func play(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite, !isRunning,
              position(at: hostTime) < songDuration || (isEnabled && currentGroup != nil) else { return }
        clearAttempt(at: hostTime)
        isRunning = true
        clock.play(at: hostTime)
        scheduleCurrentGroup(at: hostTime)
        _ = synchronize(at: hostTime)
    }

    public mutating func pause(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite else { return }
        let time = position(at: hostTime)
        clock.pause(at: hostTime)
        clock.seek(to: time, at: hostTime)
        isRunning = false
        isWaiting = false
        groupDueAt = nil
        clearAttempt(at: hostTime)
    }

    public mutating func seek(to songTime: Double, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard songTime.isFinite, hostTime.isFinite else { return }
        let time = min(songDuration, max(0, songTime))
        clock.seek(to: time, at: hostTime)
        groupIndex = groups.firstIndex { $0.start >= time } ?? groups.count
        completedGroupCount = 0
        completedNoteIDs.removeAll()
        clearAttempt(at: hostTime)
        isWaiting = false
        if isRunning { clock.play(at: hostTime) }
        scheduleCurrentGroup(at: hostTime)
        _ = synchronize(at: hostTime)
    }

    public mutating func setRate(_ rate: Double, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard rate.isFinite, rate > 0, hostTime.isFinite else { return }
        let time = position(at: hostTime)
        clock.seek(to: time, at: hostTime)
        clock.setRate(rate, at: hostTime)
        clearAttempt(at: hostTime)
        scheduleCurrentGroup(at: hostTime)
        _ = synchronize(at: hostTime)
    }

    public mutating func setChordWindow(_ seconds: Double, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite else { return }
        chordWindow = Self.validatedWindow(seconds)
        clearAttempt(at: hostTime)
    }

    /// Changes target-alignment allowance without moving playback or clearing
    /// completed targets. Previous physical attempts must be played again.
    public mutating func setEarlyInputWindow(_ seconds: Double, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite else { return }
        earlyInputWindow = Self.validatedEarlyWindow(seconds, inputTolerance: inputTolerance)
        clearAttempt(at: hostTime)
    }

    public mutating func setEnabled(_ enabled: Bool, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite, enabled != isEnabled else { return }
        let time = position(at: hostTime)
        clock.seek(to: time, at: hostTime)
        isEnabled = enabled
        clearAttempt(at: hostTime)
        isWaiting = false
        if enabled { groupIndex = groups.firstIndex { $0.start >= time } ?? groups.count }
        if isRunning { clock.play(at: hostTime) }
        scheduleCurrentGroup(at: hostTime)
        _ = synchronize(at: hostTime)
    }

    /// Call on disconnect, source change, or input reset. For channel-scoped
    /// resets, retain keys still physically held on the remaining channels.
    public mutating func resetInput(
        at hostTime: Double = ProcessInfo.processInfo.systemUptime,
        pressedPitches: Set<Int> = []
    ) {
        guard hostTime.isFinite else { return }
        heldPitches = pressedPitches
        clearAttempt(at: hostTime)
    }

    /// A frame update may complete a chord collected just before its musical onset.
    @discardableResult
    public mutating func update(at hostTime: Double = ProcessInfo.processInfo.systemUptime) -> WaitInputResult? {
        guard hostTime.isFinite else { return nil }
        let result = settleCompletions(at: hostTime)
        if inputTolerance == .strict, !hasCompleteChord,
           let first = onsets.values.min(), hostTime - first > chordWindow + 0.000000001 {
            needsRetry = true
        }
        return result
    }

    @discardableResult
    public mutating func noteOn(
        pitch: Int,
        timestamp: Double,
        receivedAt: Double,
        pressedPitches: Set<Int>
    ) -> WaitInputResult {
        guard timestamp.isFinite, receivedAt.isFinite, (0...127).contains(pitch) else {
            return result(.ignored)
        }
        let wasHeld = heldPitches.contains(pitch)
        // Settle an already collected chord against the event's source time
        // before applying the physical transition. A NoteOff before the target
        // must invalidate it, while a transition after the target must preserve it.
        var completedBeforeInput = settleCompletions(at: min(timestamp, receivedAt))?.completedNotes ?? []
        heldPitches = pressedPitches
        completedBeforeInput += settleCompletions(at: receivedAt)?.completedNotes ?? []
        guard isEnabled, isRunning, currentGroup != nil,
              pressedPitches.contains(pitch), !wasHeld,
              // Midpoint Wi-Fi clock synchronization has bounded asymmetric
              // transport error. A strict 1ms limit rejects valid key presses.
              timestamp <= receivedAt + 0.05,
              epochIsExclusive ? timestamp > inputEpoch : timestamp >= inputEpoch else {
            return result(.ignored, completedNotes: completedBeforeInput)
        }
        // A better ping sample can adjust the remote clock mapping between two
        // adjacent MIDI events. Arrival order is already validated by PianoLink;
        // do not discard a physical onset for a small source-time regression.
        latestSourceTimestamp = max(latestSourceTimestamp ?? timestamp, timestamp)
        // Relaxed practice compares against the currently displayed timeline.
        // Its clock resumes on receipt, so using the older source time here
        // would reject real subsequent input merely for spending time in Wi-Fi.
        let earlyCheckTime = inputTolerance == .relaxed ? receivedAt : timestamp
        guard let due = groupDueAt, earlyCheckTime >= due - earlyInputWindow else {
            return result(.ignored, completedNotes: completedBeforeInput)
        }
        if !requiredPitches.contains(pitch) {
            guard inputTolerance == .relaxed,
                  let future = futureGroup(for: pitch, receivedAt: receivedAt) else {
                return result(.wrong, completedNotes: completedBeforeInput)
            }
            futureOnsets[future, default: [:]][pitch] = timestamp
            return WaitInputResult(disposition: .accepted, completedNotes: completedBeforeInput,
                                   groupTime: groups[future].start,
                                   targetHostTime: groupDueAt.map { $0 + (groups[future].start - (currentGroup?.start ?? groups[future].start)) / rate })
        }
        // Relaxed arpeggios retain the first accepted onset for this pitch.
        // Replaying it cannot increment progress or assign it to a future repeat.
        if inputTolerance == .relaxed, onsets[pitch] != nil {
            return result(.ignored, completedNotes: completedBeforeInput)
        }
        if inputTolerance == .strict, let first = onsets.values.min(), let last = onsets.values.max(),
           max(last, timestamp) - min(first, timestamp) > chordWindow + 0.000000001 {
            onsets.removeAll()
            needsRetry = true
        }
        onsets[pitch] = timestamp
        needsRetry = false
        if hasCompleteChord, position(at: receivedAt) >= currentGroup!.start {
            let completion = completeCurrentGroup(at: receivedAt)
            return WaitInputResult(disposition: completion.disposition,
                                   completedNotes: completedBeforeInput + completion.completedNotes,
                                   groupTime: completion.groupTime, targetHostTime: completion.targetHostTime)
        }
        return result(.accepted, completedNotes: completedBeforeInput)
    }

    @discardableResult
    public mutating func noteOff(
        pitch: Int,
        timestamp: Double,
        receivedAt: Double,
        pressedPitches: Set<Int>
    ) -> WaitInputResult? {
        guard timestamp.isFinite, receivedAt.isFinite else { return nil }
        let completion = settleCompletions(at: min(timestamp, receivedAt))
        heldPitches = pressedPitches
        if !pressedPitches.contains(pitch) {
            if inputTolerance == .strict { onsets.removeValue(forKey: pitch) }
            else if let enteredAt = promotedAt.removeValue(forKey: pitch), timestamp < enteredAt {
                // The frame promoted this key before its earlier source-time
                // release reached us. It had not remained held until this group.
                onsets.removeValue(forKey: pitch)
            }
            for index in Array(futureOnsets.keys) {
                futureOnsets[index]?.removeValue(forKey: pitch)
                if futureOnsets[index]?.isEmpty == true { futureOnsets.removeValue(forKey: index) }
            }
        }
        let later = settleCompletions(at: receivedAt)
        guard completion != nil || later != nil else { return nil }
        return WaitInputResult(disposition: .completed,
                               completedNotes: (completion?.completedNotes ?? []) + (later?.completedNotes ?? []),
                               groupTime: later?.groupTime ?? completion?.groupTime)
    }

    private var currentGroup: Group? { groupIndex < groups.count ? groups[groupIndex] : nil }
    private var nextGroup: Group? { groupIndex + 1 < groups.count ? groups[groupIndex + 1] : nil }
    private var candidatePitches: Set<Int> {
        let accepted = Set(onsets.keys)
        return inputTolerance == .relaxed ? accepted : accepted.intersection(heldPitches)
    }
    private var hasCompleteChord: Bool {
        guard !requiredPitches.isEmpty, requiredPitches.isSubset(of: candidatePitches),
              let first = onsets.values.min(), let last = onsets.values.max() else { return false }
        return inputTolerance == .relaxed || last - first <= chordWindow + 0.000000001
    }

    private func futureGroup(for pitch: Int, receivedAt: Double) -> Int? {
        guard let current = currentGroup, let due = groupDueAt else { return nil }
        let musicalLimit = position(at: receivedAt) + earlyInputWindow * rate
        for index in (groupIndex + 1)..<groups.count {
            let group = groups[index]
            if group.start > musicalLimit + 0.000000001 { break }
            guard group.pitches.contains(pitch) else { continue }
            let predictedDue = due + (group.start - current.start) / rate
            guard receivedAt >= predictedDue - earlyInputWindow else { return nil }
            return index
        }
        return nil
    }

    /// Drain already satisfied, due groups before applying the next physical
    /// transition. This makes a late frame and a NoteOff observe the same history.
    private mutating func settleCompletions(at hostTime: Double) -> WaitInputResult? {
        var notes: [PianoNote] = []
        var lastTime: Double?
        while let completion = synchronize(at: hostTime) {
            notes += completion.completedNotes
            lastTime = completion.groupTime
        }
        guard !notes.isEmpty else { return nil }
        return WaitInputResult(disposition: .completed, completedNotes: notes, groupTime: lastTime)
    }

    private mutating func synchronize(at hostTime: Double) -> WaitInputResult? {
        guard isRunning else { return nil }
        if isEnabled, let group = currentGroup, clock.position(at: hostTime) >= group.start {
            clock.pause(at: hostTime)
            clock.seek(to: group.start, at: hostTime)
            isWaiting = true
            if hasCompleteChord {
                // These notes were already collected before their target. Their
                // musical completion is the target time, independent of which
                // frame or later input first observes it.
                return completeCurrentGroup(at: groupDueAt ?? hostTime)
            }
        } else if position(at: hostTime) >= songDuration {
            clock.pause(at: hostTime)
            clock.seek(to: songDuration, at: hostTime)
            isRunning = false
            isWaiting = false
        }
        return nil
    }

    private mutating func completeCurrentGroup(at hostTime: Double) -> WaitInputResult {
        let group = currentGroup!
        let completion = WaitInputResult(disposition: .completed, completedNotes: group.notes,
                                         groupTime: group.start, targetHostTime: groupDueAt)
        completedGroupCount += 1
        completedNoteIDs.formUnion(group.allNoteIDs)
        groupIndex += 1
        clock.seek(to: group.start, at: hostTime)
        clock.play(at: hostTime)
        // Keep relaxed source validation anchored to the last explicit control
        // point. Wi-Fi clock estimates can regress between otherwise ordered,
        // fresh MIDI events; a completed group's timestamp is not a safe cutoff.
        // Fresh physical transitions and single-use assignments prevent reuse.
        let completedSourceEpoch = inputTolerance == .relaxed
            ? inputEpoch
            : max(hostTime, latestSourceTimestamp ?? hostTime)
        clearAttempt(at: hostTime, preservingFutureOnsets: inputTolerance == .relaxed)
        // Strict practice also rejects input buffered before the previous gate.
        // Both policies keep play/seek/reset boundaries as hard lower limits.
        inputEpoch = completedSourceEpoch
        epochIsExclusive = inputTolerance == .strict
        if inputTolerance == .relaxed {
            onsets = (futureOnsets.removeValue(forKey: groupIndex) ?? [:]).filter { heldPitches.contains($0.key) }
            promotedAt = Dictionary(uniqueKeysWithValues: onsets.keys.map { ($0, hostTime) })
        }
        isWaiting = false
        scheduleCurrentGroup(at: hostTime)
        return completion
    }

    private mutating func scheduleCurrentGroup(at hostTime: Double) {
        guard isRunning, isEnabled, let group = currentGroup else { groupDueAt = nil; return }
        groupDueAt = hostTime + max(0, group.start - clock.position(at: hostTime)) / rate
    }

    private mutating func clearAttempt(at hostTime: Double, preservingFutureOnsets: Bool = false) {
        onsets.removeAll()
        promotedAt.removeAll()
        if !preservingFutureOnsets { futureOnsets.removeAll() }
        needsRetry = false
        inputEpoch = hostTime
        epochIsExclusive = false
        latestSourceTimestamp = nil
    }

    private func result(_ disposition: WaitInputDisposition, completedNotes: [PianoNote] = []) -> WaitInputResult {
        WaitInputResult(disposition: disposition, completedNotes: completedNotes,
                        groupTime: currentGroup?.start, targetHostTime: groupDueAt)
    }

    private static func validatedWindow(_ seconds: Double) -> Double {
        seconds.isFinite ? min(2, max(0.05, seconds)) : 0.15
    }

    private static func validatedEarlyWindow(_ seconds: Double, inputTolerance: WaitInputTolerance) -> Double {
        seconds.isFinite ? min(2, max(0.05, seconds)) : (inputTolerance == .relaxed ? 0.8 : 0.15)
    }
}
