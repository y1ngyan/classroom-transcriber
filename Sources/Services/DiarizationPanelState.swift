import Foundation

// MARK: - 跑一次要多久

/// 一次说话人识别跑到第几秒了。
///
/// **为什么是按时间报进度、不是「第 2/7 片」**：helper 是**一个进程吃整节课**
/// （拍板第 1 条），一次把所有片段喂完才出结果，中途没有任何可以报的进度点。
/// 照着课后笔记那个 `StudyNotesProgress` 编一个「第 2/7 片」出来是**编的**——
/// 那七片是那边真有分片，这里没有。所以这里只报两件真事：已经等了多久，
/// 以及通常要多久。
struct DiarizationProgress: Equatable, Sendable {
    var startedAt: Date
    /// 这节课的音频总长（秒）。只用来把说明写成本节课的，**不参与估算**
    var audioSeconds: Double

    /// 派单给的量级：**helper 会跑 10–70 秒**（C-3-2 派单 §1）。
    /// 两端对应 C-1 实测的两头：纯计算最慢 98.6× 实时（45 分钟音频约 27 秒），
    /// 模型首次加载/编译 66.4 秒（见 `DiarizeTimeoutPolicy` 的注释）。
    ///
    /// **不按音频长度缩成一个「预计 23 秒」**：缩出来是个看着精确的假数字，
    /// 而真实耗时主要由模型缓存状态决定（首跑 66 秒 vs 命中缓存几乎立刻），
    /// 跟这节音频多长关系不大
    static let typicalSeconds: ClosedRange<Int> = 10...70

    func elapsed(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// 界面上那一行。**必须明说可以离开这个页面**：十几秒到一分多钟，
    /// 不说的话用户会守着转圈；而这件事从头到尾在主 actor 之外跑，切走照样跑完
    func label(now: Date = Date()) -> String {
        "正在识别说话人：已用 \(Int(elapsed(now: now))) 秒"
            + "（这节课 \(Self.durationText(audioSeconds))，通常 "
            + "\(Self.typicalSeconds.lowerBound)–\(Self.typicalSeconds.upperBound) 秒，"
            + "模型首次加载会更久。可以离开这个页面，跑完回来就能看到）"
    }

    static func durationText(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds)) / 60
        return minutes >= 1 ? "\(minutes) 分钟" : "不到 1 分钟"
    }
}

// MARK: - 已落盘的标签摘要

/// 一条会话**已经落盘的**说话人标签摘要。
///
/// 这是「已跑过」那一档**唯一**的数据来源：`RecordingSession` 上**没有**
/// `diarization` 字段（C-3-2 明确「别加字段」），标签就是 `TranscriptSegment`
/// 上那 3 个字段本身。所以 `speakerCount` 是「界面上真的会出现几个说话人」，
/// **不是** helper 报的那个数——两者可以不等（有人一段都没拿到），
/// 而用户能看见的是前者。
///
/// **用「有没有标签」判跑没跑过，不用「有没有错误记录」判**：错误记录活在内存里，
/// 关掉 App 就没了；标签在磁盘上，明天打开还在
struct DiarizationLabelSummary: Equatable {
    var speakerCount: Int
    var labeled: Int
    var total: Int

    var annotationRate: Double { total == 0 ? 0 : Double(labeled) / Double(total) }

    var rateText: String { String(format: "%.0f%%", annotationRate * 100) }

    /// 一个标签都没有 → `nil`（＝没跑过）
    init?(session: RecordingSession) {
        var speakers = Set<String>()
        var labeled = 0
        var total = 0
        for part in session.parts {
            for segment in part.segments {
                total += 1
                if let id = segment.speakerId, !id.isEmpty {
                    speakers.insert(id)
                    labeled += 1
                }
            }
        }
        guard labeled > 0 else { return nil }
        speakerCount = speakers.count
        self.labeled = labeled
        self.total = total
    }
}

// MARK: - 段级：显示不显示说话人

/// **「这一段显不显示说话人」的唯一判据**（拍板第 6 条：低置信不显示）。
///
/// `nil` = 不显示。判据就是 `speakerId == nil`：低置信（赢家占比不到一半）、
/// 反向段、零长段在**映射那一层**就已经是 nil（`SpeakerMapper.assign` +
/// `RecordingSession.absoluteRange`），界面这里**不再自己判一遍**——同一个判定
/// 写两份，两份早晚会不一致，那时界面上显示的和磁盘上存的就对不上了。
///
/// **`speakerMixed` 不进界面**：拍板第 6 条否掉的正是「显示多数派 + 小字『多人』」
/// 这个形状。它只进统计（`DiarizationStats.mixed`）。要让它上界面，先改拍板结论
enum SpeakerLabel {
    static func text(for segment: TranscriptSegment) -> String? {
        guard let id = segment.speakerId, !id.isEmpty else { return nil }
        return id
    }
}

// MARK: - 面板档位（纯函数）

/// 详情页那条「说话人」区块该显示哪一档。
///
/// **为什么抽成纯函数**：判断一旦自然长进 View 的 `if/else`，「跑不了的时候
/// 该说什么」就变成只能靠肉眼在真机上确认的事——而 View 是唯一没法离线自检的
/// 地方（`--diarize-ui-selftest` 碰不到它）。这里只做「输入 → 档位」的映射，
/// 不碰界面、不读全局状态、**不做任何 IO**：helper 在不在、有没有音频都由
/// 调用方查好传进来（同 `StudyNotesPanelState` 的 `hasKey`）
struct DiarizationPanelState: Equatable {

    enum Phase: Equatable {
        /// 跑不了：缺 helper，或这条录音没有音频存档。
        /// **具体是哪一种看 `runDisabledReason`**，那里必须是能给用户看的一句话
        case unavailable
        /// 跑得了，但还没跑过
        case empty
        case running
        /// 跑过：`labels` 里有东西
        case ready
        case failed(message: String)
    }

    var phase: Phase
    /// 已经落盘的标签摘要。**失败和重跑期间照样有值**——见 `init` 里第 2 条
    var labels: DiarizationLabelSummary?
    /// 跑/重跑按钮为什么点不动。`nil` = 能点。
    ///
    /// **只要禁用了就必须有原因**，不许出现「灰着但一个字不说」——
    /// 那正是用户 2026-09-24 报的「点导出没反应」的形状（见
    /// `StudyNotesPanelState.generateDisabledReason`）。自检里有一条不变量
    /// 专门穷举所有输入组合钉这件事
    var runDisabledReason: String?
    /// 已经标过、又要重跑时那句提示。`nil` = 没事要说
    var rerunNotice: String?

    var canRun: Bool { runDisabledReason == nil }

    /// 是不是失败那一档。`Phase` 带关联值，`phase == .failed` 写不出来，
    /// 而按钮的措辞要按它分成「重试」——**判据放在这里**，不让 View 去
    /// `if case .failed = ...`（那又是一处散在 View 里的状态判断）
    var hasFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// 没有音频存档时那一句。**说清下一步**（录音时「保存音频」没开），不是只说「不可用」。
    ///
    /// **引用服务层那一条的文案，不在这里另写一份**：同一句话存两份，改一处
    /// 就分叉，而分叉的表现是「按钮旁边写的原因」和「跑失败后写的原因」
    /// 不是同一句——用户看到两种说法，会以为遇到了两种毛病。2026-09-28 实测
    /// 两边逐字节相同，才合并成这一处
    static let noAudioReason = DiarizationFailureReason.noAudio.userMessage

    /// 缺 helper 时那一句。**写清楚去哪儿解决**：这是构建产物，不是配置项。
    /// 同样引用服务层，理由同上
    static let noHelperReason = DiarizationFailureReason.helperMissing.userMessage

    /// 输入 → 档位。**优先级是这里唯一的实质内容**，逐条都有理由：
    ///
    /// 1. **正在跑最高**：这一瞬间有一个确定的动作在跑，进度是用户最需要知道的，
    ///    压过「上次失败了」——上次的错误在重跑成功的瞬间就过期了；
    /// 2. **失败压过已标过**：否则失败了界面一切照旧，用户以为重跑成功、
    ///    看的还是旧标签（旧标签仍在下面显示，见 `labels`）；
    /// 3. **已标过压过跑不了**：标签已经落盘了，看它不需要 helper、也不需要音频
    ///    （录音被移走是常见事）。没 helper 只是「不能再重跑一次」，
    ///    不该连看都不让看——同 `StudyNotesPanelState` 第 3 条；
    /// 4. **跑不了压过没跑过**：「缺 helper」比「你还没点过」是更具体的信息，
    ///    而两者同时为真时用户要解决的是前者
    init(
        hasAudio: Bool,
        helperPresent: Bool,
        session: RecordingSession,
        progress: DiarizationProgress?,
        error: String?
    ) {
        labels = DiarizationLabelSummary(session: session)
        let hasLabels = labels != nil

        // 只看「在不在跑」，不绑它的值：档位判断只需要知道有这么一回事，
        // 写成 `if let` 会引入一个用不到的绑定（编译器那条 no-usage 告警
        // 就是基线之外多出来的东西）
        if progress != nil {
            phase = .running
        } else if let error {
            phase = .failed(message: error)
        } else if hasLabels {
            phase = .ready
        } else if !hasAudio || !helperPresent {
            phase = .unavailable
        } else {
            phase = .empty
        }

        // 原因的顺序：**先说这条录音自己的事，再说环境的事**。
        // 「没有音频存档」是这条录音独有的（换一条录音可能就有），
        // 「缺 helper」是整个 App 的（每条录音都没有）；两条同时成立时，
        // 用户手上这条录音缺音频是他更该先知道的那一件
        if !hasAudio {
            runDisabledReason = Self.noAudioReason
        } else if !helperPresent {
            runDisabledReason = Self.noHelperReason
        } else if phase == .running {
            runDisabledReason = "正在识别，等这一轮跑完再试"
        } else {
            runDisabledReason = nil
        }

        // **重跑的说法**：明说会重写什么、以及**不会动什么**。
        // 只说「重新识别」的话，用户没法判断他看过的转录文字会不会跟着变——
        // 而那正是他最怕丢的东西（实际不动，见 `DiarizationStore.run`：
        // 落盘只写那 3 个说话人字段）
        if let labels {
            rerunNotice = "重跑会按新的识别结果重写这 \(labels.labeled) 段的说话人标签"
                + "（转录文字和时间不动）"
        } else {
            rerunNotice = nil
        }
    }
}

// MARK: - 离线自检

extension DiarizationPanelState {

    struct SelfTestResult {
        var lines: [String] = []
        var passed = 0
        var failed = 0
    }

    /// `--diarize-ui-selftest` 的第一组。
    ///
    /// **离线**：不联网、不加载模型、不碰音频、不发声、不写盘——这里测的是
    /// 「输入 → 该显示哪一档」的映射，一次 helper 调用都不该发生
    static func selfTest() -> SelfTestResult {
        var r = SelfTestResult()
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { r.passed += 1; r.lines.append("  ✅ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
            else { r.failed += 1; r.lines.append("  ❌ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
        }

        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let partID = UUID()

        func segment(_ start: Int, _ end: Int, speaker: String? = nil) -> TranscriptSegment {
            var s = TranscriptSegment(
                text: "t", isFinal: true,
                startTimeMillis: start, endTimeMillis: end,
                timestamp: stamp, languages: ["zh-CN"]
            )
            s.speakerId = speaker
            return s
        }

        func session(_ segments: [TranscriptSegment]) -> RecordingSession {
            RecordingSession(
                id: UUID(), startedAt: stamp, updatedAt: stamp,
                parts: [RecordingPart(
                    id: partID, fileName: "a.wav", startedAt: stamp,
                    durationMillis: 120_000, offsetMillis: 0, segments: segments
                )]
            )
        }

        // 没跑过的会话：一段标签都没有
        let fresh = session([segment(0, 2_000), segment(3_000, 5_000)])
        // 跑过的会话：三段里两段有标签，一个人
        let labeled = session([
            segment(0, 2_000, speaker: "S1"),
            segment(3_000, 5_000, speaker: "S1"),
            segment(6_000, 8_000),
        ])
        // 跑过、两个说话人
        let twoSpeakers = session([
            segment(0, 2_000, speaker: "S1"),
            segment(3_000, 5_000, speaker: "S2"),
        ])

        let progress = DiarizationProgress(startedAt: Date(), audioSeconds: 1_980)

        // ① 四档各一例 + 「跑不了」那一档
        let empty = DiarizationPanelState(
            hasAudio: true, helperPresent: true, session: fresh, progress: nil, error: nil)
        check(empty.phase == .empty, "没跑过：显示「识别说话人」那一档", "\(empty.phase)")
        check(empty.canRun, "没跑过：按钮能点")
        check(empty.rerunNotice == nil, "没跑过：不说重跑那句（没有旧标签可重写）")

        let running = DiarizationPanelState(
            hasAudio: true, helperPresent: true, session: fresh, progress: progress, error: nil)
        check(running.phase == .running, "正在跑：显示进度那一档", "\(running.phase)")
        check(!running.canRun, "正在跑：按钮点不动")
        check(running.runDisabledReason != nil, "正在跑：禁用带原因",
              running.runDisabledReason ?? "（居然是 nil）")

        let ready = DiarizationPanelState(
            hasAudio: true, helperPresent: true, session: labeled, progress: nil, error: nil)
        check(ready.phase == .ready, "已跑过：显示结果那一档", "\(ready.phase)")
        check(ready.canRun, "已跑过：还能重跑（拍板：标过的会话允许重跑）")
        check(ready.labels?.speakerCount == 1 && ready.labels?.labeled == 2
                && ready.labels?.total == 3,
              "已跑过：说话人数与标注数从**段落字段**现算",
              "\(ready.labels?.speakerCount ?? -1) 人 · \(ready.labels?.labeled ?? -1)/\(ready.labels?.total ?? -1)")
        check(ready.labels?.rateText == "67%",
              "已跑过：标注率", ready.labels?.rateText ?? "（nil）")
        check(ready.rerunNotice != nil, "已跑过：重跑要有可见提示",
              ready.rerunNotice ?? "（居然是 nil）")
        check((ready.rerunNotice ?? "").contains("不动"),
              "已跑过：提示里说清**不会动什么**（转录文字和时间）",
              ready.rerunNotice ?? "")

        let failed = DiarizationPanelState(
            hasAudio: true, helperPresent: true, session: fresh, progress: nil,
            error: "说话人模型不在 App 的模型目录里。跑一次 diarize-helper download 把它下下来")
        check(failed.phase == .failed(message: "说话人模型不在 App 的模型目录里。跑一次 diarize-helper download 把它下下来"),
              "失败：显示原因那一档", "\(failed.phase)")
        check(failed.canRun, "失败：还能重试")

        let unavailable = DiarizationPanelState(
            hasAudio: true, helperPresent: false, session: fresh, progress: nil, error: nil)
        check(unavailable.phase == .unavailable, "缺 helper：单独一档", "\(unavailable.phase)")
        check(unavailable.runDisabledReason == noHelperReason, "缺 helper：禁用且带原因",
              unavailable.runDisabledReason ?? "（居然是 nil）")
        check((unavailable.runDisabledReason ?? "").contains("build.sh"),
              "缺 helper：说清怎么解决（这是构建产物，不是配置项）",
              unavailable.runDisabledReason ?? "")

        let noAudio = DiarizationPanelState(
            hasAudio: false, helperPresent: true, session: fresh, progress: nil, error: nil)
        check(noAudio.phase == .unavailable, "没音频：单独一档", "\(noAudio.phase)")
        check(noAudio.runDisabledReason == noAudioReason, "没音频：禁用且带原因",
              noAudio.runDisabledReason ?? "（居然是 nil）")
        check(noAudio.runDisabledReason != noHelperReason,
              "没音频 vs 缺 helper：两条原因**不是同一句**（否则用户不知道该修哪一件）")
        check((noAudio.runDisabledReason ?? "").contains("保存音频"),
              "没音频：说清这件事的来由（录音时没开保存音频）",
              noAudio.runDisabledReason ?? "")

        let bothMissing = DiarizationPanelState(
            hasAudio: false, helperPresent: false, session: fresh, progress: nil, error: nil)
        check(bothMissing.runDisabledReason == noAudioReason,
              "没音频 + 缺 helper：先说这条录音自己的那件事",
              bothMissing.runDisabledReason ?? "")

        // ② 边界：失败**且已经标过**——旧标签不许被拿掉（同 StudyNotesPanelState 第 2 条）
        let failedWithLabels = DiarizationPanelState(
            hasAudio: true, helperPresent: true, session: labeled, progress: nil,
            error: "说话人识别超时了（录音太长或机器太忙），可以重试")
        check(failedWithLabels.phase == .failed(message: "说话人识别超时了（录音太长或机器太忙），可以重试"),
              "边界·失败且已标过：错误要看得见，不能被旧标签盖掉", "\(failedWithLabels.phase)")
        check(failedWithLabels.labels != nil,
              "边界·失败且已标过：旧标签继续显示（重跑失败不等于旧标签没了）")

        // ③ 边界：**已经标过但 helper 没了 / 音频没了**——仍然显示标签（优先级第 3 条）
        let labeledNoHelper = DiarizationPanelState(
            hasAudio: true, helperPresent: false, session: labeled, progress: nil, error: nil)
        check(labeledNoHelper.phase == .ready,
              "边界·已标过但缺 helper：仍然显示标签（优先级：已标过 > 跑不了）",
              "\(labeledNoHelper.phase)")
        check(!labeledNoHelper.canRun, "边界·已标过但缺 helper：重跑仍然点不动")
        check(labeledNoHelper.runDisabledReason == noHelperReason,
              "边界·已标过但缺 helper：禁用原因还是 helper 那条",
              labeledNoHelper.runDisabledReason ?? "")

        let labeledNoAudio = DiarizationPanelState(
            hasAudio: false, helperPresent: true, session: twoSpeakers, progress: nil, error: nil)
        check(labeledNoAudio.phase == .ready && labeledNoAudio.labels?.speakerCount == 2,
              "边界·已标过但音频没了：标签照样看得见，两个说话人",
              "\(labeledNoAudio.phase)")

        // ④ 边界：**正在跑且已经标过**——进度那一档，旧标签继续显示
        let rerunning = DiarizationPanelState(
            hasAudio: true, helperPresent: true, session: labeled, progress: progress, error: nil)
        check(rerunning.phase == .running,
              "边界·重跑且已标过：显示进度，不是「已跑过」", "\(rerunning.phase)")
        check(rerunning.labels != nil, "边界·重跑且已标过：旧标签继续显示（重跑没成功前不该把它拿走）")
        check(!rerunning.canRun, "边界·重跑且已标过：按钮禁用，不许并发跑第二次")

        // ⑤ 「禁用必须带原因」是个**不变量**，对全部输入成立。
        // 单点断言只能证明那几个点，这条扫一遍组合
        let allSessions = [("fresh", fresh), ("labeled", labeled), ("two", twoSpeakers)]
        var silentDisables: [String] = []
        for (sessionName, s) in allSessions {
            for hasAudio in [true, false] {
                for helperPresent in [true, false] {
                    for hasProgress in [true, false] {
                        for hasError in [true, false] {
                            let state = DiarizationPanelState(
                                hasAudio: hasAudio, helperPresent: helperPresent, session: s,
                                progress: hasProgress ? progress : nil,
                                error: hasError ? "失败" : nil
                            )
                            if !state.canRun, (state.runDisabledReason ?? "").isEmpty {
                                silentDisables.append(
                                    "\(sessionName) audio=\(hasAudio) helper=\(helperPresent)"
                                        + " progress=\(hasProgress) error=\(hasError)")
                            }
                        }
                    }
                }
            }
        }
        check(silentDisables.isEmpty,
              "不变量：48 种输入组合里没有一种「禁用了却不说为什么」",
              silentDisables.isEmpty ? "3 种会话 × 16 种组合全扫过"
                                     : silentDisables.joined(separator: " / "))

        // ⑥ 进度文案：秒数按传入的 now 算，量级与「可以离开这个页面」都要说
        let stamped = DiarizationProgress(
            startedAt: Date(timeIntervalSince1970: 1_000), audioSeconds: 1_980)
        let label = stamped.label(now: Date(timeIntervalSince1970: 1_012))
        check(label.contains("12 秒"), "进度文案：已用时按 now 算，不是存下来的", label)
        check(label.contains("33 分钟"), "进度文案：说清这节课多长", label)
        check(label.contains("10–70 秒"), "进度文案：给的是量级区间，不是一个假精确值", label)
        check(label.contains("可以离开"), "进度文案：明说可以离开这个页面", label)

        // ⑦ 段级显示判据（拍板第 6 条）
        check(SpeakerLabel.text(for: segment(0, 1_000, speaker: "S1")) == "S1",
              "显示：有标签的段显示它")
        check(SpeakerLabel.text(for: segment(0, 1_000)) == nil,
              "显示：低置信 / 没标的段**不显示**（拍板第 6 条）")
        check(SpeakerLabel.text(for: segment(0, 1_000, speaker: "")) == nil,
              "显示：空串标签当没标（不然那一行会多出一个空档）")

        return r
    }
}
