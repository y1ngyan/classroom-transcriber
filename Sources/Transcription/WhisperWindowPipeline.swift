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
    /// 且在 App 同时录音时量的）。
    /// 3 秒步长：中位 2.19 秒 < 3 秒，留约 0.8 秒余量。再小就必然跟不上，
    /// 跟不上要跳轮——不丢音频（下一窗整段覆盖），但界面上出句子的间隔会变长。
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
    }

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
    /// ⚠️ 含窗口重叠导致的**重复计入**（10 秒窗 / 3 秒步长，同一句平均被转 3 次
    /// 左右），所以它是分布参考，不是逐句的精确统计。
    private(set) var recognizedConfidences: [Double] = []

    init(segments: [TranscriptSegment] = [], capacitySeconds: Double = 15) {
        self.segments = segments
        self.buffer = WhisperWindowBuffer(capacitySeconds: capacitySeconds, sampleRate: Self.sampleRate)
    }

    /// 采集线程调用。样本必须是 16kHz 单声道 Float32。
    func append(_ samples: [Float]) {
        buffer.append(samples)
    }

    /// 取最近一窗转写并合并。
    ///
    /// - Returns: `nil` = 缓冲还不够一窗，或者自上次取窗以来没有新音频。
    func advance(engine: WhisperEngine) throws -> Update? {
        guard let window = buffer.windowWithOrigin(
            durationSeconds: Self.windowSeconds,
            sampleRate: Self.sampleRate
        ) else { return nil }
        guard window.startMillis != lastWindowStartMillis else { return nil }
        return try merge(windowSamples: window.samples, windowStartMillis: window.startMillis, engine: engine)
    }

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
        if let window = buffer.windowWithOrigin(
            durationSeconds: Self.windowSeconds,
            sampleRate: Self.sampleRate,
            minimumSeconds: Self.minimumFlushSeconds
        ), window.startMillis != lastWindowStartMillis {
            let update = try merge(
                windowSamples: window.samples,
                windowStartMillis: window.startMillis,
                engine: engine
            )
            changes += update.changes
        }
        let final = finalizeWithoutTranscribing()
        return Update(segments: final.segments, changes: changes + final.changes)
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
        let raw = try engine.transcribe(windowSamples)
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
                stepMillis: Self.stepMillis
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
