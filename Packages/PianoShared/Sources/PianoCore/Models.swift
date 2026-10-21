import Foundation

/// Visual state belongs to a score note, not every future note sharing its pitch.
public enum PianoNoteFeedback: String, Equatable, Sendable {
    case normal, pressed, matched
}

public struct PianoNote: Identifiable, Codable, Sendable, Hashable {
    public let id: Int
    public let pitch: Int
    public let start: Double
    public let duration: Double
    public let velocity: Int
    public let track: Int
    public let channel: Int

    public var end: Double { start + duration }

    public init(id: Int, pitch: Int, start: Double, duration: Double, velocity: Int = 100, track: Int = 0, channel: Int = 0) {
        self.id = id
        self.pitch = pitch
        self.start = start
        self.duration = max(0, duration)
        self.velocity = velocity
        self.track = track
        self.channel = channel
    }
}

public struct SongTrack: Identifiable, Codable, Sendable, Hashable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct PianoSong: Codable, Sendable, Hashable {
    public let title: String
    public let notes: [PianoNote]
    public let duration: Double
    public let tracks: [SongTrack]
    public let beatGrid: PianoBeatGrid

    public init(title: String, notes: [PianoNote], duration: Double? = nil, tracks: [SongTrack] = [], beatGrid: PianoBeatGrid? = nil) {
        self.title = title
        self.notes = notes.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            return $0.id < $1.id
        }
        self.duration = max(duration ?? 0, notes.map(\.end).max() ?? 0)
        self.tracks = tracks
        self.beatGrid = beatGrid ?? PianoBeatGrid(duration: self.duration)
    }

    public func beats(in range: ClosedRange<Double>, limit: Int = 256) -> [PianoBeat] {
        beatGrid.beats(in: range, limit: limit)
    }

    private enum CodingKeys: String, CodingKey { case title, notes, duration, tracks, beatGrid }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: try values.decode(String.self, forKey: .title),
                  notes: try values.decode([PianoNote].self, forKey: .notes),
                  duration: try values.decodeIfPresent(Double.self, forKey: .duration),
                  tracks: try values.decodeIfPresent([SongTrack].self, forKey: .tracks) ?? [],
                  beatGrid: try values.decodeIfPresent(PianoBeatGrid.self, forKey: .beatGrid))
    }
}
