import Foundation

/// 一个 Whisper 滑窗结果。segment 的时间是相对于窗口起点的。
struct WhisperWindow {
    let startMillis: Int
    /// 本窗覆盖到的时间。目前**只作记录**：第一趟匹配的时间上界从阶段 1.5 起取
    /// `input.stepMillis`，不再依赖窗口时长，所以这里填什么都不会静默改变合并率
    /// （原先「填错会让上界退化成 0」的 ⚠️ 随之作废，`durationMillis` 已删除）。
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
    ///    - `.same(≥6 字)`：认为是同一段的 refine，**不看时间**，但有一个上界：
    ///      候选与已有段的时间间隔必须 ≤ `input.stepMillis`（**一个步长**）。
    ///      不看时间，是因为 Whisper 换窗后同一句的时间戳会整体平移；设上界，是因为
    ///      这一趟会**连文本带时间戳一起改写**已有段，而老师隔十几秒重复一句口头禅
    ///      是课堂常态——没有上界就会把旧段的文本和时间戳搬到当前时刻（时间线被破坏，
    ///      那次重复也没留下自己的段）。
    ///      为什么是步长而不是窗口时长（2026-09-21 阶段 1.5 收紧）：这一趟要补偿的是
    ///      「同一句在相邻窗口之间的时间戳位移」，而窗口每次只前进一个步长，位移的
    ///      量级就该按步长算。原先取一个窗口（10 秒）时余量大到能把老师 10 秒后的
    ///      口头禅重复也算成「同一句」——探针实测三种子「时间线位置消失的句子」
    ///      7/42（旧版无上界 14/42）；收到一个步长后 4/42，代价是三种子段数 46 → 49。
    ///    - `.similar`：且时间重叠或相邻（candidate.start 与 existing.end 相差
    ///      ≤ 1 秒）时认为是同一段。1 秒而不是 Apple 那条链路的 4000ms：
    ///      这里只用来盖住「同一句被重识别时的时间戳抖动」，不需要那么宽。
    ///    - 时间重叠的未定稿段，即使 `.different` 也视为修正（保留 id，更新 text），
    ///      避免同一时间出现两段不同文本。
    /// 4. 稳定性判据：一段 segment 在 `previousTail` 里存在，且本窗在重叠区
    ///    给出 `.same(≥6 字)` 的文本，才标记为 `isFinal = true`。
    /// 5. 补定稿：候选循环之后，`endTimeMillis <= window.startMillis + stepMillis`
    ///    且未定稿的段一律定稿。下一窗的起点正是 `window.startMillis + stepMillis`、
    ///    之后的窗口只会更晚，所以这些段再也无法与任何候选**按时间重叠**，也就
    ///    永远过不了第 4 条（它要求候选落在 `previousTail` 里，而 `pendingTail`
    ///    的判据是 `endMillis > stepMillis`）。它缺的是判据，不是「没人能改它」——
    ///    第 3 条第一趟仍可按文本改写它。
    ///    第 4、5 条互补：**还能再被覆盖的靠两窗一致定稿，再也覆盖不到的靠这条定稿**，
    ///    合起来的不变式是「每一段最终都会定稿」（窗口起点每步递增，任何一段的
    ///    结束时间迟早落进阈值）。少了第 5 条，滑出覆盖范围的段会永久停在临时，
    ///    而下游的核查、质量档位都挂在定稿上，这些段就永远拿不到。
    ///    ⚠️ 这条不变式的**前提是 `stepMillis > 0`**（调用方按步长推进窗口起点）。
    ///    `stepMillis <= 0` 时阈值不前移，`endTimeMillis > window.startMillis` 的段
    ///    会永久停在临时——2026-09-21 核验时用 `stepMillis = 0` 实测确认过。
    ///    调用方接线时要保证步长为正。
    /// 6. 未匹配到的 segment 新建，初始 isFinal=false。
    ///
    /// **`isFinal` 的语义（弱语义，2026-09-21 裁决）**：它承诺的是「已被两个窗口
    /// 独立确认，或已不可能再被按时间重叠覆盖」，**不是「文本从此不再改变」**——
    /// 已定稿段仍可能被后续窗口按第 3 条第一趟改写文本与时间戳（这种改写不回退
    /// isFinal，也不会再报一次定稿）。
    /// 为什么不承诺冻结：要冻结就得处理「候选与已定稿段文本相同（≥6 字）但时间
    /// 零重叠」这一大类，而那只能靠「丢弃候选」——在课堂场景里丢弃就是丢内容
    /// （老师重复口头禅是常态），代价大于「定稿后被精修几个字」。
    /// 下游按 isFinal 触发一次性动作（比如送核查）时要按这个语义理解。
    static func merge(
        _ input: WhisperMergeInput,
        scanBackLimit: Int = 5
    ) -> WhisperMergeResult {
        var segments = input.existing
        var changes: [String] = []

        // 候选段转全局时间
        //
        // 档位在**候选构造时**就带上，而不是等定稿再算：合并之后
        // `WhisperSegment` 就不存在了（只剩合并器吐出的 `TranscriptSegment`），
        // 逐字符置信度只有这一刻拿得到。Apple 那条链路是反过来的——它的
        // 置信度挂在 `AttributedString` 上、跟着结果一路走到 `applyUpdate`，
        // 所以那边可以「定稿时才算档位」。两条链路的档位最终都由同一个
        // `TranscriptQualityAssessor` 判，口径一致。
        //
        // `seg.grade` 为 nil 只在拿不到 token 概率时发生（见
        // `WhisperEngine.spreadTokenProbabilities`），不是错判成「不可信」。
        let candidates = input.window.segments.map { seg -> TranscriptSegment in
            var candidate = TranscriptSegment(
                text: seg.text,
                isFinal: false,
                startTimeMillis: input.window.startMillis + seg.startMillis,
                endTimeMillis: input.window.startMillis + seg.endMillis,
                languages: ["zh-CN"]
            )
            candidate.qualityGrade = seg.grade
            return candidate
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
            // 第三趟的文本守卫触发次数（每个候选至多 1 次）。带出来只为在 changes 里留个
            // 区别于普通「新增」的标签——真实录音上要靠它量化「文本归属在别处」多常见。
            var guardTrips = 0
            if let index = matchIndex(
                in: segments,
                candidate: candidate,
                scanBackLimit: scanBackLimit,
                maxIntervalGapMillis: input.stepMillis,
                guardTrips: &guardTrips
            ) {
                let shouldStabilize = !segments[index].isFinal
                    && isStable(candidate: candidate, previousTail: previousTailGlobal)

                segments[index].text = candidate.text
                segments[index].startTimeMillis = candidate.startTimeMillis
                segments[index].endTimeMillis = candidate.endTimeMillis
                // 档位跟着这一版文本走：文本被换掉了，旧档位就不是这段的档位了
                segments[index].qualityGrade = candidate.qualityGrade

                if shouldStabilize {
                    segments[index].isFinal = true
                    changes.append("落定（两窗一致）：\(candidate.text.prefix(30))")
                } else {
                    changes.append("刷新：\(candidate.text.prefix(30))")
                }
            } else {
                segments.append(candidate)
                // 守卫触发导致的「新增」用不同标签：下游要靠它数「文本归属在别处」的频次，
                // 与真正的第一次出现区分开。
                changes.append(guardTrips > 0
                    ? "新增（文本归属在别处，不按时间改写）：\(candidate.text.prefix(30))"
                    : "新增：\(candidate.text.prefix(30))")
            }
        }

        // 补定稿：滑出「还能被覆盖」的范围的段，从此不会再有任何窗口按时间重叠
        // 碰到它，稳定性判据（第 4 条）对它永远为假。判据见上面策略第 5 条。
        //
        // 注意范围是**全部** segments（不只后 scanBackLimit 段），且包含本窗刚
        // 新建的段：新段若当窗就落在阈值以内，它同样永远等不到第二次确认。
        let coverageEndMillis = input.window.startMillis + input.stepMillis
        for index in segments.indices
        where !segments[index].isFinal && segments[index].endTimeMillis <= coverageEndMillis {
            segments[index].isFinal = true
            changes.append("补定稿（滑出覆盖）：\(segments[index].text.prefix(30))")
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
        scanBackLimit: Int,
        maxIntervalGapMillis: Int,
        guardTrips: inout Int
    ) -> Int? {
        guard !existing.isEmpty else { return nil }
        let lower = max(0, existing.count - scanBackLimit)
        let range = existing.indices.suffix(from: lower)

        // 第一趟：same（≥6 字）。长文本撞车概率极低，不看时间——Whisper 不同窗口
        // 对同一句的重识别常落到相邻但不重叠的时间戳上。
        //
        // 但**必须有个上界**（2026-09-21 裁决，阶段 1.5 收紧到一个步长）：这一趟会
        // 连文本带时间戳一起改写已有段，而老师隔十几秒重复同一句是课堂常态；只要
        // 那段还在后 scanBackLimit 段里，就会被当成「同一句」，把旧段的文本和时间戳
        // 搬到当前时刻——时间线损坏 + 那次重复没留下自己的段，比显示瑕疵严重。
        // 上界为什么是步长而不是窗口时长：见 `merge` 策略 3 第一条（附实测数字）。
        for index in range.reversed() {
            guard intervalGapMillis(existing[index], candidate) <= maxIntervalGapMillis else { continue }
            if case .same(let shorter) = TranscriptionEngine.textRelation(existing[index].text, candidate.text),
               shorter >= 6 {
                return index
            }
        }

        // 第二趟：similar，且**区间距离** ≤ 1 秒。
        // 滑窗里同一句的时间戳可能因上下文变化而整体平移几百毫秒，
        // 但 different 的相邻句不该被合并。
        //
        // 2026-09-22（阶段 1.7）：判据从「候选起点 − 旧段终点的带符号差」改成
        // `intervalGapMillis`。那个带符号差其实是**重叠深度**，不是距离：两段重叠 1500ms
        // 时它算出 1500 而拒绝，可它们的真实间隔是 0——而「同一句被重识别成重叠但错位
        // 的一版」正是滑窗里最常见的形态。模块里 `intervalGapMillis` 的注释一直写着
        // 「用区间距离而不是起点之差」，那句话此前只对第一趟成立。
        // 三种子实测（探针）：过分割 7 → 0，段数 49 → 42（正好等于真句数），
        // 代价是「时间线位置被吸收的句子」4 → 5——合并必然牺牲时间线位置，契约写明的取舍。
        //
        // 为什么不顺手把容差也放成一个步长：那会把**相隔最多 3 秒的两句 similar** 也并掉
        // （正间隔一律按真实间隔算，没有「重叠」这个下限兜着），放宽幅度超过需要。
        // 这里要的只是把距离算对，1 秒这个数不动。
        for index in range.reversed() {
            switch TranscriptionEngine.textRelation(existing[index].text, candidate.text) {
            case .similar:
                guard intervalGapMillis(existing[index], candidate) <= 1_000 else { continue }
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
        //
        // 文本守卫（2026-09-22，阶段 1.7）：命中一个「重叠 + 未定稿」的段之前，先看候选的
        // **文本归属**在不在别处——若存在另一个已有段与候选同文本（.same ≥6）或近似
        // （.similar），就不许按时间改写这个段。理由：这种情况下第一趟刚刚因为上界
        // **正确地**拒绝过这次归属（远距离重复各自成段，裁决 2），第三趟按时间收编等于把
        // 那个拒绝推翻——而且命中的是**另一个**段，整句原文会被候选的文本覆盖掉
        // （实测：「训练集和测试集要分开」整段消失，属于内容丢失级）。
        // 守卫触发时返回 nil：候选走「新增一段」的正常路径，既不改写时间重叠的那段，
        // 也**不**并到远处那个文本双胞胎里（并过去就是「搬时间戳」，正是裁决 2 修掉的 bug）。
        //
        // 守卫为什么只能用文本判断：能走到这一趟的段必然与候选时间重叠，而重叠 ⇒ 区间距离
        // 恒为 0 ⇒ 「找一段距离更小的」永远不可满足。
        //
        // 为什么收 .similar（它是弱判据、编辑距离 ≤20% 无下限）：代价不对称——多触发一次
        // 的代价是「多一段」（显示瑕疵），漏触发一次的代价是「整句原文被覆盖」（内容丢失）。
        // 三种子实测两者**没有差别**（都是 42 段 / 0 过分割、守卫触发 0 次），所以这个选择
        // 是按代价不对称定的，不是按合成数据定的；真实录音上的触发频次要靠 changes 里
        // 「文本归属在别处」这个标签去数。若将来发现它把第三趟该做的修正挡掉了，收窄成
        // `.same(≥6)` 是一行的事。
        for index in range.reversed() {
            let seg = existing[index]
            guard !seg.isFinal else { continue }
            guard candidate.startTimeMillis < seg.endTimeMillis
                && candidate.endTimeMillis > seg.startTimeMillis else { continue }
            if hasTextAffinityElsewhere(in: existing, range: range, candidate: candidate, excluding: index) {
                guardTrips += 1
                return nil
            }
            return index
        }

        return nil
    }

    /// 候选的文本是否明确属于**别的**段（`.same(≥6)` 或 `.similar`）——第三趟的守卫用它。
    ///
    /// 单独抽出来是为了让它能被单独说清：它判的是**文本归属**，与时间无关。
    /// 与候选时间重叠的那一段经 `excluding` 排除在外。
    private static func hasTextAffinityElsewhere(
        in existing: [TranscriptSegment],
        range: Range<Int>,
        candidate: TranscriptSegment,
        excluding index: Int
    ) -> Bool {
        for other in range where other != index {
            switch TranscriptionEngine.textRelation(existing[other].text, candidate.text) {
            case .same(let shorter) where shorter >= 6:
                return true
            case .similar:
                return true
            default:
                continue
            }
        }
        return false
    }

    /// 两段时间区间之间隔了多远（毫秒），重叠或相接算 0。
    ///
    /// 用「区间距离」而不是「起点之差」：同一句被重识别时段的长度会变，
    /// 起点之差会把「长段被截短」（起点差大、实际紧挨着）误判成漂移很大。
    private static func intervalGapMillis(
        _ a: TranscriptSegment,
        _ b: TranscriptSegment
    ) -> Int {
        max(0, max(a.startTimeMillis - b.endTimeMillis, b.startTimeMillis - a.endTimeMillis))
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

            // 第二段 [3000,7000] 跨过阈值、后面还会被覆盖 → 仍临时；
            // 第一段 [0,3000] 结束在阈值上（0 + 步长），此后没有任何窗口能按时间
            // 重叠碰到它 → 当窗就补定稿（策略 5，2026-09-21 裁决）
            check("W1：[0,3000] 已滑出可覆盖范围（补定稿），[3000,7000] 仍临时",
                  segments.count == 2 && segments[0].isFinal && !segments[1].isFinal,
                  "段数 \(segments.count) · final=\(segments[0].isFinal)/\(segments[1].isFinal)")

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
            check("这条定稿走的是稳定性判据（changes 里带自己的标签）",
                  r.changes.contains { $0.hasPrefix("落定（两窗一致）") },
                  r.changes.joined(separator: " / "))

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

        // MARK: 用例 10：补定稿的边界（闭区间）
        //
        // 阈值判据是 `endTimeMillis <= window.startMillis + stepMillis`（闭区间取到）。
        // 这里的段都是本窗新建的：新段若当窗就落在阈值以内，它同样永远等不到
        // 第二次确认（下一窗的起点正好在阈值上，覆盖不到它）——按策略 5 一并补定稿。
        do {
            let w = window(0, windowMillis, [
                seg("刚好落在阈值上", 0, stepMillis),
                seg("比阈值多一毫秒", stepMillis, stepMillis + 1),
            ])
            let r = merge(WhisperMergeInput(
                existing: [],
                window: w,
                previousTail: [],
                previousWindowStartMillis: 0,
                stepMillis: stepMillis
            ))
            check("end == 窗口起点+步长：补定稿（闭区间取到）",
                  r.segments[0].isFinal, "final=\(r.segments[0].isFinal)")
            check("end 多 1 毫秒且没通过稳定性判据：不得定稿",
                  !r.segments[1].isFinal, "final=\(r.segments[1].isFinal)")
            check("补定稿在 changes 里有区别于稳定性落定的标签",
                  r.changes.contains { $0.hasPrefix("补定稿（滑出覆盖）") },
                  r.changes.joined(separator: " / "))
        }

        // MARK: 用例 11：第一趟上界的三个邻点——一个步长内 / 正好一个步长 / 超 1 毫秒
        do {
            // 阶段 1.5 把上界从「一个窗口时长」收到「一个步长」：相邻窗口对同一句的
            // 时间戳位移本来就只有一个步长的量级，内测点仍必须合并。
            // 期望值由 stepMillis 推导，不写死数字——上界再变这条用例也跟着变。
            func trial(_ gapMillis: Int) -> (count: Int, start: Int, end: Int) {
                let existing = [
                    TranscriptSegment(text: "它的核心思想是沿着负梯度方向迭代", isFinal: false,
                                      startTimeMillis: 0, endTimeMillis: 4_000, languages: ["zh-CN"])
                ]
                let r = merge(WhisperMergeInput(
                    existing: existing,
                    window: window(4_000 + gapMillis, windowMillis,
                                   [seg("它的核心思想是沿着负梯度方向迭代", 0, 4_000)]),
                    previousTail: [],
                    previousWindowStartMillis: 0,
                    stepMillis: stepMillis
                ))
                return (r.segments.count, r.segments[0].startTimeMillis, r.segments[0].endTimeMillis)
            }

            let inside = trial(2_000)
            let onBoundary = trial(stepMillis)          // 判据是 ≤，闭区间取到
            let outside = trial(stepMillis + 1)

            check("间隔 2000ms < 一个步长：仍按同一句合并，时间戳跟到新位置",
                  inside.count == 1 && inside.start == 6_000 && inside.end == 10_000,
                  "段数 \(inside.count) · \(inside.start)–\(inside.end)")
            check("间隔正好一个步长（\(stepMillis)ms）：闭区间取到，仍合并",
                  onBoundary.count == 1 && onBoundary.start == 7_000,
                  "段数 \(onBoundary.count) · \(onBoundary.start)–\(onBoundary.end)")
            check("间隔超 1 毫秒（\(stepMillis + 1)ms）：不得认成同一句，各自成段",
                  outside.count == 2 && outside.start == 0 && outside.end == 4_000,
                  "段数 \(outside.count) · 首段 \(outside.start)–\(outside.end)")
        }

        // MARK: 用例 12：第一趟上界之外——同一句远距离重复必须各自成段
        do {
            // 老师说过一次「大家理解我的意思吧」，18 秒后又重复一遍：两段相隔
            // 14000ms > 一个窗口时长（10000）。第一趟不得认成同一句——认了就会
            // 把旧段的文本和时间戳搬到当前时刻（时间线损坏，那次重复也没留下段）。
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            var r = merge(WhisperMergeInput(
                existing: segments,
                window: window(0, windowMillis, [seg("大家理解我的意思吧", 0, 4_000)]),
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments; pendingTail = r.pendingTail; previousStart = 0
            let oldText = segments[0].text
            let oldRange = (segments[0].startTimeMillis, segments[0].endTimeMillis)

            // 直接跳到 18 秒后的窗口：中间隔了 6 步，这条用例关心的是距离不是过程
            r = merge(WhisperMergeInput(
                existing: segments,
                window: window(18_000, windowMillis, [seg("大家理解我的意思吧", 0, 4_000)]),
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            ))
            segments = r.segments

            check("相隔 > 一个窗口：新增一段（不并成一段）",
                  segments.count == 2, "段数 \(segments.count)")
            check("旧段文本原样不动",
                  segments[0].text == oldText, segments[0].text)
            check("旧段起止时间原样不动",
                  segments[0].startTimeMillis == oldRange.0 && segments[0].endTimeMillis == oldRange.1,
                  "\(segments[0].startTimeMillis)–\(segments[0].endTimeMillis)（期望 \(oldRange.0)–\(oldRange.1)）")
        }

        // MARK: 用例 13：不变式——滑过若干窗口后没有段永久停在临时
        do {
            var pendingTail: [WhisperSegment] = []
            var previousStart = 0
            var segments: [TranscriptSegment] = []

            // 每窗吐同样的两句：长句跨过阈值（走稳定性判据），两段都落在可覆盖区
            for k in 0..<3 {
                let w = window(k * stepMillis, windowMillis, [
                    seg("今天讲梯度下降算法", 0, 4_000),
                    seg("它的核心思想是沿着负梯度方向迭代", 4_000, 8_000),
                ])
                let r = merge(WhisperMergeInput(
                    existing: segments, window: w,
                    previousTail: pendingTail, previousWindowStartMillis: previousStart,
                    stepMillis: stepMillis
                ))
                segments = r.segments; pendingTail = r.pendingTail; previousStart = w.startMillis
            }

            // 再滑一个静音窗：让「最后一个窗口吐出的段」也滑出可覆盖范围
            segments = merge(WhisperMergeInput(
                existing: segments,
                window: window(3 * stepMillis, windowMillis, []),
                previousTail: pendingTail, previousWindowStartMillis: previousStart,
                stepMillis: stepMillis
            )).segments

            let stuck = segments.filter { !$0.isFinal }
            check("全部段都已定稿（没有永久停在临时的段）",
                  stuck.isEmpty,
                  "仍临时 \(stuck.count) 段：\(stuck.map(\.text).joined(separator: " / "))")
            check("同一句反复出现不产生重复段", segments.count == 2, "段数 \(segments.count)")
        }

        // MARK: 用例 14：第二趟的距离是「区间距离」——重叠不因错位而被当成很远
        //
        // 2026-09-22（阶段 1.7）。这是探针 D1 抓到的形状（三种子多出的 7 段全是它）：
        // 同一句在相邻窗口被重识别成差一个虚词的一版，候选起点落在旧段**内部**，
        // 旧段已定稿。改动前第二趟算的是「起点减终点」= 负数 = 重叠深度，1500 > 1000
        // 直接拒绝，于是同一句被拆成两段。
        do {
            let oldText = "今天我们讲梯度下降算法呢"
            let newText = "今天我们讲梯度下降算法的"

            func trial(_ candidateStart: Int) -> [TranscriptSegment] {
                let existing = [
                    TranscriptSegment(text: oldText, isFinal: true, startTimeMillis: 20_000,
                                      endTimeMillis: 22_500, languages: ["zh-CN"])
                ]
                return merge(WhisperMergeInput(
                    existing: existing,
                    window: window(candidateStart, windowMillis,
                                   [seg(newText, 0, 600)]),
                    previousTail: [], previousWindowStartMillis: 0, stepMillis: stepMillis
                )).segments
            }

            // 重叠：候选起点 21000 落在旧段 [20000,22500] 内部，重叠 1500ms（区间距离 0）
            let overlapping = trial(21_000)
            check("第二趟：similar 且区间距离 0（重叠 1500ms）→ 合并为一段，不拆成两段",
                  overlapping.count == 1, "段数 \(overlapping.count)")
            check("合并后留下的是重识别那一版文本与时间戳",
                  overlapping.count == 1 && overlapping[0].text == newText
                  && overlapping[0].startTimeMillis == 21_000 && overlapping[0].endTimeMillis == 21_600,
                  overlapping[0].formattedTimestamp + " " + overlapping[0].text)

            // 反面对照：真正相隔 1500ms（不重叠）——容差仍是 1 秒，不许合并。
            // 这一条是防「顺便把容差也放大」的：改距离定义 ≠ 放宽容差。
            let apart = trial(24_000)
            check("第二趟：真间隔 1500ms > 容差 1 秒 → 各自成段（容差没有被放大）",
                  apart.count == 2 && apart[0].text == oldText
                  && apart[0].startTimeMillis == 20_000 && apart[0].endTimeMillis == 22_500,
                  "段数 \(apart.count) · 首段 \(apart[0].formattedTimestamp) \(apart[0].text)")
        }

        // MARK: 用例 15：第三趟的文本守卫——候选的文本归属在别处时，不许按时间改写
        //
        // 2026-09-22（阶段 1.7）。探针 D2 抓到的破坏路径：候选的文本与一个**远**段
        // （.same，但超了第一趟的上界 → 正确拒绝）相同，同时又与一个**近**段时间重叠
        // （different 文本、未定稿）。改动前第三趟按时间改写近段，把它的整句原文覆盖掉。
        do {
            let farText = "正则化可以防止过拟合"
            let nearText = "训练集和测试集要分开"
            let candidateText = "正则化可以防止过拟合的"

            let existing = [
                TranscriptSegment(text: farText, isFinal: true, startTimeMillis: 30_000,
                                  endTimeMillis: 33_000, languages: ["zh-CN"]),
                TranscriptSegment(text: nearText, isFinal: false, startTimeMillis: 44_500,
                                  endTimeMillis: 46_500, languages: ["zh-CN"]),
            ]
            let r = merge(WhisperMergeInput(
                existing: existing,
                // 候选全局 [44000,47000]：与近段重叠，与远段文本同句但相隔 11000ms
                window: window(43_000, windowMillis, [seg(candidateText, 1_000, 4_000)]),
                previousTail: [], previousWindowStartMillis: 0, stepMillis: stepMillis
            ))
            let segments = r.segments

            check("守卫触发时候选新增一段（不改写时间重叠的那段）",
                  segments.count == 3 && segments[2].text == candidateText,
                  "段数 \(segments.count)")
            check("时间重叠那段的文本 · 起止 · isFinal 全部原样不动",
                  segments[1].text == nearText
                  && segments[1].startTimeMillis == 44_500 && segments[1].endTimeMillis == 46_500
                  && !segments[1].isFinal,
                  "\(segments[1].formattedTimestamp) \(segments[1].text)")
            check("也没有并进远处那个文本双胞胎（不搬时间戳）",
                  segments[0].text == farText && segments[0].startTimeMillis == 30_000
                  && segments[0].endTimeMillis == 33_000,
                  "\(segments[0].formattedTimestamp) \(segments[0].text)")
            check("守卫触发在 changes 里有区别于普通「新增」的标签",
                  r.changes.contains { $0.hasPrefix("新增（文本归属在别处") },
                  r.changes.joined(separator: " / "))
        }

        lines.append(allPassed ? "✅ Whisper 滑窗合并自检通过" : "❌ Whisper 滑窗合并自检未通过")
        return lines
    }
}
