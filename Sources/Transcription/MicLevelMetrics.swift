import Foundation

/// 一段录音的可打印判据。**纯计算**：给样本、出读数，不碰设备、不碰磁盘。
///
/// 所以它能被自检用构造好的波形（正弦、静音、削顶方波）钉住——
/// 「峰值算错了」这种缺陷在真录音上很难看出来（真录音的峰值到底该是多少，
/// 谁也不知道），但喂一段已知幅度的正弦就一眼可见。
struct MicLevelReading: Equatable {

    /// 一个时间窗的读数。**口径照 `tools/audio_health.swift`**：
    /// 帧长 20ms、底噪取帧 RMS 的 p5、语音取 p90、语音帧阈值 `max(floor*3, 0.005)`。
    /// 那几个数是那个工具跑出来的经验值，这里不另立一套——两处对「多少算底噪」
    /// 的说法不一致的话，同一段音频在两边会得出不同的结论
    struct Window: Equatable {
        var start: Double
        var floor: Double
        var median: Double
        var speech: Double
        var speechRatio: Double

        var rangeDB: Double { 20 * log10(max(speech, 1e-7) / max(floor, 1e-7)) }

        /// 和 audio_health 同一套：两种情况算法都算得出一个漂亮的数字，
        /// 但都不是结论，必须各自认出来
        enum Quality: Equatable {
            case ok
            /// 整窗都在说话，p5 取到的还是语音
            case noPause
            /// 几乎没人说话，p90 取到的是噪声上尾
            case noSpeech
        }

        var quality: Quality {
            if speechRatio < 0.10 { return .noSpeech }
            if speechRatio > 0.80 { return .noPause }
            return .ok
        }

        var qualityNote: String? {
            switch quality {
            case .ok: return nil
            case .noPause: return "整窗都在说话，量不到底噪"
            case .noSpeech: return "几乎没人说话，量不到语音"
            }
        }
    }

    var sampleCount: Int
    var sampleRate: Double
    /// 峰值 dBFS（全段最大 |样本|）
    var peakDBFS: Double
    /// 底噪 dBFS（全段帧 RMS 的 p5）
    var noiseFloorDBFS: Double
    /// 动态范围 dB（全段 p90 − p5）。**和窗口表里的不是一回事**：
    /// 这里是整段一个数，窗口表是逐秒。整段那个会把塌陷平均掉，
    /// 逐秒的才看得出「前 20 秒好好的、中间塌了」——两个都要给
    var dynamicRangeDB: Double
    /// 削顶样本计数（|样本| ≥ 0.999）
    var clippedSamples: Int
    /// 最长的一段**连续**削顶样本有多少个。只看总计数分不出
    /// 「零星碰到几次顶」和「整段糊成一片方波」——后者才说明增益给爆了
    var longestClipRun: Int
    var windows: [Window]

    var durationSeconds: Double { sampleRate > 0 ? Double(sampleCount) / sampleRate : 0 }
    var clippedFraction: Double {
        sampleCount > 0 ? Double(clippedSamples) / Double(sampleCount) : 0
    }
}

enum MicLevelMetrics {

    /// 削顶阈值。派单书 ② 点名的「≥ 0.999 连续样本」
    static let clipThreshold: Float = 0.999

    /// 帧长 20ms——和 `tools/audio_health.swift` 一致
    static let frameSeconds = 0.02

    /// 全段统计 + 逐窗表。`windowSeconds` 默认 1（派单书：「每 1 秒一行」）
    static func analyze(
        samples: [Float],
        sampleRate: Double,
        windowSeconds: Double = 1.0
    ) -> MicLevelReading {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }

        // 逐帧 RMS。全段和逐窗共用同一批帧——分两趟算的话，
        // 「整段底噪」和「窗口底噪的平均」会给出不一致的数，
        // 而看的人只会以为其中一个算错了
        let frameSize = max(1, Int(sampleRate * frameSeconds))
        var frames: [(index: Int, rms: Double)] = []
        if frameSize > 0 {
            var i = 0
            while i + frameSize <= samples.count {
                var sum = 0.0
                for j in i..<(i + frameSize) {
                    let v = Double(samples[j])
                    sum += v * v
                }
                frames.append((i, (sum / Double(frameSize)).squareRoot()))
                i += frameSize
            }
        }

        let allRMS = frames.map(\.rms).sorted()
        let floorAll = percentile(allRMS, 0.05)
        let speechAll = percentile(allRMS, 0.90)

        var windows: [MicLevelReading.Window] = []
        let windowFrames = max(1, Int(windowSeconds / frameSeconds))
        var cursor = 0
        // **按帧切窗，不按样本切**：逐窗和整段用的是同一批帧，
        // 两个读数才对得上（见上面那段注释）
        while cursor < frames.count {
            let slice = Array(frames[cursor..<min(cursor + windowFrames, frames.count)])
            let sorted = slice.map(\.rms).sorted()
            let floor = percentile(sorted, 0.05)
            let median = percentile(sorted, 0.50)
            let speech = percentile(sorted, 0.90)
            let threshold = max(floor * 3, 0.005)
            let ratio = Double(sorted.filter { $0 > threshold }.count) / Double(sorted.count)
            windows.append(.init(
                start: Double(slice[0].index) / sampleRate,
                floor: floor, median: median, speech: speech, speechRatio: ratio
            ))
            cursor += windowFrames
        }

        return MicLevelReading(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            peakDBFS: dbfs(peak),
            noiseFloorDBFS: dbfs(Float(floorAll)),
            dynamicRangeDB: 20 * log10(max(speechAll, 1e-7) / max(floorAll, 1e-7)),
            clippedSamples: samples.reduce(0) { $0 + (abs($1) >= clipThreshold ? 1 : 0) },
            longestClipRun: longestRun(samples),
            windows: windows
        )
    }

    /// 分位数。**下标算法与 `tools/audio_health.swift` 逐字相同**
    /// （`count/20`、`count*9/10`）——那边是实测调出来的取值点，
    /// 换成插值法会让两边对同一段音频报出不同的底噪
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index: Int
        switch q {
        case ..<0.5: index = Int(Double(sorted.count) * q)   // p5 → count/20
        case 0.5..<0.9: index = sorted.count / 2
        default: index = sorted.count * 9 / 10
        }
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// 幅度 → dBFS。0 映射到 -120 而不是 -∞：
    /// 「-inf dBFS」在表格里对齐不了，而一段真正的全零用 -120 表示也够清楚了
    static func dbfs(_ amplitude: Float) -> Double {
        amplitude <= 0 ? -120 : max(-120, 20 * log10(Double(amplitude)))
    }

    static func longestRun(_ samples: [Float]) -> Int {
        var best = 0
        var run = 0
        for s in samples {
            if abs(s) >= clipThreshold {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }
}
