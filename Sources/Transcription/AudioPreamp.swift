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
        case .auto: return "声音小自动放大，麦克风极弱时整体提升，纯静音不抬"
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
/// - `auto`：轻量 AGC。按帧 RMS 缓慢把语音拉向目标电平，增益自身做平滑
///   以防「抽吸」。**门限不是固定的**，按场景分两种模式（见下）。
///
/// ## 为什么门限必须分模式（2026-09-21 实测，两个独立的 bug）
///
/// 旧实现是固定噪声门 0.005 + 上限 4.5×。拿一条真实录音（144.8 秒，整体
/// RMS 0.00336 / -49.5 dBFS）逐帧模拟旧逻辑：80.2% 的帧增益恰好 1.0（被门
/// 住），全程平均增益 1.29×，而拉到目标电平需要 26.8×。同时 4.5× 的上限
/// 就算门放开也只能把 0.0034 抬到 0.015，离目标还差 6 倍。**门限太死和上
/// 限太小是两个独立的 bug**，只修一个都不够。
///
/// 为什么不能简单改成「自适应门 = 底噪 × 系数」：那条录音底噪 0.00205、
/// 语音 0.00347，只差 4.9 dB。试过门设底噪 4× 和 2×，两种都门掉 94% 的帧
/// —— **低 SNR 场景下电平无法区分语音和噪声，任何基于电平的门都误伤语音**。
/// 所以按整体电平分两种模式：
///
/// - **正常模式**（包络 ≥ `lowLevelCeiling`，即 -40 dBFS）：麦克风工作正常，
///   电平差异有意义，噪声门照用——门 = 底噪基线 × 2，门下帧增益钉 1.0，
///   底噪原地不动，只有语音帧被抬起，SNR 是改善的。这一模式里门本身把
///   增益自然限制在 目标/门 ≈ 8.6× 以内，`maxGain` 不会触到。
/// - **低电平模式**（包络 < -40 dBFS）：整场连最响的内容都极弱，说明是
///   「麦克风增益极低的低 SNR 场景」，电平门必然误伤语音（上面的实测）。
///   此时改用**动态范围**判有无语音：包络明显高出底噪基线（×1.5，约 3.5 dB）
///   说明信号在调制、大概率有语音 → 撤掉电平门，整体拉向目标电平；
///   包络贴着底噪（纯静音 / 平稳噪声）→ 增益钉 1.0，**不把纯噪声抬成
///   噪声墙**。
///
/// 低电平模式里连底噪一起放大是**有意的取舍**：识别器对 -49 dBFS 的信号
/// 无论 SNR 如何都只能硬猜（实测该录音原始置信度 0.646）；整体抬 27× 到
/// -22 dBFS 后置信度 0.76，新闻联播段 0.87–0.92，比手动固定 45.5× 直放
/// （0.75）更稳。SNR 没变，但识别器有绝对电平门槛，抬过门槛就是改善。
/// 注意这是明显改善而非质变——剩下的差距来自录音本身的 SNR，不是增益
/// 能补的。
///
/// ## 底噪基线的跟踪方式
///
/// `floorEstimate` 向下快（0.05/帧，约 4 秒跟上——句间停顿很快就能重新
/// 锚定）、向上极慢（0.0001/帧，约 14 分钟——**防止持续语音被慢慢当成
/// 底噪然后被门掉**，这是固定信号下任何电平跟踪器都会犯的错，只能靠
/// 放慢来推迟；代价是房间真的变吵时门限要十几分钟才跟上，可接受）。
///
/// ## 为什么初值从 targetRMS 改成 initialFloor
///
/// 旧实现包络初值是 targetRMS（0.09），开局要按 levelDown 慢慢掉穿门限，
/// 那一段里它把房间底噪当小声说话、按上限放大——这就是旧自检 6b 量到的
/// 「开局暂态」。初值改低后增益从 1 出发，语音来了靠快升包络（0.55/帧）
/// 一两帧内跟上，暂态整个消失。
///
/// 处理只在唯一的采集线程内进行，对象本身不带锁——和 `HighPassFilter`
/// 同理，用锁保护反而会在实时线程上引入优先级倒置。
final class AudioPreamp {

    /// 本次录音的档位。构造时定死，不在录音中途改：改档意味着 AGC 状态
    /// 要跟着重置，而「录到一半突然换了个增益曲线」在存档和转录两边都会
    /// 留下对不上的痕迹。要换档就重新开始一段录音。
    let mode: MicGainMode

    // ---- AGC 运行状态（仅采集线程访问）----
    private var agcLevel: Float = AudioPreamp.initialFloor
    private var agcGain: Float = 1
    private var floorEstimate: Float = AudioPreamp.initialFloor

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
        agcLevel = Self.initialFloor
        agcGain = 1
        floorEstimate = Self.initialFloor
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

        // 2) 底噪基线：向下快、向上极慢。向上慢是关键——持续语音不能
        //    被慢慢吸收成「底噪」再被门限反杀（理由见类型注释）
        floorEstimate += (rms < floorEstimate ? Self.floorDown : Self.floorUp)
            * (rms - floorEstimate)

        // 3) 电平包络：上升快、下降慢，贴合语音的起止。
        //    不对称是有意的——话音一进来要马上跟上，话音停下则慢慢放掉，
        //    否则句与句之间的停顿会把增益顶上去，下一句开头就爆一下
        agcLevel = rms > agcLevel
            ? agcLevel + Self.levelUp * (rms - agcLevel)
            : agcLevel + Self.levelDown * (rms - agcLevel)

        // 4) 是否抬升：两种模式的判据不同（完整的「为什么」见类型注释）。
        //    正常模式比电平门；低电平模式电平门必然误伤语音，改比动态范围。
        //    低电平模式的门没有迟滞，句间停顿超过一两帧增益就会回落——
        //    靠 gainSmooth（时间常数约 0.4 秒）桥接词间短停顿，长停顿
        //    回落到 1× 反而正是要的「静音不抬」。
        let boosting: Bool = agcLevel >= Self.lowLevelCeiling
            ? agcLevel >= floorEstimate * Self.gateMargin
            : agcLevel >= floorEstimate * Self.signalMargin

        // 5) 目标增益：不抬则钉 1.0，抬则拉向目标电平并限制上限
        let desired: Float = boosting
            ? min(max(Self.targetRMS / max(agcLevel, 1e-6), 1), Self.maxGain)
            : 1

        // 6) 增益自身平滑，避免帧间跳变
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

    /// 底噪基线与包络的初值。取旧固定门限 0.005：比它低的真实底噪几秒内
    /// 被向下跟踪跟上，比它吵的房间靠向上慢跟踪十几分钟跟上——开局宁可
    /// 保守（少放大），不可把底噪抬起来（旧初值 0.09 的教训，见类型注释）
    private static let initialFloor: Float = 0.005
    /// 底噪基线向下跟踪速度（每帧逼近 5%，约 4 秒收敛）
    private static let floorDown: Float = 0.05
    /// 底噪基线向上跟踪速度（每帧 0.01%，约 14 分钟）。故意极慢：
    /// 持续语音不能被吸成底噪，否则门限会反杀语音
    private static let floorUp: Float = 0.0001
    /// 正常模式的噪声门：底噪基线的 2 倍
    private static let gateMargin: Float = 2
    /// 正常 / 低电平模式的分界（-40 dBFS）。连包络峰值都越不过这条线，
    /// 说明麦克风整体增益极低，电平门失效，改用动态范围判据
    private static let lowLevelCeiling: Float = 0.01
    /// 低电平模式的「有语音」判据：包络高出底噪基线 1.5 倍（约 3.5 dB）。
    /// 判的是动态范围不是绝对电平——实测低 SNR 录音（底噪 0.002 语音
    /// 0.0035）能过，纯静音过不了
    private static let signalMargin: Float = 1.5
    /// 目标语音 RMS（约 -21dBFS），离线识别比较舒适的电平区间。
    /// 实测把 -49.5 dBFS 的录音抬到约 -22 dBFS 后置信度 0.646 → 0.76，
    /// 验证过这个量级有效；不再往上提是因为目标越高、低 SNR 场景里
    /// 底噪被抬得越响
    private static let targetRMS: Float = 0.09
    /// 自动增益上限。低电平模式实测需要 26.8×（0.0034 → 0.09），4.5× 的
    /// 旧上限差 6 倍是独立 bug；取 32 留一档余量。正常模式触不到它——
    /// 电平门天然把增益限在 目标/门 ≈ 8.6× 以内
    private static let maxGain: Float = 32
    private static let levelUp: Float = 0.55
    private static let levelDown: Float = 0.12
    private static let gainSmooth: Float = 0.18

    // MARK: - 自检

    /// 离线自检：不需要麦克风，也不依赖任何设备状态。
    ///
    /// 要防的是「AGC 看着在工作、其实增益没生效」和它的反面「门没门住、
    /// 底噪被一起放大」。这两种在听感和转录结果上都很难当场分辨，
    /// 而界面上只会显示一个「自动」——所以直接量增益和输入输出 RMS。
    /// 自动档的核心用例按 2026-09-21 那次实测的两个 bug 设计成三个场景：
    /// 正常 SNR（门要工作）、低 SNR 极低电平（不能再门住，要整体提升）、
    /// 绝对静音（不能抬成噪声墙）。数字取自真实录音，见类型注释。
    static func selfTest() -> [String] {
        var lines: [String] = ["音频前级自检 · 目标 RMS \(targetRMS) · 上限 \(maxGain)× · 低电平分界 \(lowLevelCeiling) · 门 \(gateMargin)×底噪"]
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

        /// 自动档场景用：同一个实例上按顺序喂若干段不同振幅的正弦，
        /// 返回每段末尾的（增益、输出 RMS）和全程峰值增益。
        ///
        /// **帧长固定 4096，与 installTap(bufferSize:) 一致。** 包络、底噪
        /// 基线、增益平滑都是每调用一次 process 推进一次，收敛快慢按
        /// 「回调次数」算而不是按样本数——用别的帧长量出来的秒数对不上
        /// 线上行为（旧自检 6b 的教训）。
        func runAuto(
            segments: [(amplitude: Float, frames: Int)]
        ) -> (end: [(gain: Float, outRMS: Float)], peakGain: Float) {
            let preamp = AudioPreamp(mode: .auto)
            let tapFrames = 4_096
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                )!,
                frameCapacity: AVAudioFrameCount(tapFrames)
            ), let channel = buffer.floatChannelData?[0] else {
                return ([], 0)
            }
            buffer.frameLength = AVAudioFrameCount(tapFrames)

            var end: [(gain: Float, outRMS: Float)] = []
            var peakGain: Float = 1
            for segment in segments {
                var gain: Float = 1
                for _ in 0..<segment.frames {
                    // 每帧都要重填：处理是原地的，不填的话样本会被反复放大
                    for i in 0..<tapFrames {
                        channel[i] = segment.amplitude
                            * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
                    }
                    gain = preamp.process(channel, count: tapFrames)
                    peakGain = max(peakGain, gain)
                }
                var sumSq = 0.0
                for i in 0..<tapFrames {
                    let v = Double(channel[i])
                    sumSq += v * v
                }
                end.append((gain, Float((sumSq / Double(tapFrames)).squareRoot())))
            }
            return (end, peakGain)
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
            quiet.gain > 4.0 && quiet.outRMS > 0.05 && quiet.outRMS < 0.12,
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

        // 6. AUTO · 场景一：正常 SNR，噪声门必须工作。
        //    语音（RMS 0.035）和纯底噪（RMS 0.002，相差 25 dB）交替：
        //    语音段要被抬起，之后的纯底噪段增益必须回到 1——底噪不跟着放大，
        //    这就是噪声门存在的全部意义。注意语音结束后包络按 levelDown
        //    缓慢释放，头一两秒增益会短暂上冲再回落（经典 AGC 释放特性，
        //    旧实现同样如此），所以底噪段要喂够长再量末端的值。
        do {
            let r = runAuto(segments: [
                (amplitude: 0.05, frames: 60),      // 语音，RMS ≈ 0.035
                (amplitude: 0.0028, frames: 150)    // 纯底噪，RMS ≈ 0.002
            ])
            let speech = r.end[0]
            let noise = r.end[1]
            check(
                "正常 SNR：语音抬起、底噪不抬（噪声门工作）",
                speech.gain > 1.8 && speech.gain < 3.5
                    && speech.outRMS > 0.06 && speech.outRMS < 0.12
                    && noise.gain < 1.05 && noise.outRMS < 0.004,
                String(format: "语音段 %.2f×（RMS → %.4f）· 底噪段末 %.3f×（RMS → %.4f）",
                       speech.gain, speech.outRMS, noise.gain, noise.outRMS)
            )
        }

        // 7. AUTO · 场景二：低 SNR 极低电平，不能再门住。
        //    数字取自 2026-09-21 那条真实录音：底噪 RMS 0.00205、语音 RMS
        //    0.00347，只差 4.9 dB，整体 -49.5 dBFS。旧逻辑在这里 80% 的帧
        //    增益恰好 1.0。新逻辑应该认出「麦克风极弱但有动态范围」，
        //    撤掉电平门整体提升——那条录音需要 26.8×，这里断言留足余量。
        //    语音停了一段之后增益还要回得去（长停顿不抬底噪）。
        do {
            let r = runAuto(segments: [
                (amplitude: 0.0029, frames: 100),   // 底噪，RMS ≈ 0.00205
                (amplitude: 0.00495, frames: 120),  // 语音，RMS ≈ 0.0035
                (amplitude: 0.0029, frames: 100)    // 又回到纯底噪
            ])
            let speech = r.end[1]
            let after = r.end[2]
            check(
                "低 SNR 极低电平：整体提升而不是门住",
                speech.gain > 15 && speech.outRMS > 0.05 && speech.outRMS < 0.12
                    && after.gain < 1.5,
                String(format: "语音段 %.1f×（RMS 0.0035 → %.4f，旧逻辑给 1.0×）· 停后回落 %.2f×",
                       speech.gain, speech.outRMS, after.gain)
            )
        }

        // 8. AUTO · 场景三：绝对静音，不能抬成噪声墙。
        //    平稳噪声没有任何动态范围，低电平模式的「有语音」判据不能放行。
        //    这一条同时覆盖旧自检 6b 的「开局暂态」：包络初值改低之后，
        //    从第 0 帧起增益就不该离开 1.0，旧实现开局按上限放大底噪
        //    数秒的暂态应当整个消失。
        do {
            let r = runAuto(segments: [(amplitude: 0.0028, frames: 300)])
            let tail = r.end[0]
            check(
                "绝对静音：全程不抬升（无噪声墙、无开局暂态）",
                r.peakGain < 1.05 && abs(tail.outRMS - 0.00198) < 0.0005,
                String(format: "300 次回调峰值增益 %.3f× · 输出 RMS %.4f（输入 0.0020）",
                       r.peakGain, tail.outRMS)
            )
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
