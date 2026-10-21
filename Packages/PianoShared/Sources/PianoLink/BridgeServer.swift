import Foundation
import Network
import Observation

@MainActor @Observable
public final class BridgeServer {
    public private(set) var status = "中转服务未启动"
    public private(set) var clientCount = 0
    public private(set) var eventCount: UInt64 = 0
    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false
    public private(set) var connectedClients: [BridgePeer] = []
    public private(set) var isSendingFile = false
    public private(set) var fileTransferProgress = 0.0
    public private(set) var fileTransferStatus = "尚未发送曲目"

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [UUID: LinkConnection] = [:]
    @ObservationIgnored private var lastSeen: [UUID: Double] = [:]
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    private var session = UUID().uuidString
    private var sequence: UInt64 = 0
    private var generation = UUID()
    @ObservationIgnored private var outgoingFile: OutgoingFile?
    @ObservationIgnored private let fileAckTimeout: Duration
    @ObservationIgnored private let fileResultTimeout: Duration

    private final class OutgoingFile {
        let id: UUID
        let attempt = UUID()
        let clientID: UUID
        var expectedIndex = -1
        var expectsResult = false
        var waiter: CheckedContinuation<Void, any Error>?
        var timeout: Task<Void, Never>?
        init(id: UUID, clientID: UUID) { self.id = id; self.clientID = clientID }
    }

    public convenience init() { self.init(fileAckTimeout: .seconds(10), fileResultTimeout: .seconds(45)) }

    init(fileAckTimeout: Duration, fileResultTimeout: Duration) {
        self.fileAckTimeout = fileAckTimeout
        self.fileResultTimeout = fileResultTimeout
    }

    public func start() {
        guard listener == nil else { return }
        do {
            session = UUID().uuidString; sequence = 0
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            let generation = UUID(); self.generation = generation
            listener.service = NWListener.Service(name: "\(ProcessInfo.processInfo.hostName) · Piano Bridge", type: "_pianovision._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue ?? 0
                        self.isRunning = true
                        self.status = "正在等待 Vision Pro 连接"
                    case .failed(let error):
                        self.stop(); self.status = "中转启动失败：\(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: DispatchQueue(label: "com.pianovision.bridge.listener"))
            status = "正在启动本地中转服务…"
            heartbeat = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    let expired = self.lastSeen.filter { ProcessInfo.processInfo.systemUptime - $0.value > 10 }.map(\.key)
                    for id in expired { self.removeClient(id) }
                }
            }
        } catch { status = "中转启动失败：\(error.localizedDescription)" }
    }

    public func stop() {
        failFileTransfer(MIDIFileTransferError.disconnected)
        generation = UUID()
        heartbeat?.cancel(); heartbeat = nil
        listener?.cancel(); listener = nil
        for client in clients.values { client.cancel() }
        clients.removeAll(); lastSeen.removeAll()
        clientCount = 0; connectedClients.removeAll(); port = 0; isRunning = false
        status = "中转服务已停止"
    }

    public func send(_ event: LinkMIDIEvent) {
        guard isRunning else { return }
        sequence &+= 1; eventCount &+= 1
        broadcast(LinkPacket(kind: .event, session: session, sequence: sequence, event: event))
    }

    /// Clear every receiver when changing MIDI source, stopping, or cancelling test notes.
    public func reset() {
        sequence &+= 1
        broadcast(LinkPacket(kind: .reset, session: session, sequence: sequence))
    }

    /// Stop-and-wait chunks bound the TCP send queue and allow MIDI and heartbeats
    /// between every 16 KB payload. Success means the receiver's import callback
    /// has completed, rather than merely that TCP accepted the bytes.
    public func sendMIDIFile(_ file: LinkMIDIFile, to clientID: UUID) async throws {
        do { try await performMIDIFileTransfer(file, to: clientID) }
        catch {
            if !isSendingFile { fileTransferStatus = "发送失败：\(error.localizedDescription)" }
            throw error
        }
    }

    private func performMIDIFileTransfer(_ file: LinkMIDIFile, to clientID: UUID) async throws {
        guard !file.data.isEmpty, file.data.count <= LinkMIDIFile.maximumByteCount else { throw MIDIFileTransferError.invalidSize }
        guard !isSendingFile, outgoingFile == nil else { throw MIDIFileTransferError.busy }
        guard isRunning, connectedClients.contains(where: { $0.id == clientID }), clients[clientID] != nil else {
            throw MIDIFileTransferError.disconnected
        }
        let transfer = OutgoingFile(id: file.id, clientID: clientID)
        outgoingFile = transfer
        isSendingFile = true
        fileTransferProgress = 0
        fileTransferStatus = "正在发送：\(file.title)"
        defer {
            transfer.timeout?.cancel()
            if outgoingFile === transfer { outgoingFile = nil }
            isSendingFile = false
        }
        do {
            try await sendFileStep(.init(kind: .fileBegin, session: session,
                                        file: .init(id: file.id, title: file.title, totalBytes: file.data.count,
                                                    activateOnImport: file.activateOnImport, importID: file.importID)),
                                   transfer: transfer, index: -1)
            var offset = 0
            var index = 0
            while offset < file.data.count {
                try Task.checkCancellation()
                let end = min(file.data.count, offset + LinkMIDIFile.chunkByteCount)
                let chunk = file.data.subdata(in: offset..<end)
                try await sendFileStep(.init(kind: .fileChunk, session: session,
                                            file: .init(id: file.id, index: index, data: chunk)),
                                       transfer: transfer, index: index)
                offset = end
                index += 1
                fileTransferProgress = Double(offset) / Double(file.data.count)
            }
            fileTransferStatus = "已发送，等待 Vision Pro 完成导入…"
            try await sendFileStep(.init(kind: .fileEnd, session: session,
                                        file: .init(id: file.id, index: index)),
                                   transfer: transfer, index: index, expectsResult: true)
            fileTransferStatus = "Vision Pro 已确认导入：\(file.title)"
        } catch {
            // Cancellation may be observed between acknowledged chunks, after a
            // step's cancellation handler has already been removed. Close that
            // attempt synchronously before defer releases its ownership.
            if outgoingFile === transfer { failFileTransfer(error) }
            fileTransferStatus = "发送失败：\(error.localizedDescription)"
            throw error
        }
    }

    private func sendFileStep(_ packet: LinkPacket, transfer: OutgoingFile, index: Int,
                              expectsResult: Bool = false) async throws {
        let attempt = transfer.attempt
        let timeout = expectsResult ? fileResultTimeout : fileAckTimeout
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard outgoingFile === transfer, let client = clients[transfer.clientID] else {
                    continuation.resume(throwing: MIDIFileTransferError.disconnected)
                    return
                }
                transfer.expectedIndex = index
                transfer.expectsResult = expectsResult
                transfer.waiter = continuation
                transfer.timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard self?.outgoingFile === transfer else { return }
                    self?.failFileTransfer(MIDIFileTransferError.timedOut)
                }
                client.send(packet)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.outgoingFile?.attempt == attempt else { return }
                self?.failFileTransfer(CancellationError())
            }
        }
    }

    private func failFileTransfer(_ error: any Error) {
        guard let transfer = outgoingFile else { return }
        outgoingFile = nil
        transfer.timeout?.cancel()
        clients[transfer.clientID]?.send(LinkPacket(kind: .fileCancel, session: session, file: .init(id: transfer.id)))
        let waiter = transfer.waiter
        transfer.waiter = nil
        waiter?.resume(throwing: error)
    }

    private func broadcast(_ packet: LinkPacket) { for client in clients.values { client.send(packet) } }

    private func accept(_ connection: NWConnection) {
        let pipe = LinkConnection(connection: connection, onPacket: { [weak self] id, packet in
            DispatchQueue.main.async { self?.receive(id: id, packet: packet) }
        }, onState: { [weak self] id, state, ready in
            DispatchQueue.main.async {
                guard let self, let client = self.clients[id] else { return }
                if ready {
                    self.lastSeen[id] = ProcessInfo.processInfo.systemUptime
                    client.send(LinkPacket(kind: .hello, session: self.session, sequence: self.sequence,
                                           remoteTime: ProcessInfo.processInfo.systemUptime))
                    self.clientCount = self.clients.count
                    self.connectedClients.append(BridgePeer(id: id, name: "Vision Pro \(self.connectedClients.count + 1)"))
                    self.status = "已连接 \(self.clientCount) 台 Vision Pro"
                } else { self.removeClient(id) }
            }
        })
        clients[pipe.id] = pipe
        lastSeen[pipe.id] = ProcessInfo.processInfo.systemUptime
        pipe.start()
    }

    private func receive(id: UUID, packet: LinkPacket) {
        guard let client = clients[id] else { return }
        lastSeen[id] = ProcessInfo.processInfo.systemUptime
        if packet.kind == .ping, let sent = packet.sentTime {
            client.send(LinkPacket(kind: .pong, session: session, sentTime: sent,
                                   remoteTime: ProcessInfo.processInfo.systemUptime))
        } else if packet.kind == .hello, packet.session == session, let name = packet.peerName {
            if let index = connectedClients.firstIndex(where: { $0.id == id }) {
                connectedClients[index] = BridgePeer(id: id, name: LinkMIDIFile.safeTitle(name))
            }
        } else if packet.kind == .fileAck || packet.kind == .fileResult {
            guard packet.session == session, let payload = packet.file,
                  let transfer = outgoingFile, transfer.id == payload.id, transfer.clientID == id,
                  let waiter = transfer.waiter else { return }
            if payload.accepted == false {
                failFileTransfer(MIDIFileTransferError.rejected(String((payload.message ?? "接收失败").prefix(256))))
                return
            }
            guard payload.accepted == true, payload.index == transfer.expectedIndex,
                  (packet.kind == .fileResult) == transfer.expectsResult else {
                failFileTransfer(MIDIFileTransferError.invalidTransfer)
                return
            }
            transfer.timeout?.cancel(); transfer.timeout = nil
            transfer.waiter = nil
            waiter.resume()
        }
    }

    private func removeClient(_ id: UUID) {
        if outgoingFile?.clientID == id { failFileTransfer(MIDIFileTransferError.disconnected) }
        clients.removeValue(forKey: id)?.cancel()
        lastSeen.removeValue(forKey: id)
        connectedClients.removeAll { $0.id == id }
        clientCount = clients.count
        if isRunning { status = clientCount == 0 ? "正在等待 Vision Pro 连接" : "已连接 \(clientCount) 台 Vision Pro" }
    }
}
