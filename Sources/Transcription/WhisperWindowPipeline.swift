import Foundation

/// 滑窗准实时转写的一轮推进：**取窗 → 转写 → 合并**。
///
/// 抽成独立类型，是为了让**实时链路和离线对照跑的是同一段代码**。离线对照
/// 如果自己再写一遍「取窗 + 合并」，验的就是那份复制品，而这一包要回答的
/// 恰恰是「接线后的那条路径好不好」——复制品好不能说明路径好。
///
/// **线程模型**（`@unchecked Sendable` 的依据）：`advance` / `finish` 是
/// 同步阻塞的（`whisper_full` 一次两秒左右），只允许在 `WhisperRuntime` 的
/// 专属推理队列上调用；`append` 由采集线程调用，它只碰 `buffer`，而
/// `buffer` 自己带锁。`segments` / `tail` 这些合并状态只在那条队列上读写，
/// 所以这里的 `@unchecked` 不是「大概没事」，是「只有一个写者」。
final class WhisperWindowPipeline: @unchecked Sendable {

    /// 窗口时长与步长。**两个数只此一份**——窗口多长直接决定单次转写要多久，
    /// 也就直接决定占用率（见下面的实测数字），所以它俩必须住在一起，
    /// 改一个就要重新量一遍占用率。
    ///
    /// 10 秒窗口：探针基线用的就是它（10 秒窗单次 2.07–2.10 秒、中位 2.19，
    /// 且在 App 同时录音时量的）。**解码单元不变**是压重叠时的硬约束：
    /// 精度数字全部是在「一次喂 10 秒音频」上量的，把窗改短会让文本没法与
    /// 历史数字对账（见 P12-2 交付报告里两种压法的对照）。
    ///
    /// 步长 3 秒 = **重叠 7 秒**（70%）。同一句话平均被解 3.3 次，代价是
    /// 占用率 74%；收益是「合并器在重叠区做二次确认」（`WhisperWindowMerger`
    /// 策略第 4 条），以及**边界被覆盖多次**——某一窗空转时它的邻居还能
    /// 认出这段音频。
    ///
    /// **P12-2 试过把它压到 9.6 秒（重叠 0.4 秒），量完没上。** 在同一段
    /// 120 秒真实课堂录音上，9.6 秒步长让第 9 窗 [76.5,86.5) 一个字都没出，
    /// 而那一窗的语音帧占比是 0.598（该录音第三高），另外两条独立链路
    /// （3 秒步长的参照臂、把该段单独切出来跑的两窗链）都在那里认出了
    /// 真人说话。灵敏度表（步长 3.0/5.0/7.0/9.6）见 P12-2 交付报告。
    /// 所以这里留着 3 秒，**不是忘了压，是压了会丢内容**。
    ///
    /// `--step` 能把步长覆盖成别的值（探针复现老/demo 取窗用），
    /// 但生产恒走这个常量。
    static let windowSeconds = 10.0
    static let stepSeconds = 3.0
    static let stepMillis = 3_000
    static let sampleRate = 16_000.0

    /// 录音收尾那一窗至少要有的音频。低于这个长度不转：Whisper 喂几百毫秒
    /// 会编出幻觉文本，而「编一句」比「少一句」更坏——它看起来像真的
    static let minimumFlushSeconds = 1.0

    struct Update {
        let segments: [TranscriptSegment]
        let changes: [String]
        /// 这一轮是「判为静音、**跳过解码**」：`segments` 原样返回，没动过。
        /// 单独标出来是因为下游要能分辨「这一窗什么都没认出来」和「这一窗
        /// 根本没送进模型」——后者是省下来的时间，前者是模型空转
        var skippedSilence = false
    }

    /// 静音门控的开关（见 `SpeechGatePolicy`）。缺省从环境变量读（缺省开）
    let gatePolicy: SpeechGatePolicy

    /// 交给**合并器**的步长（`WhisperMergeInput.stepMillis`）。
    ///
    /// 生产上它恒等于 `Self.stepMillis`；只有「探针用 `--step` 复现老取窗」
    /// 那一趟会不一样。**必须跟着取窗步长一起走**：合并器拿这个数当
    /// 「下一窗的起点」——`coverageEndMillis = startMillis + stepMillis`、
    /// `pendingTail` 的过滤、`maxIntervalGapMillis` 全是它。取窗按 `--step 3.0`
    /// 推进而这里还填 9.6 秒（当时的生产值）的话，合并器会以为每窗前进
    /// 9.6 秒，于是提前定稿、提前丢掉 pending tail ——实测（P12-2 参照臂
    /// 第一次跑）段数 24 → 44、总字数 218 → 552，看上去像「多认出一倍的内容」，
    /// 其实是**参照臂根本没能复现改造前的合并**
    let mergeStepMillis: Int

    let buffer: WhisperWindowBuffer

    private var segments: [TranscriptSegment]
    /// 上一窗在重叠区产生的原始 segment（相对上一窗起点的时间）
    private var tail: [WhisperSegment] = []
    private var tailWindowStartMillis = 0
    /// 已经取过窗的最新起点。用来判「缓冲里有没有新音频」——
    /// 没有新音频时不重复转同一窗（重复转只会白白占掉一个步长的余量）
    private(set) var lastWindowStartMillis: Int?

    /// 本轮已定稿的段（收尾后就是全部）。界面要按这个数说「已定稿 N 段」
    private(set) var finalizedCount = 0
    private(set) var transcriptionSeconds: [Double] = []
    /// 合并器第三趟文本守卫的触发次数（文本归属在别处、不按时间改写）
    private(set) var guardTrips = 0
    /// 本段录音里所有被识别出来的**逐字符置信度**（原始分布）。
    ///
    /// 收它的理由：下一包要给 Whisper 段标定质量档位阈值，而 `TranscriptQualityAssessor`
    /// 现在的常数是从 Apple 的逐字符置信度上量出来的（准确段 0.96 / 崩坏段 0.58），
    /// 和 Whisper 的 token 概率不是一个量纲——不先把真实分布摆出来就没法标定。
    /// 在这里顺手收是因为**只有这里拿得到**：合并之后 `WhisperSegment` 就没了。
    /// 代价是几十 KB 内存，换来不用为标定再跑一遍真实录音。
    ///
    /// ⚠️ 含窗口重叠导致的**重复计入**：同一句话会被它所在的每一个窗口各记一遍，
    /// 重复次数 = 窗长 / 步长，**3 秒步长时是 3.3 倍**。P12-2 试过 9.6 秒步长
    /// （≈1.04 倍）但没上生产，所以别拿那一包的读数当基准比「置信度样本个数」。
    /// 它是分布参考，不是逐句的精确统计。
    private(set) var recognizedConfidences: [Double] = []

    /// 本次录音的 `initial_prompt`（P12-1）。
    ///
    /// **在 init 时定死、整场不变**：它描述的是「这门课的术语表」，
    /// 而术语表是开录前的先验（`GlossaryStore` 的注释：「术语表必须先于录音」）。
    /// 每窗现拼的话，用户录到一半改了词表，同一场课的前后两段就会用两套先验，
    /// 而转录文本上看不出这个分界。
    /// （`let` 但对外可读：A/B 要**从管线本身**回读实际用的那串，
    /// 而不是把入参回显一遍——见 `WhisperFileTranscription.Result.initialPrompt`）
    let initialPrompt: String?

    init(
        segments: [TranscriptSegment] = [],
        capacitySeconds: Double = 15,
        initialPrompt: String? = nil,
        gatePolicy: SpeechGatePolicy = .fromEnvironment(),
        mergeStepMillis: Int = WhisperWindowPipeline.stepMillis
    ) {
        self.segments = segments
        self.initialPrompt = initialPrompt
        self.gatePolicy = gatePolicy
        self.mergeStepMillis = mergeStepMillis
        self.buffer = WhisperWindowBuffer(capacitySeconds: capacitySeconds, sampleRate: Self.sampleRate)
    }

    /// 采集线程调用。样本必须是 16kHz 单声道 Float32。
    func append(_ samples: [Float]) {
        buffer.append(samples)
    }

    /// 取最近一窗转写并合并。
    ///
    /// 门控在**这里**、不在 `merge()` 里：这一层是「音频 → 模型」的门口，
    /// 判为静音的窗**根本不进 `merge`**，也就不会调 `engine.transcribe`
    /// ——「跳过解码」和「解完再丢」的区别就在这一行上。
    ///
    /// - Returns: `nil` = 缓冲还不够一窗，或者自上次取窗以来没有新音频。
    ///   被跳过的静音窗**不是 nil**：它是一次真的取窗（时间在往前走），
    ///   只是没送进模型
    func advance(engine: WhisperEngine) throws -> Update? {
        guard let window = peekWindow() else { return nil }
        guard window.startMillis != lastWindowStartMillis else { return nil }
        if let update = skipIfSilent(window) { return update }
        return try merge(windowSamples: window.samples, windowStartMillis: window.startMillis, engine: engine)
    }

    /// 取窗（**不解码、不判定、不动任何状态**）。
    ///
    /// `advance` / `finish` / 分布扫描（`--whisper-window-file … --gate-scan`，
    /// 见 `WhisperWindowFileRun.gateScan`）都从它拿窗，
    /// 所以三处看到的是同一批窗——扫描另写一遍取窗口径的话，扫出来的分布
    /// 就不描述生产实际取的窗（这个坑 `WhisperWindowBuffer.windowWithOrigin`
    /// 的注释里已经踩过一次）
    func peekWindow(minimumSeconds: Double = 0) -> (samples: [Float], startMillis: Int)? {
        guard let window = buffer.windowWithOrigin(
            durationSeconds: Self.windowSeconds,
            sampleRate: Self.sampleRate,
            minimumSeconds: minimumSeconds
        ) else { return nil }
        return (window.samples, window.startMillis)
    }

    // MARK: - 静音门控

    /// 这一层判定为静音就返回一个「没转写」的 Update，否则返回 nil（继续走解码）。
    ///
    /// 关掉开关时**一个字节的判定都不做**（连电平都不算）——「关掉后与改造前
    /// 一致」这句话才不是「大概一致」，而是同一段代码路径
    private func skipIfSilent(_ window: (samples: [Float], startMillis: Int)) -> Update? {
        windowsTaken += 1
        guard gatePolicy == .on else { return nil }
        let (verdict, reading) = SpeechGate.evaluate(samples: window.samples, sampleRate: Self.sampleRate)
        guard case .silence(let reason) = verdict else { return nil }

        windowsSkipped += 1
        skippedAudioSeconds += reading.windowSeconds
        lastWindowStartMillis = window.startMillis
        let line = String(
            format: "跳过静音窗 @%dms（%s）— %@",
            window.startMillis, reason, reading.summaryLine
        )
        if gateLog.count < Self.gateLogLimit { gateLog.append(line) }
        return Update(segments: segments, changes: [line], skippedSilence: true)
    }

    /// 这一趟取了多少窗、其中多少窗因为静音没进模型。**主判据就是这两个数**
    /// （跳过率），所以它们由管线自己记，不从日志文本里数
    private(set) var windowsTaken = 0
    private(set) var windowsSkipped = 0
    /// 被跳过的音频总秒数（按窗时长算，含重叠）
    private(set) var skippedAudioSeconds = 0.0
    /// 被跳过的那些窗，按时间顺序（给排障看「跳的是哪些窗、读数是多少」）。
    /// 只留前 `gateLogLimit` 条：一节课可能跳几百窗，全留着会撑内存，
    /// 而排障要看的是开头那几窗判得对不对
    private(set) var gateLog: [String] = []
    private static let gateLogLimit = 40

    /// 录音结束时的收尾：把缓冲里最后一段音频也转一遍，然后把所有还没定稿的
    /// 段强制定稿。
    ///
    /// **为什么必须补这一窗**：滑窗只在「攒够一个新步长」时才取窗，所以停机
    /// 时刻落在最后一个窗口之后的那段音频（最多一个步长）从来没被任何窗口
    /// 覆盖过——不补的话，一节课的最后三秒就是空的。
    ///
    /// **为什么必须强制定稿**：合并器的两条定稿判据都指望「后面还会有窗口」
    /// （见 `WhisperWindowMerger.merge` 策略第 4、5 条）。录音都停了，不会再有
    /// 窗口了，停在未定稿的段就永远拿不到质量档位、也不会送核查——下游全都
    /// 挂在定稿上。表现是「最后几分钟的段落永远显示成临时的」。
    func finish(engine: WhisperEngine) throws -> Update {
        var changes: [String] = []
        var skippedSilence = false
        if let window = peekWindow(minimumSeconds: Self.minimumFlushSeconds),
           window.startMillis != lastWindowStartMillis {
            // 收尾窗也过门控：整段录音最后那一窗常常正是「静下来之后没人说话」
            // （P12-2 实测：被判静音的那条录音，尾巴整段是静音），补转它
            // 就是给模型一次编句子的机会——而那正是这一包要挡的东西
            if let skipped = skipIfSilent(window) {
                changes += skipped.changes
                skippedSilence = true
            } else {
                let update = try merge(
                    windowSamples: window.samples,
                    windowStartMillis: window.startMillis,
                    engine: engine
                )
                changes += update.changes
            }
        }
        let final = finalizeWithoutTranscribing()
        return Update(
            segments: final.segments,
            changes: changes + final.changes,
            skippedSilence: skippedSilence
        )
    }

    /// 丢掉本窗的幻觉段。判据在 `WhisperHallucination`，这里只负责
    /// 「把这一窗的音频电平喂给它」。
    ///
    /// 被丢的段**记进 `hallucinationLog`**。理由：删用户的转录内容是可见的删除，
    /// 「这段为什么没了」必须答得上来，不能静默丢。
    /// （今天答这个问题的只有探针，界面还没接——见 `hallucinationLog` 的注释）
    private func filterHallucinations(
        _ segments: [WhisperSegment],
        windowSamples: [Float]
    ) -> [WhisperSegment] {
        let floor = WhisperHallucination.speechFloor(
            samples: windowSamples, sampleRate: Self.sampleRate
        )
        return segments.filter { segment in
            let verdict = WhisperHallucination.verdict(
                text: segment.text,
                noSpeechProbability: segment.noSpeechProbability,
                audioLevel: WhisperHallucination.level(
                    of: segment, in: windowSamples, sampleRate: Self.sampleRate
                ),
                silenceFloor: floor
            )
            if case .keep = verdict { return true }
            hallucinationLog.append("丢掉「\(segment.text)」— \(verdict)")
            return false
        }
    }

    /// 被丢掉的幻觉，按时间顺序。
    ///
    /// **当前只有一个读者**：探针 `--whisper-window-file`（`WhisperWindowFileRun`
    /// 打「生产链路的幻觉过滤」那一段）。界面还没有读它——所以「用户能看到
    /// 删了什么」这件事**今天还没做到**，这里记一笔，别把注释写成已经做到了
    private(set) var hallucinationLog: [String] = []

    /// 只强制定稿、不再转写。
    ///
    /// 单独拆出来是给收尾转写失败时兜底：那一段音频救不回来是一回事，
    /// 已经认出来的段落停在「未定稿」是另一回事——未定稿的段拿不到质量档位、
    /// 不会送核查，而用户已经没法再录一遍来补齐它们了。
    func finalizeWithoutTranscribing() -> Update {
        var changes: [String] = []
        var finalized = 0
        for index in segments.indices where !segments[index].isFinal {
            segments[index].isFinal = true
            finalized += 1
        }
        finalizedCount = segments.filter(\.isFinal).count
        if finalized > 0 {
            changes.append("收尾定稿 \(finalized) 段（录音已停，不会再有窗口了）")
        }
        return Update(segments: segments, changes: changes)
    }

    // MARK: - 内部

    private func merge(
        windowSamples: [Float],
        windowStartMillis: Int,
        engine: WhisperEngine
    ) throws -> Update {
        let started = ContinuousClock.now
        // `audio` 只喂诊断日志：时间戳一旦非法，光说「有个段坏了」没用，
        // 得能翻回是这次录音的哪一窗
        let raw = try engine.transcribe(
            windowSamples,
            initialPrompt: initialPrompt,
            audio: "实时 · 窗口@\(windowStartMillis)ms"
        )
        // 幻觉过滤放在**合并之前**：合并器会把「同一句的多次识别」揉成一个段，
        // 幻觉一旦进了合并器就可能和真话粘在一起，那时再按段判就判不干净了。
        let recognized = filterHallucinations(raw, windowSamples: windowSamples)
        recognizedConfidences.append(contentsOf: recognized.flatMap(\.confidences))
        let elapsed = ContinuousClock.now - started
        transcriptionSeconds.append(
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )

        let result = WhisperWindowMerger.merge(
            WhisperMergeInput(
                existing: segments,
                window: WhisperWindow(
                    startMillis: windowStartMillis,
                    endMillis: windowStartMillis + Int(Self.windowSeconds * 1000),
                    segments: recognized
                ),
                previousTail: tail,
                previousWindowStartMillis: tailWindowStartMillis,
                stepMillis: mergeStepMillis
            )
        )
        segments = result.segments
        tail = result.pendingTail
        tailWindowStartMillis = windowStartMillis
        lastWindowStartMillis = windowStartMillis
        finalizedCount = segments.filter(\.isFinal).count
        guardTrips += result.changes.filter { $0.hasPrefix("新增（文本归属在别处") }.count
        return Update(segments: segments, changes: result.changes)
    }

    /// 实测占用率（这一包要贴的数字）。
    ///
    /// 占用率 = 单次转写耗时 / 步长。它 > 100% 就意味着「跟不上」——那时
    /// 驱动循环会跳轮，界面上出句子的间隔从 3 秒变成 6 秒、9 秒……
    /// 所以这个数不是性能指标，是**能不能按设计的节奏出句子**的判据。
    // 门控那一行由 `WhisperWindowFileRun.gateSection` 打（含「真的解了 N 窗」
    // 与逐窗明细）。这里原本还有一个 `gateStatsLine`，全仓库没人调用——
    // 两处各写一份「跳过率」的格式串，改一处忘一处就会打出互相矛盾的两个数，
    // 所以删掉，只留一处。

    var statsLine: String {
        guard !transcriptionSeconds.isEmpty else { return "Whisper 滑窗：还没转过一窗" }
        let sorted = transcriptionSeconds.sorted()
        let mean = transcriptionSeconds.reduce(0, +) / Double(transcriptionSeconds.count)
        let median = sorted[sorted.count / 2]
        return String(
            format: "Whisper 滑窗 %d 窗 · 单次转写 均 %.2f / 中位 %.2f / 最大 %.2f 秒 · 步长 %.1f 秒 → 占用 %.0f%% · 守卫触发 %d 次",
            transcriptionSeconds.count,
            mean,
            median,
            sorted.last ?? 0,
            Self.stepSeconds,
            mean / Self.stepSeconds * 100,
            guardTrips
        )
    }
}
