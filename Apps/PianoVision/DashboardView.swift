import SwiftUI
import UniformTypeIdentifiers
import PianoCore

struct DashboardView: View {
    @Bindable var session: PianoSession
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isImporting = false
    @State private var isChangingSpace = false
    @State private var page = 0
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var editingNoteID: Int?
    @State private var isAdjustingControl = false
    @State private var isConfirmingRestart = false
    @State private var restartSongRevision: Int?
    @State private var startPracticeTask: Task<Void, Never>?

    private let accent = Color.cyan

    var body: some View {
        VStack(spacing: 20) {
            header
            Picker("工作区", selection: $page) {
                Text("练习台").tag(0)
                Text("曲库").tag(4)
                Text("琴位校准").tag(1)
                Text("连接").tag(2)
                Text("设置").tag(3)
            }
            .pickerStyle(.segmented)
            ZStack {
                ScrollView {
                    if page != 4 {
                        switch page {
                        case 1: CalibrationControlsView(session: session, isAdjusting: $isAdjustingControl)
                        case 3: DisplaySettingsView(session: session, isAdjusting: $isAdjustingControl)
                        case 2: connectionPanel
                        default: practicePanel
                        }
                    }
                }
                .scrollDisabled(isAdjustingControl)
                .opacity(page == 4 ? 0 : 1)
                .allowsHitTesting(page != 4)
                .accessibilityHidden(page == 4)

                // Keep the native scroll view and library state alive between
                // pages, preserving the exact offset in both lists and grids.
                ScrollView {
                    SongLibraryView(session: session, isActive: page == 4,
                                    onSelect: { page = 0 }, onImport: { isImporting = true })
                }
                .opacity(page == 4 ? 1 : 0)
                .allowsHitTesting(page == 4)
                .disabled(page != 4)
                .accessibilityHidden(page != 4)
            }
        }
        .onChange(of: page) { _, _ in isAdjustingControl = false }
        .onChange(of: session.songRevision) { _, _ in
            startPracticeTask?.cancel()
            isConfirmingRestart = false
            restartSongRevision = nil
        }
        .padding(28)
        .frame(minWidth: 900, minHeight: 660)
        .background(.black.opacity(0.14))
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.midi], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { session.importMIDI(from: url) }
            case .failure(let error): session.errorMessage = error.localizedDescription
            }
        }
        .alert("需要处理", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("知道了") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .task { session.start() }
        .onDisappear { startPracticeTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "pianokeys").font(.system(size: 36)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("PianoVision Pro").font(.title.bold())
                Text("让音符落在真实琴键上").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Label(session.bridge.isConnected ? "Mac 已连接" : "等待 Mac", systemImage: session.bridge.isConnected ? "wifi" : "wifi.slash")
                .font(.subheadline).foregroundStyle(session.bridge.isConnected ? .green : .secondary)
            Button { toggleSpace() } label: {
                Label(session.isImmersiveActive ? "退出空间练习" : "打开空间练习", systemImage: "viewfinder")
            }
            .buttonStyle(.borderedProminent).tint(accent)
            .disabled(isChangingSpace)
        }
    }

    private var practicePanel: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("当前曲目").font(.caption).foregroundStyle(.secondary)
                            Text(session.song?.title ?? "导入一首 MIDI 开始").font(.title2.bold()).lineLimit(2)
                        }
                        Spacer()
                        Button { page = 4 } label: { Label("打开曲库", systemImage: "music.note.list") }
                    }
                    PianoRollPreview(session: session).frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 16))
                    if session.preparationCountdown > 0 {
                        Label("准备 \(session.preparationCountdown) 秒 · 音符正在就位，倒计时结束后开始判定", systemImage: "timer")
                            .font(.subheadline.bold()).foregroundStyle(.cyan)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("蓝 / 橙：左 / 右手 · 亮边：正在按住 · 绿勾：已累计")
                        Text("青短线：提前就位，需保持 · 双起音线：松开重弹")
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(PianoSession.timeLabel(session.uiTime))
                        Slider(value: Binding(get: { session.uiTime }, set: { session.seek(to: $0) }), in: 0...max(0.1, session.song?.duration ?? 0.1)) { editing in
                            if editing { session.pause() }
                        }
                        Text(PianoSession.timeLabel(session.song?.duration ?? 0))
                    }.font(.caption.monospacedDigit())
                    HStack(spacing: 16) {
                        Button {
                            restartSongRevision = session.songRevision
                            isConfirmingRestart = true
                        } label: { Label("回到开头", systemImage: "backward.end.fill") }
                            .disabled(session.song == nil)
                            .help("确认后暂停并回到曲目开头，清空本轮演奏统计")
                            .alert("回到曲目开头？", isPresented: $isConfirmingRestart) {
                                Button("取消", role: .cancel) { restartSongRevision = nil }
                                Button("回到开头", role: .destructive) {
                                    guard restartSongRevision == session.songRevision else { return }
                                    session.restart()
                                    restartSongRevision = nil
                                }
                            } message: {
                                Text("这会暂停练习、回到曲目开头，并清空本轮演奏统计。")
                            }
                        Button { startOrPausePractice() } label: {
                            Label(isChangingSpace ? "正在准备…" : session.isPlaying ? "暂停" : "开始练习",
                                  systemImage: session.isPlaying ? "pause.fill" : "play.fill")
                        }.buttonStyle(.borderedProminent).tint(accent)
                            .disabled(isChangingSpace || session.song == nil || session.selectedNoteCount == 0)
                        Spacer()
                        Text("速度").foregroundStyle(.secondary)
                        Picker("播放速度", selection: Binding(get: { session.playbackRate }, set: { session.setRate($0) })) {
                            ForEach(5...12, id: \.self) { step in
                                Text("\(step * 10)%").tag(Double(step) / 10)
                            }
                        }.frame(width: 110)
                    }
                    practiceModeControls
                    if !session.isImmersiveActive {
                        Label("打开空间练习并校准琴位，即可把引导叠加在实体琴键上。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.panel()
                trackPanel
                fingeringPanel
            }
            VStack(alignment: .leading, spacing: 20) {
                feedbackPanel
                inputPanel
            }.frame(width: 270)
        }
    }

    private var trackPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("练习轨道").font(.headline)
            ForEach(session.song?.tracks ?? []) { track in
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { session.enabledTrackIDs.contains(track.id) }, set: { session.setTrack(track.id, enabled: $0) })) {
                        Text(track.name.isEmpty ? "轨道 \(track.id + 1)" : track.name)
                    }
                    Picker("轨道演奏手", selection: Binding<PianoHand?>(
                        get: { session.trackHands[track.id] },
                        set: { session.setHand($0, forTrack: track.id) }
                    )) {
                        Text("自动").tag(Optional<PianoHand>.none)
                        Text("左手").tag(Optional(PianoHand.left))
                        Text("右手").tag(Optional(PianoHand.right))
                        Text("未分配").tag(Optional(PianoHand.unassigned))
                    }.frame(width: 160)
                }
            }
            Toggle("自动拆分未指定的轨道", isOn: $session.automaticHandSplit)
            if session.automaticHandSplit {
                HStack {
                    Text("左右手分界").font(.subheadline)
                    Spacer()
                    Stepper(PianoSession.noteName(session.splitPitch), value: $session.splitPitch, in: 21...108)
                        .frame(width: 160)
                }
                Text("分界音及以上建议右手，更低的音建议左手；可按轨道手动指定。跨手段落需自行判断。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                ForEach([PianoHand.left, .right, .unassigned], id: \.self) { hand in
                    Label {
                        Text(PracticeAppearance.name(for: hand))
                    } icon: {
                        Circle().fill(PracticeAppearance.color(for: hand)).frame(width: 9, height: 9)
                    }.font(.caption)
                }
            }
            if let song = session.song {
                let outside = song.notes.filter { $0.pitch < 21 || $0.pitch > 108 }.count
                if outside > 0 { Text("\(outside) 个音符超出 88 键范围，空间视图将跳过这些音符。").font(.caption).foregroundStyle(.orange) }
            }
        }.panel()
    }

    private var practiceModeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("练习方式", selection: Binding(get: { session.practiceMode }, set: { session.setPracticeMode($0) })) {
                Text("自动滚动").tag(PracticeMode.automatic)
                Text("弹对再继续").tag(PracticeMode.waitForNotes)
            }.pickerStyle(.segmented)
            if session.practiceMode == .waitForNotes {
                Text("当前和弦逐音累积，允许像琶音一样松手移位弹完。提前范围由“设置”中的目标音对齐容差决定；后续重复音仍需重新按下。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("开始、继续或播放中跳转后，音符先滚动 3 秒再开始判定；准备时间不受播放速度影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var fingeringPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("显示指法建议", isOn: $session.showFingering).font(.headline)
            if session.showFingering {
                HStack {
                    Text("1 为拇指，5 为小指；数字表示建议指法，不检测实际手指。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        session.generateFingering()
                    } label: {
                        if session.isGeneratingFingering { ProgressView() } else { Text("生成指法") }
                    }.disabled(session.song == nil || session.isGeneratingFingering)
                }
                let notes = editableNotes
                if !notes.isEmpty {
                    Picker("修正接下来的音符", selection: Binding<Int?>(
                        get: { notes.contains(where: { $0.id == editingNoteID }) ? editingNoteID : notes.first?.id },
                        set: { editingNoteID = $0 }
                    )) {
                        ForEach(notes) { note in
                            Text("\(PianoSession.timeLabel(note.start)) · \(PianoSession.noteName(note.pitch)) · \(PracticeAppearance.name(for: session.hand(for: note)))")
                                .tag(Optional(note.id))
                        }
                    }
                    if let note = notes.first(where: { $0.id == editingNoteID }) ?? notes.first {
                        HStack(spacing: 10) {
                            Text("指法").font(.subheadline)
                            ForEach(1...5, id: \.self) { finger in
                                Button("\(finger)") { session.setFinger(finger, for: note.id) }
                                    .tint(session.finger(for: note) == finger ? PracticeAppearance.color(for: session.hand(for: note)) : .gray)
                                    .buttonStyle(.borderedProminent)
                            }
                            Button("恢复建议") { session.setFinger(nil, for: note.id) }
                        }
                    }
                }
                Text("自动拆手和指法适用于初步练习；复杂和弦、跨手与特殊奏法请按需要修正。")
                    .font(.caption).foregroundStyle(.secondary)
                if session.unsupportedFingeringCount > 0 {
                    Text("\(session.unsupportedFingeringCount) 个音符无法可靠生成指法，已留空；可在上方手动填写。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }.panel()
    }

    private var editableNotes: [PianoNote] {
        Array((session.song?.notes ?? []).lazy.filter {
            $0.start >= session.uiTime - 0.05 && session.enabledTrackIDs.contains($0.track)
        }.prefix(20))
    }

    private var feedbackPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("演奏反馈").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                percentageMetric("完成度", value: session.completionPercentage, color: .green)
                percentageMetric("时机分", value: session.timingPercentage, color: .cyan)
            }
            Text("完成度 = 正确 ÷（正确＋错音＋漏音），随已判定结果更新。")
                .font(.caption2).foregroundStyle(.secondary)
            Text(session.timingEvaluatedNoteCount > 0
                 ? "时机分仅评已弹对音，按下与松开各占一半；已评 \(session.timingEvaluatedNoteCount) 音。"
                 : "松键后更新时机分，尚无完整评分样本。")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            if session.practiceMode == .waitForNotes {
                if session.isWaiting {
                    Label("本组已弹 \(session.matchedWaitingPitches.count)/\(session.waitingPitches.count)", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Text(session.waitingPitches.sorted().map(PianoSession.noteName).joined(separator: " · "))
                        .font(.caption.monospaced())
                } else {
                    Label(session.isPlaying ? "跟随曲目，弹对继续" : "开始后弹完目标音继续", systemImage: "pianokeys")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
            HStack {
                metric("正确", value: session.hitCount, color: .green)
                metric("错音", value: session.wrongCount, color: .red)
                metric("漏音", value: session.missedCount, color: .orange)
            }
            Divider()
            HStack {
                Text("最近时差").foregroundStyle(.secondary)
                Spacer()
                Text(session.lastTimingMilliseconds.map { String(format: "%+.0f ms", $0) } ?? "—").monospacedDigit()
            }.font(.subheadline)
            Text(session.practiceMode == .automatic ? "负值表示提前，正值表示延后。暂停时仍可检查琴键输入。" : "等待期间不计漏音；已按下的琴键会立即显示。")
                .font(.caption).foregroundStyle(.secondary)
            Label(session.pedalDown ? "延音踏板按下" : "延音踏板松开", systemImage: "pianokeys")
                .font(.caption).foregroundStyle(session.pedalDown ? .cyan : .secondary)
        }.panel()
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("实时输入").font(.headline); Spacer(); Text("\(session.activeNotes.count) 键").font(.caption).foregroundStyle(.secondary) }
            if session.recentInputs.isEmpty {
                Text("在电钢琴上弹奏，或在 Mac 中转程序中点击测试音。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(session.recentInputs.prefix(7)) { input in
                HStack {
                    Text(PianoSession.noteName(input.pitch)).font(.body.monospaced().bold()).frame(width: 46, alignment: .leading)
                    Text("力度 \(input.velocity)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(input.label).font(.caption).foregroundStyle(input.label == "错音" ? .red : .cyan)
                }
            }
            Button("清空按键状态") { session.resetInput() }.font(.caption)
        }.panel()
    }

    private func metric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(value)").font(.title.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percentageMetric(_ label: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.title.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: value ?? 0, total: 100).tint(color)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("连接 Mac 中转", systemImage: "desktopcomputer").font(.title3.bold())
            Text("RD-2000 EX 的 USB COMPUTER 接口连接 Mac，并在 PianoBridge 中选择 MIDI 输入源。两台设备需位于同一局域网。").font(.subheadline).foregroundStyle(.secondary)
            Text(session.bridge.status).font(.subheadline)
            if let milliseconds = session.bridge.latencyMilliseconds {
                Text(String(format: "网络往返 %.1f ms", milliseconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(session.bridge.services) { service in
                Button { session.bridge.connect(to: service) } label: {
                    HStack { Image(systemName: "desktopcomputer"); Text(service.name); Spacer(); Image(systemName: "arrow.right") }
                }
            }
            if session.bridge.services.isEmpty { Text("正在寻找 PianoBridge…").foregroundStyle(.secondary) }
            Divider()
            TextField("Mac IP 地址（自动发现失败时）", text: $manualHost).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Mac 界面显示的端口", text: $manualPort).keyboardType(.numberPad)
            HStack {
                Button("连接 IP") {
                    if let port = UInt16(manualPort), port > 0 {
                        session.bridge.connect(host: manualHost.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
                    }
                }.disabled(manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (UInt16(manualPort) ?? 0) == 0)
                Button("重新搜索") { session.bridge.restartBrowsing() }
                if session.bridge.isConnected { Button("断开") { session.bridge.disconnect() } }
            }
            Divider()
            Picker("接收 MIDI 通道", selection: $session.inputChannel) {
                Text("全部通道").tag(-1)
                ForEach(0..<16) { channel in Text("通道 \(channel + 1)").tag(channel) }
            }.onChange(of: session.inputChannel) { _, _ in session.resetInput() }
            Text("若 RD 多个音区重复发送相同音符，可只接收一个通道。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("输入时间修正")
                Spacer()
                Text(String(format: "%+.0f ms", session.inputOffsetMilliseconds)).monospacedDigit()
            }.font(.caption)
            Slider(value: $session.inputOffsetMilliseconds, in: -150...150, step: 5)
            Text("时间修正仅影响自动滚动的节奏计分。")
                .font(.caption).foregroundStyle(.secondary)
        }.panel().frame(maxWidth: .infinity)
    }

    private func startOrPausePractice() {
        if session.isPlaying { session.pause(); return }
        guard !isChangingSpace, session.song != nil, session.selectedNoteCount > 0 else { return }
        isChangingSpace = true
        let revision = session.songRevision
        startPracticeTask = Task { @MainActor in
            defer {
                isChangingSpace = false
                startPracticeTask = nil
            }
            if !session.isImmersiveActive {
                switch await openImmersiveSpace(id: "PianoSpace") {
                case .opened: session.isImmersiveActive = true
                case .error:
                    session.errorMessage = "无法打开空间练习，请关闭其他沉浸式应用后重试。"
                    return
                case .userCancelled: return
                @unknown default: return
                }
            }
            // Let the existing world anchor resume before beginning the score.
            for _ in 0..<50 {
                guard !Task.isCancelled, session.songRevision == revision, session.isImmersiveActive else { return }
                if session.calibration.isTracked { break }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled, session.songRevision == revision, session.isImmersiveActive else { return }
            session.play()
        }
    }

    private func toggleSpace() {
        guard !isChangingSpace else { return }
        isChangingSpace = true
        Task {
            if session.isImmersiveActive {
                session.pause()
                await dismissImmersiveSpace()
                session.isImmersiveActive = false
            } else {
                switch await openImmersiveSpace(id: "PianoSpace") {
                case .opened: session.isImmersiveActive = true
                case .error: session.errorMessage = "无法打开空间练习，请关闭其他沉浸式应用后重试。"
                case .userCancelled: break
                @unknown default: break
                }
            }
            isChangingSpace = false
        }
    }
}

private extension View {
    func panel() -> some View {
        self.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct PianoRollPreview: View {
    let session: PianoSession
    @State private var cachedNotes: [PianoNote] = []
    @State private var maximumEnds: [Double] = []
    @State private var nextOnsets: [Int: Double] = [:]

    var body: some View {
        // Input echoes also fade while playback is paused or waiting at a chord.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in drawPreview(context: &context, size: size) }
        }
        .onChange(of: session.songRevision, initial: true) { _, _ in cacheNotes() }
        .onChange(of: session.enabledTrackIDs) { _, _ in cacheNotes() }
        .accessibilityLabel("平铺音符预览，当前 \(PianoSession.timeLabel(session.uiTime))，\(session.activeNotes.count) 个琴键按下")
    }

    private struct KeyCue {
        var hand: PianoHand
        var role: PianoNoteRole
    }

    private func drawPreview(context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.025, green: 0.055, blue: 0.085)))
        let layout = KeyboardLayout(whiteKeyWidth: session.calibration.whiteKeyWidth,
                                    whiteKeyDepth: session.calibration.whiteKeyDepth)
        let settings = session.displaySettings.validated()
        let timing = PianoRollTiming(settings: settings, playbackRate: session.playbackRate)
        let geometry = PianoRollGeometry(layout: layout, rearOffsetMeters: settings.rearOffsetMeters,
                                         surfaceHeightMeters: settings.surfaceHeightMeters)
        let ratio = size.width / CGFloat(layout.width)
        let keyY = max(1, size.height - 38)
        let connectorHeight = min(keyY * 0.2, CGFloat(settings.rearOffsetMeters) / CGFloat(timing.lengthMeters) * keyY)
        let hitY = keyY - connectorHeight
        let pixelsPerMeter = hitY / CGFloat(timing.lengthMeters)
        let time = session.songTime
        let windowEnd = time + timing.horizonSeconds
        let waitingNoteIDs = session.waitingNoteIDs
        let previewNoteIDs = session.targetPreviewNoteIDs
        let keyboardCueIDs = session.keyboardTargetNoteIDs
        let activeNotes = session.activeNotes
        let heldCorrectNotes = session.heldCorrectNotes
        let heldWrongNotes = session.heldWrongNotes
        let correctNotes = session.correctNotes
        let wrongNotes = session.wrongNotes
        var notes: [(PianoNote, PianoNotePresentation)] = []
        var cues: [Int: KeyCue] = [:]
        var acceptedCurrentPitches: Set<Int> = []
        var index = firstIndex(withEndAtOrAfter: time)
        while index < cachedNotes.count {
            let note = cachedNotes[index]
            if note.start > windowEnd { break }
            index += 1
            guard note.end > time || waitingNoteIDs.contains(note.id), layout.key(for: note.pitch) != nil else { continue }
            let presentation = session.notePresentation(for: note)
            notes.append((note, presentation))
            if presentation.role == .current, presentation.progress == .accepted, !presentation.isPendingEarly {
                acceptedCurrentPitches.insert(note.pitch)
            }
            guard keyboardCueIDs.contains(note.id), presentation.role != .upcoming else { continue }
            let hand = session.hand(for: note)
            if let previous = cues[note.pitch] {
                if presentation.role == .current && previous.role != .current {
                    cues[note.pitch] = KeyCue(hand: hand, role: .current)
                } else if presentation.role == previous.role, hand != previous.hand {
                    cues[note.pitch]?.hand = .unassigned
                }
            } else {
                cues[note.pitch] = KeyCue(hand: hand, role: presentation.role)
            }
        }

        if settings.showsLaneLandmarks {
            drawLandmarks(context: &context, layout: layout, ratio: ratio, hitY: hitY)
        }
        if settings.showsBeatGrid, let song = session.song {
            for beat in song.beats(in: time...windowEnd, limit: 96) {
                let offset = beat.time - time
                let y = hitY - CGFloat(offset / timing.horizonSeconds) * hitY
                let fade = Double(timing.distanceOpacity(forScoreOffset: offset, settings: settings))
                let line = CGRect(x: 0, y: y, width: size.width, height: beat.isMeasure ? 1 : 0.5)
                context.fill(Path(line), with: .color(Color.white.opacity((beat.isMeasure ? 0.19 : 0.07) * fade)))
                if beat.isMeasure, y > 8 {
                    context.draw(Text("\(beat.measure)").font(.system(size: 7)).foregroundColor(.white.opacity(0.35 * fade)),
                                 at: CGPoint(x: 5, y: y - 5), anchor: .leading)
                }
            }
        }
        if settings.showsKeyConnectors, connectorHeight > 0 {
            for key in layout.keys {
                guard let cue = cues[key.note] else { continue }
                let x = CGFloat(key.centerX) * ratio
                var line = Path()
                line.move(to: CGPoint(x: x, y: hitY))
                line.addLine(to: CGPoint(x: x, y: keyY + 1))
                context.stroke(line, with: .color(PracticeAppearance.color(for: cue.hand)
                    .opacity(cue.role == .current ? 0.6 : 0.25)), lineWidth: cue.role == .current ? 1.4 : 0.8)
            }
        }
        for (note, presentation) in notes {
            guard let key = layout.key(for: note.pitch),
                  let visual = geometry.note(note, at: time, speed: timing.speedMetersPerScoreSecond,
                    horizon: timing.horizonSeconds, gapMillimeters: settings.noteGapMillimeters,
                    nextSamePitchStart: nextOnsets[note.id], isWaitingTarget: waitingNoteIDs.contains(note.id)) else { continue }
            // A repeated pitch may consume an older sustained bar completely.
            // Its check and finger marks must disappear with the body;
            // a real onset (including a zero-duration waiting target) stays.
            guard visual.hasVisibleContent else { continue }
            let bottom = hitY - CGFloat(geometry.hitLineZ - visual.frontZ) * pixelsPerMeter
            let top = hitY - CGFloat(geometry.hitLineZ - visual.tailZ) * pixelsPerMeter
            guard bottom > 0 else { continue }
            let width = max(2, CGFloat(key.width * 0.8) * ratio)
            let minimumHeight: CGFloat = waitingNoteIDs.contains(note.id) ? 2 : 0
            let visibleTop = max(0, min(top, bottom - minimumHeight))
            let rect = CGRect(x: CGFloat(key.centerX - key.width * 0.4) * ratio,
                              y: visibleTop, width: width, height: max(0, bottom - visibleTop))
            var noteContext = context
            noteContext.opacity = settings.noteOpacity * Double(timing.distanceOpacity(forScoreOffset: note.start - time, settings: settings))
            drawNote(context: &noteContext, note: note, presentation: presentation, visual: visual,
                     key: key, rect: rect, bottom: bottom, hitY: hitY, settings: settings,
                     isPreviewTarget: previewNoteIDs.contains(note.id))
        }
        context.fill(Path(CGRect(x: 0, y: hitY - 1, width: size.width, height: 1)), with: .color(.cyan.opacity(0.75)))
        for black in [false, true] {
            for key in layout.keys where key.isBlack == black {
                let inset: CGFloat = black ? 0 : 0.5
                let rect = CGRect(x: CGFloat(key.centerX - key.width / 2) * ratio + inset, y: keyY,
                                  width: max(1, CGFloat(key.width) * ratio - inset * 2), height: black ? 24 : 38)
                drawKey(context: &context, key: key, rect: rect, cue: cues[key.note],
                        isPlayed: activeNotes.contains(key.note), isCorrect: heldCorrectNotes.contains(key.note),
                        isWrong: heldWrongNotes.contains(key.note), isAccepted: acceptedCurrentPitches.contains(key.note),
                        recentCorrect: correctNotes.contains(key.note), recentWrong: wrongNotes.contains(key.note), settings: settings)
                if settings.showsLaneLandmarks, key.note % 12 == 0 {
                    context.draw(Text("C\(key.note / 12 - 1)").font(.system(size: 7, weight: .medium))
                        .foregroundColor(.white.opacity(0.75)), at: CGPoint(x: rect.midX, y: rect.maxY - 6))
                }
            }
        }
    }

    private func drawLandmarks(context: inout GraphicsContext, layout: KeyboardLayout, ratio: CGFloat, hitY: CGFloat) {
        for key in layout.keys {
            if key.isBlack {
                let lane = CGRect(x: CGFloat(key.centerX - key.width / 2) * ratio, y: 0,
                                  width: CGFloat(key.width) * ratio, height: hitY)
                context.fill(Path(lane), with: .color(.black.opacity(0.23)))
            } else if key.note % 12 == 0 {
                let line = CGRect(x: CGFloat(key.centerX - key.width / 2) * ratio, y: 0, width: 0.7, height: hitY)
                context.fill(Path(line), with: .color(.white.opacity(0.15)))
            }
            if key.note % 12 == 1 || key.note % 12 == 6 {
                let lastPitch = key.note + (key.note % 12 == 1 ? 2 : 4)
                guard let last = layout.key(for: lastPitch) else { continue }
                let left = CGFloat(key.centerX - key.width / 2) * ratio
                let right = CGFloat(last.centerX + last.width / 2) * ratio
                let group = CGRect(x: left, y: 4, width: right - left, height: 1.5)
                context.fill(Path(roundedRect: group, cornerRadius: 0.75), with: .color(.white.opacity(0.2)))
            }
        }
    }

    private func drawNote(context: inout GraphicsContext, note: PianoNote, presentation: PianoNotePresentation,
                          visual: PianoRollNoteGeometry, key: KeyGeometry, rect: CGRect,
                          bottom: CGFloat, hitY: CGFloat, settings: PianoDisplaySettings, isPreviewTarget: Bool) {
        let hand = session.hand(for: note)
        let body = PracticeAppearance.noteColor(for: presentation.isHeld ? .pressed : .normal, hand: hand, isBlack: key.isBlack)
        if rect.height > 0 {
            let shape = Path(roundedRect: rect, cornerRadius: 2)
            context.fill(shape, with: .color(body))
            let isCurrentUnplayed = isPreviewTarget && presentation.role == .current && presentation.progress == .unplayed
            let edgeOpacity = presentation.isHeld ? 1.0 : isCurrentUnplayed ? 0.95 : key.isBlack ? 0.55 : 0.25
            if rect.height > 1 {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2),
                               with: .color(Color.white.opacity(edgeOpacity)), lineWidth: presentation.isHeld || isCurrentUnplayed ? 1.6 : 0.7)
            }
        }
        let attackY = min(hitY - 2, bottom - 2)
        if (settings.showsOnsetMarkers && visual.showsOnset) || presentation.needsRestrike {
            let edge = CGRect(x: rect.minX, y: attackY, width: rect.width, height: 1.5)
            context.fill(Path(edge), with: .color(.white.opacity(0.9)))
            if presentation.needsRestrike {
                context.fill(Path(edge.offsetBy(dx: 0, dy: -3)), with: .color(.white.opacity(0.9)))
            }
        }
        if presentation.isPendingEarly {
            let pending = CGRect(x: rect.minX, y: attackY - 1, width: rect.width, height: 2)
            context.fill(Path(pending), with: .color(.cyan))
        } else if presentation.progress != .unplayed {
            drawCheck(context: &context, at: CGPoint(x: rect.midX, y: min(hitY - 4, max(rect.minY + 3, bottom - 4))),
                      size: min(6, max(3, rect.width - 1)))
        }
        if session.showFingering, let finger = session.finger(for: note),
           (visual.showsOnset || presentation.isHeld), rect.height >= 13 {
            let point = CGPoint(x: rect.midX, y: min(hitY - 11, max(rect.minY + 7, bottom - 11)))
            context.draw(Text("\(finger)").font(.system(size: min(10, max(7, rect.width)), weight: .bold))
                .foregroundColor(key.isBlack ? .white : .black), at: point)
        }
    }

    private func drawKey(context: inout GraphicsContext, key: KeyGeometry, rect: CGRect, cue: KeyCue?,
                         isPlayed: Bool, isCorrect: Bool, isWrong: Bool, isAccepted: Bool,
                         recentCorrect: Bool, recentWrong: Bool, settings: PianoDisplaySettings) {
        let base = key.isBlack ? Color(white: 0.035) : .white
        context.fill(Path(rect), with: .color(base.opacity(settings.showsKeyboardGuides ? settings.templateOpacity : 0)))
        context.stroke(Path(rect), with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        if isPlayed {
            let feedback: PracticeAppearance.InputFeedback = isWrong ? .wrong : isCorrect || isAccepted ? .correct : .pressed
            let fill = Color(uiColor: PracticeAppearance.inputUIColor(feedback, isBlack: key.isBlack))
            context.fill(Path(rect), with: .color(fill.opacity(settings.feedbackOpacity)))
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(.white.opacity(settings.feedbackOpacity * 0.85)), lineWidth: 1)
        } else if let cue {
            let strength = cue.role == .current ? 1.0 : 0.25
            context.fill(Path(rect), with: .color(PracticeAppearance.color(for: cue.hand, isBlack: key.isBlack)
                .opacity(settings.highlightOpacity * strength)))
        }
        if !isPlayed {
            let intensity = session.inputPulseIntensity(for: key.note)
            if intensity > 0 {
                let feedback: PracticeAppearance.InputFeedback = recentWrong ? .wrong : recentCorrect || isAccepted ? .correct : .pressed
                let fill = Color(uiColor: PracticeAppearance.inputUIColor(feedback, isBlack: key.isBlack))
                let pulse = CGRect(x: rect.minX + 1, y: rect.maxY - 4, width: max(1, rect.width - 2), height: 3)
                context.fill(Path(pulse), with: .color(fill.opacity(settings.feedbackOpacity * intensity)))
            }
        }
        if isAccepted && !isPlayed && settings.highlightOpacity > 0 {
            var checkContext = context
            checkContext.opacity *= settings.highlightOpacity
            drawCheck(context: &checkContext, at: CGPoint(x: rect.midX, y: rect.minY + 5), size: min(6, max(3, rect.width - 1)))
        }
    }

    private func drawCheck(context: inout GraphicsContext, at point: CGPoint, size: CGFloat) {
        var check = Path()
        check.move(to: CGPoint(x: point.x - size * 0.45, y: point.y))
        check.addLine(to: CGPoint(x: point.x - size * 0.1, y: point.y + size * 0.3))
        check.addLine(to: CGPoint(x: point.x + size * 0.5, y: point.y - size * 0.4))
        context.stroke(check, with: .color(.black.opacity(0.75)), style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round))
        context.stroke(check, with: .color(.green), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }

    private func firstIndex(withEndAtOrAfter time: Double) -> Int {
        var low = 0
        var high = maximumEnds.count
        while low < high {
            let middle = (low + high) / 2
            if maximumEnds[middle] < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func cacheNotes() {
        cachedNotes = (session.song?.notes ?? []).filter { session.enabledTrackIDs.contains($0.track) }
        var maximumEnd = -Double.infinity
        maximumEnds = cachedNotes.map { note in
            maximumEnd = max(maximumEnd, note.end)
            return maximumEnd
        }
        nextOnsets = PianoRollGeometry.nextOnsets(for: cachedNotes)
    }
}
