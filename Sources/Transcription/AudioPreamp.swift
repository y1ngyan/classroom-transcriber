import AVFoundation
import Foundation

/// 麦克风软件增益档位。
///
/// 存在的理由：老师离麦克风远、说话偏小的时候，原始 PCM 电平太低，
/// 离线识别会明显变差。在音频送进识别引擎**之前**做软件放大能实打实地
/// 改善小声 / 远距离的识别率；音频依然只在内存里流转，不落盘、不上传。
enum MicGainMode: String, CaseIterable, Identifiable {
    case auto
    case off
    case x2
    case x3
    case x5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .off: return "关闭"
        case .x2: return "2 倍"
        case .x3: return "3 倍"
        case .x5: return "5 倍"
        }
    }

    var hint: String {
        switch self {
        case .auto: return "声音小时自动放大，近静音不抬升、爆音有软限幅"
        case .off: return "不放大，用原始音量"
        case .x2: return "轻微放大"
        case .x3: return "明显放大"
        case .x5: return "离得很远 / 很安静时用"
        }
    }

    /// 状态栏那行里用的短标签。`label` 是给设置页的选择器用的，
    /// 带「（推荐）」这类说明，放进状态行会把一行字撑得没重点
    var shortLabel: String {
        switch self {
        case .auto: return "AGC"
        case .off: return "原音量"
        case .x2: return "×2"
        case .x3: return "×3"
        case .x5: return "×5"
        }
    }

    /// 固定倍数档用；AUTO / OFF 不走这个值
    var fixedGain: Float {
        switch self {
        case .auto: return 0
        case .off: return 1
        case .x2: return 2
        case .x3: return 3
        case .x5: return 5
        }
    }

    /// 从配置里读回来。
    ///
    /// 认不出来的一律回落 AUTO：配置里躺着一个笔误的档位名时，用户该拿到的
    /// 是默认行为，而不是「静默地一个增益都没做」——后者从界面上看不出来。
    static func of(_ id: String?) -> MicGainMode {
        guard let id, let mode = MicGainMode(rawValue: id) else { return .auto }
        return mode
    }

    /// 送进识别器的增益档，是不是「不放大」那一档
    var isPassthrough: Bool { self == .off }
}

/// 录音前级增益：纯计算、无系统依赖，可离线自检。
///
/// - 固定档：样本 × 倍数后做 `tanh` 软限幅。用 tanh 而不是直接夹到 ±1，
///   是因为硬削波会在波形上制造出原信号里没有的高次谐波，听感是「炸」，
///   对识别也是新的干扰；tanh 在 1.0 附近渐近饱和，越界只是压缩，不折叠。
/// - `auto`：轻量 AGC。按帧 RMS 缓慢把语音拉向目标电平，**带噪声门**，
///   增益有上限，增益自身做平滑以防「抽吸」。
///
/// **噪声门是这一档和「把信号归一化到某个电平」的全部区别，也是它值得存在
/// 的原因。** 之前在本项目上量过一次「增益对识别无用」，量的是无噪声门的
/// 简单归一化：底噪跟着语音一起被放大，SNR 分毫未变甚至更差，识别自然
/// 没有改善。这里的门限让近静音帧（`noiseFloor` 以下）的增益钉在 1.0，
/// 底噪原地不动，只有真正有语音的帧才被抬起来——SNR 是**改善**的。
/// 所以别再拿当初那条结论来否定这一级：两者不是同一个东西。
/// AGC 的价值全在低 SNR 场景（老师声音小、底噪不变）。
///
/// 处理只在唯一的采集线程内进行，对象本身不带锁——和 `HighPassFilter`
/// 同理，用锁保护反而会在实时线程上引入优先级倒置。
final class AudioPreamp {

    /// 本次录音的档位。构造时定死，不在录音中途改：改档意味着 AGC 状态
    /// 要跟着重置，而「录到一半突然换了个增益曲线」在存档和转录两边都会
    /// 留下对不上的痕迹。要换档就重新开始一段录音。
    let mode: MicGainMode

    // ---- AGC 运行状态（仅采集线程访问）----
    private var agcLevel: Float = AudioPreamp.targetRMS
    private var agcGain: Float = 1

    init(mode: MicGainMode = .auto) {
        self.mode = mode
    }

    /// 原地处理一帧 [-1,1] 的 PCM。
    ///
    /// - Returns: 本帧实际应用的线性增益。报出来是为了让界面能显示
    ///   「AGC 现在到底在不在干活」——只看输入电平是看不出来的。
    @discardableResult
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Float {
        switch mode {
        case .off:
            return 1
        case .auto:
            return processAuto(samples, count: count)
        case .x2, .x3, .x5:
            applyGain(samples, count: count, gain: mode.fixedGain)
            return mode.fixedGain
        }
    }

    @discardableResult
    func process(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 1 }
        return process(channel, count: Int(buffer.frameLength))
    }

    /// 开始一段新录音时复位 AGC 平滑状态。
    ///
    /// 不复位的话，上一段录音末尾收敛到的包络 / 增益会被当成新录音的起点，
    /// 开头那几帧就带着一个和实际电平无关的增益进去。
    func reset() {
        agcLevel = Self.targetRMS
        agcGain = 1
    }

    /// 当前 AGC 增益。读数用，不参与处理。
    var currentGain: Float { mode == .auto ? agcGain : mode.fixedGain }

    private func processAuto(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Float {
        // 1) 本帧均方根电平
        var sumSq = 0.0
        for i in 0..<count {
            let v = Double(samples[i])
            sumSq += v * v
        }
        let rms = count > 0 ? Float((sumSq / Double(count)).squareRoot()) : 0

        // 2) 电平包络：上升快、下降慢，贴合语音的起止。
        //    不对称是有意的——话音一进来要马上跟上，话音停下则慢慢放掉，
        //    否则句与句之间的停顿会把增益顶上去，下一句开头就爆一下
        agcLevel = rms > agcLevel
            ? agcLevel + Self.levelUp * (rms - agcLevel)
            : agcLevel + Self.levelDown * (rms - agcLevel)

        // 3) 目标增益：近静音不抬（这就是噪声门，见类型注释），
        //    其余拉向目标电平并限制上限
        let desired: Float = agcLevel < Self.noiseFloor
            ? 1
            : min(max(Self.targetRMS / agcLevel, 1), Self.maxGain)

        // 4) 增益自身平滑，避免帧间跳变
        agcGain += Self.gainSmooth * (desired - agcGain)

        applyGain(samples, count: count, gain: agcGain)
        return agcGain
    }

    private func applyGain(_ samples: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
        // 增益为 1 时整级跳过。tanh(x) ≠ x，所以这不是省一次乘法，
        // 而是「不做任何处理」和「过一遍软限幅」的区别
        if gain == 1 { return }
        for i in 0..<count {
            samples[i] = tanh(samples[i] * gain)
        }
    }

    // MARK: - 参数

    /// 低于该 RMS（约 -46dBFS）视为近静音 / 底噪，不做提升
    private static let noiseFloor: Float = 0.005
    /// 目标语音 RMS（约 -21dBFS），离线识别比较舒适的电平区间
    private static let targetRMS: Float = 0.09
    /// 自动增益上限，避免过度放大造成失真
    private static let maxGain: Float = 4.5
    private static let levelUp: Float = 0.55
    private static let levelDown: Float = 0.12
    private static let gainSmooth: Float = 0.18

    // MARK: - 自检

    /// 离线自检：不需要麦克风，也不依赖任何设备状态。
    ///
    /// 要防的是「AGC 看着在工作、其实增益没生效」和它的反面「噪声门根本没
    /// 门住、底噪被一起放大」。这两种在听感和转录结果上都很难当场分辨，
    /// 而界面上只会显示一个「自动」——所以直接量增益和输入输出 RMS。
    static func selfTest() -> [String] {
        var lines: [String] = ["音频前级自检 · 噪声门 \(noiseFloor) · 目标 RMS \(targetRMS) · 上限 \(maxGain)×"]
        var allPassed = true

        func check(_ name: String, _ ok: Bool, _ detail: String) {
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") \(name)：\(detail)")
        }

        let sampleRate = 48_000.0
        let frameCount = 1_024

        /// 喂进去的波形。
        ///
        /// 固定档和有意的「原样通过」用常数（直流）验：`tanh(g·c)` 对每个样本
        /// 都是同一个确定值，能拿解析解逐位对照。正弦被 tanh 压缩之后的 RMS
        /// 没有干净的解，只能拿一个近似的期望值去比，反而会把「系数抄错了
        /// 一点点」这类错误放进容差里放过去。
        /// AGC 那几条必须用正弦：它判的是 RMS 电平，而直流的 RMS 就是它自己，
        /// 等于绕过被测的那一环。
        enum Waveform { case constant, sine }

        /// 按帧喂一段波形，返回（最终增益、输入 RMS、输出 RMS）
        func run(
            mode: MicGainMode,
            amplitude: Float,
            frames: Int,
            waveform: Waveform,
            frequency: Double = 440
        ) -> (gain: Float, inRMS: Float, outRMS: Float) {
            let preamp = AudioPreamp(mode: mode)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                )!,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channel = buffer.floatChannelData?[0] else {
                return (0, 0, 0)
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)

            var gain: Float = 0
            for _ in 0..<frames {
                switch waveform {
                case .constant:
                    for i in 0..<frameCount { channel[i] = amplitude }
                case .sine:
                    for i in 0..<frameCount {
                        channel[i] = amplitude
                            * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
                    }
                }
                gain = preamp.process(channel, count: frameCount)
            }

            var sumSq = 0.0
            for i in 0..<frameCount {
                let v = Double(channel[i])
                sumSq += v * v
            }
            let outRMS = Float((sumSq / Double(frameCount)).squareRoot())
            let inRMS = waveform == .sine ? amplitude / Float(2.0.squareRoot()) : amplitude
            return (gain, inRMS, outRMS)
        }

        // 1. 关闭档：必须一个样本都不碰。
        //    注意这里不能用「增益 == 1 就跳过」去推断——要验的正是它真没动样本
        let off = run(mode: .off, amplitude: 0.3, frames: 3, waveform: .constant)
        check(
            "关闭档原样通过",
            off.gain == 1 && abs(off.outRMS - off.inRMS) < 1e-7,
            String(format: "增益 %.2f× · 样本 0.3000 → %.6f", off.gain, off.outRMS)
        )

        // 2. 固定档：增益按倍数走，输出是 tanh 后的值（比线性小一截）
        let x2 = run(mode: .x2, amplitude: 0.3, frames: 3, waveform: .constant)
        let expectedX2 = tanh(0.3 * 2)
        check(
            "2 倍档增益与软限幅",
            x2.gain == 2 && abs(Double(x2.outRMS) - Double(expectedX2)) < 1e-6,
            String(format: "样本 0.3 × 2 → tanh(0.6) = %.6f（线性会是 0.6）", expectedX2)
        )

        // 3. 大声输入下必须仍然有界——这是「防爆音」的全部意义。
        //    没有软限幅的话这里会出去一个 4.75，硬件和识别器都要挨一下
        let loud = run(mode: .x5, amplitude: 0.95, frames: 3, waveform: .constant)
        let expectedX5 = tanh(0.95 * 5)
        check(
            "5 倍档大声输入不越界",
            abs(Double(loud.outRMS) - Double(expectedX5)) < 1e-6 && loud.outRMS < 1,
            String(format: "样本 0.95 × 5 = 4.75 → tanh = %.6f（永远 < 1）", expectedX5)
        )

        // 4. AUTO · 小声语音：该被拉到目标电平
        //    振幅 0.02 → RMS 约 0.014，低于目标一个数量级
        let quiet = run(mode: .auto, amplitude: 0.02, frames: 300, waveform: .sine)
        check(
            "自动档把小声音抬到目标电平",
            quiet.gain > 4.0 && quiet.outRMS > 0.06 && quiet.outRMS < 0.12,
            String(format: "增益 %.2f× · RMS %.4f → %.4f（目标 %.2f）",
                   quiet.gain, quiet.inRMS, quiet.outRMS, targetRMS)
        )

        // 5. AUTO · 中等音量：增益按需给，不硬拉到上限
        let medium = run(mode: .auto, amplitude: 0.06, frames: 300, waveform: .sine)
        check(
            "自动档中等音量按需增益",
            medium.gain > 1.5 && medium.gain < 3.0,
            String(format: "增益 %.2f×（理论上限 %.1f×）", medium.gain, maxGain)
        )

        // 6. AUTO · 近静音：**噪声门**。整条改进的价值就在这一条上——
        //    没有门的话这里会给出 0.09/0.002 = 45 倍，底噪被抬成主角
        let silent = run(mode: .auto, amplitude: 0.0028, frames: 300, waveform: .sine)
        let openLoopGain = targetRMS / silent.inRMS
        check(
            "自动档对近静音不抬升（噪声门）",
            abs(silent.gain - 1) < 0.05 && abs(silent.outRMS - silent.inRMS) < 0.0005,
            String(format: "增益 %.3f×（无门的话会是 %.1f×）· 输入 RMS %.4f → 输出 %.4f",
                   silent.gain, openLoopGain, silent.inRMS, silent.outRMS)
        )

        // 6b. 开局暂态：**这一级已知的代价，量出来而不是猜。**
        //     agcLevel 初值是 targetRMS（0.09），要按 levelDown 慢慢掉到
        //     噪声门以下才认得出「这是底噪」。在那之前它会把房间底噪当成
        //     小声说话，按上限放大。这不是移植引入的——原实现同样是这个初值，
        //     参数照搬不动，但代价得摆在明面上：一段安静录音的开头若干秒，
        //     送进识别器的是被抬高过的底噪，识别器可能据此吐出一两个幻觉词。
        //    **用真实 tap 的缓冲长度（4096）来量，而不是上面那几条的 1024。**
        //    包络每调用一次 process 才推进一次，所以收敛快慢是按「回调次数」
        //    算的，不是按样本数——换个缓冲长度，同样的秒数会走出不同的曲线。
        //    要报一个能对得上线上行为的数，就得用线上那个缓冲长度。
        do {
            let tapFrames = 4_096          // 与 installTap(bufferSize:) 一致
            let preamp = AudioPreamp(mode: .auto)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                )!,
                frameCapacity: AVAudioFrameCount(tapFrames)
            )!
            buffer.frameLength = AVAudioFrameCount(tapFrames)
            let channel = buffer.floatChannelData![0]

            var peakGain: Float = 1
            var settleFrame: Int?
            var boosted = false
            let secondsPerFrame = Double(tapFrames) / sampleRate
            for frame in 0..<300 {
                for i in 0..<tapFrames {
                    channel[i] = 0.0028
                        * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
                }
                let gain = preamp.process(channel, count: tapFrames)
                peakGain = max(peakGain, gain)
                // 增益是从 1 开始**往上**爬的，所以「回落」只能在它确实抬起来
                // 之后才算数。少了这个门槛，第 0 帧（增益还贴着 1）就会被当成
                // 已经回落——量出来的暂态长度会是 0，正好把要看的东西抹掉
                if gain > 1.5 { boosted = true }
                if boosted, settleFrame == nil, abs(gain - 1) < 0.05 { settleFrame = frame }
            }
            let settle = settleFrame.map {
                String(format: "第 %d 次回调（约 %.1f 秒音频）起回落到 1×", $0, Double($0) * secondsPerFrame)
            } ?? "300 次回调内没有回落——噪声门没起作用"
            lines.append(String(
                format: "  ℹ️ 近静音开局暂态（4096 帧/回调）：峰值增益 %.2f× · %@",
                peakGain, settle
            ))
        }

        // 7. 复位：录完一段再录下一段时，不能带着上一段的收敛值开局
        let preamp = AudioPreamp(mode: .auto)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )!,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let channel = buffer.floatChannelData?[0] {
            // 每帧都要重新填。处理是**原地**的，只填一次再喂 300 遍，
            // 样本会被反复放大到饱和，量到的就不是 AGC 的收敛行为了
            for _ in 0..<300 {
                for i in 0..<frameCount { channel[i] = 0.02 }
                preamp.process(channel, count: frameCount)
            }
            let before = preamp.currentGain
            preamp.reset()
            check(
                "reset() 复位 AGC 状态",
                before > 4.0 && preamp.currentGain == 1,
                String(format: "复位前 %.2f× → 复位后 %.2f×", before, preamp.currentGain)
            )
        } else {
            check("reset() 复位 AGC 状态", false, "缓冲区分配失败")
        }

        lines.append(allPassed ? "✅ 音频前级自检通过" : "❌ 音频前级自检未通过")
        return lines
    }
}
