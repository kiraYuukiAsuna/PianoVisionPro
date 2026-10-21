import CoreAudio
import CoreMIDI
import Foundation
import Observation
import PianoLink

struct MIDISource: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
    let endpoint: MIDIEndpointRef
}

/// MIDI callbacks only copy bytes. Decoding and delivery are serialized before reaching the UI.
private final class MIDIReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pianovision.bridge.midi")
    private var decoder = MIDIByteDecoder()
    private let deliver: @MainActor @Sendable ([LinkMIDIEvent]) -> Void

    init(deliver: @escaping @MainActor @Sendable ([LinkMIDIEvent]) -> Void) { self.deliver = deliver }

    func receive(_ packetList: UnsafePointer<MIDIPacketList>) {
        let batch = MIDIPacketReader.copyPackets(from: packetList).map { packet in
            let timestamp = packet.hostTimestamp == 0 ? ProcessInfo.processInfo.systemUptime
                : Double(AudioConvertHostTimeToNanos(packet.hostTimestamp)) / 1_000_000_000
            return (bytes: packet.bytes, timestamp: timestamp)
        }
        queue.async { [self] in
            let events = batch.flatMap { decoder.decode($0.bytes, timestamp: $0.timestamp) }
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { [deliver] in deliver(events) }
        }
    }
}

@MainActor @Observable
final class MIDIInputModel {
    private(set) var sources: [MIDISource] = []
    var selectedSourceID: MIDIUniqueID?
    private(set) var connectedSourceID: MIDIUniqueID?
    private(set) var status = "请选择 USB MIDI 输入设备"
    private(set) var receivedEvents: UInt64 = 0
    var onEvent: (@MainActor (LinkMIDIEvent) -> Void)?
    var onReset: (@MainActor () -> Void)?

    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var inputPort = MIDIPortRef()
    @ObservationIgnored private var connectedEndpoint = MIDIEndpointRef()
    @ObservationIgnored private var receiver: MIDIReceiver?
    private var generation = UUID()

    init() {
        start()
    }

    func start() {
        guard client == 0 else { refreshSources(); return }
        let notify: @Sendable (UnsafePointer<MIDINotification>) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refreshSources() }
        }
        let result = MIDIClientCreateWithBlock("PianoVision USB Bridge" as CFString, &client, notify)
        if result == noErr { refreshSources() }
        else { status = "MIDI 初始化失败：\(describe(result))" }
    }

    func refreshSources() {
        sources = (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            var uniqueID: MIDIUniqueID = 0
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID) == noErr else { return nil }
            var unmanaged: Unmanaged<CFString>?
            let result = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanaged)
            let name = result == noErr ? (unmanaged?.takeRetainedValue() as String?) : nil
            return MIDISource(id: uniqueID, name: name ?? "MIDI 输入 \(index + 1)", endpoint: endpoint)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let connectedSourceID, !sources.contains(where: { $0.id == connectedSourceID }) {
            disconnect(); status = "MIDI 设备已移除，琴键状态已清空"
        }
        if let selectedSourceID, !sources.contains(where: { $0.id == selectedSourceID }) { self.selectedSourceID = nil }
        if selectedSourceID == nil { selectedSourceID = sources.first?.id }
    }

    func connectSelected() {
        disconnect()
        guard client != 0 else { status = "MIDI 客户端不可用，请重新启动应用"; return }
        guard let source = sources.first(where: { $0.id == selectedSourceID }) else {
            status = "没有可连接的 MIDI 输入设备"; return
        }
        let generation = UUID(); self.generation = generation
        let receiver = MIDIReceiver { [weak self] events in
            guard let self, self.generation == generation, self.connectedSourceID == source.id else { return }
            for event in events { self.receivedEvents &+= 1; self.onEvent?(event) }
        }
        self.receiver = receiver
        let read: @Sendable (UnsafePointer<MIDIPacketList>, UnsafeMutableRawPointer?) -> Void = { packets, _ in
            receiver.receive(packets)
        }
        let createResult = MIDIInputPortCreateWithBlock(client, "PianoVision Input" as CFString, &inputPort, read)
        guard createResult == noErr else {
            self.receiver = nil; status = "创建 MIDI 输入失败：\(describe(createResult))"; return
        }
        let result = MIDIPortConnectSource(inputPort, source.endpoint, nil)
        guard result == noErr else {
            MIDIPortDispose(inputPort); inputPort = 0; self.receiver = nil
            status = "连接 MIDI 输入失败：\(describe(result))"; return
        }
        connectedEndpoint = source.endpoint; connectedSourceID = source.id
        status = "已连接：\(source.name)"
    }

    func disconnect() {
        generation = UUID()
        if inputPort != 0 {
            if connectedEndpoint != 0 { MIDIPortDisconnectSource(inputPort, connectedEndpoint) }
            MIDIPortDispose(inputPort)
        }
        inputPort = 0; connectedEndpoint = 0; connectedSourceID = nil; receiver = nil
        status = "MIDI 已断开"
        onReset?()
    }

    func shutdown() {
        disconnect()
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    private func describe(_ status: OSStatus) -> String {
        "\(NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription) (\(status))"
    }
}
