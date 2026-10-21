import Foundation
import Network
import Observation
import Testing
@testable import PianoLink

private enum FileTestError: Error { case timeout, invalidSong }
@MainActor private final class SaveGate { var allowed = false }

/// Cancel synchronously on a progress write, between the previous chunk's ACK
/// and registration of the following step's cancellation handler.
@MainActor private final class ChunkCancellationProbe {
    private let server: BridgeServer
    private(set) var progressWrites = 0

    init(server: BridgeServer) { self.server = server }

    func arm() {
        withObservationTracking {
            _ = server.fileTransferProgress
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progressWrites += 1
                if self.progressWrites < 2 { self.arm() }
                else { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
    }
}

@MainActor private func awaitFileCondition(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw FileTestError.timeout }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor private func connectFilePeers(_ server: BridgeServer, _ client: BridgeClient) async throws -> UUID {
    server.start()
    try await awaitFileCondition { server.port != 0 }
    client.connect(host: "127.0.0.1", port: server.port)
    try await awaitFileCondition { client.latencyMilliseconds != nil && server.connectedClients.count == 1 }
    return server.connectedClients[0].id
}

@Suite(.serialized)
struct MIDIFileTransferTests {
    @Test @MainActor func multiChunkRoundTripKeepsMIDIFlowingAndWaitsForSavedReceipt() async throws {
        let server = BridgeServer()
        let client = BridgeClient()
        var received: LinkMIDIFile?
        let saveGate = SaveGate()
        var events: [LinkMIDIEvent] = []
        var midiDuringChunks = false
        client.onMIDIFile = { file in
            received = file
            while !saveGate.allowed { try await Task.sleep(for: .milliseconds(2)) }
        }
        client.onEvent = { event in
            events.append(event)
            if client.fileTransferProgress > 0 && client.fileTransferProgress < 1 { midiDuringChunks = true }
        }
        defer { client.disconnect(); server.stop() }
        let peer = try await connectFilePeers(server, client)
        let bytes = Data((0..<2_000_003).map { UInt8($0 % 251) })
        let file = LinkMIDIFile(title: "练习曲", data: bytes)
        let sending = Task { try await server.sendMIDIFile(file, to: peer) }
        try await awaitFileCondition { server.isSendingFile }
        let notes = Task { @MainActor in
            while received == nil {
                server.send(.init(kind: .noteOn, note: 60, velocity: 90))
                server.send(.init(kind: .noteOff, note: 60))
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try await awaitFileCondition { received != nil }
        try await notes.value
        #expect(received == file)
        #expect(midiDuringChunks, "MIDI must be delivered before the file is fully assembled")
        #expect(server.isSendingFile && client.isReceivingFile)
        #expect(!server.fileTransferStatus.contains("已确认"))
        let before = events.count
        server.send(.init(kind: .noteOn, note: 67, velocity: 90))
        try await awaitFileCondition { events.count > before }
        saveGate.allowed = true
        try await sending.value
        #expect(!server.isSendingFile && !client.isReceivingFile)
        #expect(server.fileTransferStatus.contains("已确认导入"))
        #expect(client.fileTransferStatus.contains("已导入"))
        #expect(server.fileTransferProgress == 1)
    }

    @Test @MainActor func receiverParseFailureIsNotSuccessAndRetryWorks() async throws {
        let server = BridgeServer()
        let client = BridgeClient()
        client.onMIDIFile = { _ in throw FileTestError.invalidSong }
        defer { client.disconnect(); server.stop() }
        let peer = try await connectFilePeers(server, client)
        do {
            try await server.sendMIDIFile(LinkMIDIFile(title: "Bad", data: Data([1, 2, 3])), to: peer)
            Issue.record("Parse failure was incorrectly confirmed")
        } catch {
            #expect(error is MIDIFileTransferError)
        }
        #expect(server.fileTransferStatus.contains("失败"))
        #expect(!server.isSendingFile && !client.isReceivingFile && client.isConnected)
        var imports = 0
        client.onMIDIFile = { _ in imports += 1 }
        try await server.sendMIDIFile(LinkMIDIFile(title: "Retry", data: Data(repeating: 5, count: 32_769)), to: peer)
        #expect(imports == 1)
        #expect(server.fileTransferStatus.contains("已确认导入"))
    }

    @Test @MainActor func chunkedTransfersPreserveActivationAndStableImportIdentityAcrossAttempts() async throws {
        let server = BridgeServer()
        let client = BridgeClient()
        var received: [LinkMIDIFile] = []
        client.onMIDIFile = { file in received.append(file) }
        defer { client.disconnect(); server.stop() }
        let peer = try await connectFilePeers(server, client)
        let importID = UUID()
        let bytes = Data(repeating: 7, count: LinkMIDIFile.chunkByteCount + 3)
        let files = [LinkMIDIFile(title: "Batch", data: bytes, activateOnImport: false, importID: importID),
                     LinkMIDIFile(title: "Batch retry", data: bytes, activateOnImport: false, importID: importID),
                     LinkMIDIFile(title: "Single", data: bytes)]
        for file in files { try await server.sendMIDIFile(file, to: peer) }
        #expect(received == files)
        #expect(received[0].id != received[1].id)
        #expect(received[0].importID == received[1].importID)
        #expect(!received[0].activateOnImport && !received[1].activateOnImport)
        #expect(received[2].activateOnImport && received[2].importID == nil)
    }

    @Test func assemblyUsesBeginMetadataAndDefaultsLegacyTransfersToActiveImport() throws {
        let id = UUID()
        let legacyJSON = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "title": "Legacy", "totalBytes": 1])
        let legacy = try JSONDecoder().decode(LinkFilePayload.self, from: legacyJSON)
        #expect(legacy.activateOnImport == nil && legacy.importID == nil)
        var legacyAssembly = try MIDIFileAssembly(legacy)
        try legacyAssembly.append(.init(id: id, index: 0, data: Data([1])))
        let legacyFile = try legacyAssembly.finish(.init(id: id, index: 1, activateOnImport: false, importID: UUID()))
        #expect(legacyFile.activateOnImport && legacyFile.importID == nil)
        for activate in [false, true] {
            let importID = UUID()
            let begin = LinkFilePayload(id: id, title: "Current", totalBytes: 1,
                                        activateOnImport: activate, importID: importID)
            let decoded = try JSONDecoder().decode(LinkFilePayload.self, from: JSONEncoder().encode(begin))
            var assembly = try MIDIFileAssembly(decoded)
            try assembly.append(.init(id: id, index: 0, data: Data([2]), activateOnImport: !activate, importID: UUID()))
            let file = try assembly.finish(.init(id: id, index: 1, activateOnImport: !activate, importID: UUID()))
            #expect(file.activateOnImport == activate && file.importID == importID)
        }
    }

    @Test @MainActor func onlySelectedHeadsetReceivesFileAndDisconnectedTargetFails() async throws {
        let server = BridgeServer()
        let first = BridgeClient()
        let second = BridgeClient()
        var firstImports = 0
        var secondImports = 0
        first.onMIDIFile = { _ in firstImports += 1 }
        second.onMIDIFile = { _ in secondImports += 1 }
        defer { first.disconnect(); second.disconnect(); server.stop() }
        let selected = try await connectFilePeers(server, first)
        second.connect(host: "127.0.0.1", port: server.port)
        try await awaitFileCondition { second.latencyMilliseconds != nil && server.connectedClients.count == 2 }
        try await server.sendMIDIFile(LinkMIDIFile(title: "Selected", data: Data([1])), to: selected)
        #expect(firstImports == 1 && secondImports == 0)
        first.disconnect()
        try await awaitFileCondition { server.connectedClients.count == 1 }
        do {
            try await server.sendMIDIFile(LinkMIDIFile(title: "Disconnected", data: Data([1])), to: selected)
            Issue.record("Disconnected target silently redirected to another headset")
        } catch { #expect(error as? MIDIFileTransferError == .disconnected) }
        #expect(secondImports == 0)
    }

    @Test @MainActor func disconnectDuringImportFailsSenderAndCancelsReceiverCallback() async throws {
        let server = BridgeServer()
        let client = BridgeClient()
        var beganImport = false
        var cancelledImport = false
        client.onMIDIFile = { _ in
            beganImport = true
            do { try await Task.sleep(for: .seconds(100)) }
            catch { cancelledImport = true; throw error }
        }
        defer { client.disconnect(); server.stop() }
        let peer = try await connectFilePeers(server, client)
        let sending = Task { try await server.sendMIDIFile(LinkMIDIFile(title: "Disconnect", data: Data([1])), to: peer) }
        try await awaitFileCondition { beganImport }
        client.disconnect()
        do { try await sending.value; Issue.record("A disconnected transfer was confirmed") }
        catch { #expect(error is MIDIFileTransferError) }
        try await awaitFileCondition { cancelledImport }
        #expect(!server.isSendingFile && !client.isReceivingFile)
        #expect(server.fileTransferStatus.contains("失败"))
        #expect(client.fileTransferStatus.contains("失败"))
    }

    @Test @MainActor func senderCancellationClearsReceiverAndDoesNotBlockRetry() async throws {
        let server = BridgeServer()
        let client = BridgeClient()
        var beganImport = false
        client.onMIDIFile = { _ in beganImport = true; try await Task.sleep(for: .seconds(100)) }
        defer { client.disconnect(); server.stop() }
        let peer = try await connectFilePeers(server, client)
        let sending = Task { try await server.sendMIDIFile(LinkMIDIFile(title: "Cancel", data: Data([1])), to: peer) }
        try await awaitFileCondition { beganImport }
        sending.cancel()
        do { try await sending.value; Issue.record("Cancelled transfer was confirmed") }
        catch { #expect(error is CancellationError) }
        try await awaitFileCondition { !client.isReceivingFile }
        client.onMIDIFile = { _ in }
        try await server.sendMIDIFile(LinkMIDIFile(title: "Retry", data: Data([2])), to: peer)
        #expect(server.fileTransferStatus.contains("已确认导入"))
    }

    @Test @MainActor func cancellationBetweenAcknowledgedChunksClearsReceiverBeforeRetry() async throws {
        let server = BridgeServer()
        let client = BridgeClient()
        var imports = 0
        client.onMIDIFile = { _ in imports += 1 }
        defer { client.disconnect(); server.stop() }
        let peer = try await connectFilePeers(server, client)
        let probe = ChunkCancellationProbe(server: server)
        probe.arm()
        let sending = Task {
            try await server.sendMIDIFile(LinkMIDIFile(title: "Between chunks",
                data: Data(repeating: 1, count: LinkMIDIFile.chunkByteCount * 2)), to: peer)
        }
        do { try await sending.value; Issue.record("Cancellation between chunks was ignored") }
        catch { #expect(error is CancellationError) }
        #expect(probe.progressWrites == 2)
        #expect(!server.isSendingFile)
        try await awaitFileCondition { !client.isReceivingFile }
        #expect(imports == 0)
        try await server.sendMIDIFile(LinkMIDIFile(title: "Immediate retry", data: Data([2])), to: peer)
        #expect(imports == 1)
        #expect(server.fileTransferStatus.contains("已确认导入"))
    }

    @Test @MainActor func sizeLimitsAreEnforcedBeforeSendingAndNoHandlerRejects() async throws {
        let server = BridgeServer()
        let client = BridgeClient()
        defer { client.disconnect(); server.stop() }
        let peer = try await connectFilePeers(server, client)
        for size in [0, LinkMIDIFile.maximumByteCount + 1] {
            do {
                try await server.sendMIDIFile(LinkMIDIFile(title: "Too large", data: Data(repeating: 0, count: size)), to: peer)
                Issue.record("Invalid size was accepted")
            } catch { #expect(error as? MIDIFileTransferError == .invalidSize) }
        }
        do {
            try await server.sendMIDIFile(LinkMIDIFile(title: "Unsupported receiver", data: Data([1])), to: peer)
            Issue.record("Receiver without an import handler confirmed a file")
        } catch { #expect(error is MIDIFileTransferError) }
        #expect(!client.isReceivingFile && !server.isSendingFile)
        #expect(server.fileTransferStatus.contains("失败"))
    }

    @Test @MainActor func missingImportReceiptTimesOutAndMIDIConnectionRemainsUsable() async throws {
        let server = BridgeServer(fileAckTimeout: .seconds(2), fileResultTimeout: .milliseconds(100))
        let client = BridgeClient()
        var events = 0
        client.onMIDIFile = { _ in try await Task.sleep(for: .seconds(100)) }
        client.onEvent = { _ in events += 1 }
        defer { client.disconnect(); server.stop() }
        let peer = try await connectFilePeers(server, client)
        do {
            try await server.sendMIDIFile(LinkMIDIFile(title: "Missing receipt", data: Data([1])), to: peer)
            Issue.record("Missing import receipt was treated as success")
        } catch { #expect(error as? MIDIFileTransferError == .timedOut) }
        try await awaitFileCondition { !client.isReceivingFile }
        #expect(client.isConnected && server.fileTransferStatus.contains("超时"))
        server.send(.init(kind: .noteOn, note: 60, velocity: 90))
        server.send(.init(kind: .noteOff, note: 60))
        try await awaitFileCondition { events == 2 }
    }

    @Test func assemblyRejectsOversizeMissingOutOfOrderDuplicateAndTruncatedChunks() throws {
        let id = UUID()
        let maximum = try MIDIFileAssembly(.init(id: id, title: "Maximum", totalBytes: LinkMIDIFile.maximumByteCount))
        #expect(maximum.totalBytes == LinkMIDIFile.maximumByteCount && maximum.data.isEmpty)
        #expect(throws: MIDIFileTransferError.invalidSize) {
            try MIDIFileAssembly(.init(id: id, title: "A", totalBytes: LinkMIDIFile.maximumByteCount + 1))
        }
        var receiver = try MIDIFileAssembly(.init(id: id, title: "../../a\n/b:c", totalBytes: 3))
        #expect(!receiver.title.contains("/") && !receiver.title.contains(":") && !receiver.title.contains("\n"))
        #expect(throws: MIDIFileTransferError.invalidTransfer) {
            try receiver.append(.init(id: id, index: 1, data: Data([1])))
        }
        #expect(throws: MIDIFileTransferError.invalidTransfer) {
            try receiver.append(.init(id: UUID(), index: 0, data: Data([1])))
        }
        #expect(throws: MIDIFileTransferError.invalidTransfer) {
            try receiver.append(.init(id: id, index: 0, data: Data(repeating: 1, count: LinkMIDIFile.chunkByteCount + 1)))
        }
        try receiver.append(.init(id: id, index: 0, data: Data([1, 2])))
        #expect(throws: MIDIFileTransferError.invalidTransfer) {
            try receiver.append(.init(id: id, index: 0, data: Data([1])))
        }
        #expect(throws: MIDIFileTransferError.invalidTransfer) { try receiver.finish(.init(id: id, index: 1)) }
        #expect(throws: MIDIFileTransferError.invalidTransfer) {
            try receiver.append(.init(id: id, index: 1, data: Data([3, 4])))
        }
        try receiver.append(.init(id: id, index: 1, data: Data([3])))
        let complete = try receiver.finish(.init(id: id, index: 2))
        #expect(complete.data == Data([1, 2, 3]))
        #expect(LinkMIDIFile(title: "..", data: Data()).title == "导入曲目")
    }

    @Test @MainActor func rawOutOfOrderTransferIsRejectedWithoutInvokingImport() async throws {
        let fixture = try MIDIFileFixture()
        let client = BridgeClient()
        var imports = 0
        client.onMIDIFile = { _ in imports += 1 }
        defer { client.disconnect(); fixture.stop() }
        try await awaitFileCondition { fixture.port != 0 }
        client.connect(host: "127.0.0.1", port: fixture.port)
        try await awaitFileCondition { client.latencyMilliseconds != nil }
        let id = UUID()
        fixture.send(.fileBegin, payload: .init(id: id, title: "Incomplete", totalBytes: 3))
        try await awaitFileCondition { fixture.received.contains { $0.kind == .fileAck && $0.file?.id == id } }
        fixture.send(.fileChunk, payload: .init(id: id, index: 1, data: Data([1, 2, 3])))
        try await awaitFileCondition { fixture.received.contains { $0.kind == .fileResult && $0.file?.accepted == false } }
        #expect(imports == 0 && !client.isReceivingFile && client.isConnected)
    }
}

@MainActor private final class MIDIFileFixture {
    let session = UUID().uuidString
    private(set) var port: UInt16 = 0
    private(set) var received: [LinkPacket] = []
    private let listener: NWListener
    private var pipe: LinkConnection?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                if case .ready = state { self?.port = self?.listener.port?.rawValue ?? 0 }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                guard let self else { return }
                let pipe = LinkConnection(connection: connection, onPacket: { [weak self] _, packet in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.received.append(packet)
                        if packet.kind == .ping {
                            self.pipe?.send(.init(kind: .pong, session: self.session, sentTime: packet.sentTime,
                                                 remoteTime: ProcessInfo.processInfo.systemUptime))
                        }
                    }
                }, onState: { [weak self] _, _, ready in
                    DispatchQueue.main.async {
                        guard let self, ready else { return }
                        self.pipe?.send(.init(kind: .hello, session: self.session))
                    }
                })
                self.pipe = pipe
                pipe.start()
            }
        }
        listener.start(queue: DispatchQueue(label: "PianoLinkTests.file-listener"))
    }

    func send(_ kind: LinkPacket.Kind, payload: LinkFilePayload) {
        pipe?.send(.init(kind: kind, session: session, file: payload))
    }
    func stop() { pipe?.cancel(); listener.cancel() }
}
