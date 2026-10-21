import SwiftUI

/// Large discrete controls stay usable inside the dashboard's scrolling content.
struct CalibrationControlsView: View {
    @Bindable var session: PianoSession
    @Binding var isAdjusting: Bool
    @State private var fineAdjustment = false
    @State private var drafts: [NumericField: String] = [:]
    @State private var inputError: String?
    @State private var fingerCalibrationTask: Task<Void, Never>?
    @FocusState private var focusedField: NumericField?

    private var calibration: SpatialCalibration { session.calibration }
    private var translationStep: Float { fineAdjustment ? 0.001 : 0.01 }
    private var isFingerCalibrationInProgress: Bool {
        calibration.isFingerCalibrationBusy || calibration.hasFingerCalibrationFirstPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            instructions
            fingerCalibrationControls
            HStack(alignment: .top, spacing: 20) {
                movementControls
                dimensionsControls
            }
            .disabled(!calibration.isCalibrating || calibration.isSavingAnchor || isFingerCalibrationInProgress)
            saveControls
        }
        .onChange(of: focusedField) { old, new in
            if let old { commit(old) }
            if let new {
                session.pause()
                drafts[new] = formattedValue(new)
            }
            isAdjusting = new != nil
        }
        .onDisappear {
            if let focusedField { commit(focusedField) }
            fingerCalibrationTask?.cancel()
            fingerCalibrationTask = nil
            calibration.cancelFingerCalibration()
            isAdjusting = false
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("琴位校准 · 88 键", systemImage: "viewfinder").font(.title2.bold())
            Text("先依次取左右两端的位置，再检查两端、C4 与黑键。需要微调时开启校准参照，用下方按钮调整，最后保存琴位。")
                .foregroundStyle(.secondary)
            HStack {
                Toggle("显示校准参照", isOn: $session.calibration.isCalibrating)
                Spacer()
                Text(calibration.trackingStatus).font(.caption)
                    .foregroundStyle(calibration.isTracked ? .green : .orange)
            }
            Button {
                finishEditing()
                session.pause()
                Task { await calibration.placeTemplateInFront() }
            } label: {
                Label("把模板放到面前", systemImage: "person.crop.rectangle")
                    .frame(minHeight: 34)
            }.buttonStyle(.borderedProminent).tint(.cyan)
            Text("校准参照与练习时的黑白琴键底图独立；关闭参照后，位置与尺寸会锁定。")
                .font(.caption).foregroundStyle(.secondary)
            Text("此按钮只提供手动校准的起点：前方约 65 cm、琴高约 72 cm；仍需对齐实体琴键。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(calibration.isSavingAnchor || isFingerCalibrationInProgress)
        .calibrationPanel()
    }

    private var fingerCalibrationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("两端指尖取点", systemImage: "hand.point.up.left.fill").font(.headline)
            Text("1. 先点“采左端”，在 3 秒内把左手食指轻触最左 A0 白键的前缘中心。保持左手，直到左端完成提示。")
                .font(.subheadline)
            Text("2. 再点“采右端”，用右手食指轻触最右 C8 白键的前缘中心。保持右手，直到成功提示。")
                .font(.subheadline)
            Text("不用按下琴键；每次只需保持当前那只手。首次使用会请求手部追踪权限，仅在点击后读取指定食指位置，完成后停止采样。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button {
                    finishEditing()
                    session.pause()
                    fingerCalibrationTask?.cancel()
                    fingerCalibrationTask = Task { await calibration.startFingerCalibration() }
                } label: {
                    Label(calibration.hasFingerCalibrationFirstPoint ? "3 秒后采右端 C8" : "3 秒后采左端 A0",
                          systemImage: "timer")
                        .frame(minHeight: 34)
                }
                .buttonStyle(.borderedProminent).tint(.cyan)
                .disabled(!calibration.canStartFingerCalibration || calibration.isSavingAnchor || calibration.isFingerCalibrationActive)
                if calibration.isFingerCalibrationActive {
                    Button("取消取点") { cancelFingerCalibration() }
                        .buttonStyle(.bordered)
                } else if calibration.hasFingerCalibrationFirstPoint {
                    Button("重新取左端") { cancelFingerCalibration() }
                        .buttonStyle(.bordered)
                        .disabled(calibration.isSavingAnchor)
                }
            }
            Text(calibration.fingerCalibrationStatus)
                .font(.subheadline).foregroundStyle(calibration.isFingerCalibrationActive ? .cyan : .secondary)
            if !calibration.isTracked {
                Text("请先打开空间练习，等待琴位追踪恢复后再开始取点。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("两端成功后会估算位置、宽度与高度。请检查两端及中部 C4 的琴面高度和黑键，必要时用按钮微调，再点“保存并固定琴位”。")
                .font(.caption).foregroundStyle(.secondary)
        }.calibrationPanel()
    }

    private var movementControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("移动模板").font(.headline)
            Picker("移动步长", selection: $fineAdjustment) {
                Text("粗调 · 1 cm").tag(false)
                Text("细调 · 1 mm").tag(true)
            }.pickerStyle(.segmented)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    moveButton("向左", symbol: "arrow.left") { calibration.nudgePlacement(right: -translationStep) }
                    moveButton("向右", symbol: "arrow.right") { calibration.nudgePlacement(right: translationStep) }
                }
                GridRow {
                    moveButton("升高", symbol: "arrow.up") { calibration.nudgePlacement(up: translationStep) }
                    moveButton("降低", symbol: "arrow.down") { calibration.nudgePlacement(up: -translationStep) }
                }
                GridRow {
                    moveButton("远离身体", symbol: "arrow.up.right") { calibration.nudgePlacement(towardPlayer: -translationStep) }
                    moveButton("靠近身体", symbol: "arrow.down.left") { calibration.nudgePlacement(towardPlayer: translationStep) }
                }
            }
            Text("左右与前后跟随参照方向；升降始终沿竖直方向。长按按钮可连续步进。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(calibration.hasSavedAnchor ? "位置数值 · 相对已保存定位点" : "位置数值 · 房间坐标")
                .font(.subheadline).foregroundStyle(.secondary)
            numericRow(.x)
            numericRow(.y)
            numericRow(.z)
        }.calibrationPanel()
    }

    private var dimensionsControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("角度与琴键尺寸").font(.headline)
            Text(fineAdjustment ? "角度每次 0.1°；键宽每次 0.1 mm。" : "角度每次 1°；键宽每次 0.5 mm。")
                .font(.caption).foregroundStyle(.secondary)
            numericRow(.yaw)
            numericRow(.pitch)
            numericRow(.roll)
            Divider()
            numericRow(.width)
            numericRow(.depth)
            Text("宽度会同时改变整排琴键间距。先对齐左右两端，再检查中部与黑键。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("预读时长与轨道长度可在“设置”中调整。")
                .font(.caption).foregroundStyle(.secondary)
            if let inputError { Text(inputError).font(.caption).foregroundStyle(.orange) }
        }.calibrationPanel()
    }

    private var saveControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button {
                    finishEditing()
                    session.pause()
                    Task { await calibration.saveAnchor() }
                } label: {
                    if calibration.isSavingAnchor { ProgressView("正在固定琴位…") }
                    else { Label("保存并固定琴位", systemImage: "pin.fill") }
                }.buttonStyle(.borderedProminent).tint(.cyan)
                    .disabled(!calibration.isCalibrating || calibration.isSavingAnchor || isFingerCalibrationInProgress)
                Button("重新放置琴位") {
                    finishEditing()
                    session.pause()
                    Task { await calibration.clearAnchor() }
                }
                .disabled(calibration.isSavingAnchor || isFingerCalibrationInProgress)
                Spacer()
                Text(calibration.hasSavedAnchor ? "已保存定位点 · 开启参照后可微调" : "尚未保存定位点")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = calibration.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Text("移动实体钢琴后请重新放置并保存。数值可直接点选输入，按回车或移开焦点后应用。")
                .font(.caption).foregroundStyle(.secondary)
        }.calibrationPanel()
    }

    private func moveButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            finishEditing()
            session.pause()
            action()
        } label: {
            Label(title, systemImage: symbol).font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
        }.buttonStyle(.bordered).buttonRepeatBehavior(.enabled)
    }

    private func numericRow(_ field: NumericField) -> some View {
        HStack(spacing: 10) {
            Text(field.title).font(.subheadline)
            Spacer(minLength: 4)
            Button {
                finishEditing()
                change(field, by: -step(for: field))
            } label: { Image(systemName: "minus").frame(width: 24, height: 28) }
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("减小\(field.title)")
            TextField(field.title, text: Binding(
                get: { drafts[field] ?? formattedValue(field) },
                set: { drafts[field] = $0 }
            ))
            .font(.body.monospacedDigit())
            .textFieldStyle(.roundedBorder)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .focused($focusedField, equals: field)
            .onSubmit { finishEditing() }
            .frame(width: 100)
            Text(field.unit).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Button {
                finishEditing()
                change(field, by: step(for: field))
            } label: { Image(systemName: "plus").frame(width: 24, height: 28) }
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("增大\(field.title)")
        }
    }

    private func value(for field: NumericField) -> Float {
        switch field {
        case .x: calibration.translationX
        case .y: calibration.translationY
        case .z: calibration.translationZ
        case .yaw: calibration.yawDegrees
        case .pitch: calibration.pitchDegrees
        case .roll: calibration.rollDegrees
        case .width: calibration.whiteKeyWidth
        case .depth: calibration.whiteKeyDepth
        }
    }

    private func setValue(_ value: Float, for field: NumericField) {
        guard !calibration.isSavingAnchor, value.isFinite else { return }
        session.pause()
        let limited = min(field.range.upperBound, max(field.range.lowerBound, value))
        switch field {
        case .x: calibration.translationX = limited
        case .y: calibration.translationY = limited
        case .z: calibration.translationZ = limited
        case .yaw: calibration.yawDegrees = limited
        case .pitch: calibration.pitchDegrees = limited
        case .roll: calibration.rollDegrees = limited
        case .width: calibration.whiteKeyWidth = limited
        case .depth: calibration.whiteKeyDepth = limited
        }
    }

    private func formattedValue(_ field: NumericField) -> String {
        String(format: "%.1f", value(for: field) * field.scale)
    }

    private func step(for field: NumericField) -> Float {
        switch field {
        case .x, .y, .z: translationStep
        case .yaw, .pitch, .roll: fineAdjustment ? 0.1 : 1
        case .width: fineAdjustment ? 0.0001 : 0.0005
        case .depth: fineAdjustment ? 0.001 : 0.005
        }
    }

    private func change(_ field: NumericField, by delta: Float) {
        inputError = nil
        setValue(value(for: field) + delta, for: field)
    }

    private func commit(_ field: NumericField) {
        guard let draft = drafts.removeValue(forKey: field) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let number = Float(text), number.isFinite else {
            inputError = "\(field.title)请输入有效数字，原值已保留。"
            return
        }
        inputError = nil
        setValue(number / field.scale, for: field)
    }

    private func finishEditing() {
        if let focusedField { commit(focusedField) }
        focusedField = nil
        isAdjusting = false
    }

    private func cancelFingerCalibration() {
        fingerCalibrationTask?.cancel()
        fingerCalibrationTask = nil
        calibration.cancelFingerCalibration()
    }
}

private enum NumericField: Hashable {
    case x, y, z, yaw, pitch, roll, width, depth

    var title: String {
        switch self {
        case .x: "左右 X"
        case .y: "高度 Y"
        case .z: "前后 Z"
        case .yaw: "水平旋转"
        case .pitch: "前后倾斜"
        case .roll: "左右倾斜"
        case .width: "白键宽度"
        case .depth: "白键深度"
        }
    }

    var unit: String {
        switch self {
        case .yaw, .pitch, .roll: "°"
        default: "mm"
        }
    }

    var scale: Float {
        switch self {
        case .yaw, .pitch, .roll: 1
        default: 1000
        }
    }

    var range: ClosedRange<Float> {
        switch self {
        case .x, .z: -100...100
        case .y: -10...10
        case .yaw: -180...180
        case .pitch, .roll: -45...45
        case .width: 0.018...0.028
        case .depth: 0.10...0.19
        }
    }
}

private extension View {
    func calibrationPanel() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }
}
