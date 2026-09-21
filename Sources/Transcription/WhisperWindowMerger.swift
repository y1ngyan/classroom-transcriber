import Foundation

/// 一个 Whisper 滑窗结果。segment 的时间是相对于窗口起点的。
struct WhisperWindow {
    let startMillis: Int
    let endMillis: Int
    let segments: [WhisperSegment]
}

/// 合并器的输入。调用方负责维护 `previousTail` 和 `previousWindowStartMillis`，
/// 合并器本身无状态、纯函数。
struct WhisperMergeInput {
    let existing: [TranscriptSegment]
    let window: WhisperWindow
    /// 上一窗在重叠区产生的原始 segment（相对上一窗起点的时间）。
    let previousTail: [WhisperSegment]
    /// 上一窗的起点，用于把 `previousTail` 换算成全局时间。
    let previousWindowStartMillis: Int
    /// 步长。决定本次窗口哪些 segment 会被下一窗再次覆盖。
    let stepMillis: Int
}

struct WhisperMergeResult {
    let segments: [TranscriptSegment]
    /// 本窗应当传给下一次合并的尾部 segment（相对本窗起点的时间）。
    /// 调用方原样保存，下次作为 `previousTail` 传回即可。
    let pendingTail: [WhisperSegment]
    /// 供日志/自检查看的变更说明。
    let changes: [String]
}

/// Whisper 滑窗结果的纯函数合并器。
///
/// 核心任务：把「最近 10 秒音频整体重转」得到的新结果，合并进已显示的
/// 转录段列表，既不重复也不吞内容。
enum WhisperWindowMerger {

    /// 合并一个新窗口的结果到已有段列表。
    ///
    /// 策略：
    /// 1. 窗口内 segment 的时间戳 = window.startMillis + segment.startMillis。
    /// 2. 只在 `existing` 的最后 `scanBackLimit` 段里找匹配——随会话变长不能变慢。
    /// 3. 匹配分三档（复用 `TranscriptionEngine.textRelation`）：
    ///    - `.same(≥6 字)`：直接认为是同一段的 refine，**不看时间**——
    ///      Whisper 换窗后同一句的时间戳会整体平移，固定时间窗框不住；
    ///    - `.similar`：且时间重叠或相邻（candidate.start 与 existing.end 相差
    ///      ≤ 1 秒）时认为是同一段。1 秒而不是 Apple 那条链路的 4000ms：
    ///      这里只用来盖住「同一句被重识别时的时间戳抖动」，不需要那么宽。
    ///    - 时间重叠的未定稿段，即使 `.different` 也视为修正（保留 id，更新 text），
    ///      避免同一时间出现两段不同文本。
    /// 4. 稳定性判据：一段 segment 在 `previousTail` 里存在，且本窗在重叠区
    ///    给出 `.same(≥6 字)` 的文本，才标记为 `isFinal = true`。
    ///    这回答的是「这句话还会不会被改」，不依赖固定时间边界。
    /// 5. 未匹配到的 segment 新建，初始 isFinal=false。
    ///
    /// **已知缺口（2026-09-21 探针实测，本轮未改，等接线时裁决）**：
    /// - 一个段落若结束在「本窗起点 + 步长」之前，之后的窗口只会从更晚的位置
    ///   开始，永远不会再覆盖它；如果它当时没能通过稳定性判据，就会**永久停在
    ///   临时**（下游的核查、质量档位都挂在定稿上，等于这些段拿不到）。
    ///   实测：W0 的段 [0,3000] 之后连过 3 个窗口仍是 final=false。
    /// - 反过来，已定稿段的文本**仍可能被后续窗口改写**：第一趟 `.same(≥6)` 不
    ///   区分是否已定稿，改写后 isFinal 保持 true、也不会再触发一次定稿事件，
    ///   于是「已送去核查的文本」和「界面上显示的文本」可能不一致。
    ///   实测：定稿段「今天我们讲梯度下降」被下一窗改写成「…算法」，id 不变、
    ///   final 保持 true、changes 里只有「刷新」。
    /// 两条都取决于 isFinal 打算对外承诺什么语义（「两窗一致」还是「不再改写」），
    /// 是接线前要定的契约，不是这里的逻辑错。
    static func merge(
        _ input: WhisperMergeInput,
        scanBackLimit: Int = 5
    ) -> WhisperMergeResult {
        var segments = input.existing
        var changes: [String] = []

        // 候选段转全局时间
        let candidates = input.window.segments.map { seg in
            TranscriptSegment(
                text: seg.text,
                isFinal: false,
                startTimeMillis: input.window.startMillis + seg.startMillis,
                endTimeMillis: input.window.startMillis + seg.endMillis,
                languages: ["zh-CN"]
            )
        }

        // 上一窗尾部转全局时间
        let previousTailGlobal = input.previousTail.map { seg in
            TranscriptSegment(
                text: seg.text,
                isFinal: false,
                startTimeMillis: input.previousWindowStartMillis + seg.startMillis,
                endTimeMillis: input.previousWindowStartMillis + seg.endMillis,
                languages: ["zh-CN"]
            )
        }

        // 本窗的 pending tail：相对结束时间 > stepMillis 的段（下一窗还会覆盖它们）
        let pendingTail = input.window.segments.filter { $0.endMillis > input.stepMillis }

        for candidate in candidates {
            if let index = matchIndex(
                in: segments,
                candidate: candidate,
                scanBackLimit: scanBackLimit
            ) {
                let shouldStabilize = !segments[index].isFinal
                    && isStable(candidate: candidate, previousTail: previousTailGlobal)

                segments[index].text = candidate.text
                segments[index].startTimeMillis = candidate.startTimeMillis
                segments[index].endTimeMillis = candidate.endTimeMillis

                if shouldStabilize {
                    segments[index].isFinal = true
                    changes.append("落定：\(candidate.text.prefix(30))")
                } else {
                    changes.append("刷新：\(candidate.text.prefix(30))")
                }
            } else {
                segments.append(candidate)
                changes.append("新增：\(candidate.text.prefix(30))")
            }
        }

        return WhisperMergeResult(
            segments: segments,
            pendingTail: pendingTail,
            changes: changes
        )
    }

    // MARK: - 内部匹配

    private static func matchIndex(
        in existing: [TranscriptSegment],
        candidate: TranscriptSegment,
        scanBackLimit: Int
    ) -> Int? {
        guard !existing.isEmpty else { return nil }
        let lower = max(0, existing.count - scanBackLimit)
        let range = existing.indices.suffix(from: lower)

        // 第一趟：same（≥6 字）。长文本撞车概率极低，不依赖时间窗——
        // Whisper 不同窗口对同一句的重识别常落到相邻但不重叠的时间戳上。
        for index in range.reversed() {
            if case .same(let shorter) = TranscriptionEngine.textRelation(existing[index].text, candidate.text),
               shorter >= 6 {
                return index
            }
        }

        // 第二趟：similar，且时间重叠或相邻（≤ 1 秒）。
        // 滑窗里同一句的时间戳可能因上下文变化而整体平移几百毫秒，
        // 但 different 的相邻句不该被合并。
        for index in range.reversed() {
            switch TranscriptionEngine.textRelation(existing[index].text, candidate.text) {
            case .similar:
                let gap = candidate.startTimeMillis - existing[index].endTimeMillis
                guard abs(gap) <= 1_000 else { continue }
                return index
            default:
                continue
            }
        }

        // 第三趟：时间真正重叠且未定稿，视为内容修正。
        // 这种情况发生在 Whisper 对同一句的识别发生较大变化时（同一句话
        // 被不同窗口重识别成不同文本）——保留同一个 id 可以避免下游引用
        // （核查、笔记）变成孤儿。
        //
        // 注意：只认「重叠」，不认「相邻」。相邻但文本 different 的段更可能
        // 是老师真的换了一句话，合并会把两句真话吞成一句。
        for index in range.reversed() {
            let seg = existing[index]
            guard !seg.isFinal else { continue }
            guard candidate.startTimeMillis < seg.endTimeMillis
                && candidate.endTimeMillis > seg.startTimeMillis else { continue }
            return index
        }

        return nil
    }

    private static func isStable(
        candidate: TranscriptSegment,
        previousTail: [TranscriptSegment]
    ) -> Bool {
        for prev in previousTail {
            // 时间必须重叠：稳定性只关心重叠区里的段
            guard candidate.startTimeMillis < prev.endTimeMillis
                && candidate.endTimeMillis > prev.startTimeMillis else { continue }

            switch TranscriptionEngine.textRelation(candidate.text, prev.text) {
            case .same(let shorter):
                guard shorter >= 6 else { continue }
                return true
            case .similar, .different:
                continue
            }
        }
        return false
    }
}

// MARK: - 无头自检

extension WhisperWindowMerger {

    /// `--whisper-window-selftest`：纯函数合并策略回归。
    ///
    /// 不依赖麦克风、模型、网络。构造一系列窗口序列，模拟滑窗准实时
    /// 转录的边界情况。
    static func selfTest() -> [String] {
        var lines: [String] = ["Whisper 滑窗合并自检（纯函数 · 无麦克风 · 无模型 · 无网络）"]
        var allPassed = true

        func check(_ name: String, _ condition: Bool, _ detail: String) {
            allPassed = allPassed && condition
            lines.append("  \(condition ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        func dump(_ segments: [TranscriptSegment]) {
            for seg in segments {
                lines.append(String(
                    format: "     [%@] %@  %@",
                    seg.formattedTimestamp,
                    seg.isFinal ? "定稿" : "临时",
                    seg.text
                ))
            }
        }

        // 辅助构造。confidences 为空，不影响合并逻辑
        func seg(_ text: String, _ start: Int, _ end: Int) -> WhisperSegment {
            WhisperSegment(text: text, startMillis: start, endMillis: end, confidences: [])
        }

        func window(_ start: Int, _ duration: Int, _ segments: [WhisperSegment]) -> WhisperWindow {
            WhisperWindow(startMillis: start, endMillis: start + duration, segments: segments)
        }

        let stepMillis = 3_000
        let windowMillis = 10_000

        // MARK: 用例 1：基本合并 + 稳定性落定
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            // W1 [0, 10000]
            let w1 = window(0, windowMillis, [
                seg("今天我们讲梯度下降", 0, 3_000),
                seg("它的核心思想是沿着负梯度方向迭代", 3_000, 7_000),
            ])
            let r1 = merge(WhisperMergeInput(
                existing: segments,
                window: w1,
                previousTail: pendingTail,
                previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r1.segments
            pendingTail = r1.pendingTail
            previousStart = w1.startMillis

            check("W1 产生两段且都临时",
                  segments.count == 2 && !segments[0].isFinal && !segments[1].isFinal,
                  "段数 \(segments.count)")

            // W2 [3000, 13000]：第一段修正，第二段 same
            let w2 = window(3_000, windowMillis, [
                seg("今天我们讲梯度下降算法", 0, 3_500),
                seg("它的核心思想是沿着负梯度方向迭代", 3_500, 8_000),
            ])
            let r2 = merge(WhisperMergeInput(
                existing: segments,
                window: w2,
                previousTail: pendingTail,
                previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r2.segments
            pendingTail = r2.pendingTail
            previousStart = w2.startMillis

            check("W2 后段数仍为 2", segments.count == 2, "段数 \(segments.count)")
            check("第一段被修正为「梯度下降算法」",
                  segments[0].text == "今天我们讲梯度下降算法", segments[0].text)
            check("第二段连续两窗一致，已落定",
                  segments[1].isFinal, "final=\(segments[1].isFinal)")

            lines.append("  ── 用例 1 当前段表 ──")
            dump(segments)
        }

        // MARK: 用例 2：新增段 + 新段临时、旧段落定
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            let w1 = window(0, windowMillis, [
                seg("它的核心思想是沿着负梯度方向迭代", 0, 4_000),
            ])
            var r = merge(WhisperMergeInput(
                existing: segments, window: w1,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = w1.startMillis

            let w2 = window(3_000, windowMillis, [
                seg("它的核心思想是沿着负梯度方向迭代", 0, 4_500),
                seg("大家注意学习率这个超参数", 4_500, 8_500),
            ])
            r = merge(WhisperMergeInput(
                existing: segments, window: w2,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = w2.startMillis

            check("W2 新增第二段", segments.count == 2, "段数 \(segments.count)")
            check("第一段连续两窗一致，已落定", segments[0].isFinal, "")
            check("第二段只出现一次，仍临时", !segments[1].isFinal, "")

            lines.append("  ── 用例 2 当前段表 ──")
            dump(segments)
        }

        // MARK: 用例 3：空窗口不造成变化
        do {
            // 只是喂给 merge 的输入，不改——所以是 let
            let segments: [TranscriptSegment] = [
                TranscriptSegment(text: "已有内容", isFinal: true, startTimeMillis: 0, endTimeMillis: 3_000, languages: ["zh-CN"])
            ]
            let r = merge(WhisperMergeInput(
                existing: segments,
                window: window(3_000, windowMillis, []),
                previousTail: [],
                previousWindowStartMillis: 0,
                stepMillis: stepMillis
            ))
            check("空窗口不新增也不删除",
                  r.segments.count == 1 && r.segments[0].text == "已有内容",
                  "段数 \(r.segments.count)")
        }

        // MARK: 用例 4：窗口比上一窗短，不截断已有段
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            let w1 = window(0, windowMillis, [
                seg("今天我们讲梯度下降", 0, 3_000),
                seg("它的核心思想是沿着负梯度方向迭代", 3_000, 7_000),
            ])
            var r = merge(WhisperMergeInput(
                existing: segments, window: w1,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = w1.startMillis

            // W2 只返回第一段
            let w2 = window(3_000, windowMillis, [
                seg("今天我们讲梯度下降算法", 0, 3_500),
            ])
            r = merge(WhisperMergeInput(
                existing: segments, window: w2,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments

            check("短窗口不截断后续段",
                  segments.count == 2 && segments[1].text == "它的核心思想是沿着负梯度方向迭代",
                  "段数 \(segments.count)，第二段=\(segments[1].text)")
        }

        // MARK: 用例 5：说话人中途换句（不同内容，时间重叠）
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            let w1 = window(0, windowMillis, [
                seg("今天我们讲梯度下降", 0, 3_000),
            ])
            var r = merge(WhisperMergeInput(
                existing: segments, window: w1,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = w1.startMillis

            // W2 在同样时间段给出完全不同的句子——视为修正，不新增
            let w2 = window(3_000, windowMillis, [
                seg("下面我们看一个具体的例子", 0, 3_500),
            ])
            r = merge(WhisperMergeInput(
                existing: segments, window: w2,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments

            // 注意：这里不是「修正同一句」，而是相邻窗口里出现了两句
            // 不同的话（W1 的段在 3000ms 结束，W2 的新段从 3000ms 开始）。
            // 时间相邻且文本 different 时保留两段，避免把两句真话吞成一句。
            check("换句时相邻不同段保留两段",
                  segments.count == 2,
                  "段数 \(segments.count)，第一段=\(segments[0].text)，第二段=\(segments[1].text)")
        }

        // MARK: 用例 6：跨 stepMillis 边界的段能稳定落定
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            let w1 = window(0, windowMillis, [
                seg("这句话跨越三秒边界", 0, 4_000),
            ])
            var r = merge(WhisperMergeInput(
                existing: segments, window: w1,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = w1.startMillis

            let w2 = window(3_000, windowMillis, [
                seg("这句话跨越三秒边界", 0, 4_000),
            ])
            r = merge(WhisperMergeInput(
                existing: segments, window: w2,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments

            check("跨边界段连续两窗一致后落定",
                  segments.count == 1 && segments[0].isFinal && segments[0].text == "这句话跨越三秒边界",
                  "")
        }

        // MARK: 用例 7a：文本相似但不完全相同 + 时间重叠——刷新，但不落定
        //
        // 这一段原先是失败的（2026-09-21）。原写法有两处不成立，判据本身没变
        // （仍然是「不能被落定」），改的是输入——让「重识别」真的发生：
        //   · 原来的 W2 段落在全局 [3000,6500]，和已有段 [0,3000] **相邻但零重叠**。
        //     滑窗里同一句话被重识别时不可能这样：W2 只覆盖全局 3 秒以后的音频，
        //     它给出的段从相对 0 开始，正是被切掉半句、再重新拼起来的那句。
        //     相邻而不重叠 = 两句不同的话，第三趟匹配本来就（故意）只认重叠。
        //   · 原来的 W1 段结束在 3000 == 步长，`endMillis > stepMillis` 不成立，
        //     进不了 pendingTail——稳定性判据没有任何可比对象，就算合并了也测不出
        //     「不落定」，是个恒真的假通过。
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            // W1 的段跨过步长边界（end=4000 > 3000）→ 进 pendingTail
            let w1 = window(0, windowMillis, [
                seg("今天讲梯度下降算法", 0, 4_000),
            ])
            var r = merge(WhisperMergeInput(
                existing: segments, window: w1,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = w1.startMillis

            // W2 重识别同一句，多了一个「的」：编辑距离 1 / 10 字 = 10% → similar
            let w2 = window(3_000, windowMillis, [
                seg("今天讲梯度下降的算法", 0, 3_500),
            ])
            r = merge(WhisperMergeInput(
                existing: segments, window: w2,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments

            check("similar 且时间重叠：合并为一段",
                  segments.count == 1, "段数 \(segments.count)")
            check("文本刷新为重识别后的结果",
                  segments[0].text == "今天讲梯度下降的算法", segments[0].text)
            check("相似但不完全一致时不落定",
                  !segments[0].isFinal, "final=\(segments[0].isFinal)")
        }

        // MARK: 用例 7b：判 different（编辑距离超阈值）但时间重叠——视为内容修正，仍不落定
        //
        // 用原用例 7 的那对文本：「今天讲梯度下降」→「今天我们讲梯度下降」，
        // 2 字插入 / 9 字 = 22.2% > 20%，按项目的判据就是 different（探针独立
        // 复算过：编辑距离 2、占比 22.2%，与引擎判定一致）。different 在重叠区
        // 走第三趟匹配（保留 id、更新文本），而稳定性判据要求 same(≥6)，
        // 所以只刷新、不落定。
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            let w1 = window(0, windowMillis, [
                seg("今天讲梯度下降", 0, 4_000),
            ])
            var r = merge(WhisperMergeInput(
                existing: segments, window: w1,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = w1.startMillis

            let w2 = window(3_000, windowMillis, [
                seg("今天我们讲梯度下降", 0, 3_500),
            ])
            r = merge(WhisperMergeInput(
                existing: segments, window: w2,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments

            check("different 但时间重叠：合并为一段（不新增重复段）",
                  segments.count == 1, "段数 \(segments.count)")
            check("文本刷新为重识别后的结果",
                  segments[0].text == "今天我们讲梯度下降", segments[0].text)
            check("different 不算稳定，不落定",
                  !segments[0].isFinal, "final=\(segments[0].isFinal)")
        }

        // MARK: 用例 8：窗口结果与已显示文本部分重叠——重叠的刷新，没重叠的原样留着
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            let w1 = window(0, windowMillis, [
                seg("今天我们讲梯度下降", 0, 4_000),
                seg("它的核心思想是沿着负梯度方向迭代", 4_000, 9_000),
            ])
            var r = merge(WhisperMergeInput(
                existing: segments, window: w1,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = w1.startMillis

            let untouchedText = segments[1].text
            let untouchedRange = (segments[1].startTimeMillis, segments[1].endTimeMillis)

            // W2 只吐一段，全局 [3000,6500]：与第一段 [0,4000] 重叠，与第二段
            // [4000,9000] 也压掉一部分——但只该动第一段
            let w2 = window(3_000, windowMillis, [
                seg("今天我们讲梯度下降算法", 0, 3_500),
            ])
            r = merge(WhisperMergeInput(
                existing: segments, window: w2,
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments

            check("部分重叠不改变段数",
                  segments.count == 2, "段数 \(segments.count)")
            check("重叠的那段被刷新（文本 + 时间）",
                  segments[0].text == "今天我们讲梯度下降算法"
                  && segments[0].startTimeMillis == 3_000
                  && segments[0].endTimeMillis == 6_500,
                  "\(segments[0].formattedTimestamp) \(segments[0].text)")
            check("没被覆盖到的段原样保留（文本 · 时间 · 仍临时）",
                  segments[1].text == untouchedText
                  && segments[1].startTimeMillis == untouchedRange.0
                  && segments[1].endTimeMillis == untouchedRange.1
                  && !segments[1].isFinal,
                  "\(segments[1].formattedTimestamp) \(segments[1].text)")
        }

        // MARK: 用例 9：窗口结果完全重复（同一窗连喂三次）——不产生重复段
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []
            let w = window(0, windowMillis, [
                seg("它的核心思想是沿着负梯度方向迭代", 0, 4_000),
            ])

            func feed() -> WhisperMergeResult {
                let r = merge(WhisperMergeInput(
                    existing: segments, window: w,
                    previousTail: pendingTail, previousWindowStartMillis: previousStart,
                    stepMillis: stepMillis
                ))
                segments = r.segments; pendingTail = r.pendingTail; previousStart = w.startMillis
                return r
            }

            _ = feed()
            let afterFirstCount = segments.count
            let afterFirstFinal = segments[0].isFinal
            let idAfterFirst = segments[0].id

            _ = feed()
            let afterSecondFinal = segments[0].isFinal

            _ = feed()

            check("第一次喂入：1 段、临时",
                  afterFirstCount == 1 && !afterFirstFinal,
                  "段数 \(afterFirstCount) final=\(afterFirstFinal)")
            check("第二次喂同一窗：落定，且不新增段",
                  segments.count == 1 && afterSecondFinal, "段数 \(segments.count)")
            check("第三次再喂：仍是同一段（id 不变）、不翻回临时",
                  segments.count == 1 && segments[0].id == idAfterFirst && segments[0].isFinal,
                  "段数 \(segments.count) final=\(segments[0].isFinal)")
        }

        lines.append(allPassed ? "✅ Whisper 滑窗合并自检通过" : "❌ Whisper 滑窗合并自检未通过")
        return lines
    }
}
