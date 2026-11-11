import Foundation

/// 静音门控：判定「这一窗音频有没有人在说话」。
///
/// **纯函数**：给样本、出判定与读数，不碰模型、不碰设备、不碰磁盘。所以它能被
/// 构造好的波形钉住（数字静音、底噪、人声、均匀小声人声），也能在自检里跑。
///
/// ## 为什么要有它
///
/// 静音确实在进模型：`WhisperHallucination` 的注释里记着**四次独立复现**——
/// 120 秒麦克风静音、30 秒数字静音都会稳定长出像真话的句子（`你还在那边等我?`，
/// 置信度 0.735，没有任何模板特征）。幻觉过滤器是**事后**兜底，只能在文本这一层
/// 删东西；把静音挡在解码之前，是**事前**。
///
/// ## 判据：和 `MicLevelMetrics` / `tools/audio_health.swift` 同源
///
/// 20ms 帧 RMS、底噪取 p5、语音取 p90、语音帧阈值 `max(floor*3, 0.005)`——
/// 那几个数是那个工具实测调出来的。这里直接用 `MicLevelMetrics.analyze`
/// （把整窗当一个窗口喂进去），**不另立一套**：两处对「多少算底噪」的说法不一致
/// 的话，同一段音频在两边会得出不同的结论，而看的人只会以为其中一个算错了。
///
/// ## 两个条件，缺一不可
///
/// 1. `speechRatio < minSpeechRatio`：语音帧占比低。这是**逐窗自比**的判据
///    （阈值里那个 `floor*3` 是相对的），跨录音可比。
/// 2. `speech < speechCeiling`：整窗的 p90 电平低于绝对上限。
///
/// **第 2 条不是冗余，它挡的是一类具体形态**：整窗都是**电平均匀**的人声时
/// （连续小声说话、一句话里没有停顿），p5 取到的就是人声本身 → 阈值被抬到人声
/// 之上 → 语音帧占比算出 0 → 只看第 1 条就会把一个满窗人声判成静音。
/// 绝对上限把这个形态挡在门外：p90 都到不了 `speechCeiling` 的窗，
/// 「说话声」这个解释本来就站不住。
///
/// **两条的方向性是有意的**：宁可少跳（漏掉一段静音，多花两秒算一遍），
/// 不可错跳（把真人说话整段丢掉）。所以第 2 条取的是**低**上限。
///
/// ## 2026-10-21 实测分布（两条真实课堂录音，各取前 120 秒 = 各 38 个窗）
///
/// 表里的数来自 `--whisper-window-file <录音> --gate-scan`（不加载模型，
/// 走的就是生产那条取窗路径；生产步长 3 秒 → 38 窗）：
///
/// | 录音 | 判静音 | 判静音那批：占比 / p90 的上界 | 判有声那批：占比 / p90 的下界 |
/// |---|---|---|---|
/// | `课堂-20260921-084403`（只有前 30 秒有人说话） | 28/38 | 0.084 / 0.00868（-41.2 dBFS） | 0.108 / 0.00907（-40.8 dBFS） |
/// | `课堂-20260921-194730`（前 150 秒连续说话） | 0/38 | —— | 0.470 / 0.05402（-25.3 dBFS） |
///
/// 两个维度上两批都**没有交叠**（0.10 与 0.01 都落在两组之间），但第一条
/// 录音的余量很薄：占比 0.084 对 0.108、p90 只差 **0.4 dB**。这不是
/// 「阈值卡得刚好」，而是**那段录音里本来就有几窗贴着边界**——`--gate-scan`
/// 会把它们逐个列出来（那条录音上 38 窗全列）。换步长后余量会变（9.6 秒
/// 步长时是 2.7 dB），所以**这两个阈值是绑在这条取窗路径上的**，
/// 任何改步长/改窗长的实验都要重扫一遍再看余量。
///
/// ⚠️ **没验的部分**：说话声的 p90 低于 0.01（人离麦很远的小声课堂）会被
/// 判成静音。要标定那个边界得有**真人小声说话的课堂录音**，本包不许自造输入。
enum SpeechGate {

    // MARK: - 判定

    /// 一窗的读数（判据的全部输入，也是打印出来的全部依据）
    struct Reading: Equatable {
        /// 这一窗的时长（秒）
        let windowSeconds: Double
        let frameCount: Int
        /// 底噪：20ms 帧 RMS 的 p5
        let floor: Double
        /// 帧 RMS 的中位数
        let median: Double
        /// 语音：20ms 帧 RMS 的 p90
        let speech: Double
        /// 语音帧占比：帧 RMS > max(floor*3, 0.005) 的帧的比例
        let speechRatio: Double

        var dynamicRangeDB: Double {
            20 * log10(max(speech, 1e-7) / max(floor, 1e-7))
        }

        /// 一行说明，进日志/探针输出。**带上具体数字**：只报「判为静音」的话，
        /// 「为什么这窗被跳了」在真实录音上没法复核（这也是阈值要能被检验的前提）
        var summaryLine: String {
            String(
                format: "%.1f 秒窗 · 语音帧占比 %.3f · p90 %.5f(%.1f dBFS) · 底噪 %.5f · 中位 %.5f · 动态范围 %.1f dB",
                windowSeconds, speechRatio, speech, MicLevelMetrics.dbfs(Float(speech)),
                floor, median, dynamicRangeDB
            )
        }
    }

    enum Verdict: Equatable {
        case speech
        /// 判为静音、**不进解码**。带上是哪一条判据命中的
        case silence(reason: String)

        var isSilence: Bool {
            if case .silence = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .speech: return "有声"
            case .silence(let reason): return "静音（\(reason)）"
            }
        }
    }

    /// 语音帧占比的门。**取 0.10 与 `MicLevelMetrics.Window.Quality.noSpeech`
    /// 同值**——那边也是「占比 < 0.10 = 几乎没人说话」。两个数各自一份的话，
    /// 同一段音频会出现「采集侧说几乎没人说话、门控说有人在说话」这种打架。
    /// 实测分布（两批各自落在哪、离这个数多远）见类型注释里的表
    static let minSpeechRatio = 0.10

    /// 整窗 p90 的绝对上限（-40 dBFS 附近）。
    ///
    /// 为什么是绝对值、为什么这么低：它只用来挡「电平均匀的人声」那一个形态
    /// （见类型注释），不需要覆盖「多大算大」。取低一点的代价是漏跳几窗静音
    /// （多花两秒），取高的代价是丢掉真人说话——**两个方向的代价不对称，
    /// 所以往低取**。实测分布见类型注释里那张表（判有声那批离这条线最近的
    /// 是 0.03128，判静音那批离得最近的是 0.00879，两批没有交叠）
    static let speechCeiling: Double = 0.01

    /// 判据本体。**两个变异注入点就是它**：恒 true = 全部判静音、
    /// 恒 false = 从不判静音。抽成一个函数而不是散在调用点，是为了让那两条
    /// 判据（不许丢真人说话 / 跳过率）真的能各自变红
    static func isSilence(_ reading: Reading) -> Bool {
        guard reading.frameCount > 0 else { return false }
        guard reading.speechRatio < minSpeechRatio else { return false }
        // ① 绝对线：安静环境下的静音窗
        if reading.speech < speechCeiling { return true }
        // ② 相对线：**教室噪声下的静音窗**。
        // 绝对线在真实教室里经常永远不成立——实测（2026-11-04 那节课）底噪
        // 0.0049、p90 判据 0.01，18 个窗一个有都没被判静音；可同一段里
        // 没人说话的窗 p90 也就底噪的 1.2 倍左右。于是 whisper 在每个静音窗里
        // 照解，编出「谢谢观看」那类句子——用户听到的「静音幻听」就是这个。
        // 相对线只在**底噪本身不低**（≥ 0.002）时生效：安静的房间里底噪接近 0，
        // 用倍数判会把真人小声说话一起吞掉，那比幻觉更糟
        // 只对「噪声级」底噪生效：底噪必须落在 [0.002, 0.01]。
        // 上限这一条不能省——电平均匀的人声（幅度 0.02）底噪也接近 0.02，
        // 不设上限的话它会被自己的底噪倍数判成静音，而这正是第 2 条判据
        // 要保护的那一类（自检里有现成用例）。
        guard reading.floor >= relativeFloorActivation, reading.floor <= 0.01 else { return false }
        return reading.speech < reading.floor * relativeCeilingFactor
    }

    /// 相对线的启用门槛：底噪低于这个值说明房间本来就安静，走绝对线就够
    static let relativeFloorActivation: Double = 0.002

    /// 窗内 p90 低于「底噪 × 这个倍数」判静音。
    /// 2.2 的来历：实测该节课判有声那批最近的窗是底噪的 3.7 倍（0.01808 / 0.00488），
    /// 而纯噪声窗在 1.0–1.5 倍之间；2.2 落在两批中间，且离「真人小声」那侧更远
    static let relativeCeilingFactor: Double = 2.2

    /// 一窗的判定。`samples` 是 16kHz 单声道。
    static func evaluate(samples: [Float], sampleRate: Double = 16_000) -> (verdict: Verdict, reading: Reading) {
        let seconds = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        // 整窗当一个窗口喂进去：`MicLevelMetrics.analyze` 的逐窗口径就是本判据
        // 的口径，取窗数量为 1 时它给出的就是「这一窗的」floor/speech/占比
        let analyzed = MicLevelMetrics.analyze(samples: samples, sampleRate: sampleRate, windowSeconds: seconds)
        let window = analyzed.windows.first
        let reading = Reading(
            windowSeconds: seconds,
            frameCount: Int(seconds / MicLevelMetrics.frameSeconds),
            floor: window?.floor ?? 0,
            median: window?.median ?? 0,
            speech: window?.speech ?? 0,
            speechRatio: window?.speechRatio ?? 0
        )
        guard samples.count > 0 else {
            // 空窗没有「静音」可言：没有音频可跳，也不该把判定说成「这里没人说话」
            return (.speech, reading)
        }
        if isSilence(reading) {
            let reason = String(
                format: "语音帧占比 %.3f<%.2f 且 p90 %.5f<%.5f",
                reading.speechRatio, minSpeechRatio, reading.speech, speechCeiling
            )
            return (.silence(reason: reason), reading)
        }
        return (.speech, reading)
    }
}

// MARK: - 自检

extension SpeechGate {

    /// `--speech-gate-selftest`。**纯函数、纯内存**：不加载模型、不碰麦克风、
    /// 不读磁盘。用例里的音频是**合成波形**，不是真实录音——这条自检只钉
    /// 「判据在构造出来的形态上怎么判」，真实录音上的分布见交付报告
    /// （`--whisper-window-file` 的门控那一段）。
    ///
    /// ## 这套用例的每一组都在钉一个具体的失效形态
    ///
    /// - 数字静音 / 低电平底噪：**必须判静音**（否则门控等于没接）
    /// - 有人说话（带停顿 / 静音占一半）：**必须判有声**（不许因为「一半是静音」
    ///   就把整窗丢掉——那是丢内容）
    /// - 电平均匀的连续小声人声：**必须判有声**。这一组是第 2 条判据
    ///   （p90 绝对上限）存在的唯一理由，删掉它这一组立刻变红
    /// - 小声连续说话（p90 低于上限）：**判成静音，而且是已知误判**。
    ///   这一组钉的是「我们知道它错在哪」，不是「它是对的」——真实的课堂
    ///   小声说话要真人录音才能标定，本包不造输入（见交付报告「没验的部分」）
    /// - 判据常量、开关契约：**写死数值**。这两处谁被改动，这一条就红
    static func selfTest() -> [String] {
        var lines = ["─── 静音门控自检（纯函数／合成波形；不加载模型、不碰麦克风）───"]
        var failures = 0
        var checked = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            checked += 1
            if condition {
                lines.append("  ✅ \(name)\(detail.isEmpty ? "" : " · \(detail)")")
            } else {
                lines.append("  ❌ \(name)\(detail.isEmpty ? "" : " · \(detail)")")
                failures += 1
            }
        }

        let rate = 16_000.0

        /// 确定性噪声：**不用随机数**。随机数会让「这条用例为什么过/不过」
        /// 变成不可复现的——本仓库的判据必须能被人重跑出同一个结果
        func noise(seconds: Double, amplitude: Float, seed: UInt64 = 1) -> [Float] {
            var state = seed &* 6364136223846793005 &+ 1442695040888963407
            var out: [Float] = []
            out.reserveCapacity(Int(seconds * rate))
            for _ in 0..<Int(seconds * rate) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let unit = Float(state >> 11) / Float(UInt64(1) << 53) * 2 - 1   // [-1, 1)
                out.append(unit * amplitude)
            }
            return out
        }

        /// 正弦（“人声”的替身）。频率取 300Hz：落在人声基频里，
        /// 且远低于 8kHz 奈奎斯特，不会因为欠采样变形
        func tone(seconds: Double, amplitude: Float) -> [Float] {
            (0..<Int(seconds * rate)).map { i in
                amplitude * Float(sin(2 * Double.pi * 300 * Double(i) / rate))
            }
        }

        /// 说话 + 停顿交替（模拟真人语流：字与字之间有停）
        func speechWithPauses(seconds: Double, amplitude: Float, burst: Double = 1.0, gap: Double = 0.5) -> [Float] {
            var out: [Float] = []
            while Double(out.count) / rate < seconds {
                out += tone(seconds: burst, amplitude: amplitude)
                out += [Float](repeating: 0, count: Int(gap * rate))
            }
            return Array(out.prefix(Int(seconds * rate)))
        }

        func verdict(_ samples: [Float]) -> Verdict {
            evaluate(samples: samples, sampleRate: rate).verdict
        }

        // MARK: 一、该判静音的形态

        let digitalSilence = [Float](repeating: 0, count: Int(10 * rate))
        check("数字静音（全 0）判静音", verdict(digitalSilence).isSilence)

        let deadMic = noise(seconds: 10, amplitude: 0.0002)
        let deadReading = evaluate(samples: deadMic, sampleRate: rate).reading
        check("极低电平底噪（0.0002 幅度）判静音", verdict(deadMic).isSilence,
              String(format: "p90 %.5f · 占比 %.3f", deadReading.speech, deadReading.speechRatio))

        let roomTone = noise(seconds: 10, amplitude: 0.002, seed: 7)
        check("课堂底噪量级（0.002 幅度）判静音", verdict(roomTone).isSilence)

        // MARK: 二、该判有声的形态（**丢内容的那一侧，同等重要**）

        let speech = speechWithPauses(seconds: 10, amplitude: 0.05)
        let speechReading = evaluate(samples: speech, sampleRate: rate).reading
        check("真人语流（300Hz 断续、0.05 幅度）判有声", !verdict(speech).isSilence,
              String(format: "占比 %.3f · p90 %.5f", speechReading.speechRatio, speechReading.speech))

        // 一半说话、一半数字静音：**不许整窗跳掉**。这条挡的是「按比例判」
        // 那种写法（比如「静音帧超过一半就跳」）——课堂上句子之间的停顿
        // 本来就占一半左右
        let halfSpeech = [Float](repeating: 0, count: Int(5 * rate)) + tone(seconds: 5, amplitude: 0.05)
        check("一半静音一半说话仍判有声（句子之间的停顿不许把整窗带走）",
              !verdict(halfSpeech).isSilence)

        // **电平均匀的连续小声人声**：这是第 2 条判据（p90 上限）的唯一理由。
        // 删掉那条 `speech < speechCeiling`，这一组立刻判成静音（自检变红）
        let uniformSpeech = tone(seconds: 10, amplitude: 0.02)
        let uniformReading = evaluate(samples: uniformSpeech, sampleRate: rate).reading
        check("电平均匀的连续人声（0.02 幅度、无停顿）判有声——第 2 条判据挡的就是它",
              !verdict(uniformSpeech).isSilence,
              String(format: "占比 %.3f（小于门 %.2f）· p90 %.5f（高于上限 %.5f 所以留下）",
                     uniformReading.speechRatio, minSpeechRatio,
                     uniformReading.speech, speechCeiling))

        // MARK: 三、已知误判形态（钉住它，别装作不存在）

        // 连续小声说话、p90 低于绝对上限 → 会被判成静音。**这是已知代价**，
        // 不是这一版要修的缺陷：要把它和「底噪」分开需要真实的课堂小声录音
        // 来标定（本包不许自造输入）。这一组存在的意义是：哪天有人改了判据，
        // 这一条会红，读的人就会看到这行注释，而不是以为「门控从来不会误判」
        let quietContinuous = tone(seconds: 10, amplitude: 0.006)
        let quietReading = evaluate(samples: quietContinuous, sampleRate: rate).reading
        check("已知误判：连续小声说话（0.006 幅度、p90 低于上限）会被判成静音",
              verdict(quietContinuous).isSilence,
              String(format: "p90 %.5f < 上限 %.5f；真实课堂小声说话要真人录音才能标定",
                     quietReading.speech, speechCeiling))

        // MARK: 四、判据本体（两个条件的形状）

        func reading(ratio: Double, speech p90: Double) -> Reading {
            Reading(windowSeconds: 10, frameCount: 500, floor: 0.001, median: 0.002,
                    speech: p90, speechRatio: ratio)
        }
        check("两条都成立才判静音：占比低 + p90 低 → 静音",
              isSilence(reading(ratio: 0.01, speech: 0.002)))
        check("占比低但 p90 高 → **不**判静音（第 2 条挡住）",
              !isSilence(reading(ratio: 0.01, speech: 0.5)))
        check("p90 低但占比高 → **不**判静音（第 1 条挡住）",
              !isSilence(reading(ratio: 0.9, speech: 0.001)))
        check("空窗不判静音（没有音频可跳，也不该说「这里没人说话」）",
              !isSilence(Reading(windowSeconds: 0, frameCount: 0, floor: 0, median: 0, speech: 0, speechRatio: 0)))
        check("空样本喂进 evaluate 也判有声、不崩",
              !evaluate(samples: [], sampleRate: rate).verdict.isSilence)

        // MARK: 四之二、相对线（教室噪声下的静音窗）

        func noisy(floor: Double, p90: Double, ratio: Double = 0.05) -> Reading {
            Reading(windowSeconds: 10, frameCount: 500, floor: floor,
                    median: floor * 1.1, speech: p90, speechRatio: ratio)
        }
        check("噪声地板 0.004、p90 只有地板的 1.2 倍 → 判静音（绝对线管不到这里）",
              isSilence(noisy(floor: 0.004, p90: 0.0048)))
        check("同底噪、p90 是地板 3.7 倍（实测真人说话那批的下沿）→ 判有声",
              !isSilence(noisy(floor: 0.004, p90: 0.0148)))
        check("安静房间（底噪 0.0005）走绝对线：p90 0.0008 → 静音",
              isSilence(noisy(floor: 0.0005, p90: 0.0008)))
        check("安静房间不启用相对线：p90 0.004（地板的 8 倍但低于绝对上限）→ 仍判静音",
              isSilence(noisy(floor: 0.0005, p90: 0.004)))
        check("相对线的启用门槛是底噪 0.002",
              relativeFloorActivation == 0.002, "\(relativeFloorActivation)")
        check("相对倍数是 2.2",
              relativeCeilingFactor == 2.2, "\(relativeCeilingFactor)")

        // MARK: 五、常量与同源性（写死数值，别拿实现再算一遍）

        check("语音帧占比的门是 0.10（与 MicLevelMetrics 的「几乎没人说话」同值）",
              minSpeechRatio == 0.10, "\(minSpeechRatio)")
        check("p90 绝对上限是 0.01000", speechCeiling == 0.01, "\(speechCeiling)")
        // 同源：门控的读数必须就是 `MicLevelMetrics` 对同一段音频给出的那一组数。
        // 这条挡的是「门控自己另写一套帧/分位数」——那会让同一段音频在采集侧
        // 与门控侧得出不同的结论
        let analyzed = MicLevelMetrics.analyze(samples: speech, sampleRate: rate, windowSeconds: 10)
        let gateReading = evaluate(samples: speech, sampleRate: rate).reading
        if let w = analyzed.windows.first {
            check("与 MicLevelMetrics 逐数一致（floor / p90 / 占比 / 中位）",
                  w.floor == gateReading.floor && w.speech == gateReading.speech
                    && w.speechRatio == gateReading.speechRatio && w.median == gateReading.median,
                  String(format: "占比 %.6f / %.6f", w.speechRatio, gateReading.speechRatio))
        } else {
            check("与 MicLevelMetrics 逐数一致（floor / p90 / 占比 / 中位）", false, "analyze 没给出窗口")
        }

        // MARK: 六、开关契约

        check("没给环境变量 → 默认开（静音幻觉是已实测的缺陷，不是可选优化）",
              SpeechGatePolicy.fromEnvironment([:]) == .on)
        for alias in ["0", "off", "false", "no", "OFF", " off "] {
            check("「\(alias)」是关", SpeechGatePolicy.fromEnvironment([SpeechGatePolicy.environmentKey: alias]) == .off)
        }
        for other in ["1", "on", "true", "yes"] {
            check("「\(other)」不是关（只有写明的那几个才算关）",
                  SpeechGatePolicy.fromEnvironment([SpeechGatePolicy.environmentKey: other]) == .on)
        }
        check("环境变量名是 CLASSROOM_SPEECH_GATE",
              SpeechGatePolicy.environmentKey == "CLASSROOM_SPEECH_GATE", SpeechGatePolicy.environmentKey)

        // P12-3：设置页那一层。**每一条都钉一个方向**——环境变量能盖过设置页
        // 的两个方向都要验：只验「能关」的话，把环境变量写成单向覆盖
        // （只会关、不会开）也照样绿，而那种实现会让「探针强制开」失效
        check("没环境变量、文件也没值 → 缺省开",
              SpeechGatePolicy.resolve(fileValue: nil, envValue: nil) == .on)
        check("设置页关掉 → 关（用户关得掉，这是 P12-3 的目的）",
              SpeechGatePolicy.resolve(fileValue: false, envValue: nil) == .off)
        check("设置页打开 → 开",
              SpeechGatePolicy.resolve(fileValue: true, envValue: nil) == .on)
        check("环境变量 off 盖过设置页「开」（探针要能强制关）",
              SpeechGatePolicy.resolve(fileValue: true, envValue: "off") == .off)
        check("环境变量 on 盖过设置页「关」（两个方向都要能盖）",
              SpeechGatePolicy.resolve(fileValue: false, envValue: "on") == .on)
        check("空白环境变量视同没设 → 回到设置页",
              SpeechGatePolicy.resolve(fileValue: false, envValue: "   ") == .off)

        lines.append(failures == 0
            ? "✅ 静音门控自检通过（\(checked) 条）"
            : "❌ 静音门控自检未通过（\(failures)/\(checked) 条红）")
        return lines
    }
}

// MARK: - 开关

/// 门控的开关。**关掉 = 这门不存在**：`skipIfSilent` 在关的时候直接返回，
/// 连电平都不算，走的还是同一条取窗 → 解码 → 合并的路径。
///
/// 判据有两条，都在 `tools/probes/p12_2_speech_gate.sh` 里：探针判「同一段
/// 录音、开关两态，关那一臂**一窗都不跳**（跳过 0 且 真的解了 == 取窗）」，
/// `exit_codes.sh` 用合成夹具把同一件事钉成一行断言。
///
/// 「关掉与**改造前**一致」这一条是**逐项验过**的：生产步长在 P12-2 最终
/// 没有改动（压缩重叠那一版量出会丢内容，撤了），所以关掉门控后段数 /
/// 总字数 / 窗口取用节奏与基线 `6f664e8` 相同。见交付报告里那张对照表。
///
/// 与 `URLFallbackPolicy`（P12-1b）同形：环境变量、缺省开、关的写法有穷枚举。
/// 缺省开是因为它挡的是**已经实测过四次**的静音幻觉——那是个 bug 级别的现象，
/// 不是「可选的优化」；关掉留给 A/B 与排障。
///
/// **P12-3 起多了一层设置页**：`CLASSROOM_SPEECH_GATE` 从「唯一的开关」变成
/// 「探针/开发用的强制覆盖」，没设时才看用户在设置页里选的值（缺省仍是开）。
/// 在这之前，用户在界面上关不掉它——而判据在这条录音上只有 0.4 dB 的 p90 余量，
/// 「人离麦很远、说话很小声」那条边界没标定过，于是存在一种没量过的场景：
/// 门控把真人说话整窗跳过，而用户没有任何办法把它关掉。裁决顺序见 `resolve`。
enum SpeechGatePolicy: Equatable, Sendable {
    case on
    case off

    /// 探针/开发的**强制覆盖**。设了它就必须按它走，盖过设置页——
    /// 两臂 A/B 要的是「同一份二进制、同一条录音、只差这一个变量」，
    /// 让用户存的值参与进来，两臂就不再只差一个变量了
    static let environmentKey = "CLASSROOM_SPEECH_GATE"

    /// 两步裁决的**纯函数**本体。P12-3 把它抽出来，因为三处要问同一件事：
    /// 生产管线（`fromConfig`）、设置页（`AppConfig.speechGateEnabled`）、
    /// 自检。三处各写一遍 `?? true`，改一处另两处不会跟着动，而分家之后
    /// 界面上看不出来（界面显示「开」、生产却是关）。
    ///
    /// - 环境变量**设了且非空白** → 按它（`0/off/false/no` 是关，其余是开）；
    ///   空白视同没设，与 `AppConfig.value(env:file:)` 的口径一致。
    /// - 没设 → 文件里的值；文件里**也没有这一项**（老配置）→ **开**。
    ///
    /// 缺省开不是随手定的：门控挡的是已实测四次的静音幻觉，缺省关 =
    /// 把那个 bug 放回默认路径。判据的余量薄（那条录音上 p90 只差 0.4 dB）、
    /// 「人离麦很远的小声课堂」没标定过，所以**用户要能关**——但关是一条
    /// 显式选择，不是缺省
    static func resolve(fileValue: Bool?, envValue: String?) -> SpeechGatePolicy {
        if let raw = envValue {
            let clean = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if !clean.isEmpty {
                switch clean {
                case "0", "off", "false", "no": return .off
                default: return .on
                }
            }
        }
        guard let fileValue else { return .on }
        return fileValue ? .on : .off
    }

    /// 只看环境变量（缺省开）。保留这个入口是因为自检与历史探针按它断言
    /// 「环境变量的写法有穷」；生产走 `fromConfig()`，它多看了设置页那一层
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SpeechGatePolicy {
        resolve(fileValue: true, envValue: environment[environmentKey])
    }

    /// 生产缺省：环境变量优先，其次设置页，最后缺省开。
    ///
    /// **不要把它换回 `fromEnvironment()`**：那样设置页的开关对生产管线完全无效，
    /// 用户关掉了、门控还在跳，而且没有任何报错——这正是 P12-3 要修的那件事
    static func fromConfig() -> SpeechGatePolicy {
        AppConfig.speechGatePolicy
    }

    var label: String { self == .on ? "开" : "关" }
}
