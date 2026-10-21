import Foundation
import Network
import Observation

@MainActor @Observable
public final class BridgeClient {
    public private(set) var services: [BridgeService] = []
    public private(set) var status = "尚未连接 Mac 中转"
    public private(set) var isConnected = false
    public private(set) var latencyMilliseconds: Double?
    public var onEvent: (@MainActor (LinkMIDIEvent) -> Void)?
    public var onReset: (@MainActor () -> Void)?
    /// Return only after parsing and saving the received file. Throwing sends an
    /// import failure to the Mac. Disconnect cancels the callback task.
    public var onMIDIFile: (@MainActor (LinkMIDIFile) async throws -> Void)?
    public private(set) var fileTransferStatus = "等待 Mac 发送 MIDI 曲目"
    public private(set) var fileTransferProgress = 0.0
    public private(set) var isReceivingFile = false

    @ObservationIgnored private var browser: (any BridgeDiscoveryBrowsing)?
    @ObservationIgnored private var discoveryGeneration = UUID()
    @ObservationIgnored private let discoveryBrowserFactory: @MainActor () -> any BridgeDiscoveryBrowsing
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var pipe: LinkConnection?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    private var session: String?
    private var lastSequence: UInt64 = 0
    private var remoteClockOffset: Double?
    private var bestRTT = Double.infinity
    private var lastReceived = 0.0
    private var connectedName = "Mac"
    @ObservationIgnored private var incomingFile: MIDIFileAssembly?
    @ObservationIgnored private var receivingTimeout: Task<Void, Never>?
    @ObservationIgnored private var importingFile: Task<Void, Never>?
    private var processingFileID: UUID?
    private var processingGeneration = UUID()

    public convenience init() {
        self.init(discoveryBrowserFactory: { NetworkBridgeDiscoveryBrowser() })
    }

    init(discoveryBrowserFactory: @escaping @MainActor () -> any BridgeDiscoveryBrowsing) {
        self.discoveryBrowserFactory = discoveryBrowserFactory
    }

    public func startBrowsing() {
        guard browser == nil else { return }
        let generation = UUID()
        discoveryGeneration = generation
        let browser = discoveryBrowserFactory()
        self.browser = browser
        if pipe == nil { status = "正在寻找 Mac 中转…" }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, self.discoveryGeneration == generation else { return }
            switch state {
            case .failed(let error):
                self.stopBrowsing()
                if self.pipe == nil { self.status = "发现服务失败：\(error.localizedDescription)" }
            case .cancelled:
                self.stopBrowsing()
            default:
                break
            }
        }
        browser.resultsUpdateHandler = { [weak self] results in
            guard let self, self.discoveryGeneration == generation else { return }
            var endpoints: [String: NWEndpoint] = [:]
            var services: [BridgeService] = []
            for endpoint in results {
                if case .service(let name, let type, let domain, _) = endpoint {
                    let id = "\(name).\(type).\(domain)"
                    endpoints[id] = endpoint
                    services.append(BridgeService(id: id, name: name))
                }
            }
            self.endpoints = endpoints
            self.services = services.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        browser.start()
    }

    /// Refresh discovery independently of the active MIDI connection.
    public func restartBrowsing() {
        stopBrowsing()
        startBrowsing()
    }

    private func stopBrowsing() {
        // Invalidate before cancelling: cancellation and queued result callbacks may arrive late.
        discoveryGeneration = UUID()
        let old = browser
        browser = nil
        endpoints.removeAll()
        services.removeAll()
        old?.cancel()
    }

    public func connect(to service: BridgeService) {
        guard let endpoint = endpoints[service.id] else { status = "该 Mac 服务已离线，请重新选择"; return }
        connect(endpoint: endpoint, name: service.name)
    }

    public func connect(host: String, port: UInt16) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port), port.rawValue != 0 else {
            status = "请输入有效的 Mac 地址和端口"; return
        }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: port), name: host)
    }

    public func disconnect() {
        clearFileTransfer(message: isReceivingFile ? "接收失败：Mac 已断开，曲目未确认导入" : nil)
        heartbeat?.cancel(); heartbeat = nil
        let old = pipe; pipe = nil; old?.cancel()
        isConnected = false
        session = nil; lastSequence = 0; remoteClockOffset = nil; bestRTT = .infinity
        latencyMilliseconds = nil
        status = "已断开 Mac 中转"
        onReset?()
    }

    private func connect(endpoint: NWEndpoint, name: String) {
        disconnect()
        connectedName = name
        status = "正在连接 \(name)…"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        let pipe = LinkConnection(connection: connection, onPacket: { [weak self] id, packet in
            DispatchQueue.main.async { self?.receive(id: id, packet: packet) }
        }, onState: { [weak self] id, state, ready in
            DispatchQueue.main.async { self?.connectionState(id: id, state: state, ready: ready) }
        })
        self.pipe = pipe
        pipe.start()
        // A silent or unreachable host must not leave the UI connecting forever.
        heartbeat = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard self.pipe?.id == pipe.id else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if (!self.isConnected && now - started > 12) || (self.isConnected && now - self.lastReceived > 8) {
                    self.disconnect(); self.status = "Mac 中转连接超时，琴键状态已清空"; return
                }
                if self.isConnected { self.sendPing() }
            }
        }
    }

    private func connectionState(id: UUID, state: String, ready: Bool) {
        guard pipe?.id == id else { return }
        if ready {
            isConnected = true; lastReceived = ProcessInfo.processInfo.systemUptime
            status = "已连接 \(connectedName)"
            sendPing()
        } else {
            disconnect()
            status = "Mac 中转已断开：\(state)"
        }
    }

    private func sendPing() {
        pipe?.send(LinkPacket(kind: .ping, session: session ?? "", sentTime: ProcessInfo.processInfo.systemUptime))
    }

    private func receive(id: UUID, packet: LinkPacket) {
        guard pipe?.id == id, isConnected else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastReceived = now
        switch packet.kind {
        case .hello:
            guard !packet.session.isEmpty else { return }
            clearFileTransfer(message: isReceivingFile ? "接收失败：Mac 会话已改变" : nil)
            session = packet.session; lastSequence = packet.sequence
            pipe?.send(LinkPacket(kind: .hello, session: packet.session,
                                  peerName: String(ProcessInfo.processInfo.hostName.prefix(80))))
            onReset?()
            sendPing()
        case .pong:
            guard packet.session == session, let sent = packet.sentTime, let remote = packet.remoteTime else { return }
            let rtt = now - sent
            guard rtt >= 0, rtt < 10 else { return }
            latencyMilliseconds = rtt * 1000
            if rtt < bestRTT { bestRTT = rtt; remoteClockOffset = remote - (sent + now) / 2 }
        case .event:
            guard packet.session == session, packet.sequence > lastSequence, var event = packet.event,
                  (0...15).contains(event.channel), (0...127).contains(event.note),
                  (0...127).contains(event.velocity), (0...127).contains(event.controller),
                  (0...127).contains(event.value), event.timestamp.isFinite else { return }
            lastSequence = packet.sequence
            event.timestamp = remoteClockOffset.map { event.timestamp - $0 } ?? now
            // A stalled TCP stream must never replay an old key-down after recovery.
            if now - event.timestamp > 1.0 || event.timestamp - now > 1.0 { onReset?(); return }
            onEvent?(event)
        case .reset:
            guard packet.session == session, packet.sequence >= lastSequence else { return }
            lastSequence = packet.sequence
            onReset?()
        case .fileBegin, .fileChunk, .fileEnd, .fileCancel:
            guard packet.session == session, let payload = packet.file else { return }
            receiveFile(packet.kind, payload: payload, connectionID: id)
        case .ping, .fileAck, .fileResult: break
        }
    }

    private func receiveFile(_ kind: LinkPacket.Kind, payload: LinkFilePayload, connectionID: UUID) {
        do {
            switch kind {
            case .fileCancel:
                if incomingFile?.id == payload.id || processingFileID == payload.id {
                    clearFileTransfer(message: "接收已取消，请在 Mac 上重新发送")
                }
            case .fileBegin:
                guard !isReceivingFile else { throw MIDIFileTransferError.busy }
                guard onMIDIFile != nil else { throw MIDIFileTransferError.rejected("此版本尚未启用曲目接收") }
                let assembly = try MIDIFileAssembly(payload)
                incomingFile = assembly
                isReceivingFile = true
                fileTransferProgress = 0
                fileTransferStatus = "正在接收：\(assembly.title)"
                refreshFileTimeout(id: payload.id)
                acknowledgeFile(payload.id, index: -1)
            case .fileChunk:
                guard incomingFile?.id == payload.id else { throw MIDIFileTransferError.invalidTransfer }
                try incomingFile?.append(payload)
                if let assembly = incomingFile {
                    fileTransferProgress = Double(assembly.data.count) / Double(assembly.totalBytes)
                }
                refreshFileTimeout(id: payload.id)
                acknowledgeFile(payload.id, index: payload.index!)
            case .fileEnd:
                guard let assembly = incomingFile, assembly.id == payload.id else { throw MIDIFileTransferError.invalidTransfer }
                let file = try assembly.finish(payload)
                incomingFile = nil
                receivingTimeout?.cancel(); receivingTimeout = nil
                processingFileID = file.id
                let generation = UUID()
                processingGeneration = generation
                fileTransferStatus = "已接收，正在导入：\(file.title)"
                importingFile = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        guard let handler = self.onMIDIFile else { throw MIDIFileTransferError.rejected("曲目接收已关闭") }
                        try Task.checkCancellation()
                        try await handler(file)
                        try Task.checkCancellation()
                        guard self.pipe?.id == connectionID, self.processingGeneration == generation else { return }
                        self.finishFile(file.id, index: payload.index, accepted: true)
                        self.fileTransferStatus = "已导入：\(file.title)"
                    } catch {
                        guard self.pipe?.id == connectionID, self.processingGeneration == generation else { return }
                        self.finishFile(file.id, index: payload.index, accepted: false, message: error.localizedDescription)
                        self.fileTransferStatus = "导入失败：\(error.localizedDescription)"
                    }
                    self.processingFileID = nil
                    self.importingFile = nil
                    self.isReceivingFile = false
                }
            default: break
            }
        } catch {
            if incomingFile?.id == payload.id { clearFileTransfer(message: "接收失败：\(error.localizedDescription)") }
            finishFile(payload.id, index: payload.index, accepted: false, message: error.localizedDescription)
            if !isReceivingFile { fileTransferStatus = "接收失败：\(error.localizedDescription)" }
        }
    }

    private func acknowledgeFile(_ id: UUID, index: Int) {
        pipe?.send(LinkPacket(kind: .fileAck, session: session ?? "", file: .init(id: id, index: index, accepted: true)))
    }

    private func finishFile(_ id: UUID, index: Int?, accepted: Bool, message: String? = nil) {
        pipe?.send(LinkPacket(kind: .fileResult, session: session ?? "",
                              file: .init(id: id, index: index, accepted: accepted,
                                          message: message.map { String($0.prefix(256)) })))
    }

    private func refreshFileTimeout(id: UUID) {
        receivingTimeout?.cancel()
        receivingTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.incomingFile?.id == id else { return }
            self.finishFile(id, index: nil, accepted: false, message: "接收数据超时")
            self.clearFileTransfer(message: "接收失败：数据传输超时，请在 Mac 上重新发送")
        }
    }

    private func clearFileTransfer(message: String?) {
        receivingTimeout?.cancel(); receivingTimeout = nil
        importingFile?.cancel(); importingFile = nil
        incomingFile = nil; processingFileID = nil; processingGeneration = UUID()
        isReceivingFile = false
        if let message { fileTransferStatus = message }
    }
}

/// The boundary keeps discovery callbacks deterministic in tests without mocking MIDI transport.
@MainActor
protocol BridgeDiscoveryBrowsing: AnyObject {
    var stateUpdateHandler: (@MainActor @Sendable (NWBrowser.State) -> Void)? { get set }
    var resultsUpdateHandler: (@MainActor @Sendable ([NWEndpoint]) -> Void)? { get set }
    func start()
    func cancel()
}

@MainActor
private final class NetworkBridgeDiscoveryBrowser: BridgeDiscoveryBrowsing {
    var stateUpdateHandler: (@MainActor @Sendable (NWBrowser.State) -> Void)?
    var resultsUpdateHandler: (@MainActor @Sendable ([NWEndpoint]) -> Void)?
    private let browser: NWBrowser

    init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_pianovision._tcp", domain: nil), using: parameters)
    }

    func start() {
        let stateHandler = stateUpdateHandler
        let resultsHandler = resultsUpdateHandler
        browser.stateUpdateHandler = { state in
            DispatchQueue.main.async { stateHandler?(state) }
        }
        browser.browseResultsChangedHandler = { results, _ in
            let endpoints = results.map(\.endpoint)
            DispatchQueue.main.async { resultsHandler?(endpoints) }
        }
        browser.start(queue: DispatchQueue(label: "com.pianovision.link.discovery"))
    }

    func cancel() { browser.cancel() }
}
