import Foundation

public enum SMFError: Error, Equatable, LocalizedError, Sendable {
    case invalidHeader
    case unsupportedFormat(Int)
    case unsupportedTimeDivision
    case invalidTrackCount
    case truncated
    case invalidVariableLengthQuantity
    case invalidRunningStatus
    case invalidStatus(UInt8)
    case invalidDataByte(UInt8)
    case invalidMetaEvent(UInt8)
    case invalidTempo
    case missingEndOfTrack
    case eventAfterEndOfTrack
    case tickOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "The file does not contain a valid Standard MIDI File header."
        case .unsupportedFormat(let format): "MIDI format \(format) is unsupported. Import a format 0 or format 1 file."
        case .unsupportedTimeDivision: "This MIDI file uses SMPTE time division. Export it with ticks per quarter note."
        case .invalidTrackCount: "The MIDI track count does not match its header."
        case .truncated: "The MIDI file ends before its declared data is complete."
        case .invalidVariableLengthQuantity: "The MIDI file contains an invalid variable-length value."
        case .invalidRunningStatus: "A MIDI event uses running status before a channel status was specified."
        case .invalidStatus(let status): "The MIDI file contains unsupported event status \(status)."
        case .invalidDataByte(let byte): "The MIDI file contains an invalid event data byte \(byte)."
        case .invalidMetaEvent(let type): "The MIDI file contains an invalid meta event \(type)."
        case .invalidTempo: "The MIDI file contains a zero or malformed tempo."
        case .missingEndOfTrack: "A MIDI track is missing its end-of-track event."
        case .eventAfterEndOfTrack: "A MIDI track contains data after its end-of-track event."
        case .tickOverflow: "The MIDI timeline is too long to represent."
        }
    }
}

/// A bounded SMF format 0/1 reader. All tracks share a tempo map in PPQN ticks.
/// Note durations represent key-down duration; sustain is retained for live feedback,
/// not baked into the imported note lengths.
public enum SMFParser {
    public static func parse(data: Data, title: String) throws -> PianoSong {
        var reader = ByteReader(Array(data))
        guard try reader.readID() == "MThd" else { throw SMFError.invalidHeader }
        let headerLength = Int(try reader.readUInt32())
        guard headerLength >= 6 else { throw SMFError.invalidHeader }
        var header = try reader.readSubreader(count: headerLength)
        let format = Int(try header.readUInt16())
        guard format == 0 || format == 1 else { throw SMFError.unsupportedFormat(format) }
        let trackCount = Int(try header.readUInt16())
        guard trackCount > 0, format != 0 || trackCount == 1 else { throw SMFError.invalidTrackCount }
        let division = try header.readUInt16()
        guard division & 0x8000 == 0, division != 0 else { throw SMFError.unsupportedTimeDivision }

        var rawNotes: [RawNote] = []
        var tempos: [Tempo] = []
        var signatures: [TimeSignature] = []
        var tracks: [SongTrack] = []
        var endTick: Int64 = 0
        var nextNoteID = 0
        var metaOrder = 0
        while reader.remaining > 0 {
            let chunkID = try reader.readID()
            let chunkLength = Int(try reader.readUInt32())
            var chunk = try reader.readSubreader(count: chunkLength)
            // SMF readers must tolerate extension chunks whose types they do not recognize.
            guard chunkID == "MTrk" else { continue }
            guard tracks.count < trackCount else { throw SMFError.invalidTrackCount }
            let trackIndex = tracks.count
            let parsed = try parseTrack(&chunk, index: trackIndex, nextNoteID: &nextNoteID, metaOrder: &metaOrder)
            tracks.append(SongTrack(id: trackIndex, name: parsed.name ?? "Track \(trackIndex + 1)"))
            rawNotes.append(contentsOf: parsed.notes)
            tempos.append(contentsOf: parsed.tempos)
            signatures.append(contentsOf: parsed.signatures)
            endTick = max(endTick, parsed.endTick)
        }
        guard tracks.count == trackCount else { throw SMFError.invalidTrackCount }
        let timeline = TempoTimeline(tempos: tempos, ticksPerQuarter: Double(division))
        let notes = rawNotes.map { raw in
            let start = timeline.seconds(at: raw.start)
            let end = timeline.seconds(at: raw.end)
            return PianoNote(id: raw.id, pitch: raw.pitch, start: start, duration: max(0, end - start), velocity: raw.velocity, track: raw.track, channel: raw.channel)
        }
        let duration = timeline.seconds(at: endTick)
        let grid = PianoBeatGrid(duration: duration, tempoChanges: tempos.sorted {
            $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick
        }.map {
            PianoTempoChange(quarterPosition: Double($0.tick) / Double(division), microsecondsPerQuarter: $0.microsecondsPerQuarter)
        }, timeSignatures: signatures.sorted {
            $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick
        }.map {
            PianoTimeSignature(quarterPosition: Double($0.tick) / Double(division), numerator: $0.numerator,
                               denominator: $0.denominator, clocksPerMetronomeClick: $0.clocks,
                               thirtySecondNotesPerQuarter: $0.thirtySeconds)
        })
        return PianoSong(title: title, notes: notes, duration: duration, tracks: tracks, beatGrid: grid)
    }

    private struct NoteKey: Hashable {
        let channel: Int
        let pitch: Int
    }

    private struct PendingNote {
        let id: Int
        let start: Int64
        let velocity: Int
    }

    private struct PendingQueue {
        var notes: [PendingNote] = []
        var next = 0

        mutating func popFirst() -> PendingNote? {
            guard next < notes.count else { return nil }
            defer { next += 1 }
            return notes[next]
        }
    }

    private struct RawNote {
        let id: Int
        let pitch: Int
        let start: Int64
        let end: Int64
        let velocity: Int
        let track: Int
        let channel: Int
    }

    private struct Tempo {
        let tick: Int64
        let microsecondsPerQuarter: Int
        let order: Int
    }

    private struct TimeSignature {
        let tick: Int64
        let numerator: Int
        let denominator: Int
        let clocks: Int
        let thirtySeconds: Int
        let order: Int
    }

    private struct ParsedTrack {
        var name: String?
        var notes: [RawNote] = []
        var tempos: [Tempo] = []
        var signatures: [TimeSignature] = []
        var endTick: Int64 = 0
    }

    private static func parseTrack(_ reader: inout ByteReader, index: Int, nextNoteID: inout Int, metaOrder: inout Int) throws -> ParsedTrack {
        var result = ParsedTrack()
        var pending: [NoteKey: PendingQueue] = [:]
        var tick: Int64 = 0
        var runningStatus: UInt8?
        var foundEnd = false
        while reader.remaining > 0 {
            let delta = Int64(try reader.readVLQ())
            let (newTick, overflow) = tick.addingReportingOverflow(delta)
            guard !overflow else { throw SMFError.tickOverflow }
            tick = newTick
            let first = try reader.readByte()
            let status: UInt8
            var initialData: UInt8?
            if first < 0x80 {
                guard let previous = runningStatus else { throw SMFError.invalidRunningStatus }
                status = previous
                initialData = first
            } else {
                status = first
            }

            switch status {
            case 0x80...0xEF:
                runningStatus = status
                let firstData = try initialData ?? reader.readDataByte()
                let command = status & 0xF0
                let secondData: UInt8 = command == 0xC0 || command == 0xD0 ? 0 : try reader.readDataByte()
                let channel = Int(status & 0x0F)
                if command == 0x90 && secondData > 0 {
                    let key = NoteKey(channel: channel, pitch: Int(firstData))
                    pending[key, default: PendingQueue()].notes.append(PendingNote(id: nextNoteID, start: tick, velocity: Int(secondData)))
                    nextNoteID += 1
                } else if command == 0x80 || (command == 0x90 && secondData == 0) {
                    let key = NoteKey(channel: channel, pitch: Int(firstData))
                    if let start = pending[key]?.popFirst() {
                        result.notes.append(RawNote(id: start.id, pitch: key.pitch, start: start.start, end: tick, velocity: start.velocity, track: index, channel: key.channel))
                    }
                } else if command == 0xB0 && (firstData == 120 || (123...127).contains(firstData)) {
                    // All Sound Off, All Notes Off, and mode changes release this
                    // channel's pending keys. Sustain does not extend key duration.
                    let keys = pending.keys.filter { $0.channel == channel }
                    for key in keys {
                        guard let queue = pending.removeValue(forKey: key) else { continue }
                        for start in queue.notes.dropFirst(queue.next) {
                            result.notes.append(RawNote(id: start.id, pitch: key.pitch, start: start.start, end: tick, velocity: start.velocity, track: index, channel: key.channel))
                        }
                    }
                }
            case 0xFF:
                runningStatus = nil
                let type = try reader.readByte()
                let count = Int(try reader.readVLQ())
                var payload = try reader.readSubreader(count: count)
                switch type {
                case 0x2F:
                    guard count == 0 else { throw SMFError.invalidMetaEvent(type) }
                    guard reader.remaining == 0 else { throw SMFError.eventAfterEndOfTrack }
                    foundEnd = true
                case 0x51:
                    guard count == 3 else { throw SMFError.invalidTempo }
                    let tempo = Int(try payload.readByte()) << 16 | Int(try payload.readByte()) << 8 | Int(try payload.readByte())
                    guard tempo > 0 else { throw SMFError.invalidTempo }
                    result.tempos.append(Tempo(tick: tick, microsecondsPerQuarter: tempo, order: metaOrder))
                    metaOrder += 1
                case 0x58:
                    guard count == 4 else { throw SMFError.invalidMetaEvent(type) }
                    let numerator = Int(try payload.readByte())
                    let exponent = Int(try payload.readByte())
                    let clocks = Int(try payload.readByte())
                    let thirtySeconds = Int(try payload.readByte())
                    guard numerator > 0, exponent <= 30, thirtySeconds > 0 else { throw SMFError.invalidMetaEvent(type) }
                    result.signatures.append(TimeSignature(tick: tick, numerator: numerator, denominator: 1 << exponent,
                                                           clocks: clocks, thirtySeconds: thirtySeconds, order: metaOrder))
                    metaOrder += 1
                case 0x03:
                    let nameBytes = payload.readRemaining()
                    let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1)
                    if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.name = name }
                default:
                    break
                }
            case 0xF0, 0xF7:
                runningStatus = nil
                let count = Int(try reader.readVLQ())
                _ = try reader.readSubreader(count: count)
            default:
                throw SMFError.invalidStatus(status)
            }
            if foundEnd { break }
        }
        guard foundEnd else { throw SMFError.missingEndOfTrack }
        // Some exports omit note-offs at the end. Close them at the track boundary.
        for (key, queue) in pending {
            for start in queue.notes.dropFirst(queue.next) {
                result.notes.append(RawNote(id: start.id, pitch: key.pitch, start: start.start, end: tick, velocity: start.velocity, track: index, channel: key.channel))
            }
        }
        result.endTick = tick
        return result
    }

    private struct TempoTimeline {
        private struct Segment {
            let tick: Int64
            let seconds: Double
            let secondsPerTick: Double
        }
        private let segments: [Segment]

        init(tempos: [Tempo], ticksPerQuarter: Double) {
            var built = [Segment(tick: 0, seconds: 0, secondsPerTick: 0.5 / ticksPerQuarter)]
            for tempo in tempos.sorted(by: { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }) {
                let previous = built[built.count - 1]
                let seconds = previous.seconds + Double(tempo.tick - previous.tick) * previous.secondsPerTick
                let segment = Segment(tick: tempo.tick, seconds: seconds, secondsPerTick: Double(tempo.microsecondsPerQuarter) / 1_000_000 / ticksPerQuarter)
                if previous.tick == tempo.tick { built[built.count - 1] = segment } else { built.append(segment) }
            }
            segments = built
        }

        func seconds(at tick: Int64) -> Double {
            var lower = 0
            var upper = segments.count
            while lower + 1 < upper {
                let mid = (lower + upper) / 2
                if segments[mid].tick <= tick { lower = mid } else { upper = mid }
            }
            let segment = segments[lower]
            return segment.seconds + Double(tick - segment.tick) * segment.secondsPerTick
        }
    }

    private struct ByteReader {
        private let bytes: [UInt8]
        private var offset: Int
        private let end: Int
        var remaining: Int { end - offset }

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            offset = 0
            end = bytes.count
        }

        private init(bytes: [UInt8], offset: Int, end: Int) {
            self.bytes = bytes
            self.offset = offset
            self.end = end
        }

        mutating func readByte() throws -> UInt8 {
            guard offset < end else { throw SMFError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func readDataByte() throws -> UInt8 {
            let byte = try readByte()
            guard byte < 0x80 else { throw SMFError.invalidDataByte(byte) }
            return byte
        }

        mutating func readUInt16() throws -> UInt16 {
            let high = UInt16(try readByte())
            return high << 8 | UInt16(try readByte())
        }

        mutating func readUInt32() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 { value = value << 8 | UInt32(try readByte()) }
            return value
        }

        mutating func readID() throws -> String {
            var id: [UInt8] = []
            for _ in 0..<4 { id.append(try readByte()) }
            return String(decoding: id, as: UTF8.self)
        }

        mutating func readVLQ() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = try readByte()
                value = value << 7 | UInt32(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw SMFError.invalidVariableLengthQuantity
        }

        mutating func readSubreader(count: Int) throws -> ByteReader {
            guard count >= 0, count <= remaining else { throw SMFError.truncated }
            let subreader = ByteReader(bytes: bytes, offset: offset, end: offset + count)
            offset += count
            return subreader
        }

        mutating func readRemaining() -> [UInt8] {
            defer { offset = end }
            return Array(bytes[offset..<end])
        }
    }
}
