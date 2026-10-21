import Foundation

/// Resolves a fixed physical track and a real-time preview into score geometry.
/// Increasing playback rate changes the score horizon, not the reader's preview time.
public struct PianoRollTiming: Sendable, Equatable {
    public let lookAheadSeconds: Double
    public let playbackRate: Double
    public let horizonSeconds: Double
    public let speedMetersPerScoreSecond: Float
    public let lengthMeters: Float

    public init(settings: PianoDisplaySettings, playbackRate: Double) {
        let display = settings.validated()
        let rate = playbackRate.isFinite && playbackRate > 0 ? min(100, max(0.01, playbackRate)) : 1
        self.lookAheadSeconds = display.lookAheadSeconds
        self.playbackRate = rate
        self.horizonSeconds = display.lookAheadSeconds * rate
        self.lengthMeters = Float(display.rollLengthMeters)
        self.speedMetersPerScoreSecond = Float(display.rollLengthMeters / horizonSeconds)
    }

    /// Notes enter through the farthest 20% of the track, reaching zero opacity
    /// at the horizon. Strength changes the fade curve, never an abrupt edge floor.
    /// Use a note's onset offset so a long tail crossing the horizon stays readable.
    public func distanceOpacity(forScoreOffset offset: Double, settings: PianoDisplaySettings) -> Float {
        guard settings.fadesDistantNotes else { return 1 }
        guard offset.isFinite else { return 0 }
        let position = min(1, max(0, offset / horizonSeconds))
        let progress = min(1, max(0, (position - 0.8) / 0.2))
        let smooth = progress * progress * (3 - 2 * progress)
        let strength = settings.farFadeStrength.isFinite ? min(1, max(0, settings.farFadeStrength)) : 0.65
        return Float(pow(max(0, 1 - smooth), 0.25 + strength * 1.75))
    }
}

/// A flat note lies behind the keyboard, parallel to its top plane. Distances are
/// in metres in keyboard-local space; +Z points toward the pianist.
public struct PianoRollNoteGeometry: Sendable, Equatable {
    public let frontZ: Float
    public let centerZ: Float
    public let length: Float
    public let surfaceY: Float
    public let showsOnset: Bool
    /// Visible endpoint, which may be clipped by the horizon or a repeated pitch.
    public let tailZ: Float

    /// Decorations belong to the visible body/attack. A completely trimmed old
    /// tail must not leave its completion check on a later strike of this pitch.
    public var hasVisibleContent: Bool { length > 0.00001 || showsOnset }
}

public struct PianoRollGeometry: Sendable, Equatable {
    public let hitLineZ: Float
    public let surfaceY: Float

    public init(layout: KeyboardLayout, rearOffsetMeters: Double = 0.02, surfaceHeightMeters: Double = 0.018) {
        let rearOffset = rearOffsetMeters.isFinite ? max(0, rearOffsetMeters) : 0.02
        let height = surfaceHeightMeters.isFinite ? max(0, surfaceHeightMeters) : 0.018
        hitLineZ = -layout.whiteKeyDepth - Float(rearOffset)
        surfaceY = max(layout.blackKeyHeight + 0.003, Float(height))
    }

    /// Trim only the visible tail to separate repeated pitches. Neither score
    /// duration nor MIDI matching time is changed. An onset marker remains even
    /// when a very short note has no room for a body after visual separation.
    public func note(
        _ note: PianoNote,
        at songTime: Double,
        speed: Float,
        horizon: Double = 5,
        gapMillimeters: Double = 3,
        nextSamePitchStart: Double? = nil,
        isWaitingTarget: Bool = false
    ) -> PianoRollNoteGeometry? {
        guard songTime.isFinite, note.start.isFinite, note.end.isFinite,
              speed.isFinite, speed > 0, horizon.isFinite, horizon > 0,
              note.start <= songTime + horizon,
              note.end > songTime || isWaitingTarget else { return nil }
        let gap = gapMillimeters.isFinite ? max(0, gapMillimeters) / 1000 : 0.003
        let front = max(0, Float(note.start - songTime) * speed)
        let scoreTail = max(0, Float(note.end - songTime) * speed)
        var tail = min(Float(horizon) * speed, scoreTail)
        if note.duration == 0 || isWaitingTarget {
            tail = max(tail, front + 0.004)
        }
        if let next = nextSamePitchStart, next.isFinite, next > note.start {
            let limit = max(front, Float(next - songTime) * speed - Float(gap))
            tail = min(tail, limit)
        }
        tail = max(front, tail)
        return PianoRollNoteGeometry(
            frontZ: hitLineZ - front,
            centerZ: hitLineZ - (front + tail) / 2,
            length: tail - front,
            surfaceY: surfaceY,
            showsOnset: isWaitingTarget || note.start >= songTime,
            tailZ: hitLineZ - tail
        )
    }

    /// Duplicate pitches at the same score onset share the following distinct
    /// onset. Filter disabled tracks before calling this to avoid trimming to
    /// notes that the user is not currently displaying.
    public static func nextOnsets(for notes: [PianoNote]) -> [Int: Double] {
        let sorted = notes.filter { $0.start.isFinite }.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        var current: [Int: Double] = [:]
        var following: [Int: Double] = [:]
        var result: [Int: Double] = [:]
        for note in sorted.reversed() {
            if current[note.pitch] != note.start {
                following[note.pitch] = current[note.pitch]
                current[note.pitch] = note.start
            }
            if let next = following[note.pitch] { result[note.id] = next }
        }
        return result
    }
}
