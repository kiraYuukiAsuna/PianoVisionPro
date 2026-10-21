import Foundation

/// A MIDI 1 channel event. Timestamps are monotonic system uptime, in seconds.
public struct LinkMIDIEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case noteOn, noteOff, controlChange, allNotesOff
    }

    public var kind: Kind
    public var note: Int
    public var velocity: Int
    public var channel: Int
    public var controller: Int
    public var value: Int
    public var timestamp: Double

    public init(kind: Kind, note: Int = 0, velocity: Int = 0, channel: Int = 0,
                controller: Int = 0, value: Int = 0,
                timestamp: Double = ProcessInfo.processInfo.systemUptime) {
        self.kind = kind
        self.note = note
        self.velocity = velocity
        self.channel = channel
        self.controller = controller
        self.value = value
        self.timestamp = timestamp
    }
}

struct LinkPacket: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello, event, reset, ping, pong
        case fileBegin, fileChunk, fileEnd, fileAck, fileResult, fileCancel
    }
    var kind: Kind
    var session: String
    var sequence: UInt64 = 0
    var event: LinkMIDIEvent? = nil
    var sentTime: Double? = nil
    var remoteTime: Double? = nil
    var peerName: String? = nil
    var file: LinkFilePayload? = nil
}

public struct BridgePeer: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

public struct BridgeService: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
