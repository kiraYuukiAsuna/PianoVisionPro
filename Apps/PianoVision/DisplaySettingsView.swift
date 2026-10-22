import PianoCore
import SwiftUI

struct DisplaySettingsView: View {
    @Bindable var session: PianoSession
    @Binding var isAdjusting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("设置", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Button("恢复显示默认") { session.displaySettings = PianoDisplaySettings() }
            }
            practiceSettings
            Divider()
            previewSettings
            Divider()
            guideSettings
            Divider()
            appearanceSettings
            Divider()
            placementSettings
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
        .onDisappear { isAdjusting = false }
    }

    private var practiceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("练习判定").font(.subheadline.bold())
            adjustment("目标音对齐容差", value: $session.targetAlignmentMilliseconds,
                       range: 50...2000, step: 50, scale: 1, unit: "ms")
            Text(session.practiceMode == .waitForNotes
                 ? "弹对再继续：容差决定可提前多久按下；到达目标后持续等待，晚弹不超时。"
                 : "自动滚动：容差决定可提前或延后多久按下，超出后判为错音或漏音。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("时机评分规则") {
                Text("只评已弹对音，按下与松开各占 50%。偏差 80 ms 内满分，达到 500 ms 为零分；长时间未松开会扣分。暂停、变速或输入中断时，未完成的测量不计入。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private var previewSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音符轨道").font(.subheadline.bold())
            adjustment("预读时长（实际时间）", value: $session.displaySettings.lookAheadSeconds,
                       range: 2...10, step: 0.5, scale: 1, unit: "秒")
            adjustment("音符轨道长度", value: $session.displaySettings.rollLengthMeters,
                       range: 0.35...2, step: 0.05, scale: 100, unit: "cm")
            Text("预读按实际秒数计算，不随播放速度改变；预读越长，音符越密。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("远端音符渐入", isOn: $session.displaySettings.fadesDistantNotes)
            opacity("远端淡入强度", value: $session.displaySettings.farFadeStrength)
                .disabled(!session.displaySettings.fadesDistantNotes)
        }
    }

    private var guideSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("认谱辅助").font(.subheadline.bold())
            Toggle("黑键分组与 C 音位置", isOn: $session.displaySettings.showsLaneLandmarks)
            Toggle("拍线与小节线", isOn: $session.displaySettings.showsBeatGrid)
            Toggle("起音线与琴键的连接线", isOn: $session.displaySettings.showsKeyConnectors)
            Toggle("显示每个音符的起音标记", isOn: $session.displaySettings.showsOnsetMarkers)
            Text("关闭起音标记后，仍显示松开重弹的双线提醒。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("颜色与清晰度").font(.subheadline.bold())
            opacity("音符不透明度", value: $session.displaySettings.noteOpacity)
            adjustment("空间音符厚度", value: $session.displaySettings.noteThicknessMillimeters,
                       range: 2...20, step: 1, scale: 1, unit: "mm")
            opacity("目标提示不透明度", value: $session.displaySettings.highlightOpacity)
            opacity("按住整键高亮不透明度", value: $session.displaySettings.feedbackOpacity)
            Toggle("练习时显示黑白琴键底图", isOn: $session.displaySettings.showsKeyboardGuides)
            opacity("黑白琴键底图不透明度", value: $session.displaySettings.templateOpacity)
        }
    }

    private var placementSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("间隙与琴面位置").font(.subheadline.bold())
            adjustment("连续音间隙", value: $session.displaySettings.noteGapMillimeters,
                       range: 0...10, step: 0.5, scale: 1, unit: "mm")
            adjustment("起音线距琴键后缘", value: $session.displaySettings.rearOffsetMeters,
                       range: 0...0.4, step: 0.005, scale: 100, unit: "cm")
            adjustment("轨道离琴面的高度", value: $session.displaySettings.surfaceHeightMeters,
                       range: 0...0.2, step: 0.002, scale: 100, unit: "cm")
            Text("间隙仅影响显示，不改变时值或判定。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func opacity(_ title: String, value: Binding<Double>) -> some View {
        adjustment(title, value: value, range: 0...1, step: 0.01, scale: 100, unit: "%")
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                            step: Double, scale: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: unit == "%" || unit == "ms" ? "%.0f %@" : "%.1f %@", value.wrappedValue * scale, unit))
                    .font(.caption.monospacedDigit()).frame(width: 76, alignment: .trailing)
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: { Image(systemName: "minus") }
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: { Image(systemName: "plus") }
            }
            Slider(value: value, in: range, step: step, onEditingChanged: { isAdjusting = $0 })
        }
    }
}
