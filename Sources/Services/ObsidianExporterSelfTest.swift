import Foundation

/// `ObsidianExporter` 的离线自检。**纯本地**：临时目录里写文件，不联网、不加载模型、不发声。
///
/// 这些断言盯的都是「导出去之后用户真会撞上」的形状：frontmatter 里带冒号的标题、
/// 课程名里的斜杠、术语重复链接套娃、课程索引每导一次少一讲、已有文件被静默覆盖。
enum ObsidianExporterSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    private final class Checker {
        var lines: [String] = []
        var passed = 0
        var failed = 0

        func note(_ text: String) { lines.append(text) }

        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            let mark = ok ? "✅" : "❌"
            lines.append("  \(mark) \(title)" + (detail.isEmpty ? "" : " · \(detail)"))
        }
    }

    static func run() -> SelfTestResult {
        let c = Checker()
        c.note("Obsidian 导出自检（纯本地 · 临时目录 · 不联网、不加载模型、不发声）")

        c.note("")
        c.note("─── 一、文件名与 YAML 转义 ───")
        checkNaming(c)

        c.note("")
        c.note("─── 二、主笔记结构 ───")
        checkNoteBody(c)

        c.note("")
        c.note("─── 三、术语链接 ───")
        checkLinks(c)

        c.note("")
        c.note("─── 四、课程索引追加 ───")
        checkIndex(c)

        c.note("")
        c.note("─── 五、落盘与覆盖 ───")
        checkWrite(c)

        c.note("")
        c.note(c.failed == 0
            ? "✅ Obsidian 导出自检通过（\(c.passed) 条）"
            : "❌ Obsidian 导出自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }

    // MARK: - 一

    private static func checkNaming(_ c: Checker) {
        c.check(ObsidianExporter.sanitize("第 3 讲:梯度下降") == "第 3 讲-梯度下降",
                "文件名里的半角冒号换成短横（macOS 会把 : 显示成 /）", "\"第 3 讲-梯度下降\"")
        c.check(ObsidianExporter.sanitize("第 3 讲：梯度下降") == "第 3 讲：梯度下降",
                "全角冒号保留（它在文件名里合法，也不影响 YAML）")
        c.check(ObsidianExporter.sanitize("机器学习/深度学习") == "机器学习-深度学习",
                "路径分隔符不能让文件跑出课程目录")
        c.check(ObsidianExporter.sanitize("   ") == "未命名", "空白名回落「未命名」")
        c.check(ObsidianExporter.sanitize("a--b") == "a-b", "连续短横合并（目录名干净）")
        c.check(ObsidianExporter.sanitize(String(repeating: "字", count: 200)).count == 80,
                "超长名截到 80 字（macOS 文件名上限 255 字节）")

        c.check(ObsidianExporter.quoted("第 3 讲: 梯度下降") == "\"第 3 讲: 梯度下降\"",
                "含半角冒号的标题必须加引号（否则 frontmatter 解析坏掉）")
        c.check(ObsidianExporter.quoted("第 3 讲：梯度下降") == "第 3 讲：梯度下降",
                "全角冒号不用加引号（YAML 只对半角冒号 + 空格敏感）")
        c.check(ObsidianExporter.quoted("梯度下降") == "梯度下降",
                "普通标题不加多余引号（Obsidian 里更好读）")
        c.check(ObsidianExporter.quoted("他说\"停\"") == "\"他说\\\"停\\\"\"",
                "标题里的引号要转义")
    }

    // MARK: - 二

    private static func checkNoteBody(_ c: Checker) {
        let meta = fixtureMeta()
        let notes = fixtureNotes()
        let questions = [fixtureAnsweredQuestion(), fixtureUnaskedQuestion()]
        let text = ObsidianExporter.noteMarkdown(meta: meta, notes: notes,
                                                 questions: questions, glossary: [])
        c.check(text.hasPrefix("---\n"), "主笔记以 frontmatter 开头")
        c.check(text.contains("title: 第 3 讲：梯度下降"), "frontmatter 带标题（全角冒号原样）")
        c.check(text.contains("course: 机器学习"), "frontmatter 带课程")
        c.check(text.contains("date: 2026-11-10"), "frontmatter 带日期")
        c.check(text.contains("tags: [课堂笔记, 机器学习]"),
                "标签固定项 + 课程，且去重保序", "tags")
        c.check(text.contains("questions: 2") && text.contains("answered: 1"),
                "frontmatter 带提问数与已答数（2 / 1）")
        c.check(text.contains("## 重点") && text.contains("## 考点") && !text.contains("## 待办"),
                "空组不出现（这节没有待办就不印标题）")
        c.check(text.contains("- `00:00:42` 学习率应该怎么选？ — 有答案"),
                "提问行带时间戳与状态")
        c.check(text.contains("  > 因为步长过大时会越过极小值点"),
                "答案以引用块缩进（不和正文混在一起）")
        c.check(text.contains("  > 来源：[Learning rate — Wikipedia](https://example.com/lr)"),
                "答案带来源链接")
        c.check(text.contains("返回 [[机器学习]]"), "结尾回链到课程索引")

        let empty = ObsidianExporter.noteMarkdown(meta: meta, notes: nil, questions: [], glossary: [])
        c.check(empty.contains("## 重点") == false && empty.contains("## 课堂提问") == false,
                "没有笔记也没有提问时，不出现空小节")
    }

    // MARK: - 三

    private static func checkLinks(_ c: Checker) {
        let glossary = [
            GlossaryEntry(term: "梯度下降", note: "沿负梯度方向迭代"),
            GlossaryEntry(term: "梯度下降法", note: "同上一词的另一种叫法"),
        ]
        let linked = ObsidianExporter.linkified("梯度下降法其实是梯度下降的推广", glossary: glossary)
        c.check(linked.contains("[[梯度下降法]]"),
                "长词优先（「梯度下降法」不能被「梯度下降」先吃掉）", linked)
        c.check(linked.contains("[[梯度下降]]的推广"), "短词照样成链")
        c.check(!linked.contains("[[[["), "不会出现套娃链接")

        let docs = ObsidianExporter.documents(meta: fixtureMeta(), notes: fixtureNotes(),
                                              questions: [], glossary: glossary)
        let termDocs = docs.filter { $0.relativePath.contains("/术语/") }
        c.check(termDocs.count == 1,
                "只给「笔记里真提到过」的术语建页（2 个词表项 → 1 页）",
                "\(termDocs.count) 页")
        c.check(termDocs.first?.relativePath == "机器学习/术语/梯度下降.md",
                "术语页路径 = 课程/术语/词.md", termDocs.first?.relativePath ?? "无")
    }

    // MARK: - 四

    private static func checkIndex(_ c: Checker) {
        let first = ObsidianExporter.appendingIndex(existing: nil, lectureLink: "- [[2026-11-10 第 3 讲]]")
        c.check(first == "- [[2026-11-10 第 3 讲]]\n", "索引首次写入就一行")
        let second = ObsidianExporter.appendingIndex(existing: first, lectureLink: "- [[2026-11-10 第 3 讲]]")
        c.check(second == first, "同一条重复追加不变（幂等）")
        let third = ObsidianExporter.appendingIndex(existing: first, lectureLink: "- [[2026-11-12 第 4 讲]]")
        c.check(third.contains("第 4 讲") && third.contains("第 3 讲"),
                "新的一讲追加在末尾，旧的不丢")
    }

    // MARK: - 五

    private static func checkWrite(_ c: Checker) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsidian-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let docs = ObsidianExporter.documents(meta: fixtureMeta(), notes: fixtureNotes(),
                                              questions: [fixtureAnsweredQuestion()],
                                              glossary: [GlossaryEntry(term: "梯度下降", note: "释义")])
        let index = docs.first { $0.relativePath == "机器学习/机器学习.md" }?.relativePath
        guard let result = try? ObsidianExporter.write(docs, to: root, overwrite: false,
                                                       courseIndexPath: index) else {
            c.check(false, "落盘不抛错", "write 抛异常")
            return
        }
        c.check(result.written.count == docs.count,
                "首次落盘全部写入（主笔记 + 术语页 + 索引）", "\(result.written.count)/\(docs.count)")

        let noteURL = root.appendingPathComponent("机器学习/2026-11-10 第 3 讲：梯度下降.md")
        let noteURLSafe = root.appendingPathComponent("机器学习/2026-11-10 第 3 讲-梯度下降.md")
        let readBack = (try? String(contentsOf: noteURLSafe, encoding: .utf8))
            ?? (try? String(contentsOf: noteURL, encoding: .utf8))
        c.check(readBack != nil, "主笔记真的落在课程目录里")
        c.check(readBack?.contains("## 重点") == true, "读回来的内容与渲染一致")

        // 覆盖语义：第二次写同名文件、不开 overwrite → 跳过而不是擦掉
        let second = try? ObsidianExporter.write([docs[0]], to: root, overwrite: false,
                                                 courseIndexPath: nil)
        c.check(second?.skipped.count == 1,
                "已存在的笔记默认跳过（不静默覆盖用户改过的文件）",
                "skipped=\(second?.skipped.count ?? -1)")

        // 索引：第二次导出追加而不是覆盖
        let indexURL = root.appendingPathComponent("机器学习/机器学习.md")
        let beforeIndex = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        _ = try? ObsidianExporter.write(docs, to: root, overwrite: false, courseIndexPath: index)
        let afterIndex = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        c.check(afterIndex == beforeIndex,
                "索引重复导出不变（同一讲不会出现两条）",
                "\(beforeIndex.count) → \(afterIndex.count) 字")

        // 空 vault 参数 → 报错而不是写到当前目录
        var threw = false
        do {
            _ = try ObsidianExporter.write(docs, to: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
                                           overwrite: true)
        } catch { threw = true }
        c.check(threw, "vault 目录不存在时报错（不会乱写）")
    }

    // MARK: - 夹具

    private static func fixtureMeta() -> ObsidianExporter.Meta {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 10; comps.hour = 9
        let date = Calendar(identifier: .gregorian).date(from: comps) ?? Date(timeIntervalSince1970: 0)
        return ObsidianExporter.Meta(course: "机器学习", title: "第 3 讲：梯度下降",
                                     startedAt: date, durationMillis: 47 * 60 * 1000 + 12_000,
                                     recordingName: "课堂-20261110-0900.wav")
    }

    private static func fixtureNotes() -> StudyNotes {
        let partID = UUID()
        func anchor(_ millis: Int) -> Anchor {
            Anchor(partID: partID, segmentID: UUID(), startMillis: millis)
        }
        return StudyNotes(
            sessionID: UUID(),
            generatedAt: Date(timeIntervalSince1970: 1_858_464_000),
            model: "deepseek-chat",
            items: [
                StudyItem(kind: .summary, text: "这节课讲梯度下降与学习率选择。", anchors: [anchor(0)]),
                StudyItem(kind: .keyPoint, text: "负梯度方向是局部下降最快的方向。", anchors: [anchor(42_000)]),
                StudyItem(kind: .examFocus, text: "会考学习率过大/过小的两种现象。", anchors: [anchor(120_000)]),
                StudyItem(kind: .term, text: "梯度下降", anchors: [anchor(5_000)]),
            ],
            usage: nil
        )
    }

    private static func fixtureAnsweredQuestion() -> LessonQuestion {
        var q = LessonQuestion(text: "学习率应该怎么选？", rawSentence: "学习率应该怎么选，有没有经验法则？",
                               startTimeMillis: 42_000, level: 2, status: .answered)
        q.answer = QuestionAnswer(
            markdown: "因为步长过大时会越过极小值点。",
            sources: [AnswerSource(title: "Learning rate — Wikipedia", url: "https://example.com/lr")],
            model: "deepseek-chat",
            searchProvider: "tavily"
        )
        return q
    }

    private static func fixtureUnaskedQuestion() -> LessonQuestion {
        LessonQuestion(text: "为什么泰勒展开的一阶项能近似原函数？",
                       rawSentence: "那为什么泰勒展开的一阶项能近似原函数呢？",
                       startTimeMillis: 60_000, level: 2, status: .unasked)
    }
}
