import Foundation

/// 系统声音的电平补偿。
///
/// **不是 AGC**：麦克风那条链路用 `AudioPreamp(.auto)` 是因为麦克风增益随
/// 距离/姿态变化，得连续跟踪。系统声音是数字信号，电平只取决于播放器音量，
/// 不需要跟踪——而且连续变增益会把已经清楚的声音弄出抽吸感（听感上像「忽大忽小」，
/// 识别上表现为字被拉糊）。
///
/// 做法：**只在明显偏小时**补一个固定倍数，够响就一个字节都不动。
enum SystemAudioGain {

    /// 低于这个 RMS 才补（约 -34 dBFS）。课堂/会议录音实测在 0.10–0.15，
    /// 正常播放远高于它
    static let lowLevelThreshold: Float = 0.02

    /// 补到的目标电平
    static let targetRMS: Float = 0.08

    /// 最大补偿倍数（再小就不是「音量小」，是没声音了，放大只会放大噪声）
    static let maxGain: Float = 8

    /// 这一块的增益。1 = 不动
    static func gain(forRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0.0001, rms < lowLevelThreshold else { return 1 }
        return min(maxGain, targetRMS / rms)
    }

    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
