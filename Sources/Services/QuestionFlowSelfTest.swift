import Foundation

/// `--question-flow-selftest`：B 包**状态机 / 查询编排 / 元问题表 / 占位会话**
/// 的离线自检（派单验收第 2 条）。
///
/// 和 `--questions-selftest`（数据层地基）的分工：那件验「存下来之后怎么活」，
/// 这件验「点下去之后发生什么」。两件都离线：**不联网、不调模型、不读真实库、
/// 不碰麦克风、不发声**。查询编排用的是注入的桩闭包，不是真的 `SearchService`。
///
/// 每条判据都能红（写这个文件时手工注入过对应的反向改动，见提交说明）。
enum QuestionFlowSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// 同 `QuestionDataSelfTest.Checker`：`run()` 在 MainActor 上，局部函数
    /// 当非隔离闭包传出去在 Swift 6 里编不过，所以用一个小类承载计数
    final class Checker {
        private(set) var lines: [String] = []
        private(set) var passed = 0
        private(set) var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        func note(_ line: String = "") { lines.append(line) }
    }

    // MARK: - 入口

    @MainActor
    static func run() -> SelfTestResult {
        let c = Checker()
        c.note("提问流程自检（离线 · 桩网络 · 临时目录 · 不读真实库）")

        c.note("")
        c.note("─── 一、归一化（§6.2；≥8 条）───")
        checkNormalization(c)

        c.note("")
        c.note("─── 二、去重键命中 / 不命中（§6.3）───")
        checkDedupKey(c)

        c.note("")
        c.note("─── 三、状态机 5 状态允许 / 禁止转移（§5.2；≥10 条）───")
        checkStateMachine(c)

        c.note("")
        c.note("─── 四、前置闸门与文案（§6.5 / §2.3）───")
        checkGatesAndMessages(c)

        c.note("")
        c.note("─── 五、查询编排（桩检索 / 桩模型；来源只从 SearchHit 拷）───")
        checkAnswerService(c)

        c.note("")
        c.note("─── 六、元问题表与知识锚点（§7）───")
        checkMetaQuestionFilter(c)

        c.note("")
        c.note("─── 七、旧存档缺字段解码（§4.6）───")
        checkBackwardCompatibility(c)

        c.note("")
        c.note("─── 八、占位会话与无录音清理（拍板第 1 条）───")
        checkPlaceholder(c)

        c.note("")
        c.note(c.failed == 0
               ? "✅ 提问流程自检通过（\(c.passed) 条）"
               : "❌ 提问流程自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }

    // MARK: - 一、归一化

    private static func checkNormalization(_ c: Checker) {
        let n = LessonQuestion.normalizeForDedup
        func same(_ a: String, _ b: String, _ name: String) {
            c.check(n(a) == n(b), name, "（\(n(a)) / \(n(b))）")
        }
        func differ(_ a: String, _ b: String, _ name: String) {
            c.check(n(a) != n(b), name, "（\(n(a)) / \(n(b))）")
        }

        same("什么是梯度下降？", "什么是梯度下降?", "n1 全角问号折半角")
        same("What IS gradient descent?", "what is gradient descent", "n3 英文字母小写 + n4 去尾标点")
        same("什么是梯度下降呢", "什么是梯度下降", "n5 去尾随语气词「呢」")
        same("这是为什么呢吧", "这是为什么", "n5 连续去语气词")
        same("这是为什么 呢", "这是为什么", "n6 剥语气词后再去尾空白")
        same("什么是\u{3000}  梯度\n下降", "什么是 梯度 下降", "n2 全角空格/换行折叠")
        same("“梯度下降”是什么？", "\"梯度下降\"是什么", "n1 引号折半角 + n4 去尾标点")
        same("  什么是梯度下降  ", "什么是梯度下降", "n2 去首尾空白")
        differ("什么是梯度下降", "什么是梯度消失", "反例：近义词不合并（§6.1）")
        differ("什么是梯度下降", "什么是梯度下降，为什么能收敛", "反例：中间标点承载逻辑，不切句")
        differ("听懂了吗", "听懂了", "反例：「吗」不剥——它决定是不是问句")
    }

    // MARK: - 二、去重键

    private static func checkDedupKey(_ c: Checker) {
        var list: [LessonQuestion] = []
        let first = LessonQuestion(
            text: "什么是梯度下降", rawSentence: "什么是梯度下降？",
            startTimeMillis: 500, level: 2
        )
        let outcome1 = LessonQuestion.enqueue(first, into: &list)
        c.check(outcome1 == .appended && list.count == 1, "新问题入列")

        let variant = LessonQuestion(
            text: "什么是梯度下降呢", rawSentence: "什么是梯度下降呢",
            startTimeMillis: 900, level: 2
        )
        let outcome2 = LessonQuestion.enqueue(variant, into: &list)
        c.check(outcome2 == .merged(into: first.id), "去重键命中：同归一化文本合并到同一行")
        c.check(list.count == 1 && list[0].askedCount == 2, "合并后条目 1 条、askedCount=2",
                "（条目 \(list.count) / 次数 \(list[0].askedCount)）")
        c.check(list[0].startTimeMillis == 500, "合并保留最早时间",
                "（实得 \(list[0].startTimeMillis)）")

        let other = LessonQuestion(
            text: "什么是梯度消失", rawSentence: "什么是梯度消失",
            startTimeMillis: 1200, level: 2
        )
        let outcome3 = LessonQuestion.enqueue(other, into: &list)
        c.check(outcome3 == .appended && list.count == 2, "去重键不命中：不同问题各占一行")
    }

    // MARK: - 三、状态机

    private static func checkStateMachine(_ c: Checker) {
        func expect(_ from: QuestionStatus, _ event: QuestionFlow.Event,
                    allowed: Bool, status: QuestionStatus?,
                    failure: QuestionFailure? = nil,
                    confirm: Bool = false,
                    _ name: String) {
            let t = QuestionFlow.decide(current: from, event: event)
            let ok = t.allowed == allowed
                && t.nextStatus == status
                && t.nextFailure == failure
                && t.requiresConfirmation == confirm
            c.check(ok, name,
                    "（实得 allowed=\(t.allowed) / \(t.nextStatus?.rawValue ?? "nil") / "
                    + "\(t.nextFailure?.rawValue ?? "nil") / 确认=\(t.requiresConfirmation)）")
        }

        expect(.unasked, .ask, allowed: true, status: .searching, "unasked + 查答案 → searching")
        expect(.answered, .requery, allowed: true, status: .searching, confirm: true,
               "answered + 重新查询 → searching（必须确认）")
        expect(.failed, .retry, allowed: true, status: .searching,
               "failed + 重试 → searching（无需确认）")
        expect(.noResults, .retry, allowed: true, status: .searching,
               "noResults + 重试 → searching（无需确认）")
        expect(.searching, .ask, allowed: false, status: nil, "searching + 查答案 → 忽略")
        expect(.searching, .retry, allowed: false, status: nil, "searching + 重试 → 忽略")
        expect(.searching, .requery, allowed: false, status: nil, "searching + 重新查询 → 忽略")
        expect(.searching, .succeeded, allowed: true, status: .answered,
               "searching + 成功 → answered")
        expect(.searching, .foundNothing, allowed: true, status: .noResults,
               "searching + 无可用结果 → noResults")
        expect(.searching, .channelFailed, allowed: true, status: .failed, failure: .channel,
               "searching + 通道不通 → failed(.channel)")
        expect(.searching, .modelFailed, allowed: true, status: .failed, failure: .model,
               "searching + 模型失败 → failed(.model)")
        expect(.unasked, .succeeded, allowed: false, status: nil,
               "非 searching 收到迟到结果 → 不改状态")
        expect(.answered, .channelFailed, allowed: false, status: nil,
               "answered 收到迟到失败 → 不改状态")

        c.check(QuestionFlow.owesConfirmation(.answered), "只有 answered 需要覆盖确认")
        c.check(!QuestionFlow.owesConfirmation(.noResults)
                && !QuestionFlow.owesConfirmation(.failed)
                && !QuestionFlow.owesConfirmation(.unasked),
                "noResults / failed / unasked 不需要确认")
    }

    // MARK: - 四、闸门与文案

    private static func checkGatesAndMessages(_ c: Checker) {
        let dupID = UUID()
        func gate(_ status: QuestionStatus, filtered: Bool = false,
                  configured: Bool = true, hasAnswer: Bool = false,
                  duplicate: UUID? = nil, searching: Bool = false) -> QuestionFlow.Gate {
            QuestionFlow.gate(status: status, filtered: filtered, isConfigured: configured,
                              hasAnswer: hasAnswer, duplicateAnswerID: duplicate,
                              duplicateSearching: searching)
        }

        c.check(gate(.searching) == .blocked(.alreadySearching), "闸门 1：查询中忽略点击")
        c.check(gate(.searching, configured: false) == .blocked(.alreadySearching),
                "闸门顺序：查询中先于配置缺失")
        c.check(gate(.unasked, configured: false) == .blocked(.notConfigured),
                "闸门 2：未配置密钥不转移")
        c.check(gate(.unasked, filtered: true) == .blocked(.filtered),
                "闸门 3：元问题没有查询入口")
        c.check(gate(.unasked, filtered: true, duplicate: dupID) == .blocked(.filtered),
                "闸门顺序：元问题先于同文本复制")
        c.check(gate(.unasked, duplicate: dupID) == .copyAnswer(from: dupID),
                "闸门 4：同文本已有答案 → 复制，不联网")
        c.check(gate(.unasked, hasAnswer: true, duplicate: dupID) == .proceed,
                "本条已有答案时重查走 proceed（由确认弹窗把关）")
        c.check(gate(.unasked, searching: true) == .blocked(.duplicateSearching),
                "同文本另一条查询中 → 忽略，防并发")
        c.check(gate(.unasked) == .proceed, "干净条目 → proceed")

        c.check(QuestionFlow.overwriteConfirmation.contains("旧的答案和来源会被替换"),
                "覆盖确认文案含拍板要求的那句")
        c.check(QuestionFlow.channelMessage.contains("通道不通"),
                "通道不通文案含「通道不通」")
        c.check(QuestionFlow.emptyMessage.contains("没搜到")
                && !QuestionFlow.emptyMessage.contains("通道不通"),
                "没搜到文案含「没搜到」且不含「通道不通」")
        c.check(QuestionFlow.modelEmptyMessage != QuestionFlow.channelMessage
                && QuestionFlow.modelEmptyMessage != QuestionFlow.emptyMessage,
                "三种失败路径文案两两不同（§2.3）")
        c.check(QuestionFlow.noResultsMessage(hasSources: true) == QuestionFlow.modelEmptyMessage
                && QuestionFlow.noResultsMessage(hasSources: false) == QuestionFlow.emptyMessage,
                "noResults 按有没有来源分两种文案")
        c.check(QuestionFlow.failureMessage(.model, note: "上次查询中断") == "上次查询中断",
                "failureNote 优先于归类文案")
    }


    /// 同步等待一次 async 查询的结果。
    ///
    /// 用 `Task.detached` + 信号量（和 `App.swift` 里那些离线入口同一个写法）：
    /// 不能用 `Task { @MainActor in }`——自检本身跑在主线程上，主线程正卡在
    /// `wait()` 上，那个任务永远排不到（死锁）。结果经一个 `@unchecked
    /// Sendable` 盒子交回，闭包都在同一次等待里串行完成
    private final class OutcomeBox: @unchecked Sendable {
        var value: QuestionAnswerOutcome?
    }

    private static func awaitOutcome(
        _ operation: @escaping @Sendable () async -> QuestionAnswerOutcome
    ) -> QuestionAnswerOutcome? {
        let box = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    // MARK: - 五、查询编排

    private static func checkAnswerService(_ c: Checker) {
        struct StubError: Error {}

        let hits = [
            SearchHit(title: "梯度下降 - 维基", url: "https://a.example/gd", snippet: "梯度下降是一种优化算法"),
            SearchHit(title: "重复页面", url: "https://a.example/gd", snippet: "同一 URL"),
            SearchHit(title: "", url: "https://b.example/x", snippet: "没有标题的来源"),
            SearchHit(title: "坏来源", url: "   ", snippet: "空 URL 应丢弃"),
        ]
        let goodReply = "梯度下降是沿着梯度反方向迭代更新参数的优化方法 [1]。"
        let good = QuestionAnswerService(
            search: { _ in hits },
            chat: { _, _ in goodReply },
            model: "stub-model", searchProvider: "stub"
        )

        let outcome = awaitOutcome { await good.answer(question: "什么是梯度下降") }
        if case .answered(let answer)? = outcome {
            c.check(answer.markdown == goodReply, "成功 → answered，正文原样")
            c.check(answer.model == "stub-model" && answer.searchProvider == "stub",
                    "答案记模型与检索通道")
            c.check(answer.notice == QuestionAnswer.aiNotice, "答案带 AI 标注常量")
            c.check(answer.origin == .aiWebSearch, "来源类型固定 aiWebSearch")
            c.check(answer.sources.map(\.url) == ["https://a.example/gd", "https://b.example/x"],
                    "来源按 URL 去重、丢弃空 URL、保留顺序",
                    "（\(answer.sources.map(\.url))）")
            c.check(answer.sources.last?.title == "https://b.example/x",
                    "空标题回落到 URL")
        } else {
            c.check(false, "成功路径应得到 answered", "（实得 \(String(describing: outcome))）")
        }

        // 模型在正文里写一个不存在的链接：来源列表不受影响（拍板第 5 条）
        let liar = QuestionAnswerService(
            search: { _ in hits },
            chat: { _, _ in "参考答案见 https://evil.example/fake 。" },
            model: "stub", searchProvider: "stub"
        )
        let liarOutcome = awaitOutcome { await liar.answer(question: "什么是梯度下降") }
        if case .answered(let answer)? = liarOutcome {
            c.check(answer.sources.allSatisfy { hitURLs.contains($0.url) },
                    "模型正文里的 URL 不会进来源列表")
            c.check(!answer.sources.contains { $0.url == "https://evil.example" },
                    "来源里没有模型编的链接")
        } else {
            c.check(false, "模型写链接的路径仍应是 answered", "（实得 \(String(describing: liarOutcome))）")
        }

        // 通道不通
        let channel = QuestionAnswerService(
            search: { _ in throw StubError() },
            chat: { _, _ in goodReply }, model: "stub", searchProvider: "stub"
        )
        let channelOutcome = awaitOutcome { await channel.answer(question: "x") }
        c.check(channelOutcome == .failed(.channel), "检索抛错 → failed(.channel)",
                "（实得 \(String(describing: channelOutcome))）")

        // 一条都没搜到：不调模型（调了就会抛，从而变成 failed(.model)）
        let empty = QuestionAnswerService(
            search: { _ in [] },
            chat: { _, _ in throw StubError() },
            model: "stub", searchProvider: "stub"
        )
        let emptyOutcome = awaitOutcome { await empty.answer(question: "x") }
        c.check(emptyOutcome == .noResults(sources: []), "空 hits → noResults，且不调模型",
                "（实得 \(String(describing: emptyOutcome))）")

        // 模型失败
        let modelFail = QuestionAnswerService(
            search: { _ in hits },
            chat: { _, _ in throw StubError() },
            model: "stub", searchProvider: "stub"
        )
        let modelOutcome = awaitOutcome { await modelFail.answer(question: "x") }
        c.check(modelOutcome == .failed(.model), "模型抛错 → failed(.model)",
                "（实得 \(String(describing: modelOutcome))）")

        // 有资料、模型只说了句寒暄：noResults，且来源留着
        let polite = QuestionAnswerService(
            search: { _ in hits },
            chat: { _, _ in "抱歉，我无法回答这个问题。" },
            model: "stub", searchProvider: "stub"
        )
        let politeOutcome = awaitOutcome { await polite.answer(question: "x") }
        if case .noResults(let sources)? = politeOutcome {
            c.check(!sources.isEmpty, "寒暄答案 → noResults 且保留来源（§2.3）")
        } else {
            c.check(false, "寒暄答案应判 noResults", "（实得 \(String(describing: politeOutcome))）")
        }

        c.check(!QuestionAnswerService.isUsableAnswer("资料不足以回答"), "空答案判据：短否定句不可用")
        c.check(!QuestionAnswerService.isUsableAnswer("抱歉，我找不到可靠资料。"),
                "空答案判据：剥否定前缀后不足 10 字")
        c.check(QuestionAnswerService.isUsableAnswer("梯度是多元函数增长最快的方向，负梯度方向下降最快。"),
                "空答案判据：正常正文可用")
    }

    /// 上面那条「模型正文里的 URL 不会进来源」要比对的真实命中 URL
    private static let hitURLs: Set<String> = [
        "https://a.example/gd", "https://b.example/x",
    ]

    // MARK: - 六、元问题表

    private static func checkMetaQuestionFilter(_ c: Checker) {
        let meta = [
            "听得到吗？", "大家听得到我说话吗", "第几页", "翻到第三页",
            "听懂了吗", "这块还有问题吗", "对不对", "屏幕上的字认识吗",
            "这道题会不会做", "要不要休息一下",
        ]
        for text in meta {
            c.check(MetaQuestionFilter.isMetaQuestion(text), "元问题：\(text)")
        }
        let knowledge = [
            "会不会过拟合，为什么", "屏幕上的这个字怎么念",
            "声音的传播速度是多少", "什么是梯度下降", "能不能证明这个定理",
        ]
        for text in knowledge {
            c.check(!MetaQuestionFilter.isMetaQuestion(text), "知识问题不被过滤：\(text)")
        }
        // 规则表本身：24 条以外还要能说清三类各有
        let kinds = Set(MetaQuestionFilter.rules.map(\.kind))
        c.check(kinds == Set(MetaQuestionFilter.Kind.allCases), "三类规则（exact/regex/contains）都有")
        c.check(MetaQuestionFilter.rules.count >= 24, "规则条数 ≥ 24",
                "（实得 \(MetaQuestionFilter.rules.count)）")
    }

    // MARK: - 七、向后兼容

    private static func checkBackwardCompatibility(_ c: Checker) {
        let decoder = JSONDecoder()
        let id = UUID()

        // 旧存档：完全没有 questions / questionSchemaVersion 两个键
        let old = """
        {"id":"\(id.uuidString)","startedAt":0,"updatedAt":0,"parts":[]}
        """
        if let session = try? decoder.decode(RecordingSession.self, from: Data(old.utf8)) {
            c.check(session.questions.isEmpty && session.questionSchemaVersion == 0,
                    "旧存档缺 questions 键 → 空列表、版本 0，不崩")
        } else {
            c.check(false, "旧存档必须能解码")
        }

        // 条目内部缺键 + 僵尸 searching + 未知枚举 + 坏条目连坐
        let messy = """
        {"id":"\(id.uuidString)","startedAt":0,"updatedAt":0,"parts":[],
         "questions":[
           {"id":"\(UUID().uuidString)","text":"什么是梯度下降","status":"searching"},
           {"id":"\(UUID().uuidString)"},
           {"id":"\(UUID().uuidString)","text":"什么是梯度消失","status":"未来状态","level":2},
           {"id":"\(UUID().uuidString)","text":"什么是学习率"}
         ],
         "questionSchemaVersion":1}
        """
        if let session = try? decoder.decode(RecordingSession.self, from: Data(messy.utf8)) {
            c.check(session.questions.count == 3, "坏条目单独丢弃，其余照常解码",
                    "（实得 \(session.questions.count) 条）")
            let zombie = session.questions.first { $0.text == "什么是梯度下降" }
            c.check(zombie?.status == .failed && zombie?.failure == .model
                    && zombie?.failureNote == LessonQuestion.interruptedNote,
                    "磁盘上的 searching → failed(.model) + 「上次查询中断」")
            let unknown = session.questions.first { $0.text == "什么是梯度消失" }
            c.check(unknown?.status == .unasked && unknown?.normalizedText.isEmpty == false,
                    "未知状态 rawValue → unasked，归一化键现算")
        } else {
            c.check(false, "条目内部缺键的会话也必须能解码")
        }

        // 答案缺 notice / createdAt
        let answerJSON = """
        {"id":"\(UUID().uuidString)","text":"什么是梯度下降",
         "answer":{"id":"\(UUID().uuidString)","markdown":"正文",
                   "sources":[{"title":"T","url":"https://a.example"}]}}
        """
        let single = """
        {"id":"\(id.uuidString)","startedAt":0,"updatedAt":0,"parts":[],
         "questions":[\(answerJSON)]}
        """
        if let session = try? decoder.decode(RecordingSession.self, from: Data(single.utf8)),
           let answer = session.questions.first?.answer {
            c.check(answer.notice == QuestionAnswer.aiNotice, "答案缺 notice → 补 AI 标注常量")
            c.check(answer.createdAt == Date(timeIntervalSince1970: 0),
                    "答案缺 createdAt → 1970，不冒充「刚查的」")
        } else {
            c.check(false, "带答案的旧存档必须能解码")
        }
    }

    // MARK: - 八、占位会话

    @MainActor
    private static func checkPlaceholder(_ c: Checker) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("question-flow-selftest-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = scratch.appendingPathComponent("sessions", isDirectory: true)
        let audioDir = scratch.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: audioDir)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let id = store.createQuestionPlaceholder(startedAt: started)

        c.check(store.session(id: id)?.parts.isEmpty == true, "占位会话没有片段")
        c.check(store.questionOnlySummaries.map(\.id) == [id],
                "无录音会话出现在清理列表里")

        // 录完：ingest 用同一 id 追加片段（同一段不能被重复计数）。
        // 先造片段，问题的 sourceSegmentID 必须指回它的 id
        var questionSegment = TranscriptSegment(
            text: "什么是梯度下降？", isFinal: true,
            startTimeMillis: 0, endTimeMillis: 1_000,
            timestamp: started, languages: ["zh-CN"]
        )
        questionSegment.questionLevel = 2
        questionSegment.coreQuestion = "什么是梯度下降"

        // 实时期间先落一条问题（模拟学生第一次点查答案）
        var session = store.session(id: id)!
        session.questions = [LessonQuestion(
            text: "什么是梯度下降", rawSentence: "什么是梯度下降？",
            startTimeMillis: 0, sourceSegmentID: questionSegment.id, level: 2,
            status: .answered,
            answer: QuestionAnswer(markdown: "旧答案", sources: [],
                                   model: "stub", searchProvider: "stub")
        )]
        store.save(session)

        let draft = SessionDraft(
            sessionID: id, recordingFileName: "x.wav", startedAt: started,
            durationMillis: 1_000, segments: [questionSegment]
        )
        _ = store.ingest(draft, questionSensitivity: .normal)

        c.check(store.summaries.count == 1, "ingest 用同一 id 追加，不产生第二条会话",
                "（实得 \(store.summaries.count) 条）")
        let merged = store.session(id: id)
        c.check(merged?.parts.count == 1, "片段追加到占位会话")
        c.check(merged?.questions.count == 1, "同一段不会被实时与 ingest 各算一次",
                "（实得 \(merged?.questions.count ?? -1) 条）")
        c.check(merged?.questions.first?.askedCount == 1, "askedCount 不翻倍",
                "（实得 \(merged?.questions.first?.askedCount ?? -1)）")
        c.check(merged?.questions.first?.answer?.markdown == "旧答案", "重录不丢已查答案")

        // 再建一条纯占位（没有片段）→ 清理只删它，带录音的那条留着
        let stray = store.createQuestionPlaceholder(startedAt: started)
        c.check(store.questionOnlySummaries.count == 1, "有录音的会话不在清理列表里",
                "（实得 \(store.questionOnlySummaries.count)）")
        let deleted = store.deleteQuestionOnlySessions()
        c.check(deleted == 1 && store.session(id: stray) == nil,
                "清理删掉无录音的提问记录")
        c.check(store.session(id: id) != nil, "有录音的会话不被误删")
    }
}
