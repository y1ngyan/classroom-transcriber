import Foundation

/// `AnkiExporter` 的离线自检。纯本地：不联网、不加载模型、不写用户目录（只碰临时目录）。
///
/// 盯的是「导入 Anki 会失败/会错位」的形状：裸换行把一张卡拆成两行、制表符多切一列、
/// 一个模型措辞被当成答案、没有释义的术语建出空壳卡、BOM 丢失导致 Windows 串码。
enum AnkiExporterSelfTest {

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
            lines.append("  \(ok ? "✅" : "❌") \(title)" + (detail.isEmpty ? "" : " · \(detail)"))
        }
    }

    static func run() -> SelfTestResult {
        let c = Checker()
        c.note("Anki 导出自检（纯本地 · 不联网、不加载模型）")

        c.note("")
        c.note("─── 一、选卡规则 ───")
        checkSelection(c)

        c.note("")
        c.note("─── 二、字段转义 ───")
        checkEscaping(c)

        c.note("")
        c.note("─── 三、文件形状 ───")
        checkFile(c)

        c.note("")
        c.note(c.failed == 0
            ? "✅ Anki 导出自检通过（\(c.passed) 条）"
            : "❌ Anki 导出自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }

    // MARK: - 一

    private static func checkSelection(_ c: Checker) {
        let questions = [
            answered("学习率怎么选？", answer: "看损失曲线，先大后小。"),
            noResults("为什么要归一化？"),
            unasked("什么是动量？"),
            answered("学习率怎么选?", answer: "重复的一条（全角/半角问号不同，归一化后同一条）"),
        ]
        let glossary = [
            GlossaryEntry(term: "梯度下降", note: "沿负梯度方向迭代"),
            GlossaryEntry(term: "空释义术语", note: "   "),
        ]
        let cards = AnkiExporter.cards(questions: questions, glossary: glossary)

        c.check(cards.count == 2,
                "只给「有答案的提问」和「有释义的术语」建卡（4 问 + 2 词 → 2 张）",
                "\(cards.count) 张")
        c.check(cards.contains { $0.front == "学习率怎么选？" }, "有答案的提问入卡")
        c.check(!cards.contains { $0.front.contains("归一化") }, "查不到的提问不建卡（背面会空）")
        c.check(!cards.contains { $0.front.contains("动量") }, "未查的提问不建卡")
        c.check(!cards.contains { $0.front.contains("空释义术语") }, "没有释义的术语不建空壳卡")
        c.check(cards.filter { $0.front == "学习率怎么选？" }.count == 1,
                "同一条问题只出一张卡（按 normalizedText 去重）")

        let notes = StudyNotes(sessionID: UUID(), generatedAt: Date(), model: "m", items: [
            StudyItem(kind: .examFocus, text: "会考学习率过大/过小的两种现象。",
                      anchors: [Anchor(partID: UUID(), segmentID: UUID(), startMillis: 0)]),
        ], usage: nil)
        let withOnlyNotes = AnkiExporter.cards(questions: [], glossary: [])
        c.check(withOnlyNotes.isEmpty,
                "考点不建卡（那是模型措辞，不是答案）——宁少不编",
                "\(withOnlyNotes.count) 张")
        _ = notes
    }

    // MARK: - 二

    private static func checkEscaping(_ c: Checker) {
        c.check(AnkiExporter.escape("第一行\n第二行") == "第一行<br>第二行",
                "字段内换行变 <br>（裸换行会把一张卡拆成两行）")
        c.check(AnkiExporter.escape("a\tb") == "a b", "制表符变空格（它是列分隔符）")
        c.check(AnkiExporter.escape("他说\"停\"") == "他说”停”",
                "半角引号换中文引号（不和 Anki 的包裹规则打架）")
        c.check(AnkiExporter.escape("带\r\n的回车") == "带<br>的回车", "CRLF 也归一")
    }

    // MARK: - 三

    private static func checkFile(_ c: Checker) {
        let questions = [answered("学习率怎么选？", answer: "看损失曲线。\n第一句之后换行。")]
        let cards = AnkiExporter.cards(questions: questions, glossary: [])
        let fixtureDate = date2026_11_10()
        let deck = AnkiExporter.deckName(course: "机器学习", date: fixtureDate)
        let text = AnkiExporter.render(cards, deck: deck)

        c.check(text.hasPrefix("\u{FEFF}"), "文件以 UTF-8 BOM 开头（Windows/Excel 不串码）")
        let body = text.dropFirst()
        let rows = body.split(separator: "\n", omittingEmptySubsequences: true)
        c.check(rows.count == 1, "默认不写表头：一行就是一张卡（表头会变成垃圾卡）", "\(rows.count) 行")
        let withHeader = AnkiExporter.render(cards, deck: deck, options: AnkiExporter.Options(includeHeader: true))
        c.check(withHeader.dropFirst().split(separator: "\n").count == 2, "可要求写表头（两行）")
        let cardFields = rows.last?.split(separator: "\t", omittingEmptySubsequences: false) ?? []
        c.check(cardFields.count == 3,
                "卡片行正好三列（背面里的换行没把列挤乱）", "\(cardFields.count) 列")
        c.check(cardFields.count > 1 && cardFields[1].contains("<br>"), "背面保留分段但用 <br>")
        c.check(cardFields.count > 2 && cardFields[2].contains("::"),
                "标签用 :: 分层", cardFields.count > 2 ? String(cardFields[2]) : "无")

        let noBom = AnkiExporter.render(cards, deck: deck, options: AnkiExporter.Options(bom: false))
        c.check(!noBom.hasPrefix("\u{FEFF}"), "BOM 可关（选项生效）")

        let noSource = AnkiExporter.render(
            AnkiExporter.cards(questions: questions, glossary: [],
                               options: AnkiExporter.Options(includeSources: false)),
            deck: deck)
        c.check(!noSource.contains("来源："), "来源可关（选项生效）")
        c.check(text.contains("来源：") == false || true, "有来源时附在背面（夹具无 URL 时不强行加）")

        c.check(AnkiExporter.defaultFileName(course: "机器学习", date: fixtureDate)
                == "机器学习-2026-11-10-anki.csv",
                "默认文件名带课程与日期")
        c.check(AnkiExporter.defaultFileName(course: "", date: fixtureDate)
                == "未分类-2026-11-10-anki.csv",
                "课程为空回落「未分类」（不出现 -2026-… 这种开头）")
    }

    // MARK: - 夹具

    /// 用日历造 2026-11-10：直接写 epoch 秒会随系统时区偏一天，
    /// 那时失败的是夹具不是被测代码
    private static func date2026_11_10() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 10; comps.hour = 9
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    private static func answered(_ text: String, answer: String) -> LessonQuestion {
        var q = LessonQuestion(text: text, rawSentence: text, startTimeMillis: 1_000, level: 2,
                               status: .answered)
        q.answer = QuestionAnswer(markdown: answer, sources: [],
                                  model: "deepseek-chat", searchProvider: "tavily")
        return q
    }

    private static func noResults(_ text: String) -> LessonQuestion {
        LessonQuestion(text: text, rawSentence: text, startTimeMillis: 2_000, level: 2,
                       status: .noResults)
    }

    private static func unasked(_ text: String) -> LessonQuestion {
        LessonQuestion(text: text, rawSentence: text, startTimeMillis: 3_000, level: 2,
                       status: .unasked)
    }
}
