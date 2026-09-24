import AVFoundation
import Foundation
// 成因探针要自己开一个 whisper context 做对照实验，所以这里直接用到 C API。
// 别的地方（引擎、管线）都不碰 C 层——这一处是**离线调试入口**的例外
import whisper

/// `--whisper-window-file <wav>`：把滑窗链路在**真实录音**上离线跑一遍。
///
/// 走的必须是接线后的那条路径（`WhisperWindowPipeline`：取窗 → 转写 → 合并 →
/// 定稿），只把「麦克风」换成文件、把「等一个步长」换成「喂够一个步长的音频
/// 就取一窗」。自己另写一遍取窗 + 合并的话，验的是那份复制品——而这一包要
/// 回答的恰恰是「接线后的那条路径在真实录音上表现如何」。
///
/// **全程不碰主 actor**：这个入口在主线程上用信号量等结果（见 App.swift）。
/// 任何一次跳回主 actor 的 await 都会死锁——`--mic-selftest` 当初就是因为
/// 主线程被阻塞把引擎饿死，才改成「不 exit、照常起窗口」的。
///
/// 诊断开关（都只影响这个入口的输出，**不改任何生产参数**）：
///
/// ```
/// --whisper-window-file <wav> [--timing] [--dump-all] [--first-window <秒>]
///                            [--repeat <n>] [--label <文字>]
///                            [--confidence-probe [--probe-step <秒>] [--probe-only]] [--sweep]
///                            [--head <秒>]
/// ```
///
/// - `--timing`：逐窗耗时表（窗序号 / 起点毫秒 / 耗时 / 该窗音频时长 /
///   该窗音频特征 / 进程内存），并给首段被改写的轨迹。占用率那条均值被
///   离群窗拖偏时，只有这张表能指出是哪一窗、以及它落在什么音频上。
/// - `--first-window <秒>`：首窗要攒够多少音频才取。默认 = 步长
///   （实时链路的行为：3 秒时缓冲里只有 3 秒 → 首窗必然是 3 秒碎片）。
/// - `--repeat <n>`：同一引擎、重开管线跑 n 遍。**第一遍的离群窗在第二遍
///   是否消失**是「内存/首次编译」和「音频内容」的分水岭——同一位置复现
///   = 内容相关，位置乱跳 = 机器状态相关。
/// - `--dump-all`：把所有段（不只前 12 段）按时间顺序打出来。
/// - `--confidence-probe`：另跑一趟**测量通道**（绕开合并器，直接调引擎），
///   把每个识别段的文本与连续置信度一起打出来。标定档位阈值必须要这一对，
///   而合并器转成 `TranscriptSegment` 时把 `confidences` 丢掉了。
///   `--probe-only` 只跑这一趟、跳过滑窗（标定阈值时用）。
/// - `--sweep`：在探针结果上扫一遍候选阈值（**只作对照，不改生产常数**），
///   看每条候选线会把多少段判成「不可信」。
/// - `--head <秒>`：只跑前 N 秒（问「开头几秒怎么样」时不用把整条跑完，
///   输出里会标明覆盖率的分母是这 N 秒）。
/// - `--suppress-regex <模式>`：把模式交给 whisper 的 `suppress_regex`。
///   **必须显式传才启用**，因为上游语义（整 token 精确匹配、每 token 遍历
///   整个词表、模式非法即 abort）使它的效果和代价都得先量再说，见
///   `WhisperEngine.suppressRegexCaveat`。探针会单独报单窗耗时以便对照。
/// - 探针输出的末尾会附**幻觉治理的改动前后对照**（`hallucinationSection`），
///   一趟跑出两条臂。生产链路自己的丢弃记录则由滑窗那一趟打印。
enum WhisperWindowFileRun {

    /// 喂音频的块长。比 4096 帧的回调块（约 85ms）粗、比步长细：
    /// 取窗的时机由「累计喂够一个步长」决定，块长只影响它对齐得准不准
    private static let chunkSeconds = 0.5

    /// 逐帧能量的帧长。100ms 是「这一窗到底有没有人在说话」的常用粒度：
    /// 再细就会被单个辅音带偏，再粗就分不出句子之间的停顿
    private static let frameSeconds = 0.1

    // MARK: - 选项

    struct Options {
        /// 首窗要攒够的音频（秒）。默认 = 步长，即实时链路的行为
        var firstWindowSeconds: Double = WhisperWindowPipeline.stepSeconds
        var timing = false
        var dumpAll = false
        var repeatCount = 1
        var label = ""
        var confidenceProbe = false
        /// 只跑置信度探针、跳过滑窗那一趟。标定要跑好几条录音，
        /// 每条都跑两趟是白等（见 run 里的那段注释）
        var probeOnly = false
        /// 置信度探针的步长。默认 = 步长（与生产一致，但同一句会被重叠窗
        /// 转 3 次左右）；标定分布时要的是**互不重叠**的样本，那时传 10
        var probeStepSeconds: Double = WhisperWindowPipeline.stepSeconds
        var sweep = false
        /// 只取前 N 秒音频（0 = 整段）。问「开头那几秒怎么样」时没必要把整条
        /// 录音跑完——一条 6 分钟的录音跑一趟要三分半，而 §3 只看首段
        var headSeconds: Double = 0
        /// 把最慢的 N 窗重新单独转一遍并打印它们的原始输出（0 = 不做）。
        /// 「慢窗在转什么」只有这条路看得见：`advance()` 把原始识别结果交给
        /// 合并器就丢了，事后从最终段列表里反推不出来
        var slowWindowCount = 0
        /// 对最慢的 N 窗做「关掉 temperature fallback」的因果对照（0 = 不做）。
        /// 会**再开一个 whisper context**，所以要显式要求
        var fallbackProbeCount = 0
        /// `--suppress-regex <模式>`：把模式交给 whisper 的 `suppress_regex`。
        /// **必须显式传才会启用**——上游语义是整 token 精确匹配、且每个生成
        /// token 遍历一遍词表，代价和效果都要先量。见 `WhisperEngine.suppressRegexCaveat`
        var suppressRegex: String?

        static func parse(_ arguments: [String]) -> Options {
            var options = Options()
            func value(_ flag: String) -> String? {
                guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
                return arguments[i + 1]
            }
            if let raw = value("--first-window"), let seconds = Double(raw), seconds > 0 {
                options.firstWindowSeconds = seconds
            }
            if let raw = value("--repeat"), let n = Int(raw) {
                options.repeatCount = max(1, n)
            }
            if let raw = value("--probe-step"), let seconds = Double(raw), seconds > 0 {
                options.probeStepSeconds = seconds
            }
            if let raw = value("--head"), let seconds = Double(raw), seconds > 0 {
                options.headSeconds = seconds
            }
            if let raw = value("--slow-windows"), let n = Int(raw), n > 0 {
                options.slowWindowCount = n
            }
            if let raw = value("--fallback-probe"), let n = Int(raw), n > 0 {
                options.fallbackProbeCount = n
            }
            if let raw = value("--label") { options.label = raw }
            if let raw = value("--suppress-regex") { options.suppressRegex = raw }
            options.timing = arguments.contains("--timing")
            options.dumpAll = arguments.contains("--dump-all")
            options.probeOnly = arguments.contains("--probe-only")
            options.confidenceProbe = arguments.contains("--confidence-probe") || options.probeOnly
            options.sweep = arguments.contains("--sweep")
            return options
        }
    }

    // MARK: - 一轮的原始记录

    /// 一次取窗的记录。`startMillis == nil` = 这轮调用没取到窗（缓冲不够
    /// 一窗，或起点没往前走）——实时链路里这些轮次是「空转」，把它们记下来
    /// 才能解释「轮次墙钟均」为什么会小于「单次转写均」。
    ///
    /// `note` 标出这一行的性质（空转 / 收尾窗）。收尾窗必须单独标出来：
    /// 它也是 `merge()` 的一次调用、也进 `transcriptionSeconds`，只是不经过
    /// `advance()`——漏掉它，这里的「N 窗」就会比 `pipeline.statsLine` 少 1，
    /// 与用户手上那份数字对不上（阶段 3 踩过：62 对 61）
    private struct WindowTrace {
        let index: Int
        let startMillis: Int?
        let elapsedSeconds: Double
        let audioSeconds: Double
        var newSegments: Int
        /// 这一窗**原始**认出多少字（合并之前）。判断「慢窗是不是说话密集」
        /// 靠它，不靠 `newSegments`——滑窗与上一窗重叠 7 秒，同一句被反复认出，
        /// 合并器把它当旧段丢掉，于是 slow 窗的 `newSegments` 常常是 0，
        /// 看起来像「什么都没说」，而实际可能正是说得最密的那一窗
        let charsRecognized: Int
        let rms: Double
        let peak: Double
        let voicedRatio: Double
        let footprintMB: Double
        var note = ""
    }

    private struct Round {
        var label = ""
        var windows: [WindowTrace] = []
        var attempts = 0
        var wallSeconds = 0.0
        var transcriptSeconds: [Double] = []
        var guardTrips = 0
        var confidences: [Double] = []
        var segments: [TranscriptSegment] = []
        var finalized = 0
        var maxFootprintMB = 0.0
        /// 首段（整轮里第一个出现的段）的文本随窗口推进的完整轨迹。
        /// 「首段是不是碎片、后来有没有被修正」只能这样看——只看最终列表
        /// 的话，被改写过的中间版本一点痕迹都不留
        var firstSegmentId: UUID?
        var firstSegmentSeenAtSeconds: Double?
        var firstSegmentSeenAtWindow: Int?
        var firstSegmentTrace: [(afterFeedSeconds: Double, text: String)] = []
        /// 每个 id 的文本被改写过几次（合并器在同一段上的覆盖次数）
        var revisionCounts: [UUID: Int] = [:]
        /// 生产链路丢掉的幻觉段（`WhisperWindowPipeline.hallucinationLog`）。
        /// 从管线自己那儿读，不是从最终段列表反推——反推不出来
        var hallucinations: [String] = []

        var realWindows: [WindowTrace] { windows.filter { $0.startMillis != nil } }
    }

    // MARK: - 音频特征

    /// 逐 100ms 帧的能量。用来回答「离群窗是不是落在特定音频段落上」——
    /// 只报耗时的话，「这一窗正好是长句 / 静音 / 说话密集」全都只能靠猜
    private struct Frames {
        let rms: [Double]
        /// 整段录音的帧能量中位数。「有声」的判据是相对它定的（见下），
        /// 不是绝对门限——绝对门限要按录音标定，而排障时没有那个余裕
        let median: Double

        init(samples: [Float], frameSamples: Int) {
            var values: [Double] = []
            values.reserveCapacity(samples.count / frameSamples + 1)
            var index = 0
            while index + frameSamples <= samples.count {
                var sum = 0.0
                for i in index..<(index + frameSamples) {
                    let v = Double(samples[i])
                    sum += v * v
                }
                values.append((sum / Double(frameSamples)).squareRoot())
                index += frameSamples
            }
            self.rms = values
            self.median = values.isEmpty ? 0 : values.sorted()[values.count / 2]
        }

        /// 帧下标区间。帧长固定 100ms，毫秒直接除
        private func range(fromMillis: Int, toMillis: Int) -> Range<Int> {
            let lo = max(0, fromMillis / 100)
            let hi = min(rms.count, max(lo, toMillis / 100))
            return lo..<hi
        }

        /// 「有声帧」占比：帧能量 ≥ 整段中位帧能量的一半。
        /// 与录音自身比而不是与某个绝对门限比，跨录音可比；一门课录下来
        /// 麦克风增益是常量，所以这条比值在同一条录音内部是稳的
        func voicedRatio(fromMillis: Int, toMillis: Int) -> Double {
            let r = range(fromMillis: fromMillis, toMillis: toMillis)
            guard !r.isEmpty, median > 0 else { return 0 }
            let voiced = r.filter { rms[$0] >= median * 0.5 }.count
            return Double(voiced) / Double(r.count)
        }
    }

    // MARK: - 入口

    static func run(path: String) async -> [String] {
        await run(path: path, options: Options.parse(CommandLine.arguments))
    }

    static func run(path: String, options: Options) async -> [String] {
        var lines: [String] = ["═══ Whisper 滑窗 · 真实录音离线跑（走接线后的管线）═══"]
        if !options.label.isEmpty { lines.append("标签: \(options.label)") }
        if options.firstWindowSeconds != WhisperWindowPipeline.stepSeconds {
            lines.append(String(format: "首窗最小长度被改为 %.1f 秒（默认 %.1f = 步长）",
                                options.firstWindowSeconds, WhisperWindowPipeline.stepSeconds))
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let file = try? AVAudioFile(forReading: url) else {
            return lines + ["❌ 打不开音频: \(url.path)"]
        }
        let format = file.processingFormat
        let totalFrames = file.length
        let seconds = Double(totalFrames) / format.sampleRate
        lines.append(String(format: "输入: %@", url.lastPathComponent))
        lines.append(String(
            format: "  格式 %@ · %d 帧 · %.1f 秒 · 声道 %d",
            format.description, totalFrames, seconds, format.channelCount
        ))

        // 一次读满整个文件：按 min(chunk, 剩余) 读，不要固定块长 + catch break
        // （那个写法在文件末尾不足一整块时会静默丢尾，本项目踩过）
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ) else { return lines + ["❌ 分配缓冲失败"] }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(totalFrames))
        } catch {
            return lines + ["❌ 读音频失败: \(error)"]
        }
        guard buffer.frameLength == totalFrames else {
            return lines + ["❌ 短读：\(buffer.frameLength) / \(totalFrames) 帧——覆盖率不足，先修这个再看质量"]
        }
        lines.append("  ✅ 读满 \(buffer.frameLength) 帧（无短读）")

        guard var samples = WhisperEngine.resampleTo16k(buffer) else {
            return lines + ["❌ 重采样到 16k 失败"]
        }
        if options.headSeconds > 0 {
            let keep = min(samples.count, Int(options.headSeconds * WhisperWindowPipeline.sampleRate))
            samples = Array(samples.prefix(keep))
            lines.append(String(
                format: "  ⚠️ 只取前 %.1f 秒（--head）——下面的覆盖率分母是这 %.1f 秒，不是整个文件",
                options.headSeconds, Double(keep) / WhisperWindowPipeline.sampleRate
            ))
        }
        let audioSeconds = Double(samples.count) / WhisperWindowPipeline.sampleRate
        lines.append(String(format: "  ✅ 重采样到 16k 单声道：%d 采样点 · %.1f 秒",
                            samples.count, audioSeconds))

        lines.append("")
        lines.append("─── 加载引擎 ───")
        let engine: WhisperEngine
        let loadStarted = ContinuousClock.now
        do {
            engine = try WhisperEngine()
        } catch {
            return lines + ["❌ 引擎构造失败: \(error.localizedDescription)（模型路径 \(WhisperEngine.resolvedModelURL.path)）"]
        }
        lines.append(String(format: "  ✅ 引擎就绪（%.2f 秒）· 模型 %@ · 进程 %.0f MB",
                            secondsSince(loadStarted), WhisperEngine.resolvedModelURL.lastPathComponent,
                            footprintMB()))

        let frames = Frames(
            samples: samples,
            frameSamples: max(1, Int(frameSeconds * WhisperWindowPipeline.sampleRate))
        )
        lines.append(String(format: "  整段帧能量中位 %.4f（%d 帧 × %.1f 秒）——「有声帧」判据是它的一半",
                            frames.median, frames.rms.count, frameSeconds))

        // --probe-only：只跑置信度探针，跳过滑窗那一趟。
        // 标定阈值只用得到探针的段，而跑整条管线还要再花一趟时间（一条 6 分钟
        // 的录音两趟加起来十几分钟）——量分布时要跑好几条录音，这个开关省的是
        // 乘以条数的那部分
        if options.probeOnly {
            lines.append("")
            // `try` 要包住：run() 不是 throws 的（它的调用方在 App.swift
            // 里只 await 不 catch），探针失败要走「打印一行 ❌」而不是上抛
            do {
                lines.append(contentsOf: try confidenceProbe(
                    samples: samples, engine: engine, options: options
                ))
            } catch {
                lines.append("❌ 置信度探针失败: \(error.localizedDescription)")
            }
            return lines
        }

        lines.append("")
        lines.append("─── 跑滑窗（窗口 \(Int(WhisperWindowPipeline.windowSeconds)) 秒 / 步长 \(Int(WhisperWindowPipeline.stepSeconds)) 秒）───")

        var rounds: [Round] = []
        do {
            for index in 1...options.repeatCount {
                let label = options.repeatCount == 1
                    ? ""
                    : "第 \(index)/\(options.repeatCount) 遍（同一引擎，重开管线）"
                if !label.isEmpty { lines.append("  ▸ \(label)") }
                rounds.append(try runRound(
                    samples: samples, engine: engine, options: options, frames: frames, label: label
                ))
            }
        } catch {
            return lines + ["❌ 转写失败: \(error.localizedDescription)"]
        }

        guard let round = rounds.first else { return lines + ["❌ 没有跑出任何一轮"] }

        lines.append(String(format: "  %d 窗 · 离线全程 %.1f 秒（音频 %.1f 秒）",
                            round.realWindows.count, round.wallSeconds, audioSeconds))
        lines.append("  \(statsLine(round))")
        if options.repeatCount > 1 {
            lines.append("")
            lines.append("─── 重复跑（看离群窗会不会自己消失）───")
            for r in rounds { lines.append("  \(repeatSummary(r))") }
        }

        if options.timing || options.repeatCount > 1 {
            lines.append("")
            lines.append(contentsOf: timingTable(round))
        }

        // 慢窗到底「转出了什么」：耗时表只有列，列不出文本。把最慢的几窗
        // 重新单独转一遍（直接调引擎，不走合并器），把**这一窗自己的原始输出**
        // 打出来——「慢是因为长句」和「慢是因为没有语音、模型在那儿空转」
        // 在这张表里长得一样，在这一段里一眼分得开
        if options.slowWindowCount > 0 {
            lines.append("")
            do {
                lines.append(contentsOf: try slowWindowDump(
                    samples: samples, engine: engine, round: round, count: options.slowWindowCount
                ))
            } catch {
                lines.append("❌ 慢窗重转失败: \(error.localizedDescription)")
            }
        }

        if options.fallbackProbeCount > 0 {
            lines.append("")
            do {
                lines.append(contentsOf: try fallbackProbe(
                    samples: samples, round: round, count: options.fallbackProbeCount
                ))
            } catch {
                lines.append("❌ 成因探针失败: \(error.localizedDescription)")
            }
        }

        lines.append("")
        lines.append("─── 结果 ───")
        let segments = round.segments
        let finalized = round.finalized
        lines.append("  段数 \(segments.count)（定稿 \(finalized)）")
        // §3 的消融表要按「字数」比文本质量：**关掉重试链会不会把内容也关掉**，
        // 只有这个数能回答。它数的是最终输出的字，不含窗口重叠的重复计入
        // （那部分见下面的逐字符置信度行，那个是带重叠的）
        lines.append("  总字数 \(segments.reduce(0) { $0 + $1.text.count })（最终输出）")
        if segments.count != finalized {
            lines.append("  ⚠️ 有 \(segments.count - finalized) 段没收尾定稿（收尾定稿应当把最后一段也带上）")
        }

        // 质量档位分布。用四个具名计数而不是字典：字典要 `!` 取键，
        // 而这是诊断入口，没必要为一行输出留一个能崩的点
        var good = 0, fair = 0, poor = 0, ungraded = 0
        for segment in segments {
            switch segment.qualityGrade {
            case .good: good += 1
            case .fair: fair += 1
            case .poor: poor += 1
            case nil: ungraded += 1
            }
        }
        lines.append("  质量档位: 可信 \(good) / 存疑 \(fair) / 不可信 \(poor) / 未评（nil） \(ungraded)")

        // 繁体残留。**引擎出口已经过 `ChineseText.toSimplified`**（WhisperEngine :384），
        // 所以这里非 0 只可能是 ICU 的转换表漏了字——`--whisper-selftest` 里
        // 「原表漏字 門/請/謝」那条用例盯的就是它。§3 的消融表拿它当文本质量的一维：
        // 第 53 窗那趟重试链吐回来的正是繁体（「謝謝大家,謝謝!」）
        let traditional = segments.filter { ChineseText.looksTraditional($0.text) }
        lines.append("  繁体残留: \(traditional.count) 段（引擎出口已过 toSimplified，非 0 = ICU 表漏字）")
        for segment in traditional.prefix(3) {
            lines.append("      「\(segment.text)」→「\(ChineseText.toSimplified(segment.text))」")
        }

        // 逐字符置信度的原始分布。**含窗口重叠导致的重复计入**（10 秒窗 / 3 秒
        // 步长 → 同一句平均被转 3 次左右），所以它只是分布参考；标定阈值要看
        // `--confidence-probe` 那份（那里有文本，能对着文本判好坏）
        if !round.confidences.isEmpty {
            lines.append(contentsOf: confidenceDistribution("逐字符置信度（含重叠重复计入）", round.confidences))
        }

        // 合并器吐回来的顺序不保证按时间（它按候选追加），引擎在 adopt 里会
        // 调 restoreOrderIfNeeded 排一遍——这里自己排，否则这份输出看起来像
        // 「界面上的段落是乱的」，而界面不是。逆序处数出来是为了别把这件事藏掉
        let inversions = zip(segments, segments.dropFirst())
            .filter { $0.startTimeMillis > $1.startTimeMillis }.count
        let ordered = segments.sorted { $0.startTimeMillis < $1.startTimeMillis }

        // 提问检出：用的是引擎那条路径上的同一个检测器与默认灵敏度
        let detector = QuestionDetector(sensitivity: .normal)
        var level1 = 0, level2 = 0
        for segment in segments {
            guard let hit = detector.detect(segment.text) else { continue }
            if hit.level >= 2 { level2 += 1 } else { level1 += 1 }
        }
        lines.append("  提问检出（灵敏度 NORMAL）: level1 \(level1) 段 / level2 \(level2) 段")

        // 覆盖率：最后一段结束时间 vs 音频总长。**先看覆盖率再看质量**——
        // 覆盖不全的话，下面的档位分布只是「被覆盖的那部分」的分布
        let lastEnd = ordered.map(\.endTimeMillis).max() ?? 0
        lines.append(String(
            format: "  覆盖率: 最晚段结束 %.1f 秒 / 音频 %.1f 秒 = %.1f%%",
            Double(lastEnd) / 1000, audioSeconds,
            Double(lastEnd) / 1000 / audioSeconds * 100
        ))
        lines.append("  守卫触发 \(round.guardTrips) 次")

        lines.append("")
        lines.append(contentsOf: firstSegmentSection(round))

        lines.append("")
        lines.append(contentsOf: duplicateSection(ordered: ordered, round: round))

        // 生产链路的幻觉过滤**必须在这一趟里看得见**：`--probe-only` 那条路
        // 是绕开生产链路的离线对照，它证明不了 `WhisperWindowPipeline` 里
        // 那一句真的接上了。所以这里把管线自己的丢弃记录打出来。
        lines.append("")
        if round.hallucinations.isEmpty {
            lines.append("─── 生产链路的幻觉过滤：这一趟没丢任何段 ───")
        } else {
            lines.append("─── 生产链路的幻觉过滤：丢了 \(round.hallucinations.count) 段 ───")
            for entry in round.hallucinations { lines.append("  \(entry)") }
        }

        let preview = options.dumpAll ? ordered.count : min(12, ordered.count)
        lines.append("")
        lines.append(options.dumpAll
            ? "─── 全部 \(ordered.count) 段（按时间排；合并器原序逆序 \(inversions) 处）───"
            : "─── 前 \(preview) 段（按时间排；合并器原序逆序 \(inversions) 处，界面侧会排）───")
        for (offset, segment) in ordered.prefix(preview).enumerated() {
            let grade = segment.qualityGrade?.label ?? "—"
            let question = segment.isQuestion ? " ❓L\(segment.questionLevel)" : ""
            let prefix = options.dumpAll ? String(format: "%4d ", offset + 1) : ""
            let revisions = round.revisionCounts[segment.id] ?? 0
            let rewritten = revisions > 0 ? " ✎\(revisions)" : ""
            lines.append("  \(prefix)[\(segment.formattedTimestamp)] (\(grade))\(question)\(rewritten) \(segment.text)")
        }

        if options.confidenceProbe || options.sweep {
            lines.append("")
            do {
                lines.append(contentsOf: try confidenceProbe(
                    samples: samples, engine: engine, options: options
                ))
            } catch {
                lines.append("❌ 置信度探针失败: \(error.localizedDescription)")
            }
        }

        return lines
    }

    // MARK: - 跑一轮（生产路径）

    private static func runRound(
        samples: [Float],
        engine: WhisperEngine,
        options: Options,
        frames: Frames,
        label: String
    ) throws -> Round {
        var round = Round()
        round.label = label
        let pipeline = WhisperWindowPipeline()
        let chunk = max(1, Int(chunkSeconds * WhisperWindowPipeline.sampleRate))
        let windowFrames = Int(WhisperWindowPipeline.windowSeconds * WhisperWindowPipeline.sampleRate)
        var fed = 0
        var nextWindowAt = Int(options.firstWindowSeconds * 1000)
        var seenIds: Set<UUID> = []
        var lastText: [UUID: String] = [:]
        let runStarted = ContinuousClock.now

        while fed < samples.count {
            let end = min(fed + chunk, samples.count)
            pipeline.append(Array(samples[fed..<end]))
            fed = end

            // 实时链路是「每过一个步长取一次窗」，这里用「已喂进去的音频够一个
            // 步长了」代替——喂进来的音频就是时间轴本身，两者的取窗时刻一致
            let fedMillis = Int(Double(fed) / WhisperWindowPipeline.sampleRate * 1000)
            guard fedMillis >= nextWindowAt else { continue }
            nextWindowAt += WhisperWindowPipeline.stepMillis

            let callStarted = ContinuousClock.now
            let charsBefore = pipeline.recognizedConfidences.count
            let update = try pipeline.advance(engine: engine)
            let charsRecognized = pipeline.recognizedConfidences.count - charsBefore
            let elapsed = secondsSince(callStarted)
            round.attempts += 1

            let startMillis = update == nil ? nil : pipeline.lastWindowStartMillis
            let startSamples = (startMillis ?? 0) * 16      // 16kHz → 毫秒 × 16
            let endSamples = max(startSamples, min(startSamples + windowFrames, fed))
            let windowAudioSeconds = Double(endSamples - startSamples) / WhisperWindowPipeline.sampleRate
            let windowEndMillis = (startMillis ?? 0) + Int(windowAudioSeconds * 1000)

            round.windows.append(WindowTrace(
                index: round.attempts,
                startMillis: startMillis,
                elapsedSeconds: elapsed,
                audioSeconds: windowAudioSeconds,
                newSegments: 0,
                charsRecognized: charsRecognized,
                rms: update == nil ? 0 : peakOrRMS(samples, startSamples, endSamples, rms: true),
                peak: update == nil ? 0 : peakOrRMS(samples, startSamples, endSamples, rms: false),
                voicedRatio: update == nil ? 0 : frames.voicedRatio(
                    fromMillis: startMillis ?? 0, toMillis: windowEndMillis
                ),
                footprintMB: footprintMB()
            ))
            round.maxFootprintMB = max(round.maxFootprintMB, round.windows[round.windows.count - 1].footprintMB)

            guard let update else { continue }
            round.segments = update.segments
            round.finalized = update.segments.filter(\.isFinal).count

            // 新增段 / 改写次数：合并器把候选追加进列表，所以「新 id 出现」是
            // 新增，「同 id 文本变了」是覆盖。两个都要数——只数新增的话，
            // 「同一句被反复改写成最终版本」这件事在输出里完全看不见
            let fresh = update.segments.filter { !seenIds.contains($0.id) }
            for segment in fresh { seenIds.insert(segment.id) }
            round.windows[round.windows.count - 1].newSegments = fresh.count

            for segment in update.segments {
                if let previous = lastText[segment.id] {
                    if previous != segment.text { round.revisionCounts[segment.id, default: 0] += 1 }
                } else {
                    round.revisionCounts[segment.id] = 0
                }
                lastText[segment.id] = segment.text
            }

            // 首段轨迹：整轮里第一个出现的段，之后每一窗都看它还在不在、文本变了没
            let orderedNow = update.segments.sorted { $0.startTimeMillis < $1.startTimeMillis }
            if round.firstSegmentId == nil, let first = orderedNow.first {
                round.firstSegmentId = first.id
                round.firstSegmentSeenAtSeconds = Double(fed) / WhisperWindowPipeline.sampleRate
                round.firstSegmentSeenAtWindow = round.attempts
                round.firstSegmentTrace.append((Double(fed) / WhisperWindowPipeline.sampleRate, first.text))
            } else if let id = round.firstSegmentId,
                      let now = update.segments.first(where: { $0.id == id }),
                      round.firstSegmentTrace.last?.text != now.text {
                round.firstSegmentTrace.append((Double(fed) / WhisperWindowPipeline.sampleRate, now.text))
            }
        }

        // 收尾：把缓冲里最后那段补转 + 强制定稿（接线后的路径就是这么收的）
        let transcriptionsBeforeFinish = pipeline.transcriptionSeconds.count
        let charsBeforeFinish = pipeline.recognizedConfidences.count
        let final = try pipeline.finish(engine: engine)
        // 收尾窗也是一次 `merge()`：它进了 `transcriptionSeconds`，但没经过
        // `advance()`，不补进表里的话这张表就少一行、统计口径也和
        // `pipeline.statsLine` 对不上
        if pipeline.transcriptionSeconds.count > transcriptionsBeforeFinish {
            let elapsed = pipeline.transcriptionSeconds.last ?? 0
            let startMillis = pipeline.lastWindowStartMillis
            let startSamples = (startMillis ?? 0) * 16
            let endSamples = min(startSamples + windowFrames, samples.count)
            let windowAudioSeconds = Double(max(0, endSamples - startSamples))
                / WhisperWindowPipeline.sampleRate
            let windowEndMillis = (startMillis ?? 0) + Int(windowAudioSeconds * 1000)
            round.windows.append(WindowTrace(
                index: round.attempts + 1,
                startMillis: startMillis,
                elapsedSeconds: elapsed,
                audioSeconds: windowAudioSeconds,
                newSegments: 0,
                charsRecognized: pipeline.recognizedConfidences.count - charsBeforeFinish,
                rms: peakOrRMS(samples, startSamples, endSamples, rms: true),
                peak: peakOrRMS(samples, startSamples, endSamples, rms: false),
                voicedRatio: frames.voicedRatio(fromMillis: startMillis ?? 0, toMillis: windowEndMillis),
                footprintMB: footprintMB(),
                note: "（收尾窗：录音最后那一段补转）"
            ))
            round.maxFootprintMB = max(round.maxFootprintMB, round.windows[round.windows.count - 1].footprintMB)
        }
        round.transcriptSeconds = pipeline.transcriptionSeconds
        round.segments = final.segments
        round.finalized = final.segments.filter(\.isFinal).count
        round.guardTrips = pipeline.guardTrips
        round.confidences = pipeline.recognizedConfidences
        round.hallucinations = pipeline.hallucinationLog
        round.wallSeconds = secondsSince(runStarted)
        return round
    }

    // MARK: - 置信度探针（测量通道，不是生产路径）

    /// 绕开合并器，直接取窗、直接调 `engine.transcribe`，把每个识别段的
    /// **文本 + 逐字符置信度**一起打出来。
    ///
    /// 为什么非绕不可：合并器把 `WhisperSegment` 变成 `TranscriptSegment` 时
    /// 只留下算好的档位，`confidences` 丢了；而标定阈值要的正是「这段文本 ↔
    /// 它的连续置信度」这一对——没有文本就没法人工判「这段到底是不是崩坏」，
    /// 没有连续值就只能看二值的档位，标定无从谈起。
    ///
    /// 取窗参数与生产一致（同一个 `windowWithOrigin`、同样的窗口/步长），
    /// 所以这一趟得到的段就是生产路径会看到的那些段。
    /// 探针认得的一段。**逐字符值必须一起带着**——它是唯一能区分「段内有一批
    /// 蒙对的字」和「整段都平平」的东西，而阈值标定要的正是这个区分度。
    private struct ProbeSegment {
        let text: String
        let mean: Double
        let lowRatio: Double
        let startMillis: Int
        let chars: [Double]
        /// whisper 自己的「这段没语音」判断。和 `mean` 是两回事——
        /// 幻觉段的 `mean` 可以到 1.00 而它整段没语音
        let noSpeech: Double
        /// 这一段对应音频的 RMS，**由本进程自己从样本算**，不依赖 whisper。
        /// 判「不许误杀」要靠它：它是独立于被检验对象的第二个视角
        let level: Double
        /// 该段的静音门（同一窗内的相对基准，见 `speechFloor`）
        let floor: Double
    }

    /// 电平与静音门的实现共用 `WhisperHallucination` 那一份——**必须共用**：
    /// 生产链路和探针要是各算各的，探针量出来的误杀率就不能代表生产的行为了，
    /// 那样整个判据就作废。
    private static func speechFloor(samples: [Float]) -> Double {
        WhisperHallucination.speechFloor(samples: samples, sampleRate: WhisperWindowPipeline.sampleRate)
    }

    private static func level(of segment: WhisperSegment, in samples: [Float]) -> Double {
        WhisperHallucination.level(of: segment, in: samples, sampleRate: WhisperWindowPipeline.sampleRate)
    }

    private static func confidenceProbe(
        samples: [Float],
        engine: WhisperEngine,
        options: Options
    ) throws -> [String] {
        var lines: [String] = []
        lines.append(String(
            format: "─── 置信度探针（测量通道：绕开合并器直接调引擎；窗口 %.0f 秒 / 步长 %.0f 秒%s）───",
            WhisperWindowPipeline.windowSeconds, options.probeStepSeconds,
            options.probeStepSeconds == WhisperWindowPipeline.windowSeconds ? " · 互不重叠" : " · 有重叠，同句会被重复计入"
        ))

        let buffer = WhisperWindowBuffer(capacitySeconds: 15)
        let chunk = max(1, Int(chunkSeconds * WhisperWindowPipeline.sampleRate))
        let stepMillis = Int(options.probeStepSeconds * 1000)
        var fed = 0
        var nextWindowAt = stepMillis
        var windows: [(
            index: Int, startMillis: Int, segments: [WhisperSegment],
            floor: Double, levels: [Double]
        )] = []
        /// 每一窗的转写耗时。`suppress_regex` 开着时用来量它的代价
        var probeWindowSeconds: [Double] = []

        if let pattern = options.suppressRegex {
            lines.append("  ⚠️ suppress_regex 已启用：\(pattern)")
            lines.append("     上游语义是**整 token 精确匹配**（非子串），且每生成一个 token 都会")
            lines.append("     遍历整个词表并重新构造一次 std::regex（whisper.cpp v1.9.4 :6373）。")
            lines.append("     所以下面这一趟的耗时要和不开时对比着看——见末尾的单窗耗时对比。")
        }


        while fed < samples.count {
            let end = min(fed + chunk, samples.count)
            buffer.append(Array(samples[fed..<end]))
            fed = end

            let fedMillis = Int(Double(fed) / WhisperWindowPipeline.sampleRate * 1000)
            guard fedMillis >= nextWindowAt else { continue }
            nextWindowAt += stepMillis

            guard let window = buffer.windowWithOrigin(
                durationSeconds: WhisperWindowPipeline.windowSeconds,
                sampleRate: WhisperWindowPipeline.sampleRate
            ) else { continue }
            // 单独计时：`suppress_regex` 的代价必须能和「不开」直接比，
            // 混进整趟耗时里就分不出来了
            let windowStarted = ContinuousClock.now
            let recognized = try engine.transcribe(window.samples, suppressRegex: options.suppressRegex)
            let windowElapsed = ContinuousClock.now - windowStarted
            probeWindowSeconds.append(Double(windowElapsed.components.seconds)
                + Double(windowElapsed.components.attoseconds) / 1e18)
            guard !recognized.isEmpty else { continue }
            // 电平必须在这里算：`window.samples` 是这几秒的音频，出了这个循环
            // 就被下一窗覆盖了。为此不缓存整段音频——一条 45 分钟的录音
            // 逐窗存样本要 170MB 量级，而电平一个 Double 就够
            windows.append((
                windows.count + 1, window.startMillis, recognized,
                speechFloor(samples: window.samples),
                recognized.map { level(of: $0, in: window.samples) }
            ))
        }

        // 逐段打：文本在前，统计量在后，方便直接肉眼判「这段是不是崩坏」
        var all: [ProbeSegment] = []
        for window in windows {
            lines.append(String(format: "  窗 %d · 起点 %.1f 秒 · %d 段 · 静音门 %.5f",
                                window.index, Double(window.startMillis) / 1000,
                                window.segments.count, window.floor))
            for (offset, segment) in window.segments.enumerated() {
                let mean = segment.averageConfidence ?? 0
                let lowRatio = segment.confidences.isEmpty ? 0
                    : Double(segment.confidences.filter { $0 < TranscriptQualityAssessor.lowConfidenceThreshold }.count)
                        / Double(segment.confidences.count)
                let grade = segment.grade?.label ?? "—"
                let segLevel = offset < window.levels.count ? window.levels[offset] : 0
                // 无语音这一列**用 6 位小数**：实测它全是 0.0000，但 0.0000 在 4 位
                // 精度下既可能是「真是 0」也可能是「1/51864≈0.0000193」——这两种
                // 情况的结论完全相反（前者说明这条臂在本项目里是死的），
                // 4 位小数分不开它们。别把它调回 %.2f
                lines.append(String(
                    format: "    [%5.3f / 低%3.0f%% / %@ / 无语音%.6f / 电平%.5f%@] %@",
                    mean, lowRatio * 100, grade, segment.noSpeechProbability, segLevel,
                    segLevel < window.floor ? " 空" : "", segment.text
                ))
                all.append(ProbeSegment(
                    text: segment.text, mean: mean, lowRatio: lowRatio,
                    startMillis: window.startMillis, chars: segment.confidences,
                    noSpeech: segment.noSpeechProbability, level: segLevel, floor: window.floor
                ))
            }
        }

        lines.append("")
        lines.append("  共 \(windows.count) 窗 · \(all.count) 段（生产路径会把重叠窗的同一句合并掉，所以这个数大于最终段数）")
        if !probeWindowSeconds.isEmpty {
            let sorted = probeWindowSeconds.sorted()
            let total = probeWindowSeconds.reduce(0, +)
            lines.append(String(
                format: "  单窗转写耗时：中位 %.3f 秒 / 均 %.3f 秒 / 最大 %.3f 秒 / 合计 %.1f 秒%@",
                sorted[sorted.count / 2], total / Double(sorted.count), sorted.last ?? 0, total,
                options.suppressRegex == nil ? "" : " ← suppress_regex 已启用，基线见不带该参数的同一命令"
            ))
        }
        if !all.isEmpty {
            lines.append(contentsOf: confidenceDistribution("逐段平均置信度", all.map(\.mean)))
            lines.append(contentsOf: confidenceDistribution("逐段低置信占比", all.map(\.lowRatio)))
            // 逐字符分布是**另一个量纲**上的东西：段均值把每段压成一个数，
            // 段内「一批高分字符 + 几个蒙的」和「整段都在 0.6 附近」压出来一样，
            // 但判据只看均值就分不开这两者。标定要看的就是这个差别。
            lines.append(contentsOf: confidenceDistribution("逐字符置信度", all.flatMap(\.chars)))
            var good = 0, fair = 0, poor = 0
            for segment in all {
                switch TranscriptQualityAssessor.grade(
                    averageConfidence: segment.mean, lowConfidenceRatio: segment.lowRatio
                ) {
                case .good: good += 1
                case .fair: fair += 1
                case .poor: poor += 1
                }
            }
            lines.append(String(
                format: "  现行判据（Apple 标定：0.70 / 0.85 / 0.30）下的分档：可信 %d（%.0f%%）/ 存疑 %d（%.0f%%）/ 不可信 %d（%.0f%%）",
                good, Double(good) / Double(all.count) * 100,
                fair, Double(fair) / Double(all.count) * 100,
                poor, Double(poor) / Double(all.count) * 100
            ))
        }

        if options.sweep, !all.isEmpty {
            lines.append("")
            lines.append(contentsOf: sweep(all))
        }

        if !all.isEmpty {
            lines.append("")
            lines.append(contentsOf: hallucinationSection(all))
        }

        // 机器可读的一份。人工判读看上面的表就够了，但**阈值标定要做自助法
        // 置信区间**，那需要每段的原始逐字符值，从格式化过的表里反解既脆又
        // 容易和「美观」的格式串纠缠。所以另出一份 TSV，单独一行一段。
        if !all.isEmpty {
            lines.append("")
            lines.append("─── TSV（起点毫秒 / 段均值 / 低置信占比 / 逐字符置信度 / 文本 / 无语音概率 / 电平 / 静音门；制表符分隔）───")
            for segment in all {
                let chars = segment.chars.map { String(format: "%.4f", $0) }.joined(separator: ",")
                // 后三列是**追加**的，前五列的位置和含义没动——已有的解析脚本
                // （`tools/probes/p2_analyze.py` 取前五列）不用改就能继续跑
                //
                // ⚠️ 这个列定义在 `HallucinationReplay.parse` 里有个副本，
                // 加列/改序要两处一起改（那边靠上下两条哨兵行定位，不猜格式）
                lines.append("\(segment.startMillis)\t\(String(format: "%.4f", segment.mean))\t"
                             + "\(String(format: "%.4f", segment.lowRatio))\t\(chars)\t\(segment.text)"
                             + "\t\(String(format: "%.6f", segment.noSpeech))"
                             + "\t\(String(format: "%.5f", segment.level))"
                             + "\t\(String(format: "%.5f", segment.floor))")
            }
            lines.append("─── TSV 结束 ───")
        }
        return lines
    }

    /// 幻觉治理的**改动前后对照**。
    ///
    /// 为什么在探针里做而不是另写一个工具：探针这一趟手里同时有
    /// 「引擎原始输出」和「每段的音频电平」，于是**一趟跑出两条臂**——
    /// 原始段数就是改动前，套上 `WhisperHallucination` 之后就是改动后。
    /// 两次跑同一条录音反而有风险：whisper 的解码在浮点上不是逐位确定的。
    ///
    /// **「不许误杀」的对照基准**：音频电平 ≥ 本窗静音门的段 = 「这一段确实
    /// 有人在出声」。它是独立于 whisper 的第二个视角（whisper 是**被检验对象**，
    /// 不能拿它自己的判断当基准），所以「被丢掉的段里有几个是这种」直接就是
    /// 误杀的**上界**。
    ///
    /// 为什么只是上界、不是精确值：电平高不等于语音（音乐、音效、掌声也高）。
    /// 所以这里把丢掉的响段**原文打出来**让人判——数字给上界，判读交给人。
    /// 反过来「光看数字就说误杀率 = 0」是自欺：漏掉的误杀定义上就看不见。
    private static func hallucinationSection(_ all: [ProbeSegment]) -> [String] {
        var lines = ["─── 幻觉治理（改动前 = 引擎原始输出；改动后 = WhisperHallucination 过滤）───"]

        var templateHits = 0
        var annotationHits = 0
        var droppedLoud = 0
        var dropped: [(ProbeSegment, WhisperHallucination.Verdict)] = []

        for segment in all {
            let verdict = WhisperHallucination.verdict(
                text: segment.text,
                noSpeechProbability: segment.noSpeech,
                audioLevel: segment.level,
                silenceFloor: segment.floor
            )
            switch verdict {
            case .keep: continue
            case .dropSubtitleTemplate: templateHits += 1
            case .dropNonSpeechAnnotation: annotationHits += 1
            }
            dropped.append((segment, verdict))
            // 「响段被丢」= 误杀上界。电平低于门的段被丢是预期行为
            if segment.level >= segment.floor { droppedLoud += 1 }
        }

        let kept = all.count - dropped.count
        let loudTotal = all.filter { $0.level >= $0.floor }.count
        lines.append(String(
            format: "  改动前 %d 段 → 改动后 %d 段（丢 %d：模板 %d / 非语音注释 %d）",
            all.count, kept, dropped.count, templateHits, annotationHits
        ))
        lines.append(String(
            format: "  其中「有语音电平」的段：改动前 %d → 改动后 %d（被丢的响段 = 误杀上界 %d）",
            loudTotal, loudTotal - droppedLoud, droppedLoud
        ))
        lines.append("  机器可读：HALLU_SUMMARY\t\(all.count)\t\(kept)\t\(dropped.count)\t\(templateHits)\t\(annotationHits)\t\(loudTotal)\t\(loudTotal - droppedLoud)")

        // 重叠窗会把同一处幻觉重复计入（滑窗每 3 秒重转一次 10 秒音频），
        // 所以上面的计数是「窗·段」次数，不是「几处幻觉」。为了不把数字吹大，
        // 另给一个按文本去重的数——**两个数都要报，只说小的那个是藏**。
        let distinctDropped = Set(dropped.map { WhisperHallucination.normalize($0.0.text) }).count
        lines.append("  ⚠️ 上面是「窗·段」次数：重叠窗会把同一处幻觉重复计入。按文本去重后是 \(distinctDropped) 处")

        if dropped.isEmpty {
            lines.append("  （本录音没有命中任何一条）")
        } else {
            lines.append("  丢掉的全部内容（逐条看，响段要人工确认到底该不该丢）：")
            for (segment, verdict) in dropped {
                let kind = switch verdict {
                case .dropSubtitleTemplate(let marker): "模板:\(marker)"
                case .dropNonSpeechAnnotation: "注释"
                case .keep: "?"
                }
                lines.append(String(
                    format: "    [%@ / 无语音%.6f / 电平%.5f vs 门%.5f%@] %@",
                    kind, segment.noSpeech, segment.level, segment.floor,
                    segment.level >= segment.floor ? " ⚠响段" : "", segment.text
                ))
            }
        }
        lines.append("  注：`suppress_regex` 那条臂不在这一趟里——它作用在解码期，要单独跑（见 --suppress-regex）")
        return lines
    }

    /// 阈值扫描。**这不是生产判据**，是给标定用的对照表：判据的**形状**
    /// 与 `TranscriptQualityAssessor.grade(averageConfidence:lowConfidenceRatio:)`
    /// 完全一致（先判 poor、再判 good、其余 fair），只把三个常数换成候选值——
    /// 生产那份常数是 `static let`，不换成参数就没法扫。
    ///
    /// 行末的「崩坏召回」要靠人工标注：把探针输出里肉眼判为崩坏的段挑出来，
    /// 数一数每条候选线判出了几段。没有标注的话，光看比例是自欺——
    /// 把所有段都判「不可信」的那条线，比例最难看但召回最高。
    private static func sweep(_ segments: [ProbeSegment]) -> [String] {
        var lines = ["─── 阈值扫描（判据形状与生产一致，只换三个常数）───"]
        lines.append("  poor 上限 / good 下限 / 低置信占比上限      可信    存疑   不可信")
        let poorCeilings = [0.70, 0.65, 0.60, 0.55, 0.50]
        let goodFloors = [0.85, 0.80, 0.75, 0.70]
        let lowRatios = [0.30, 0.40, 0.50, 0.60]
        for poorCeiling in poorCeilings {
            for goodFloor in goodFloors where goodFloor > poorCeiling {
                for lowRatioFloor in lowRatios {
                    var good = 0, fair = 0, poor = 0
                    for segment in segments {
                        let isPoor = segment.mean < poorCeiling || segment.lowRatio > lowRatioFloor
                        let isGood = segment.mean >= goodFloor && segment.lowRatio <= 0.15
                        if isPoor { poor += 1 } else if isGood { good += 1 } else { fair += 1 }
                    }
                    let total = Double(segments.count)
                    lines.append(String(
                        format: "  %.2f / %.2f / %.2f                      %5.0f%%  %5.0f%%  %5.0f%%",
                        poorCeiling, goodFloor, lowRatioFloor,
                        Double(good) / total * 100, Double(fair) / total * 100, Double(poor) / total * 100
                    ))
                }
            }
        }
        return lines
    }

    /// `rms ? 均方根 : 峰值`。二选一写在一个函数里是为了让两列的取值区间
    /// 严格一致——分开写的话很容易出现「取 RMS 用了这个范围、取峰值用了那个」
    private static func peakOrRMS(_ samples: [Float], _ from: Int, _ to: Int, rms: Bool) -> Double {
        guard from < to, to <= samples.count else { return 0 }
        var peak = 0.0
        var sum = 0.0
        for i in from..<to {
            let v = Double(samples[i])
            sum += v * v
            peak = max(peak, abs(v))
        }
        return rms ? (sum / Double(to - from)).squareRoot() : peak
    }

    // MARK: - 输出

    private static func statsLine(_ round: Round) -> String {
        guard !round.transcriptSeconds.isEmpty else { return "Whisper 滑窗：还没转过一窗" }
        let sorted = round.transcriptSeconds.sorted()
        let mean = round.transcriptSeconds.reduce(0, +) / Double(round.transcriptSeconds.count)
        return String(
            format: "Whisper 滑窗 %d 窗 · 单次转写 均 %.2f / 中位 %.2f / 最大 %.2f 秒 · 步长 %.1f 秒 → 占用 %.0f%% · 守卫触发 %d 次 · 空转 %d 轮",
            round.transcriptSeconds.count, mean, sorted[sorted.count / 2], sorted.last ?? 0,
            WhisperWindowPipeline.stepSeconds, mean / WhisperWindowPipeline.stepSeconds * 100,
            round.guardTrips, round.windows.filter { $0.startMillis == nil }.count
        )
    }

    private static func repeatSummary(_ round: Round) -> String {
        let real = round.realWindows
        guard let slowest = real.max(by: { $0.elapsedSeconds < $1.elapsedSeconds }) else {
            return "\(round.label)：没有取到窗"
        }
        let mean = real.reduce(0.0) { $0 + $1.elapsedSeconds } / Double(real.count)
        return String(
            format: "%@：%d 窗 · 均 %.2f / 最慢 %.2f 秒在第 %d 窗（起点 %.1f 秒，窗内 %.1f 秒音频）· 进程峰值 %.0f MB",
            round.label, real.count, mean, slowest.elapsedSeconds, slowest.index,
            Double(slowest.startMillis ?? 0) / 1000, slowest.audioSeconds, round.maxFootprintMB
        )
    }

    private static func timingTable(_ round: Round) -> [String] {
        var lines: [String] = ["─── 逐窗耗时表（窗序号 / 起点 / 耗时 / 该窗音频 / 该窗音频特征）───"]
        lines.append("    #   起点s   音频s   耗时s  新增段  认字数    RMS     峰值  有声帧%   进程MB")
        for trace in round.windows {
            let start = trace.startMillis.map { String(format: "%7.1f", Double($0) / 1000) } ?? "   ——  "
            let tail = trace.startMillis == nil
                ? "  （未取窗：缓冲不够一窗，或起点没往前走）"
                : (trace.note.isEmpty ? "" : "  \(trace.note)")
            lines.append(String(
                format: "  %4d %@ %6.1f  %6.2f  %5d  %5d  %7.4f  %6.3f  %5.0f%%  %7.0f%@",
                trace.index, start, trace.audioSeconds, trace.elapsedSeconds, trace.newSegments,
                trace.charsRecognized, trace.rms, trace.peak, trace.voicedRatio * 100,
                trace.footprintMB, tail
            ))
        }

        let real = round.realWindows
        guard !real.isEmpty else { return lines }
        let ranked = real.sorted { $0.elapsedSeconds > $1.elapsedSeconds }
        lines.append("")
        lines.append("  最慢的三窗：")
        for trace in ranked.prefix(3) {
            lines.append(String(
                format: "    第 %d 窗 · 耗时 %.2f 秒 · 起点 %.1f 秒 · 窗内音频 %.1f 秒 · 认出 %d 字 · 新增 %d 段 · RMS %.4f / 峰值 %.3f / 有声帧 %.0f%% / 进程 %.0f MB",
                trace.index, trace.elapsedSeconds, Double(trace.startMillis ?? 0) / 1000,
                trace.audioSeconds, trace.charsRecognized, trace.newSegments,
                trace.rms, trace.peak, trace.voicedRatio * 100, trace.footprintMB
            ))
        }
        let firstWindow = real.first
        lines.append(String(
            format: "  第 1 个取到的窗：第 %d 窗（起点 %.1f 秒）耗时 %.2f 秒",
            firstWindow?.index ?? 0, Double(firstWindow?.startMillis ?? 0) / 1000,
            firstWindow?.elapsedSeconds ?? 0
        ))
        return lines
    }

    /// 把最慢的几窗**重新**直接转一遍，打印这一窗自己的原始识别输出。
    ///
    /// 为什么必须重转、不能从 `round` 里拿：`advance()` 把原始结果交给合并器
    /// 之后就不再保留，最终段列表是合并、去重、改写之后的产物——从它反推
    /// 「某一窗当时认出了什么」在原理上就做不到（同一句被三窗认过）。
    ///
    /// 顺带量「重转耗时」：第一次慢、第二次快 = 状态问题（缓存/调度）；
    /// 两次都慢 = 内容问题。这与「同进程连跑两遍」是两回事——那两遍是整条
    /// 录音，这一条是同一个 10 秒片段原地重放。
    private static func slowWindowDump(
        samples: [Float], engine: WhisperEngine, round: Round, count: Int
    ) throws -> [String] {
        let windowFrames = Int(WhisperWindowPipeline.windowSeconds * WhisperWindowPipeline.sampleRate)
        let ranked = round.realWindows.sorted { $0.elapsedSeconds > $1.elapsedSeconds }.prefix(count)
        var lines = ["─── 最慢的 \(ranked.count) 窗：原地重转，看这一窗自己的原始输出 ───"]
        for trace in ranked {
            let startSamples = (trace.startMillis ?? 0) * 16
            let endSamples = min(startSamples + windowFrames, samples.count)
            guard endSamples > startSamples else { continue }
            let started = ContinuousClock.now
            let recognized = try engine.transcribe(Array(samples[startSamples..<endSamples]))
            let elapsed = secondsSince(started)
            let chars = recognized.reduce(0) { $0 + $1.confidences.count }
            lines.append(String(
                format: "  第 %d 窗 · 起点 %.1f 秒 · 首次耗时 %.2f 秒 → 重转 %.2f 秒 · 认出 %d 段 / %d 字",
                trace.index, Double(trace.startMillis ?? 0) / 1000,
                trace.elapsedSeconds, elapsed, recognized.count, chars
            ))
            if recognized.isEmpty { lines.append("      （这一窗什么都没认出来）") }
            for segment in recognized {
                lines.append(String(format: "      [%5.3f] %@",
                                    segment.averageConfidence ?? 0, segment.text))
            }
        }
        return lines
    }

    /// 慢窗成因的**因果**实验：同一段音频，只把 `temperature_inc` 关掉再解一遍。
    ///
    /// 为什么需要它：耗时表能证明「慢窗稳定复现、内存不涨」，证明不了**为什么**。
    /// whisper.cpp 在 GREEDY 下有一条重试链——解码结果没过 `entropy_thold` /
    /// `logprob_thold` 就把整段音频按 `temperature + temperature_inc` 重解一次，
    /// 每次重试都是一趟完整的解码。这条链正好能解释观测到的三件事：
    /// 与内容相关、与窗口边界相关（换个对齐就换了触发点）、幅度不稳（重试次数
    /// 受随机性影响）。把 `temperature_inc` 压成 0，重试链就断了——如果停顿随之
    /// 消失，因果就成立；如果照旧，这条假设就被否掉。
    ///
    /// 代价是**再开一个 context**（模型 539MB 会被再加载一次）。所以它只在
    /// 显式传 `--fallback-probe` 时才做，且 context 是局部变量、函数返回即释放
    /// （活到进程退出会被 ggml 的 Metal 后端在静态析构里 abort，见
    /// `--whisper-prewarm` 踩过的那次 exit=134）。
    private static func fallbackProbe(
        samples: [Float], round: Round, count: Int
    ) throws -> [String] {
        var lines: [String] = ["─── 慢窗成因探针：只把 temperature fallback 关掉，其余不动 ───"]
        let defaults = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        lines.append(String(
            format: "  whisper 出厂默认：temperature %.2f + inc %.2f（失败就重解）· entropy_thold %.2f · logprob_thold %.2f · no_speech_thold %.2f",
            defaults.temperature, defaults.temperature_inc,
            defaults.entropy_thold, defaults.logprob_thold, defaults.no_speech_thold
        ))
        lines.append(String(
            format: "  no_context %@ · n_max_text_ctx %d · max_tokens %d（0 = 不限）",
            defaults.no_context ? "true" : "false", defaults.n_max_text_ctx, defaults.max_tokens
        ))
        // 上面那行打的是 **whisper 的出厂默认**，不是下面每个档位实际用的参数——
        // 每个档位都把值写死在自己的 `SliceVariant` 里（见下面 variants 的注释）。
        // 这里曾经写成「引擎实际用的解码参数」，而在产品默认被改成 −10 之后，
        // 它一边打 −1.00、一边跑 −10，三档输出完全相同却没人看得出来。
        lines.append("  ⚠️ 每个档位的参数写死在各自的 variant 里，不要读上面那行的默认值当本档参数")

        ggml_backend_load_all()
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        guard let context = whisper_init_from_file_with_params(
            WhisperEngine.resolvedModelURL.path, contextParams
        ) else {
            return lines + ["  ❌ 另开 context 失败（模型路径 \(WhisperEngine.resolvedModelURL.path)）"]
        }
        defer { whisper_free(context) }

        let windowFrames = Int(WhisperWindowPipeline.windowSeconds * WhisperWindowPipeline.sampleRate)
        let ranked = round.realWindows.sorted { $0.elapsedSeconds > $1.elapsedSeconds }.prefix(count)
        for trace in ranked {
            let startSamples = (trace.startMillis ?? 0) * 16
            let endSamples = min(startSamples + windowFrames, samples.count)
            guard endSamples > startSamples else { continue }
            let slice = Array(samples[startSamples..<endSamples])
            lines.append("")
            lines.append(String(format: "  第 %d 窗 · 起点 %.1f 秒 · 窗内 %.1f 秒音频 · 管线里首发耗时 %.2f 秒",
                                trace.index, Double(trace.startMillis ?? 0) / 1000,
                                Double(endSamples - startSamples) / WhisperWindowPipeline.sampleRate,
                                trace.elapsedSeconds))
            // 每个档位都把**两个参数都写死**，一律不用 nil（=「跟随产品默认」）。
            // 这条不是洁癖：产品默认一动，传 nil 的档位就悄悄变成了别的档位。
            // 上一版这里「旧版」传的是 nil，默认被改成 −10 之后它实际跑的是候选B
            // ——四个档位两个两个相同，而标签还在说「logprob −1.0」。
            // 对照实验里「跟随默认」这种写法会让历史数字无法复现，所以钉死。
            let variants: [SliceVariant] = [
                .init(label: "旧版（whisper 出厂：inc 0.2 / logprob −1.0，最多 6 趟）",
                      temperatureInc: 0.2, logprobThold: -1.0),
                .init(label: "候选 A：inc 0 / logprob −1.0（整条链关掉）",
                      temperatureInc: 0, logprobThold: -1.0),
                .init(label: "候选 B：inc 0.2 / logprob −10（只关误判闸，熵闸保留）",
                      temperatureInc: 0.2, logprobThold: -10),
                .init(label: "候选 C：inc 0.35 / logprob −1.0（闸开着，链截到 3 趟）",
                      temperatureInc: 0.35, logprobThold: -1.0),
            ]
            for variant in variants {
                let result = runSlice(context: context, samples: slice, variant: variant)
                lines.append(String(
                    format: "    %@：耗时 %.2f 秒 · %d 段 / %d 字 · 正文 %@",
                    variant.label, result.seconds, result.segments, result.chars,
                    result.text.count <= 80 ? result.text : String(result.text.prefix(80)) + "…"
                ))
                // whisper 自己的计时与重试计数。它打在 stderr，驱动脚本里 2>&1
                // 抓得到——`fallbacks = N p / M h` 就是被截断/被熵判据打回的次数
                lines.append("      ↓ whisper 自己的计时（stderr）")
                whisper_print_timings(context)
            }
        }
        return lines
    }

    /// 一小段音频的一次完整解码。参数与 `WhisperEngine.transcribe` 对齐——
    /// 对齐是**必须的**，否则对照实验比的是「参数不同」而不是「重试链开关」。
    /// 一个解码档位。`nil` = 不覆盖，用 whisper 自己的默认值
    struct SliceVariant {
        let label: String
        let temperatureInc: Float?
        let logprobThold: Float?
    }

    private static func runSlice(
        context: OpaquePointer, samples: [Float], variant: SliceVariant
    ) -> (seconds: Double, text: String, chars: Int, segments: Int) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let language = strdup("zh")
        defer { free(language) }
        params.language = UnsafePointer(language)
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = false
        params.max_len = 60
        if let temperatureInc = variant.temperatureInc { params.temperature_inc = temperatureInc }
        if let logprobThold = variant.logprobThold { params.logprob_thold = logprobThold }

        var mutable = samples
        let started = ContinuousClock.now
        let code = mutable.withUnsafeMutableBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        let elapsed = secondsSince(started)
        guard code == 0 else { return (elapsed, "❌ whisper_full 错误码 \(code)", 0, 0) }

        var text = ""
        let count = whisper_full_n_segments(context)
        for index in 0..<count {
            guard let raw = whisper_full_get_segment_text(context, index) else { continue }
            text += String(cString: raw)
        }
        return (elapsed, text, text.count, Int(count))
    }

    private static func confidenceDistribution(_ title: String, _ values: [Double]) -> [String] {
        guard !values.isEmpty else { return [] }
        let sorted = values.sorted()
        func quantile(_ q: Double) -> Double {
            let position = q * Double(sorted.count - 1)
            let low = Int(position.rounded(.down))
            let high = Int(position.rounded(.up))
            guard low != high else { return sorted[low] }
            return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let low = Double(values.filter { $0 < 0.5 }.count) / Double(values.count)
        return [String(
            format: "  %@：n=%d 均 %.3f 中位 %.3f p10 %.3f p90 %.3f <0.5 占 %.1f%%",
            title, values.count, mean, quantile(0.5), quantile(0.1), quantile(0.9), low * 100
        )]
    }

    /// 首段轨迹。要的是「第一段是什么、后来有没有被覆盖或修正、首句何时出现」
    private static func firstSegmentSection(_ round: Round) -> [String] {
        var lines: [String] = ["─── 第一段轨迹 ───"]
        guard let id = round.firstSegmentId else { return lines + ["  整轮没有产出任何段"] }
        lines.append(String(
            format: "  首段出现时刻：喂入音频 %.1f 秒（第 %d 窗）",
            round.firstSegmentSeenAtSeconds ?? 0, round.firstSegmentSeenAtWindow ?? 0
        ))
        for step in round.firstSegmentTrace {
            lines.append(String(format: "    %6.1f 秒：%@", step.afterFeedSeconds, step.text))
        }
        let stillThere = round.segments.contains { $0.id == id }
        let final = round.segments.first { $0.id == id }
        let rewrites = round.revisionCounts[id] ?? 0
        lines.append("  首段是否还在最终输出里：\(stillThere ? "在" : "不在（被换成了别的 id）")")
        lines.append("  首段被改写的次数：\(rewrites)（最终文本「\(final?.text ?? "—")」）")
        if let final {
            lines.append(String(
                format: "  首段最终时间范围：%.1f – %.1f 秒",
                Double(final.startTimeMillis) / 1000, Double(final.endTimeMillis) / 1000
            ))
        }
        let rewritten = round.revisionCounts.filter { $0.value > 0 }.count
        lines.append("  整轮被改写过文本的段：\(rewritten) / \(round.segments.count)")
        return lines
    }

    /// 近似重复段。**只统计，不改合并器**——这一包要的是数字
    private static func duplicateSection(ordered: [TranscriptSegment], round: Round) -> [String] {
        var lines: [String] = ["─── 近似重复段 ───"]
        lines.append("  合并器输出 \(ordered.count) 段；界面去重层（adoptWhisperSegments）对它只排序、不按文本删段，")
        lines.append("  所以「去重层的输入」和「输出」段数相同——用户能看到的重复就是合并器留下的重复")
        guard ordered.count > 1 else { return lines + ["  段数不足，跳过"] }

        // 相邻对的关系。判据用引擎自带的 textRelation（--dedup-file 那条扫描
        // 用的同一个），不自己另写一套——两套判据给出的数字没法互相对照
        var samePairs: [(Int, TranscriptSegment, TranscriptSegment)] = []
        for index in 0..<(ordered.count - 1) {
            let a = ordered[index], b = ordered[index + 1]
            switch TranscriptionEngine.textRelation(a.text, b.text) {
            case .same, .similar: samePairs.append((index, a, b))
            case .different: break
            }
        }

        // 「同一句被拆成两段」：相邻两段拼起来能还原出**另一条更长的段**，
        // 而这两半单独都还原不出它。三个条件缺一不可——少一个这个数就是假的：
        // · 拼起来要能对上（不然只是正常的前后句）
        // · 对上的那条要比两半都长（否则命中的其实是「别处的重复段」——列表里
        //   同一句话存在好几版是常态，只看包含关系的话这一列会灌满假阳性）
        // · 两半单独都对不上它（否则「拆成两段」退化成「A 本身就是那句话」）
        //
        // 残留的局限（写出来免得下一包把它当准数）：判据要求**那句完整的话
        // 也在输出里**。如果一句被拆成两段、而完整版本一个窗口都没留下，
        // 这里就数不到——那种情况要看引擎每窗的原始输出，见 --confidence-probe
        var splitPairs: [(Int, TranscriptSegment, TranscriptSegment)] = []
        for index in 0..<(ordered.count - 1) {
            let a = ordered[index], b = ordered[index + 1]
            let halvesMax = max(
                TranscriptionEngine.normalizedForMatch(a.text).count,
                TranscriptionEngine.normalizedForMatch(b.text).count
            )
            for other in ordered where other.id != a.id && other.id != b.id {
                guard TranscriptionEngine.normalizedForMatch(other.text).count > halvesMax + 1,
                      case .different = TranscriptionEngine.textRelation(a.text, other.text),
                      case .different = TranscriptionEngine.textRelation(b.text, other.text),
                      case .same = TranscriptionEngine.textRelation(a.text + b.text, other.text)
                else { continue }
                splitPairs.append((index, a, b))
                break
            }
        }

        lines.append("  · 同句多版本相邻：\(samePairs.count) 处")
        for (index, a, b) in samePairs.prefix(8) {
            lines.append("      #\(index + 1) [\(a.formattedTimestamp)] \(preview(a.text))")
            lines.append("      #\(index + 2) [\(b.formattedTimestamp)] \(preview(b.text))")
        }
        if samePairs.count > 8 { lines.append("      …另有 \(samePairs.count - 8) 处") }
        lines.append("  · 同一句被拆成两段：\(splitPairs.count) 处")
        for (index, a, b) in splitPairs.prefix(8) {
            lines.append("      #\(index + 1)/#\(index + 2) [\(a.formattedTimestamp)] \(preview(a.text + " ｜ " + b.text))")
        }
        if splitPairs.count > 8 { lines.append("      …另有 \(splitPairs.count - 8) 处") }
        let rewritten = round.revisionCounts.filter { $0.value > 0 }
        lines.append("  · 同 id 被改写（合并器内部覆盖）：\(rewritten.count) 段，共 \(rewritten.values.reduce(0, +)) 次")
        // 两类会落在同一对相邻段上（既像同句多版本、又像被拆开），所以报并集，
        // 不能把两个数相加——相加会把同一处重复数两遍
        let sameIndexes = Set(samePairs.map(\.0))
        let splitIndexes = Set(splitPairs.map(\.0))
        let both = sameIndexes.intersection(splitIndexes).count
        lines.append("  · 去重层之后**用户可见**的重复：\(sameIndexes.union(splitIndexes).count) 处"
            + "（同句多版本 \(samePairs.count) + 拆成两段 \(splitPairs.count)，其中 \(both) 处两类同时命中，不能相加）")
        return lines
    }

    private static func preview(_ text: String) -> String {
        text.count <= 48 ? text : String(text.prefix(48)) + "…"
    }

    // MARK: - 小工具

    private static func secondsSince(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// 本进程的物理占用（phys_footprint，MB）。
    ///
    /// 用这个而不是 resident_size：`phys_footprint` 才是「内存压力」看的那一项，
    /// 而且它把 Metal 那边的常驻映射也算进去——离群窗若是内存压力所致，
    /// 波形会出现在这一列上，而不是等着人去猜
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
