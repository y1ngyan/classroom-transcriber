import AVFoundation
import Foundation

/// 二阶 Butterworth 高通，逐样本递推。
///
/// 用途：录音存档的低频清理。笔记本麦克风摆在桌上，收进来的低频里
/// 真正属于人声的很少——空调和投影仪的风声、桌面的敲击与震动、
/// 手持摩擦、电流底噪，全都在 80Hz 以下。这些能量不参与辨义，
/// 却实打实占掉了 16bit 存档的动态范围，也让波形看上去糊成一团。
///
/// **为什么是 80Hz：** 成年男声基频最低到 85Hz 左右，再往上切会开始削
/// 元音的第一谐波。二阶（12dB/oct）在 80Hz 处 -3dB、40Hz 处 -24dB，
/// 正好把「不是人声的低频」清掉而基本不碰人声。
///
/// **为什么只做二阶：** 更陡的斜率（四阶、六阶）在这个频点上会把
/// 相位搞得很难看，而收益只是多清掉十几 dB 的次声——那些能量本来就
/// 听不见也存不下。
///
/// **逐样本递推而不是 vDSP：** 这条链要能直接跑在实时音频线程上，
/// 逐样本 O(N) 无分配、无分块边界，不必为了离线批处理再写第二套实现——
/// 离线实验（`tools/dsp_lab.swift` 的 `--hp`）和线上用的是同一个差分方程，
/// 离线量到的结论才能直接搬到线上。
///
/// 精度：系数用 `Float`。在 80Hz/48kHz 这个点上 a2 ≈ 0.9853，
/// 极点在单位圆内很近的地方，但 Float 的 24 位尾数换算下来递推的
/// 自噪声约 -124dBFS，比存档 WAV 自己的 16bit 量化底噪（-96dBFS）
/// 还低 28dB，没有理由为它换成 Double。
final class HighPassFilter {

    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float

    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    /// 不满足采样定理时返回 nil，调用方据此跳过这一级。
    ///
    /// 与其夹一个「差不多能用」的截止频率，不如明确不做——静默地把
    /// 80Hz 的滤波器当成 22kHz 的用，会把整个人声频段削掉，而且
    /// 从代码上看不出任何异常。
    init?(sampleRate: Double, cutoff: Double) {
        guard sampleRate > 0, cutoff > 0, cutoff < sampleRate * 0.45 else { return nil }

        // 双线性变换 + 预畸变：K 用 tan 而不是 2π·fc/fs，
        // 否则截止频率会往高频偏（预畸变正是为了把它拉回来）
        let k = tan(Double.pi * cutoff / sampleRate)
        let kk = k * k
        let q = 1.0 / 2.0.squareRoot()          // Butterworth 的极点位置
        let norm = 1.0 / (1.0 + k / q + kk)

        // **b 前面不能乘 K²。** 这里踩过一次：写成 `kk * norm` 之后
        // 整条曲线只是被均匀压低了 K² 倍，形状（每倍频 12dB、80Hz 处 -3dB）
        // 完全正常，看上去「滤波器是对的」——实际增益是 -91dB，
        // 录出来只剩抖动噪声。所以自检量的不是形状而是绝对增益。
        // 验算：Nyquist 处 (b0-b1+b2)/(1-a1+a2) = (4/a0)/(4/a0) = 1，
        // 直流处 (b0+b1+b2)/(1+a1+a2) = 0，这才是高通该有的两端。
        self.b0 = Float(norm)
        self.b1 = Float(-2.0 * norm)
        self.b2 = Float(norm)
        self.a1 = Float(2.0 * (kk - 1.0) * norm)
        self.a2 = Float((1.0 - k / q + kk) * norm)
    }

    /// 原地滤一段单声道样本。
    ///
    /// **只从音频线程调用。** 和 `MicTap` 一样，对象本身不带锁：
    /// 递推状态 x1/x2/y1/y2 一旦被两个线程同时推进就全乱了，
    /// 用锁保护反而会在实时线程上引入优先级反转。
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            let x = samples[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            samples[i] = y
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        process(channel, count: Int(buffer.frameLength))
    }

    // MARK: - 自检

    /// 拿已知频率的正弦量幅频响应，和解析解对照。不需要麦克风。
    ///
    /// 之所以要跑这一趟：双线性变换的系数很容易抄错一个符号而
    /// **听不出、也看不出**——滤波器照样出声，只是截止频率和斜率
    /// 都不对了。所以直接量「20Hz 衰了多少、4kHz 有没有被削」。
    static func selfTest(sampleRate: Double = 48_000, cutoff: Double = 80) -> [String] {
        var lines: [String] = ["高通自检 · 采样率 \(Int(sampleRate))Hz · 截止 \(Int(cutoff))Hz"]

        guard let filter = HighPassFilter(sampleRate: sampleRate, cutoff: cutoff) else {
            return lines + ["❌ 滤波器构造失败"]
        }

        /// 用纯音量某个频点的增益（dB）
        func gainDB(at frequency: Double, using filter: HighPassFilter) -> Double? {
            let seconds = 1.0
            let count = Int(sampleRate * seconds)
            let settled = count / 2                       // 前半段是暂态，丢掉
            guard count > 0, let buffer = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                )!,
                frameCapacity: AVAudioFrameCount(count)
            ), let channel = buffer.floatChannelData?[0] else { return nil }

            buffer.frameLength = AVAudioFrameCount(count)
            let omega = 2 * Double.pi * frequency / sampleRate
            for i in 0..<count {
                channel[i] = Float(sin(omega * Double(i)))
            }

            filter.process(channel, count: count)

            var sumIn = 0.0, sumOut = 0.0
            for i in settled..<count {
                let input = sin(omega * Double(i))
                sumIn += input * input
                sumOut += Double(channel[i]) * Double(channel[i])
            }
            guard sumIn > 0, sumOut > 0 else { return nil }
            return 10 * log10(sumOut / sumIn)
        }

        // 解析解：二阶 Butterworth，|H|² = r⁴ / (1 + r⁴)，r = f / fc
        func expectedDB(at frequency: Double) -> Double {
            let r = frequency / cutoff
            return 10 * log10(pow(r, 4) / (1 + pow(r, 4)))
        }

        struct Check {
            let frequency: Double
            let tolerance: Double
            let note: String
        }
        let checks = [
            Check(frequency: 20, tolerance: 2.0, note: "次声，该被压掉"),
            Check(frequency: 40, tolerance: 2.0, note: "空调/桌面震动"),
            Check(frequency: 80, tolerance: 2.0, note: "截止点，应为 -3dB"),
            Check(frequency: 200, tolerance: 1.5, note: "男声基频上沿"),
            Check(frequency: 4_000, tolerance: 1.0, note: "辅音关键频段，必须原样通过"),
        ]

        var allPassed = true
        for check in checks {
            guard let measured = gainDB(at: check.frequency, using: filter) else {
                lines.append("  ❌ \(Int(check.frequency))Hz 量不了")
                allPassed = false
                continue
            }
            let expected = expectedDB(at: check.frequency)
            let delta = abs(measured - expected)
            let ok = delta <= check.tolerance
            allPassed = allPassed && ok
            lines.append(String(
                format: "  %@ %6.0fHz  实测 %+7.2fdB · 理论 %+7.2fdB · 差 %.2fdB（%@）",
                ok ? "✅" : "❌", check.frequency, measured, expected, delta, check.note
            ))
        }

        // 直流：高通必须把恒定分量彻底放掉。这条最容易在系数写错时
        // 「看起来还对」——因为交流测试仍然过，只是留了一个直流台阶
        if let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )!,
            frameCapacity: AVAudioFrameCount(Int(sampleRate))
        ), let channel = buffer.floatChannelData?[0] {
            let count = Int(sampleRate)
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { channel[i] = 1.0 }
            filter.process(channel, count: count)

            // 取尾部 1/10 的峰值：直流应该已经衰减到接近 0
            var peak: Float = 0
            for i in (count * 9 / 10)..<count { peak = max(peak, abs(channel[i])) }
            let ok = peak < 0.001
            allPassed = allPassed && ok
            lines.append(String(
                format: "  %@ 直流输入 1.0 → 稳态峰值 %.6f（应 < 0.001）",
                ok ? "✅" : "❌", peak
            ))
        }

        // 越界截止频率必须拒绝构造，而不是构造出一个错的
        let rejected = HighPassFilter(sampleRate: 48_000, cutoff: 30_000) == nil
            && HighPassFilter(sampleRate: 48_000, cutoff: 0) == nil
        allPassed = allPassed && rejected
        lines.append("  \(rejected ? "✅" : "❌") 截止频率超出 Nyquist / 为 0 时拒绝构造")

        lines.append(allPassed ? "✅ 高通自检通过" : "❌ 高通自检未通过")
        return lines
    }
}
