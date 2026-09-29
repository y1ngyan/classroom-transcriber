import Foundation

/// `--questions-selftest`：B 包**数据层地基**的离线自检。
///
/// 覆盖设计稿 §4（模型 / 向后兼容）· §4.5（摘要计数）· §4.6.4（按需回填）·
/// §6.1–§6.3（归一化与入列去重）。**不测**查询与编排——那是后面几包的事：
/// 本包不联网、不调模型、不写 UI。
///
/// **全部离线**：不联网、不花钱、不加载模型、不碰麦克风、**不发声**；
/// 所有读写都落在自己造的临时目录里——**用户真实的 sessions/ 、recordings/
/// 一个字节都不碰**（会话夹具全是内存里造、或写进临时目录的）。
///
/// 判据验过会红（两个变异各自记在提交说明里）：
/// - 把 §6.2 的 n5（去尾随语气词）拿掉 → 「去尾随「呢」」那条立刻红；
/// - 把 §4.6.3 的僵尸 `searching` 改写拿掉 → 僵尸那三条立刻红。
enum QuestionDataSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// 逐条记判据。
    ///
    /// **用一个小类，而不是把 `check` 闭包当参数传给每个检查函数**：
    /// `run()` 跑在 MainActor 上（它要用 `RecordingsStore`），而在 Swift 6 里
    /// 把一个继承主 actor 隔离的局部函数当非隔离闭包传出去是编译错误。
    /// 类没有隔离问题，且计数与行文只有这一处
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
        c.note("提问数据层自检（离线 · 临时目录 · 不联网、不调模型、不发声）")

        c.note("")
        c.note("─── 一、归一化（§6.2 的 n1–n6）───")
        checkNormalization(c)

        c.note("")
        c.note("─── 二、入列去重（§6.3 第 1 条）───")
        checkEnqueueDedup(c)

        c.note("")
        c.note("─── 三、向后兼容与僵尸条目（§4.6）───")
        checkBackwardCompatibility(c)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("questions-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        c.note("")
        c.note("─── 四、按需回填与幂等（§4.6.4）───")
        checkBackfill(c, root: root)

        c.note("")
        c.note("─── 五、摘要计数（§4.5 / rebuildIndex）───")
        checkSummaryCounts(c, root: root)

        c.note("")
        c.note(c.failed == 0
            ? "✅ 提问数据层自检通过（\(c.passed) 条）"
            : "❌ 提问数据层自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }

    // MARK: - 一、归一化

    private static func checkNormalization(_ c: Checker) {
        func same(_ a: String, _ b: String) -> Bool {
            LessonQuestion.normalizeForDedup(a) == LessonQuestion.normalizeForDedup(b)
        }

        // n1 全角折半角
        c.check(same("什么是梯度下降？", "什么是梯度下降?"),
                "n1 全角问号 == 半角问号",
                "「\(LessonQuestion.normalizeForDedup("什么是梯度下降？"))」")
        c.check(same("“什么是梯度下降”", "\"什么是梯度下降\""), "n1 全角引号 == 半角引号")
        // n2 空白折叠 + 去首尾（含全角空格 U+3000）
        c.check(same("什么是 梯度下降", "什么是\u{3000}  梯度下降"),
                "n2 连续空白（含 U+3000）折叠成一个空格")
        c.check(same("  什么是梯度下降\n", "什么是梯度下降"), "n2 去首尾空白（含换行）")
        // n3 英文字母小写
        c.check(same("What IS gradient descent?", "what is gradient descent"),
                "n3 英文大小写不敏感")
        // n4 只去首尾标点
        c.check(same("什么是梯度下降。", "什么是梯度下降"), "n4 去尾部句号")
        c.check(same("，什么是梯度下降", "什么是梯度下降"), "n4 去首部逗号")
        // n5 去尾随语气词（「呢吧啊呀哦嘛」）
        c.check(same("什么是梯度下降呢", "什么是梯度下降"), "n5 去尾随「呢」")
        c.check(same("什么是梯度下降呢吧", "什么是梯度下降"), "n5 连续语气词一起剥")
        // 「吗」不在 n5 的集合里：它决定句子是不是问句，
        // 去掉会把「听懂了吗」和「听懂了」并成同一条（§6.2）
        c.check(!same("听懂了吗", "听懂了"),
                "n5 **不去「吗」**（问句与陈述不许合并）",
                "「\(LessonQuestion.normalizeForDedup("听懂了吗"))」")
        // n6 剥完语气词后再去一次空白（n2 去过一次，这一步是给 n5 收尾的）
        c.check(same("什么是梯度下降 呢", "什么是梯度下降"),
                "n6 剥语气词后露出的空格再去掉")

        // 反例：必须**不**相等（§6.6）
        c.check(!same("什么是梯度下降", "什么是梯度消失"), "反例 1 梯度下降 ≠ 梯度消失")
        c.check(!same("什么是梯度下降", "什么是梯度下降，为什么能收敛"),
                "反例 2 中间标点不许被吃掉（整句是一个问题）")
        c.check(!same("什么是梯度下降", "梯度的下降是什么"),
                "反例 3 不做语义/词序归一（§6.1）")
    }

    // MARK: - 二、入列去重

    private static func checkEnqueueDedup(_ c: Checker) {
        let firstID = UUID()
        let secondID = UUID()
        let answer = QuestionAnswer(
            markdown: "梯度下降是……",
            sources: [AnswerSource(title: "维基", url: "https://example.com/gd")],
            model: "deepseek-chat", searchProvider: "tavily"
        )
        let first = LessonQuestion(
            text: "什么是梯度下降", rawSentence: "那么，什么是梯度下降？",
            startTimeMillis: 1_000, sourceSegmentID: firstID, level: 2,
            status: .answered, answer: answer
        )
        let repeatLater = LessonQuestion(
            text: "什么是梯度下降呢", rawSentence: "那个什么是梯度下降呢",
            startTimeMillis: 5_000, sourceSegmentID: secondID, level: 2
        )

        var list: [LessonQuestion] = []
        let outcomeA = LessonQuestion.enqueue(first, into: &list)
        let outcomeB = LessonQuestion.enqueue(repeatLater, into: &list)

        c.check(list.count == 1, "同 `normalizedText` 不新建条目", "\(list.count) 条")
        c.check(outcomeA == .appended && outcomeB == .merged(into: first.id),
                "两次入列的结果分别是 appended / merged")
        c.check(list[0].askedCount == 2, "askedCount == 2", "\(list[0].askedCount)")
        c.check(list[0].startTimeMillis == 1_000, "时间戳保留最早那次", "\(list[0].startTimeMillis)ms")
        c.check(list[0].rawSentence == first.rawSentence, "原句保留最早那次", "「\(list[0].rawSentence)」")
        c.check(list[0].id == first.id && list[0].sourceSegmentID == firstID,
                "条目 id 与出处仍是第一次那条")
        // 合并**不许**动学生已经看过的答案（§4.1「答案跟着会话走」的另一面）
        c.check(list[0].status == .answered && list[0].answer == answer,
                "合并保留已有答案与状态")

        // 「最早」是与入列顺序无关的规则：后到的这条更早，就要换上去。
        // 回填按片段顺序走，但重转、并发写入都可能打乱它——所以这条不能靠
        // 「先入列的必然最早」这个前提
        let earlier = LessonQuestion(
            text: "什么是梯度下降", rawSentence: "什么是梯度下降（更早那次）",
            startTimeMillis: 100, sourceSegmentID: UUID(), level: 1
        )
        LessonQuestion.enqueue(earlier, into: &list)
        c.check(list.count == 1 && list[0].askedCount == 3
                    && list[0].startTimeMillis == 100
                    && list[0].rawSentence == earlier.rawSentence
                    && list[0].level == 1,
                "后到的更早 → 时间/原句/等级换成更早那次（条目数仍 1）",
                "\(list[0].startTimeMillis)ms · 共 \(list[0].askedCount) 次")
        c.check(list[0].status == .answered && list[0].answer == answer,
                "换早之后答案照样在（它属于这一行，不属于某一次提问）")

        LessonQuestion.enqueue(
            LessonQuestion(text: "什么是梯度消失", rawSentence: "什么是梯度消失",
                           startTimeMillis: 500, level: 2),
            into: &list
        )
        c.check(list.count == 2, "不同 `normalizedText` 各占一行", "\(list.count) 行")
    }

    // MARK: - 三、向后兼容与僵尸条目

    private static func checkBackwardCompatibility(_ c: Checker) {
        let stamp = Date(timeIntervalSince1970: 1_858_464_000)

        // ── 1. 旧存档缺 `questions` / `questionSchemaVersion` 键 ──
        let legacy = RecordingSession(
            id: UUID(), startedAt: stamp, updatedAt: stamp,
            parts: [RecordingPart(
                id: UUID(), fileName: "legacy.wav", startedAt: stamp,
                durationMillis: 8_100, offsetMillis: 0,
                segments: [TranscriptSegment(
                    text: "今天我们讲梯度下降。", isFinal: true,
                    startTimeMillis: 0, endTimeMillis: 2_600,
                    timestamp: stamp, languages: ["zh-CN"]
                )]
            )],
            title: "旧会话", course: "旧课"
        )
        if let decoded = decodeSession(stripKeys(["questions", "questionSchemaVersion"], from: legacy)) {
            c.check(decoded.questions.isEmpty && decoded.questionSchemaVersion == 0,
                    "旧 JSON 缺键：可解码，questions 为空、版本 0",
                    "\(decoded.questions.count) 条 · v\(decoded.questionSchemaVersion)")
            c.check(decoded.title == "旧会话" && decoded.segmentCount == 1,
                    "旧 JSON 缺键：同一条里的其它字段照旧")
        } else {
            c.check(false, "旧 JSON 缺键：可解码", "整条会话读不出来（这正是要防的）")
        }

        // ── 2. 条目内部缺键：后加字段回落到默认值，一条坏不连坐 ──
        let goodA = UUID().uuidString
        let goodB = UUID().uuidString
        let questionsJSON: [[String: Any]] = [
            ["id": goodA, "text": "什么是梯度下降"],
            // 缺 id 的坏条目：该被单独丢掉，不能把整条会话带走
            ["text": "没有 id 的坏条目"],
            ["id": goodB, "text": "什么是梯度消失"],
        ]
        if let decoded = decodeSession(sessionJSON(questions: questionsJSON, schemaVersion: 1)) {
            c.check(decoded.questions.count == 2,
                    "条目内部缺键：坏条目被单独丢掉，好条目都在",
                    "喂了 3 条（1 条缺 id），读出 \(decoded.questions.count) 条")
            if decoded.questions.count == 2 {
                let q = decoded.questions[0]
                c.check(q.id.uuidString == goodA && q.rawSentence == "什么是梯度下降",
                        "缺 `rawSentence` 回落到 `text`")
                c.check(q.status == .unasked && q.failure == nil && q.failureNote == nil,
                        "缺 `status` / `failure` 回落 unasked / nil")
                c.check(q.askedCount == 1 && q.filtered == false && q.level == 0
                            && q.startTimeMillis == 0 && q.sourceSegmentID == nil && q.answer == nil,
                        "其余后加字段各自回落到默认值")
                c.check(q.normalizedText == LessonQuestion.normalizeForDedup("什么是梯度下降"),
                        "缺 `normalizedText` 就现算（不能落空串）",
                        "「\(q.normalizedText)」")
            }
        } else {
            c.check(false, "条目内部缺键：可解码", "整条会话读不出来（这正是要防的）")
        }

        // ── 3. 未知 rawValue 回落，不抛错 ──
        let unknownJSON: [[String: Any]] = [[
            "id": UUID().uuidString, "text": "什么是梯度下降",
            "status": "某个我没见过的状态", "failure": "某个我没见过的归类",
            "answer": ["id": UUID().uuidString, "markdown": "正文", "origin": "某个我没见过的来源"],
        ]]
        if let decoded = decodeSession(sessionJSON(questions: unknownJSON, schemaVersion: 1)),
           let q = decoded.questions.first {
            c.check(q.status == .unasked, "未知 status 回落 unasked", q.status.rawValue)
            c.check(q.failure == nil, "未知 failure 回落 nil（不硬塞归类）")
            c.check(q.answer?.origin == .aiWebSearch, "未知 origin 回落 aiWebSearch")
            c.check(q.answer?.notice == QuestionAnswer.aiNotice,
                    "缺 `notice` 也拿到固定文案（§4.3 的「存一份」）",
                    "「\(q.answer?.notice ?? "nil")」")
        } else {
            c.check(false, "未知 rawValue：可解码", "整条会话读不出来")
        }

        // ── 4. 僵尸 `searching`（§4.6.3）──
        let zombieJSON: [[String: Any]] = [[
            "id": UUID().uuidString, "text": "什么是梯度下降", "status": "searching",
        ]]
        if let decoded = decodeSession(sessionJSON(questions: zombieJSON, schemaVersion: 1)),
           let q = decoded.questions.first {
            c.check(q.status == .failed, "僵尸 searching → failed", q.status.rawValue)
            c.check(q.failure == .model, "僵尸 searching → failure == model", q.failure?.rawValue ?? "nil")
            c.check(q.failureNote == LessonQuestion.interruptedNote,
                    "僵尸 searching 附一句「上次查询中断」", "「\(q.failureNote ?? "nil")」")
        } else {
            c.check(false, "僵尸 searching：可解码", "整条会话读不出来")
        }

        // 「改写只发生在读入这一侧」：写盘时 `.searching` 是合法状态（§5.2
        // 「写 status=searching 并落盘」）。这条钉子防的是有人把改写挪进编码
        // ——那时「查询中」根本存不下去，App 被杀之后就再也读不出「中断」这件事
        let searching = LessonQuestion(
            text: "什么是梯度下降", rawSentence: "什么是梯度下降",
            startTimeMillis: 0, level: 2, status: .searching
        )
        let encoded = (try? JSONEncoder().encode([searching])).map {
            String(decoding: $0, as: UTF8.self)
        } ?? ""
        c.check(encoded.contains("\"searching\""), "写盘时 searching 原样存（改写只在解码期）")

        // ── 5. 答案整体坏掉时，问题条目要留下 ──
        let brokenAnswerJSON: [[String: Any]] = [[
            "id": UUID().uuidString, "text": "什么是梯度下降",
            "status": "answered", "answer": ["markdown": 12345],
        ]]
        if let decoded = decodeSession(sessionJSON(questions: brokenAnswerJSON, schemaVersion: 1)),
           let q = decoded.questions.first {
            c.check(decoded.questions.count == 1 && q.answer == nil,
                    "答案解不出来时：问题条目留下，答案当没查过",
                    "\(decoded.questions.count) 条 · answer=\(q.answer == nil ? "nil" : "有")")
        } else {
            c.check(false, "答案坏掉：问题条目不该消失", "整条会话或整条问题读不出来")
        }
    }

    // MARK: - 四、按需回填

    @MainActor
    private static func checkBackfill(_ c: Checker, root: URL) {
        let stamp = Date(timeIntervalSince1970: 1_858_464_000)
        func segment(_ text: String, _ start: Int, _ end: Int) -> TranscriptSegment {
            TranscriptSegment(
                text: text, isFinal: true, startTimeMillis: start, endTimeMillis: end,
                timestamp: stamp, languages: ["zh-CN"]
            )
        }
        func part(offset: Int, duration: Int, _ segments: [TranscriptSegment]) -> RecordingPart {
            RecordingPart(id: UUID(), fileName: "questions.wav", startedAt: stamp,
                          durationMillis: duration, offsetMillis: offset, segments: segments)
        }

        let sessionsDir = root.appendingPathComponent("backfill/sessions", isDirectory: true)
        let recordingsDir = root.appendingPathComponent("backfill/recordings", isDirectory: true)
        let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)

        // 两段「接着录」的会话：问题的绝对时间必须跨过片段偏移，
        // 否则学生拿时间戳回录音会定位到 0 点去（§4.2）
        let partA = part(offset: 0, duration: 8_100, [
            segment("今天我们讲梯度下降", 0, 2_600),
            segment("那么，请这位同学回答一下，梯度下降为什么能收敛呢", 2_600, 5_400),
        ])
        let partB = part(offset: 8_100, duration: 3_000, [
            segment("什么是梯度下降？", 0, 1_800),
            segment("什么是梯度下降呢", 1_800, 3_000),
        ])
        var session = RecordingSession(id: UUID(), startedAt: stamp, updatedAt: stamp,
                                       parts: [partA, partB])
        c.check(session.questionSchemaVersion == 0, "新会话的版本是 0（= 没回填过）")

        let ran = session.backfillQuestions(sensitivity: .normal)
        c.check(ran, "回填跑了一次")
        c.check(session.questionSchemaVersion == LessonQuestionSchema.current,
                "回填后版本推到当前值", "v\(session.questionSchemaVersion)")
        c.check(session.questions.count == 2,
                "命中 3 句提问、去重后 2 条",
                "\(session.questions.count) 条：" + session.questions.map(\.text).joined(separator: " / "))

        let detector = QuestionDetector(sensitivity: .normal)
        if let converged = session.questions.first(where: { $0.text.contains("收敛") }) {
            c.check(converged.startTimeMillis == 2_600,
                    "绝对时间 = 片段偏移 + 段内偏移（第一段）",
                    "\(converged.startTimeMillis)ms")
            c.check(converged.rawSentence == "那么，请这位同学回答一下，梯度下降为什么能收敛呢",
                    "原句就是转录文本本身（逐字对得上）")
            c.check(converged.text == detector.detect(converged.rawSentence)?.coreQuestion,
                    "text 直接取检测器的 coreQuestion，**不二次清洗**",
                    "「\(converged.text)」")
            c.check(converged.sourceSegmentID == partA.segments[1].id, "sourceSegmentID 指回原段")
            c.check(converged.level == 2, "level 沿用 questionLevel", "L\(converged.level)")
        } else {
            c.check(false, "回填：第二段里那句「…为什么能收敛呢」该被命中", "没找到")
        }

        let gradientRows = session.questions.filter { $0.normalizedText == "什么是梯度下降" }
        c.check(gradientRows.count == 1 && gradientRows.first?.askedCount == 2,
                "回填也走去重：同一问题问两次 → 一行 · askedCount 2",
                "\(gradientRows.count) 行 · askedCount \(gradientRows.first?.askedCount ?? -1)")
        c.check(gradientRows.first?.startTimeMillis == 8_100,
                "第二片段的问题落在会话时间轴上（偏移 8100，不是 0）",
                "\(gradientRows.first?.startTimeMillis ?? -1)ms")

        // 幂等：版本已达标就不重跑（重复调用不会把条目翻倍）
        let again = session.backfillQuestions(sensitivity: .normal)
        c.check(!again && session.questions.count == 2,
                "回填幂等：版本达标不重跑", "第二次返回 \(again) · 仍 \(session.questions.count) 条")

        // 灵敏度关闭时**不回填也不盖章**：否则「一条都没测」被记成「已回填过」，
        // 学生下次打开灵敏度时这些旧录音就再也没有问题了
        var offSession = RecordingSession(id: UUID(), startedAt: stamp, updatedAt: stamp, parts: [partA])
        let offRan = offSession.backfillQuestions(sensitivity: .off)
        c.check(!offRan && offSession.questionSchemaVersion == 0 && offSession.questions.isEmpty,
                "灵敏度 off：不回填、不盖章（留给下次）",
                "返回 \(offRan) · v\(offSession.questionSchemaVersion)")
        c.check(offSession.backfillQuestions(sensitivity: .normal) && offSession.questions.count == 1,
                "off 之后再打开标准档：照常回填", "\(offSession.questions.count) 条")

        // 走 Store 的那条路：版本要**落盘**才拦得住下次重跑
        let stored = store.ingest(SessionDraft(
            sessionID: nil, recordingFileName: "questions.wav", startedAt: stamp,
            durationMillis: 11_100, segments: partA.segments + partB.segments
        ))
        let storeRan = store.backfillQuestions(id: stored.id, sensitivity: .normal)
        let reread = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
        let persisted = reread.session(id: stored.id)
        c.check(storeRan && persisted?.questionSchemaVersion == LessonQuestionSchema.current
                    && persisted?.questions.count == 2,
                "经 Store 回填：版本与条目都落了盘",
                "v\(persisted?.questionSchemaVersion ?? -1) · \(persisted?.questions.count ?? -1) 条")
        c.check(reread.backfillQuestions(id: stored.id, sensitivity: .normal) == false,
                "重开一次 App 再打开提问页：版本达标，不重跑")
    }

    // MARK: - 五、摘要计数

    @MainActor
    private static func checkSummaryCounts(_ c: Checker, root: URL) {
        let stamp = Date(timeIntervalSince1970: 1_858_464_000)
        let sessionsDir = root.appendingPathComponent("summary/sessions", isDirectory: true)
        let recordingsDir = root.appendingPathComponent("summary/recordings", isDirectory: true)
        let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)

        // 未回填的旧会话：`questions` 空，但段落上有提问标记
        var legacySegment = TranscriptSegment(
            text: "什么是梯度下降？", isFinal: true,
            startTimeMillis: 0, endTimeMillis: 1_800,
            timestamp: stamp, languages: ["zh-CN"]
        )
        legacySegment.questionLevel = 2
        legacySegment.coreQuestion = "什么是梯度下降"
        let session = store.ingest(SessionDraft(
            sessionID: nil, recordingFileName: "summary.wav", startedAt: stamp,
            durationMillis: 1_800, segments: [legacySegment]
        ))

        let before = store.summaries.first { $0.id == session.id }
        c.check(before?.questionCount == 1,
                "未回填的旧会话：「N 个提问」回落到段落计数（不归零）",
                "\(before?.questionCount ?? -1)")
        c.check(before?.answeredQuestionCount == 0, "未回填：已答数为 0")

        // 回填之后：口径切到问题条目数
        c.check(store.backfillQuestions(id: session.id, sensitivity: .normal), "回填这条旧会话")
        let filled = store.summaries.first { $0.id == session.id }
        c.check(filled?.questionCount == 1 && filled?.answeredQuestionCount == 0,
                "回填后：摘要当场现算（1 个问题 · 0 个已答）",
                "\(filled?.questionCount ?? -1) 个问题 · \(filled?.answeredQuestionCount ?? -1) 个已答")

        // 给学生查出一个答案
        guard var withAnswer = store.session(id: session.id), !withAnswer.questions.isEmpty else {
            c.check(false, "摘要：取回会话并写一条答案", "取不到会话或没有条目")
            return
        }
        withAnswer.questions[0].status = .answered
        withAnswer.questions[0].answer = QuestionAnswer(
            markdown: "梯度下降是……",
            sources: [AnswerSource(title: "维基", url: "https://example.com/gd")],
            model: "deepseek-chat", searchProvider: "tavily"
        )
        store.save(withAnswer)
        let answered = store.summaries.first { $0.id == session.id }
        c.check(answered?.answeredQuestionCount == 1 && answered?.questionCount == 1,
                "写了答案之后：已答数跟着变成 1",
                "\(answered?.questionCount ?? -1) 个问题 · \(answered?.answeredQuestionCount ?? -1) 个已答")

        // rebuildIndex：**从正文现算**。索引是派生数据，删了要能重建出一样的数，
        // 而不是归零（§4.5 那句「否则重建索引后数字归零」）
        try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent("index.json"))
        let rebuilt = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
        let after = rebuilt.summaries.first { $0.id == session.id }
        c.check(after?.questionCount == 1 && after?.answeredQuestionCount == 1,
                "重建索引后计数从正文现算回来（不归零 / 不漂）",
                "\(after?.questionCount ?? -1) 个问题 · \(after?.answeredQuestionCount ?? -1) 个已答")

        // 正文里那条答案也必须原样还在（摘要只是摘要）
        let body = rebuilt.session(id: session.id)
        c.check(body?.questions.first?.answer?.markdown == "梯度下降是……"
                    && body?.questions.first?.answer?.sources.first?.url == "https://example.com/gd"
                    && body?.questions.first?.answer?.notice == QuestionAnswer.aiNotice,
                "正文往返：答案正文 / 来源 / 标注一条不少")
    }

    // MARK: - 夹具

    /// 把一条会话编码成 JSON，再删掉指定的键——**这就是旧存档的形状**
    /// （真实的老文件里本来就没有这些键），比手写一个 json 字符串可信
    private static func stripKeys(_ keys: [String], from session: RecordingSession) -> Data? {
        guard let data = try? JSONEncoder().encode(session),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in keys { object.removeValue(forKey: key) }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// 手搭一条会话 JSON。`questions` 传 nil = 不带这个键；`parts` 留空——
    /// 这一组判据验的是条目解码，不是段落
    private static func sessionJSON(questions: [[String: Any]]?, schemaVersion: Int?) -> Data {
        var object: [String: Any] = [
            "id": UUID().uuidString,
            // Date 的默认编码就是「2001 参考日期的秒数」
            "startedAt": 0.0,
            "updatedAt": 0.0,
            "title": "",
            "course": "",
            "parts": [Any](),
        ]
        if let questions { object["questions"] = questions }
        if let schemaVersion { object["questionSchemaVersion"] = schemaVersion }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func decodeSession(_ data: Data?) -> RecordingSession? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(RecordingSession.self, from: data)
    }
}
