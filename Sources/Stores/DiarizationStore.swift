import Foundation
import Observation

/// 说话人识别的界面状态：跑一次、记进度、落盘。**按会话 id 分开存**，同 `StudyNotesStore`。
///
/// 三条闸都在这里，缺一条都会出看得见的坏事：
///   · **只能手动触发**：这个类型里**没有** `autoRunIfNeeded`。6a 的课后笔记有一条
///     「录完自动跑一次」，这一包刻意没有——拍板第 2 条把「花钱/耗时的动作默认
///     不自动发生」定成了原则，而识别要跑十几秒到一分多钟、还占满 CPU；
///   · **同一会话不许并发跑两次**：两个 helper 进程同时读同一批 wav、又各自把
///     结果写回同一条会话，谁最后写的完全不确定（1400 那条教训）；
///   · **只在成功时落盘**：失败一个字都不写，见 `run` 里的注释。
///
/// 这一层**不自己写文件**：落盘走注入的 `save`，生产路径就是
/// `RecordingsStore.save`（`.atomic`，先写临时文件再替换）。自己再写一份
/// 文件写入等于把「原子」这件事实现两遍，而其中一遍没人验过
@MainActor
@Observable
final class DiarizationStore {

    /// 跑一次。**做成参数而不是直接调服务**：这一层真正的内容是那三条闸，
    /// 而它们只有在「跑」这步可控的时候才测得出来（同 `StudyNotesStore.Generate`）。
    ///
    /// **签名上带 `@MainActor`**：调用点全在主 actor 上（View 的按钮闭包、
    /// 自检），而 helper 那段长活儿在 `SpeakerDiarizationService` 里自己下
    /// 非主 actor 去等子进程——这里不需要、也不该额外放开一个并发入口
    typealias Run = @MainActor (RecordingSession) async -> DiarizationEvaluation
    /// 落盘。生产路径是 `RecordingsStore.save`（`@MainActor`，所以这里必须是
    /// `@MainActor` 闭包，否则那一句根本编译不过）
    typealias Save = @MainActor (RecordingSession) -> Void

    private(set) var progress: [UUID: DiarizationProgress] = [:]
    private(set) var errors: [UUID: String] = [:]
    /// 刚跑完那一次的统计。**只在内存里**，给验收报告和调试看；
    /// 界面要显示的「说话人数 / 标注率」从段落字段现算（见 `DiarizationLabelSummary`），
    /// 因为那个关掉 App 还在，而这个不在
    private(set) var lastStats: [UUID: DiarizationStats] = [:]

    /// 刚落盘的那份会话（按 id）。**「已跑过」那一档在内存里的真相来源**。
    ///
    /// 为什么留一份、而不是让界面去 `RecordingsStore` 拿新的 `session`：
    /// 那条链是「写盘 → `cache` 失效 → 父视图重绘 → 新的 `session` 传进详情页」。
    /// 中间任何一环没发生（SwiftUI 这次没重绘、父视图没重建），面板就停在上一次
    /// 那一档——**用户点了识别、跑成功了，界面还写着「还没有说话人标签」**，
    /// 而磁盘上明明已经有了。存在这里，面板就靠 store 自己的 `@Observable`
    /// 变化刷新，不欠任何人一次重绘。
    ///
    /// **一个已知的窟窿（不是这一包引入的）**：`RecordingsStore.save` 把写盘
    /// 失败吞进 `statusMessage` 并返回 Void，这里无从知道。所以磁盘真写失败时，
    /// 面板会显示「已跑过」而重启后没有——那时列表页上有一条 ❌ 保存失败的提示。
    /// 修它要动 `save` 的签名，超出这一包的范围
    private(set) var lastSaved: [UUID: RecordingSession] = [:]

    /// 正在跑的会话。**并发闸就在这里**
    private var running: Set<UUID> = []

    private let runHook: Run
    private let saveHook: Save
    private let helperPresentHook: () -> Bool

    init(
        save: @escaping Save,
        run: @escaping Run = DiarizationStore.liveRun,
        helperPresent: @escaping () -> Bool = { DiarizeHelperLocator.locate() != nil }
    ) {
        self.saveHook = save
        self.runHook = run
        self.helperPresentHook = helperPresent
    }

    /// 生产那条路：模型首跑就位 → 找 helper → 跑。
    ///
    /// **模型就位放在这里，不放在进详情页时**：`provision()` 在稳态下是
    /// 「什么都不动」，但它毕竟要碰一次用户的模型目录，而真正需要它的时刻
    /// 只有「用户点了识别」这一个
    @MainActor
    static let liveRun: Run = { session in
        // 模型不在就直接返回，**不启动进程**：起 helper 只会拿到一个必然失败的
        // 退出码（5），而这里已经知道原因、也说得更准（`provision` 连去哪儿找过
        // 都写在 reason 里）。这条是「模型缺失要说清原因」的落点
        if case .unavailable(let reason) = SpeakerModelStore.provision() {
            return DiarizationEvaluation(
                session: session, diarization: nil,
                failure: DiarizationFailure(reason: .modelMissing, detail: reason),
                stats: DiarizationStats())
        }
        guard let helper = DiarizeHelperLocator.locate() else {
            return DiarizationEvaluation(
                session: session, diarization: nil,
                failure: DiarizationFailure(
                    reason: .helperMissing, detail: "app bundle 里没有 diarize-helper"),
                stats: DiarizationStats())
        }
        return await SpeakerDiarizationService.diarize(
            session: session, helper: helper, modelsDirectory: SpeakerModelStore.modelsDirectory
        ).evaluation
    }

    // MARK: - 读

    /// 交给纯函数算该显示哪一档。View 里**不做任何 if/else 判断**
    /// （见 `DiarizationPanelState` 的注释：散进 View 就没法离线自检）
    func state(session: RecordingSession) -> DiarizationPanelState {
        DiarizationPanelState(
            // 「有没有音频」的判据**复用服务层那一个**，不在这里再写一遍
            // 「每个 part 都有 fileName」：两处实现早晚会不一致，那时表现是
            // 「按钮能点，点下去必然失败」
            hasAudio: SpeakerDiarizationService.inputs(of: session) != nil,
            helperPresent: helperPresentHook(),
            // 落过盘就用落盘的那一份（见 `lastSaved` 的注释）：调用方传进来的
            // `session` 可能是跑之前抓的快照，而标签是跑完才写上去的
            session: lastSaved[session.id] ?? session,
            progress: progress[session.id],
            error: errors[session.id]
        )
    }

    // MARK: - 跑

    /// 跑一次并把标签落盘。
    ///
    /// **只由「用户点了按钮」那条路调用**——拍板第 2 条。这个类型里没有
    /// 任何自动触发点，`run` 的调用方在 View 的按钮闭包里，只有那一处。
    ///
    /// 返回 `false` = 这一次没跑（该会话已经在跑）。**不做界面提示**：
    /// 「已经在跑」不是失败，用户看到的是进度条还在动
    @discardableResult
    func run(session: RecordingSession) async -> Bool {
        let id = session.id
        guard !running.contains(id) else { return false }

        running.insert(id)
        errors[id] = nil
        progress[id] = DiarizationProgress(
            startedAt: Date(), audioSeconds: Double(session.durationMillis) / 1000
        )
        defer {
            running.remove(id)
            progress[id] = nil
        }

        let evaluation = await runHook(session)

        guard let failure = evaluation.failure else {
            // **只在成功时落盘。** 失败时一个字都不写——`evaluate` 的失败路径会把
            // 三个字段清空，而「清空」也是一次写：那条会话上可能已经有上一轮跑出来的
            // 好标签，为一次失败把它们抹掉，正是本项目最忌讳的失败形状（静默的破坏性
            // 副作用）。界面那边 `phase == .failed` 压过「已跑过」，用户照样看得见
            // 这次失败了，而且旧标签还在下面显示着
            saveHook(evaluation.session)
            lastSaved[id] = evaluation.session
            lastStats[id] = evaluation.stats
            DiagnosticLog.info(.diarization, "说话人识别完成", fields: [
                .init("sessionId", id),
                .init("helper 耗时", String(format: "%.1fs", evaluation.stats.helperWallSeconds)),
                .init("说话人", evaluation.stats.speakerCount),
                .init("标注段", evaluation.stats.labeled),
            ])
            return true
        }

        // 界面只给 `userMessage` 那一句（说清下一步）；`detail` 是给日志和
        // 验收报告用的，不往界面上放
        errors[id] = failure.reason.userMessage

        // 记在这里而不是 `SpeakerDiarizationService.evaluate` 里：那个函数
        // 立过「无 IO」的规矩（自检直接喂构造好的 `DiarizeHelperRun`），
        // 在里面写日志等于把它变成有副作用的函数。这里是**同一份失败第一次
        // 离开内存的地方**，而且 `reason` 正是 `helperExitCode` 映射出来的
        // 那一档——退出码丢了，但「映射到了哪一档」才是要查的东西
        // （退出码本身在 `detail` 里，它由服务层拼进去）
        DiagnosticLog.error(.diarization, "说话人识别失败", fields: [
            .init("sessionId", id),
            .init("原因", failure.reason.label),
            .init("详情", failure.detail),
        ])
        return true
    }
}

// MARK: - 离线自检

extension DiarizationStore {

    struct SelfTestResult {
        var lines: [String] = []
        var passed: Int = 0
        var failed: Int = 0
    }

    /// 打桩的「跑一次」。`Run` 是 `@MainActor` 闭包、调用点也全在主 actor 上，
    /// 所以这个类不需要锁（`StudyNotesStore` 那边的 stub 要锁，是因为它的钩子
    /// 是 `@Sendable`、会真的跑到别的线程上）
    @MainActor
    private final class StubRunner {
        var callCount = 0
        var evaluation: DiarizationEvaluation

        init(_ evaluation: DiarizationEvaluation) { self.evaluation = evaluation }

        /// **必须真的挂起一下，否则打桩的「跑一次」是在骗并发闸那几条断言。**
        ///
        /// 真实的 `liveRun` 会在 `DiarizeHelperRunner.run` 里挂起十几秒
        /// （子进程在全局队列上跑，见那边的 `withCheckedContinuation`），
        /// 而这正是并发闸能起作用的前提：第一次调用插进 `running` 之后**让出
        /// 主 actor**，第二次才有机会在闸上被拦下。
        ///
        /// 2026-09-28 实测：不加这一句时两次调用**各跑完整条、一次都不挂起**，
        /// 「并发闸」三条断言全红（`[true, true]` / 跑了 2 次 / 落盘 2 次）
        /// ——不是闸坏了，是这个桩把闸要防的那个交错整个消掉了。
        /// 一个不挂起的桩测不出任何并发闸
        func call(_ session: RecordingSession) async -> DiarizationEvaluation {
            callCount += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            return evaluation
        }
    }

    /// `--diarize-ui-selftest` 的第二组。
    ///
    /// **离线**：helper 那一步是打桩的，不起进程、不加载模型、不碰音频、不发声、
    /// 不写盘（`save` 也是打桩的）。真实的 sessions/ 一个字节都不碰。
    ///
    /// **`async` 是必需的、不是风格问题**：`run` 要 `await`，而在主 actor 上
    /// 用信号量阻塞着等，等的那件事本身正要回主 actor —— 直接死锁。
    /// 这个坑本项目在阶段 2 踩过，`App.swift` 里那条注释就是它留下的
    @MainActor
    static func selfTest() async -> SelfTestResult {
        var r = SelfTestResult()
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { r.passed += 1; r.lines.append("  ✅ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
            else { r.failed += 1; r.lines.append("  ❌ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
        }

        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let partID = UUID()

        func segment(_ start: Int, _ end: Int, _ text: String = "t") -> TranscriptSegment {
            TranscriptSegment(
                text: text, isFinal: true,
                startTimeMillis: start, endTimeMillis: end,
                timestamp: stamp, languages: ["zh-CN"]
            )
        }

        func session(_ segments: [TranscriptSegment], fileName: String? = "a.wav") -> RecordingSession {
            RecordingSession(
                id: UUID(), startedAt: stamp, updatedAt: stamp,
                parts: [RecordingPart(
                    id: partID, fileName: fileName, startedAt: stamp,
                    durationMillis: 120_000, offsetMillis: 0, segments: segments
                )]
            )
        }

        /// 把 3 个说话人字段抹掉。用来断言「落盘只动了这 3 个」——
        /// 抹掉之后两份 session 必须**逐字段相等**，那覆盖了文本、时间、
        /// `qualityGrade`、`questionLevel`、`languages`…… 全部
        func strippingSpeakerFields(_ s: RecordingSession) -> RecordingSession {
            var copy = s
            for p in copy.parts.indices {
                for i in copy.parts[p].segments.indices {
                    copy.parts[p].segments[i].speakerId = nil
                    copy.parts[p].segments[i].speakerOverlapRatio = nil
                    copy.parts[p].segments[i].speakerMixed = false
                }
            }
            return copy
        }

        // 夹具会话：第一段被 diar 完整覆盖（会标上），第二段**没有任何 diar 覆盖**
        // （＝低置信那一类，必须保持 nil）
        let input = session([segment(0, 4_000, "被覆盖的那段"), segment(60_000, 64_000, "没人覆盖的那段")])
        let diarization = SpeakerDiarization(
            schemaVersion: 1, helperBuild: "stub", ranAt: stamp,
            audioSeconds: 120, speakerCount: 1, speakerOrder: ["raw"],
            segments: [SpeakerSpan(speakerId: "raw", startMillis: 0, endMillis: 30_000, qualityScore: 0.9)],
            partFingerprint: "stub"
        )
        let (materialized, stats) = SpeakerDiarizationService.materialize(
            session: input, diarization: diarization)
        let successEval = DiarizationEvaluation(
            session: materialized, diarization: diarization, failure: nil, stats: stats)
        let failureEval = DiarizationEvaluation(
            session: input, diarization: nil,
            failure: DiarizationFailure(reason: .timeout, detail: "helper 超过 300 秒被终止"),
            stats: DiarizationStats())

        // ① 正常跑：落盘一次、内容只动了说话人字段、进度收干净
        var saved: [RecordingSession] = []
        let okStub = StubRunner(successEval)
        let okStore = DiarizationStore(
            save: { saved.append($0) }, run: okStub.call, helperPresent: { true })
        let ran = await okStore.run(session: input)
        check(ran, "正常跑：这一次真的跑了")
        check(okStub.callCount == 1, "正常跑：只跑了一次", "跑了 \(okStub.callCount) 次")
        check(saved.count == 1, "正常跑：落盘被调了一次", "调了 \(saved.count) 次")
        if let written = saved.first {
            check(strippingSpeakerFields(written) == input,
                  "正常跑：落盘的会话**只动了说话人那 3 个字段**（文本/时间/其余全等）")
            check(written.parts[0].segments[0].speakerId == "S1",
                  "正常跑：被覆盖的段标上了 S1",
                  written.parts[0].segments[0].speakerId ?? "（nil）")
            check(written.parts[0].segments[1].speakerId == nil,
                  "低置信不显示：没人覆盖的那段**没有标签**（不是回退到 S1）",
                  written.parts[0].segments[1].speakerId ?? "（nil）")
            check(written.parts[0].segments[1].speakerOverlapRatio == nil,
                  "低置信不显示：没标时覆盖率是 nil，不是 0（0 是个合法读数）",
                  written.parts[0].segments[1].speakerOverlapRatio.map { "\($0)" } ?? "（nil）")
        }
        check(okStore.progress[input.id] == nil, "正常跑：跑完之后进度清空（不该一直转圈）")
        check(okStore.errors[input.id] == nil, "正常跑：没有错误")
        // **故意拿跑之前那份 `input` 去问**：详情页手上的就是跑之前抓的快照，
        // 而标签是跑完才写上去的。store 必须自己记得刚落盘的那一份
        // （见 `lastSaved` 的注释），不能指望调用方换一份新的递进来
        check(okStore.state(session: input).phase == .ready,
              "正常跑：档位变成「已跑过」（拿跑之前那份 session 问也是 ready）",
              "\(okStore.state(session: input).phase)")
        check(okStore.state(session: input).labels?.labeled == 1,
              "正常跑：面板上的标注数来自落盘那一份，不是跑之前的",
              "\(okStore.state(session: input).labels?.labeled ?? -1)")
        check(okStore.lastStats[input.id]?.labeled == 1,
              "正常跑：统计里标注数是 1", "\(okStore.lastStats[input.id]?.labeled ?? -1)")

        // ② 同一会话并发跑两次 → 只有一次真的跑（1400 那条教训：同一资源两个写者）
        var raceSaved: [RecordingSession] = []
        let raceStub = StubRunner(successEval)
        let raceStore = DiarizationStore(
            save: { raceSaved.append($0) }, run: raceStub.call, helperPresent: { true })
        // 同一个 id 的另一份实例：并发闸认的是 id，不是对象身份
        let other = RecordingSession(
            id: input.id, startedAt: input.startedAt, updatedAt: input.updatedAt, parts: input.parts)
        async let first = raceStore.run(session: input)
        async let second = raceStore.run(session: other)
        let results = await [first, second]
        check(results.filter { $0 }.count == 1,
              "并发闸：同一会话同时调两次，只有一次真的跑", "两次的返回：\(results)")
        check(raceStub.callCount == 1,
              "并发闸：只跑了一次（第二次没起第二个 helper 进程）", "跑了 \(raceStub.callCount) 次")
        check(raceSaved.count == 1, "并发闸：也只落盘一次（不会两个写者互相覆盖）",
              "落盘 \(raceSaved.count) 次")

        // ③ 失败：**一个字都不落盘**，错误要看得见
        var failSaved: [RecordingSession] = []
        let failStub = StubRunner(failureEval)
        let failStore = DiarizationStore(
            save: { failSaved.append($0) }, run: failStub.call, helperPresent: { true })
        _ = await failStore.run(session: input)
        check(failSaved.isEmpty,
              "失败：**一次都没落盘**（旧标签不会被一次失败抹掉）", "落盘 \(failSaved.count) 次")
        check(failStore.errors[input.id] != nil,
              "失败：错误记下来了（详情页要显示它）", failStore.errors[input.id] ?? "（居然是 nil）")
        check(failStore.state(session: input).phase
                == .failed(message: failStore.errors[input.id] ?? ""),
              "失败：档位变成「失败」", "\(failStore.state(session: input).phase)")
        check(failStore.progress[input.id] == nil, "失败：进度也要收干净")

        // ④ 失败时**已标过的会话**：错误可见，但旧标签仍在（不落盘 ⇒ 磁盘上那份没动）
        let alreadyLabeled = materialized
        let failAgain = DiarizationStore(
            save: { _ in }, run: StubRunner(failureEval).call, helperPresent: { true })
        _ = await failAgain.run(session: alreadyLabeled)
        let failState = failAgain.state(session: alreadyLabeled)
        check(failState.phase == .failed(message: failAgain.errors[alreadyLabeled.id] ?? ""),
              "边界·重跑失败且已标过：错误看得见", "\(failState.phase)")
        check(failState.labels?.speakerCount == 1,
              "边界·重跑失败且已标过：旧标签继续显示（没被清掉）",
              "\(failState.labels?.speakerCount ?? -1) 人")

        // ⑤ 没有音频存档：按钮禁用的判据来自服务层那一份 `inputs(of:)`
        let noAudio = session([segment(0, 1_000)], fileName: nil)
        let quietStore = DiarizationStore(
            save: { _ in }, run: StubRunner(successEval).call, helperPresent: { true })
        check(!quietStore.state(session: noAudio).canRun,
              "无音频：按钮点不动")
        check(quietStore.state(session: noAudio).runDisabledReason
                == DiarizationPanelState.noAudioReason,
              "无音频：禁用原因是音频那条",
              quietStore.state(session: noAudio).runDisabledReason ?? "（nil）")

        // ⑥ helper 缺失：按钮禁用的判据来自注入的那一个查询
        let noHelperStore = DiarizationStore(
            save: { _ in }, run: StubRunner(successEval).call, helperPresent: { false })
        check(!noHelperStore.state(session: input).canRun, "缺 helper：按钮点不动")
        check(noHelperStore.state(session: input).runDisabledReason
                == DiarizationPanelState.noHelperReason,
              "缺 helper：禁用原因是 helper 那条",
              noHelperStore.state(session: input).runDisabledReason ?? "（nil）")

        // ⑦ **这个类型里没有自动触发点**——拍板第 2 条。
        // 断言方式是「没有可调的东西」：能跑的路只有 `run`，而它只被 View 的
        // 按钮闭包调用。这里钉住的是它的**前置条件**：没有 pending 的 Task、
        // 没有计时器——构造完之后立刻看，什么都没发生
        let idleStub = StubRunner(successEval)
        _ = DiarizationStore(save: { _ in }, run: idleStub.call, helperPresent: { true })
        check(idleStub.callCount == 0,
              "手动触发：只是建了一个 store，**一次都没跑**（没有自动触发）",
              "跑了 \(idleStub.callCount) 次")

        return r
    }
}
