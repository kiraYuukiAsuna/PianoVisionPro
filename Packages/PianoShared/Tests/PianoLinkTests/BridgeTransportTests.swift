import Foundation
import Network
import Testing
@testable import PianoLink

private enum TransportVerificationError: Error { case timedOut(String) }

@MainActor
private func waitUntil(_ description: String, timeout: Double = 5, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            Issue.record("Timed out: \(description)")
            throw TransportVerificationError.timedOut(description)
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite(.serialized)
struct BridgeTransportTests {
    @Test @MainActor func orderedNoteOnOffsClockSyncResetAndReconnect() async throws {
        let server = BridgeServer()
        let client = BridgeClient()
        var events: [LinkMIDIEvent] = []
        var resetCount = 0
        client.onEvent = { events.append($0) }
        client.onReset = { resetCount += 1 }
        defer { client.disconnect(); server.stop() }
        server.start()
        try await waitUntil("server listening") { server.port != 0 }
        client.connect(host: "127.0.0.1", port: server.port)
        try await waitUntil("RTT synchronization") { client.isConnected && client.latencyMilliseconds != nil }
        let sent = ProcessInfo.processInfo.systemUptime
        for note in 0..<128 {
            server.send(.init(kind: .noteOn, note: note, velocity: 100, channel: note % 16))
            server.send(.init(kind: .noteOff, note: note, channel: note % 16))
        }
        try await waitUntil("256 ordered MIDI events") { events.count == 256 }
        for note in 0..<128 {
            #expect(events[note * 2].kind == .noteOn && events[note * 2].note == note)
            #expect(events[note * 2 + 1].kind == .noteOff && events[note * 2 + 1].note == note)
        }
        #expect(abs(events[0].timestamp - sent) < 0.2)
        #expect((client.latencyMilliseconds ?? .infinity) < 200)
        let beforeReset = resetCount
        server.reset()
        try await waitUntil("source reset") { resetCount == beforeReset + 1 }
        client.disconnect()
        #expect(resetCount == beforeReset + 2)
        server.send(.init(kind: .noteOn, note: 65, velocity: 90))
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.count == 256)
        client.connect(host: "127.0.0.1", port: server.port)
        try await waitUntil("reconnected with synchronized clock") { client.isConnected && client.latencyMilliseconds != nil }
        server.send(.init(kind: .noteOn, note: 67, velocity: 90))
        try await waitUntil("fresh event following reconnect") { events.count == 257 }
        #expect(events.last?.note == 67)
        let beforeStop = resetCount
        server.stop()
        try await waitUntil("server shutdown clears receiver state") { !client.isConnected && resetCount > beforeStop }
    }

    @Test @MainActor func fragmentedFramesClockOffsetSessionAndSequenceValidation() async throws {
        let fixture = try RawBridgeFixture(clockOffset: 600)
        let client = BridgeClient()
        var events: [LinkMIDIEvent] = []
        var resetCount = 0
        client.onEvent = { events.append($0) }
        client.onReset = { resetCount += 1 }
        defer { client.disconnect(); fixture.stop() }
        try await waitUntil("raw fixture listening") { fixture.port != 0 }
        client.connect(host: "127.0.0.1", port: fixture.port)
        try await waitUntil("raw fixture synchronized with +600 second clock") { client.latencyMilliseconds != nil }
        let sent = ProcessInfo.processInfo.systemUptime
        fixture.sendFragmented(.init(kind: .event, session: fixture.session, sequence: 1,
                                     event: .init(kind: .noteOn, note: 60, velocity: 100, timestamp: sent + 600)))
        fixture.send(.init(kind: .event, session: fixture.session, sequence: 1,
                           event: .init(kind: .noteOn, note: 61, velocity: 100, timestamp: sent + 600)))
        fixture.send(.init(kind: .event, session: "old-session", sequence: 2,
                           event: .init(kind: .noteOn, note: 62, velocity: 100, timestamp: sent + 600)))
        fixture.send(.init(kind: .event, session: fixture.session, sequence: 2,
                           event: .init(kind: .noteOff, note: 60, timestamp: sent + 600)))
        try await waitUntil("fragmented note on/off frames") { events.count == 2 }
        #expect(events.map(\.kind) == [.noteOn, .noteOff])
        #expect(events.map(\.note) == [60, 60])
        #expect(abs(events[0].timestamp - sent) < 0.15)
        let before = resetCount
        fixture.send(.init(kind: .event, session: fixture.session, sequence: 3,
                           event: .init(kind: .noteOn, note: 65, velocity: 100, timestamp: sent + 590)))
        try await waitUntil("stale event resets receiver instead of replaying") { resetCount > before }
        #expect(events.count == 2)
    }

    @Test @MainActor func heartbeatSilenceDisconnectsAndClearsKeys() async throws {
        let fixture = try RawBridgeFixture(respondToPings: false)
        let client = BridgeClient()
        var resetCount = 0
        client.onReset = { resetCount += 1 }
        defer { client.disconnect(); fixture.stop() }
        try await waitUntil("silent fixture listening") { fixture.port != 0 }
        client.connect(host: "127.0.0.1", port: fixture.port)
        try await waitUntil("connected to silent server") { client.isConnected }
        let before = resetCount
        try await waitUntil("heartbeat timeout", timeout: 11) { !client.isConnected }
        #expect(resetCount > before)
        #expect(client.status.contains("超时"))
    }
}

/// A peer with a deliberately different monotonic epoch and controllable framing.
@MainActor
private final class RawBridgeFixture {
    let session = UUID().uuidString
    private(set) var port: UInt16 = 0
    private var listener: NWListener
    private var pipe: LinkConnection?
    private let clockOffset: Double
    private let respondToPings: Bool

    init(clockOffset: Double = 0, respondToPings: Bool = true) throws {
        self.clockOffset = clockOffset; self.respondToPings = respondToPings
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .ready = state { self.port = self.listener.port?.rawValue ?? 0 }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async { self?.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "PianoLinkTests.listener"))
    }

    func stop() { pipe?.cancel(); pipe = nil; listener.cancel() }
    func send(_ packet: LinkPacket) { pipe?.send(packet) }

    func sendFragmented(_ packet: LinkPacket) {
        guard let connection = pipe?.connection, let payload = try? JSONEncoder().encode(packet) else { return }
        let count = UInt32(payload.count)
        let prefix = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                           UInt8((count >> 8) & 255), UInt8(count & 255)])
        connection.send(content: prefix.prefix(2), completion: .contentProcessed { _ in })
        connection.send(content: prefix.suffix(2), completion: .contentProcessed { _ in })
        connection.send(content: payload.prefix(7), completion: .contentProcessed { _ in })
        connection.send(content: payload.dropFirst(7), completion: .contentProcessed { _ in })
    }

    private func accept(_ connection: NWConnection) {
        let pipe = LinkConnection(connection: connection, onPacket: { [weak self] _, packet in
            DispatchQueue.main.async {
                guard let self, self.respondToPings, packet.kind == .ping else { return }
                self.send(.init(kind: .pong, session: self.session, sentTime: packet.sentTime,
                                remoteTime: ProcessInfo.processInfo.systemUptime + self.clockOffset))
            }
        }, onState: { [weak self] _, _, ready in
            DispatchQueue.main.async {
                guard let self, ready else { return }
                self.send(.init(kind: .hello, session: self.session))
            }
        })
        self.pipe = pipe
        pipe.start()
    }
}
