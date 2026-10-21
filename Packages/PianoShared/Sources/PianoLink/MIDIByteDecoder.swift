import Foundation

/// Stateful MIDI 1 decoder: running status, split packets, and interleaved real-time bytes.
public struct MIDIByteDecoder: Sendable {
    private var runningStatus: UInt8?
    private var pending: [UInt8] = []
    private var messageTime = 0.0
    private var inSysEx = false
    private var systemBytesRemaining = 0

    public init() {}

    public mutating func decode(_ bytes: [UInt8], timestamp: Double) -> [LinkMIDIEvent] {
        var events: [LinkMIDIEvent] = []
        for byte in bytes {
            if byte >= 0xF8 { continue } // Real-time messages do not interrupt running status.
            if byte == 0xF7 { inSysEx = false; continue }
            if inSysEx { continue }
            if byte >= 0xF0 {
                runningStatus = nil; pending.removeAll(keepingCapacity: true)
                systemBytesRemaining = byte == 0xF2 ? 2 : ((byte == 0xF1 || byte == 0xF3) ? 1 : 0)
                if byte == 0xF0 { inSysEx = true }
                continue
            }
            if byte >= 0x80 {
                runningStatus = byte; pending.removeAll(keepingCapacity: true)
                systemBytesRemaining = 0; messageTime = timestamp
                continue
            }
            if systemBytesRemaining > 0 { systemBytesRemaining -= 1; continue }
            guard let status = runningStatus else { continue }
            if pending.isEmpty { messageTime = timestamp }
            pending.append(byte)
            let command = status & 0xF0
            let count = (command == 0xC0 || command == 0xD0) ? 1 : 2
            guard pending.count == count else { continue }
            let channel = Int(status & 0x0F)
            let first = Int(pending[0])
            let second = pending.count > 1 ? Int(pending[1]) : 0
            switch command {
            case 0x80:
                events.append(.init(kind: .noteOff, note: first, velocity: second, channel: channel, timestamp: messageTime))
            case 0x90:
                events.append(.init(kind: second == 0 ? .noteOff : .noteOn, note: first,
                                    velocity: second, channel: channel, timestamp: messageTime))
            case 0xB0:
                events.append(.init(kind: (first == 120 || first == 123) ? .allNotesOff : .controlChange,
                                    channel: channel, controller: first, value: second, timestamp: messageTime))
            default: break
            }
            pending.removeAll(keepingCapacity: true)
        }
        return events
    }
}
