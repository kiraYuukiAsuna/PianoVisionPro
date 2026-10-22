import SwiftUI
import PianoLink
import UniformTypeIdentifiers

@main
struct PianoBridgeApp: App {
    @State private var model = BridgeModel()

    var body: some Scene {
        Window("PianoBridge", id: "bridge") {
            BridgeWindow(model: model)
                .task { model.start() }
                .onDisappear { model.stop() }
        }
        .defaultSize(width: 720, height: 850)
        .windowResizability(.contentMinSize)
    }
}

@MainActor @Observable
final class BridgeModel {
    let server: BridgeServer
    let files: MIDIBatchImportModel
    let midi = MIDIInputModel()
    private(set) var activeNotes: Set<Int> = []
    private var activeChannels: [Int: Set<Int>] = [:]
    private(set) var latestEvent = "等待 MIDI 演奏"
    private(set) var simulatedEvents: UInt64 = 0
    private(set) var simulationRunning = false
    @ObservationIgnored private var simulation: Task<Void, Never>?
    var selectedReceiverID: UUID?

    init() {
        let server = BridgeServer()
        self.server = server
        files = MIDIBatchImportModel { file, receiverID in
            try await server.sendMIDIFile(file, to: receiverID)
        }
    }

    var receiverID: UUID? {
        if let selectedReceiverID {
            return server.connectedClients.contains(where: { $0.id == selectedReceiverID }) ? selectedReceiverID : nil
        }
        return server.connectedClients.count == 1 ? server.connectedClients.first?.id : nil
    }

    func start() {
        midi.start()
        midi.onEvent = { [weak self] event in self?.forward(event) }
        midi.onReset = { [weak self] in self?.clearNotes() }
        server.start()
    }

    func stop() {
        files.stop()
        simulation?.cancel(); simulation = nil
        midi.shutdown(); server.stop()
    }

    func clearNotes() {
        simulation?.cancel(); simulation = nil; simulationRunning = false
        activeNotes.removeAll()
        activeChannels.removeAll()
        server.reset()
        latestEvent = "琴键状态已清空"
    }

    func testChord() { simulate([60, 64, 67], arpeggio: false) }
    func testScale() { simulate([60, 62, 64, 65, 67, 69, 71, 72], arpeggio: true) }

    private func simulate(_ notes: [Int], arpeggio: Bool) {
        clearNotes()
        simulationRunning = true
        simulation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if arpeggio {
                    for note in notes {
                        self.simulatedEvents &+= 1; self.forward(.init(kind: .noteOn, note: note, velocity: 90))
                        try await Task.sleep(for: .milliseconds(350))
                        self.simulatedEvents &+= 1; self.forward(.init(kind: .noteOff, note: note))
                    }
                } else {
                    for note in notes { self.simulatedEvents &+= 1; self.forward(.init(kind: .noteOn, note: note, velocity: 90)) }
                    try await Task.sleep(for: .seconds(1))
                    for note in notes { self.simulatedEvents &+= 1; self.forward(.init(kind: .noteOff, note: note)) }
                }
            } catch { return }
            self.simulationRunning = false; self.simulation = nil
        }
    }

    private func forward(_ event: LinkMIDIEvent) {
        server.send(event)
        switch event.kind {
        case .noteOn:
            activeChannels[event.channel, default: []].insert(event.note)
            latestEvent = "Note On  ·  \(noteName(event.note))  ·  力度 \(event.velocity)  ·  通道 \(event.channel + 1)"
        case .noteOff:
            activeChannels[event.channel, default: []].remove(event.note)
            latestEvent = "Note Off  ·  \(noteName(event.note))  ·  通道 \(event.channel + 1)"
        case .controlChange:
            latestEvent = "CC \(event.controller)  ·  值 \(event.value)  ·  通道 \(event.channel + 1)"
        case .allNotesOff:
            activeChannels[event.channel] = []
            latestEvent = "通道 \(event.channel + 1)：全部音符释放"
        }
        activeNotes = activeChannels.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
    }

    func noteName(_ note: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[note % 12])\(note / 12 - 1) (\(note))"
    }
}

private struct BridgeWindow: View {
    @Bindable var model: BridgeModel
    @State private var isChoosingImport = false
    @State private var choosingFolder = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "pianokeys").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PianoBridge").font(.title.bold())
                    Text("USB MIDI → Mac → Apple Vision Pro").foregroundStyle(.secondary)
                }
            }
            GroupBox("1. 连接电钢琴") {
                VStack(alignment: .leading, spacing: 12) {
                    if model.midi.connectedSourceID == nil {
                        Text("将 RD-2000 / RD-2000 EX 的 USB COMPUTER 端口连接到 Mac。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Picker("MIDI 输入", selection: Binding(get: { model.midi.selectedSourceID },
                                                               set: { model.midi.selectedSourceID = $0 })) {
                            Text("请选择输入").tag(Int32?.none)
                            ForEach(model.midi.sources) { source in Text(source.name).tag(Optional(source.id)) }
                        }
                        Button { model.midi.refreshSources() } label: { Image(systemName: "arrow.clockwise") }
                            .help("刷新 MIDI 输入")
                        Button(model.midi.connectedSourceID == nil ? "连接" : "切换输入") { model.midi.connectSelected() }
                            .disabled(model.midi.selectedSourceID == nil)
                        if model.midi.connectedSourceID != nil { Button("断开") { model.midi.disconnect() } }
                    }
                    Text(model.midi.status).font(.callout).textSelection(.enabled)
                    if model.midi.sources.isEmpty {
                        Text("未发现 MIDI 输入。请检查 USB 线和琴的 USB 驱动模式，或发送测试音符检查头显连接。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            GroupBox("2. 连接 Vision Pro") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(model.server.isRunning ? .green : .orange).frame(width: 8, height: 8)
                        Text(model.server.status)
                        Spacer()
                        if model.server.isRunning {
                            Button("停止中转") { model.files.cancel(); model.clearNotes(); model.server.stop() }
                        } else { Button("启动中转") { model.server.start() } }
                    }
                    if model.server.clientCount == 0 {
                        Text("Mac 与头显需在同一局域网。在头显的“连接”页选择这台 Mac，并允许本地网络访问。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Mac 地址：\(ProcessInfo.processInfo.hostName)")
                        Spacer()
                        Text(model.server.port == 0 ? "端口：—" : "端口：\(model.server.port)")
                    }.font(.caption.monospaced()).textSelection(.enabled)
                }.padding(8)
            }
            GroupBox("3. 演奏与测试") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 24) {
                        metric("输入事件", value: "\(model.midi.receivedEvents)")
                        metric("已转发事件", value: "\(model.server.eventCount)")
                        metric("已连接头显", value: "\(model.server.clientCount)")
                        metric("按下琴键", value: "\(model.activeNotes.count)")
                    }
                    Text(model.latestEvent).font(.callout.monospaced()).textSelection(.enabled)
                    Text(model.activeNotes.sorted().map { model.noteName($0) }.joined(separator: "   "))
                        .font(.caption).foregroundStyle(.secondary).frame(minHeight: 15)
                    HStack {
                        Button("测试 C 大三和弦") { model.testChord() }
                        Button("测试 C 大调音阶") { model.testScale() }
                        Spacer()
                        Button("清空按键状态") { model.clearNotes() }
                    }
                    Text("测试不发声，仅检查连接和琴键高亮。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            fileImportSection
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 680, minHeight: 620)
        .fileImporter(isPresented: $isChoosingImport,
                      allowedContentTypes: choosingFolder ? [.folder] : [.midi, UTType(filenameExtension: "midi") ?? .midi],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    if choosingFolder { model.files.selectFolder(url) }
                    else { model.files.selectFile(url) }
                }
            case .failure(let error): model.files.selectionFailed(error)
            }
        }
    }

    private var fileImportSection: some View {
        GroupBox("4. 导入 MIDI 曲目") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("选择 MIDI 文件") { choosingFolder = false; isChoosingImport = true }
                    Button("选择文件夹") { choosingFolder = true; isChoosingImport = true }
                    Spacer()
                    Text("含子文件夹 · 每首最多 20 MB").font(.caption).foregroundStyle(.secondary)
                }.disabled(model.files.isScanning || model.files.isSending)
                Text(model.files.status).font(.callout).textSelection(.enabled)
                if model.files.isScanning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button("取消扫描") { model.files.cancel() }
                    }
                }
                if !model.files.items.isEmpty {
                    HStack(spacing: 16) {
                        Text("共 \(model.files.items.count) 首")
                        Text("已导入 \(model.files.importedCount)")
                        Text("待处理 \(model.files.pendingCount)")
                        if model.files.failedCount > 0 { Text("失败 \(model.files.failedCount)").foregroundStyle(.red) }
                    }.font(.caption.monospacedDigit())
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.files.items) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(item.relativePath).lineLimit(1).truncationMode(.middle).help(item.relativePath)
                                        Spacer(minLength: 12)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
                                            .foregroundStyle(.secondary)
                                        Text(item.state.label)
                                            .foregroundStyle(item.state.isFailure ? Color.red : Color.secondary)
                                            .frame(minWidth: 70, alignment: .trailing)
                                    }
                                    if let error = item.errorMessage {
                                        Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                                    }
                                }
                                Divider()
                            }
                        }.padding(10)
                    }
                    .frame(height: min(240, CGFloat(model.files.items.count) * 58 + 12))
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
                if !model.server.connectedClients.isEmpty {
                    Picker("接收头显", selection: Binding<UUID?>(get: { model.receiverID }, set: { model.selectedReceiverID = $0 })) {
                        Text("请选择 Vision Pro").tag(UUID?.none)
                        ForEach(model.server.connectedClients) { peer in
                            Text(peer.name).tag(Optional(peer.id))
                        }
                    }.disabled(model.files.isSending)
                } else {
                    Text("请先在头显的“连接”页连接这台 Mac，再发送曲目。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(importButtonTitle) {
                        if let receiverID = model.receiverID { model.files.send(to: receiverID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSendToReceiver || model.server.isSendingFile)
                    if model.files.isSending {
                        ProgressView(value: model.server.fileTransferProgress).frame(maxWidth: 180)
                        Button("取消导入") { model.files.cancel() }
                    }
                }
                if model.files.isSending { Text(model.server.fileTransferStatus).font(.callout).textSelection(.enabled) }
                Text("批量导入不切换当前曲目；失败或取消后可重试。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var importButtonTitle: String {
        if model.files.isSending { return "正在导入…" }
        if canSendToReceiver && !model.files.canSend { return "导入到当前头显" }
        if !model.files.items.isEmpty && model.files.importedCount == model.files.items.count { return "全部已导入" }
        if model.files.importedCount > 0 || model.files.failedCount > 0 { return "继续 / 重试未完成" }
        return model.files.items.count > 1 ? "批量导入到 Vision Pro" : "发送到 Vision Pro"
    }

    private var canSendToReceiver: Bool {
        guard let receiverID = model.receiverID else { return false }
        return model.files.canSend(to: receiverID)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title2.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
