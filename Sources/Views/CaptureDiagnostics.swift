import SwiftUI

/// 采集链路的实时读数面板。
///
/// 存在的理由很具体：出过一次「界面看着在录、实际上一个字都没进来」的
/// 事故，而当时用户手上唯一的线索是一个不动的转录列表——那既可能
/// 是麦克风没进来，也可能是进来了但识别不出来，两种情况的处理方式
/// 完全相反。把音频流经的每一站的计数摊开，这两种情况就一眼可分。
struct CaptureDiagnostics: View {
    @Environment(AppState.self) private var appState

    /// 峰值保持。瞬时电平一帧就过去了，盯着看反而容易漏掉「说话时到底
    /// 有没有抬起来」——留一个峰值在旁边，说完话再回来看也算数。
    @State private var peak: Float = 0
    @State private var showsFormat = false

    private var engine: TranscriptionEngine { appState.transcription }
    private var stats: TranscriptionEngine.CaptureStats { engine.captureStats }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                levelMeter
                counters
                Spacer(minLength: 8)
                formatToggle
            }

            if let diagnosis = engine.captureDiagnosis {
                StatusMark(kind: .warning, text: diagnosis)
            }

            if showsFormat {
                // 词表那行和音频格式并排放在这里：两者都是「引擎实际谈成了
                // 什么」，而这个面板的全部意义就是把谈成的东西摊开给人看。
                // 术语表灌没灌进去，此前在界面上完全不可见——用户改了术语表
                // 却发现识别没变化时，无从判断是词表没生效还是生效了但不够。
                VStack(alignment: .leading, spacing: 3) {
                    diagLine(engine.formatDescription.isEmpty
                        ? "（尚未开始，无格式信息）"
                        : engine.formatDescription)

                    if !engine.contextStatus.isEmpty {
                        diagLine("词表: \(engine.contextStatus)")
                    }
                }
            }
        }
        .onChange(of: engine.audioLevel) { _, new in
            // 只在采集时累积：停止后残留的峰值会误导「刚才明明有声音」
            if engine.isRunning {
                peak = max(peak, new)
            } else if peak > 0 {
                peak = 0
            }
        }
    }

    private func diagLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: - 电平

    private var levelMeter: some View {
        HStack(spacing: 7) {
            Text("电平")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)

            // 峰值刻度：一个小竖线，随声音往右推
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.separator)
                    .frame(width: 84, height: 6)

                Capsule()
                    .fill(meterColor)
                    .frame(width: 84 * fraction(engine.audioLevel), height: 6)

                Rectangle()
                    .fill(peakColor)
                    .frame(width: 2, height: 12)
                    .offset(x: max(0, 84 * fraction(peak) - 2))
                    .opacity(peak > 0 ? 1 : 0)
            }
            .frame(width: 84, height: 12)

            // 数值照实显示，不做美化：用户要据此判断「到底有没有收到声音」，
            // 四舍五入到 0.00 正好把要看的那个区别抹掉了
            Text(String(format: "%.4f", engine.audioLevel))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 52, alignment: .leading)
        }
    }

    /// 把线性幅度压到 0–1。线性刻度下底噪（0.004）几乎贴地、看不出变化，
    /// 换成 dB 刻度才能同时看见「很轻」和「很响」。
    private func fraction(_ level: Float) -> Double {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return max(0, min(1, (db + 60) / 60))
    }

    private var meterColor: Color {
        let f = fraction(engine.audioLevel)
        if engine.audioLevel == 0 { return Theme.separator }
        if f > 0.94 { return Theme.error }  // 快削顶了
        if f > 0.4 { return Theme.success }
        return Theme.accent
    }

    private var peakColor: Color { Theme.textSecondary }

    // MARK: - 计数

    private var counters: some View {
        HStack(spacing: 9) {
            counter("回调", stats.tapped)
            counter("转换", stats.converted)
            counter("帧", stats.frames)

            // 增益读数。自动档报平均值：每帧的增益都在动，抽一帧没有意义。
            // 用户改了这一档之后，唯一的确认方式就是这里
            if let mode = stats.gainMode {
                if mode == .auto, let average = stats.averageGain {
                    counter("增益", String(format: "%.2f×", average))
                } else {
                    counter("增益", mode.shortLabel)
                }
            }

            if stats.silentConversions > 0 {
                Text("⚠️ 静音 \(stats.silentConversions)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.warning)
                    .help("源有信号、转换后却全零。出现这个就说明音频在转换那一步被吞了")
            }
        }
    }

    /// 计数与读数共用同一套样式。`value` 收 `CustomStringConvertible`
    /// 而不是 `Int`：增益那一栏要显示「2.31×」这种带单位的串，
    /// 为它单开一个几乎一样的函数，早晚会和这个漂移。
    private func counter(_ label: String, _ value: some CustomStringConvertible) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text(value.description)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - 格式

    private var formatToggle: some View {
        Button {
            showsFormat.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(engine.voiceProcessingActive ? Theme.success : Theme.textTertiary)
                    .frame(width: 6, height: 6)
                Text(engine.voiceProcessingActive ? "降噪开" : "降噪关")
                    .font(.system(size: 10))
                Image(systemName: showsFormat ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("点击查看音频格式逐级转换的细节")
    }
}
