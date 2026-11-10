import Foundation
import CoreGraphics
import CoreText

/// `DocumentExporter` 的离线自检：临时目录里真生成 .docx 与 .pdf，再把它们读回来验。
///
/// 为什么非要把文件读回来：docx 是一个 zip，PDF 是一个 xref 表——拼错一个标签、
/// 少一个部件，`write` 都会「成功」（文件存在、大小不为零），只有解包/打开时才会露馅。
/// 上一次笔记导出出问题就是「点导出生成不了文件」，所以这里的判据一律落在产物上。
enum DocumentExporterSelfTest {

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
        c.note("Word / PDF 导出自检（纯本地 · 临时目录 · 不联网、不加载模型）")

        c.note("")
        c.note("─── 一、内容结构 ───")
        checkContent(c)

        c.note("")
        c.note("─── 二、Word（.docx 三个部件）───")
        checkDocxParts(c)

        c.note("")
        c.note("─── 三、Word 落盘（真打包、真解包）───")
        checkDocxWrite(c)

        c.note("")
        c.note("─── 四、PDF 落盘 ───")
        checkPDF(c)

        c.note("")
        c.note(c.failed == 0
            ? "✅ Word / PDF 导出自检通过（\(c.passed) 条）"
            : "❌ Word / PDF 导出自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }

    // MARK: - 一

    private static func checkContent(_ c: Checker) {
        let content = DocumentExporter.content(meta: fixtureMeta(), notes: fixtureNotes(),
                                               questions: [answeredQuestion(), unaskedQuestion()],
                                               glossary: [
                                                GlossaryEntry(term: "梯度下降", note: "沿负梯度方向迭代"),
                                                GlossaryEntry(term: "未提及术语", note: "不该出现"),
                                               ])
        c.check(content.title == "第 3 讲：梯度下降", "标题取会话标题")
        c.check(content.subtitle.contains("2026-11-10") && content.subtitle.contains("47 分钟"),
                "副标题带日期与时长", content.subtitle)
        let headings = content.blocks.compactMap(\.heading)
        c.check(headings.contains("重点") && headings.contains("考点") && !headings.contains("待办"),
                "空组不出现（这节没有待办）", headings.joined(separator: "/"))
        c.check(headings.contains("课堂提问"), "有答案的提问成节")
        let questionLines = content.blocks.first { $0.heading == "课堂提问" }?.lines ?? []
        c.check(questionLines.contains { $0.contains("学习率应该怎么选？") }, "提问正文进来")
        c.check(!questionLines.contains { $0.contains("泰勒展开") }, "未查的提问不进文档")
        let terms = content.blocks.first { $0.heading == "术语" }?.lines ?? []
        c.check(terms == ["梯度下降：沿负梯度方向迭代"],
                "术语只收「笔记里提到过且有释义」的", terms.joined(separator: "、"))
    }

    // MARK: - 二

    private static func checkDocxParts(_ c: Checker) {
        let content = DocumentExporter.content(meta: fixtureMeta(), notes: fixtureNotes(),
                                               questions: [answeredQuestion()], glossary: [])
        let parts = DocumentExporter.docxParts(content)
        c.check(parts.keys.sorted() == ["[Content_Types].xml", "_rels/.rels", "word/document.xml"],
                "docx 三个部件齐全", parts.keys.sorted().joined(separator: ", "))
        let document = parts["word/document.xml"] ?? ""
        c.check(document.contains("<w:document"), "document.xml 有根元素")
        c.check(document.contains("<w:sectPr>"), "有页面设置（否则 Word 打开是 0 页）")
        c.check(document.contains("第 3 讲：梯度下降"), "标题写进正文")
        c.check(parts["[Content_Types].xml"]?.contains("wordprocessingml.document.main+xml") == true,
                "内容类型声明指向 document.main")

        let escaped = DocumentExporter.xmlEscape("A&B <C> \"D\"")
        c.check(escaped == "A&amp;B &lt;C&gt; &quot;D&quot;",
                "XML 特殊字符全部转义（否则 Word 报文件损坏）", escaped)
    }

    // MARK: - 三

    private static func checkDocxWrite(_ c: Checker) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("note.docx")

        let content = DocumentExporter.content(meta: fixtureMeta(), notes: fixtureNotes(),
                                               questions: [answeredQuestion()],
                                               glossary: [GlossaryEntry(term: "梯度下降", note: "沿负梯度方向迭代")])
        do {
            try DocumentExporter.writeDocx(content, to: url)
        } catch {
            c.check(false, "写 .docx 不抛错", "\(error)")
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        c.check(size > 600, "文件大小合理（>600 字节）", "\(size) 字节")

        let listing = run("/usr/bin/unzip", ["-l", url.path])
        c.check(listing.contains("word/document.xml"), "解包能看到 document.xml")
        c.check(listing.contains("[Content_Types].xml") || listing.contains("Content_Types_.xml"),
                "解包能看到 [Content_Types].xml")

        let xml = run("/usr/bin/unzip", ["-p", url.path, "word/document.xml"])
        c.check(xml.contains("第 3 讲"), "解回来的正文里有标题")
        c.check(xml.contains("负梯度方向是局部下降最快的方向"), "解回来的正文里有重点条目")
    }

    // MARK: - 四

    private static func checkPDF(_ c: Checker) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let content = DocumentExporter.content(meta: fixtureMeta(), notes: fixtureNotes(),
                                               questions: [answeredQuestion()], glossary: [])
        let short = root.appendingPathComponent("short.pdf")
        do {
            try DocumentExporter.writePDF(content, to: short)
        } catch {
            c.check(false, "写 PDF 不抛错", "\(error)")
            return
        }
        let head = (try? FileHandle(forReadingFrom: short))?.readData(ofLength: 5) ?? Data()
        c.check(String(data: head, encoding: .ascii) == "%PDF-", "文件头是 %PDF-")

        if let doc = CGPDFDocument(short as CFURL) {
            c.check(doc.numberOfPages >= 1, "CGPDFDocument 能打开且至少 1 页", "\(doc.numberOfPages) 页")
        } else {
            c.check(false, "CGPDFDocument 能打开（打不开 = 文件坏了）")
        }

        // 长内容必须分页：把重点条目灌到 300 条，一页装不下
        var longNotes = fixtureNotes()
        var anchor = Anchor(partID: UUID(), segmentID: UUID(), startMillis: 0)
        longNotes.items = (1...300).map { index in
            anchor.startMillis = index * 1_000
            return StudyItem(kind: .keyPoint, text: "第 \(index) 条要点：这是一段用来把页面填满的文字。",
                             anchors: [anchor])
        }
        let longContent = DocumentExporter.content(meta: fixtureMeta(), notes: longNotes,
                                                   questions: [], glossary: [])
        let multi = root.appendingPathComponent("multi.pdf")
        try? DocumentExporter.writePDF(longContent, to: multi)
        if let doc = CGPDFDocument(multi as CFURL) {
            c.check(doc.numberOfPages > 1, "长内容自动分页（>1 页）", "\(doc.numberOfPages) 页")
        } else {
            c.check(false, "长文档 PDF 能打开")
        }

        // 单条超长文本也必须分页：这一条是给「writePDF 到底有没有用 wrap 的宽度」兜底的
        // （上一版只验了 wrap 函数本身，把版心宽度改大 10 倍照样全绿，等于没验接线）
        var oneLongNote = fixtureNotes()
        oneLongNote.items = [StudyItem(kind: .keyPoint,
                                       text: String(repeating: "课堂笔记里的很长一句话。", count: 200),
                                       anchors: [Anchor(partID: UUID(), segmentID: UUID(), startMillis: 0)])]
        let oneLong = DocumentExporter.content(meta: fixtureMeta(), notes: oneLongNote,
                                               questions: [], glossary: [])
        let oneLongURL = root.appendingPathComponent("one-long.pdf")
        try? DocumentExporter.writePDF(oneLong, to: oneLongURL)
        if let doc = CGPDFDocument(oneLongURL as CFURL) {
            c.check(doc.numberOfPages >= 2, "单条超长文本也会折行分页（接线真的用了版心宽度）",
                    "\(doc.numberOfPages) 页")
        } else {
            c.check(false, "单条超长文本 PDF 能打开")
        }

        // 折行：每一行都不能超过版心宽度
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 11, nil)
        let long = String(repeating: "课堂笔记测试文本宽度", count: 40)
        let lines = DocumentExporter.wrap(long, font: font, size: 11, width: 483)
        c.check(lines.count > 1, "长段落被折成多行", "\(lines.count) 行")
        c.check(!lines.contains(where: { $0.isEmpty }), "折行不产生空行")
        c.check(DocumentExporter.wrap("", font: font, size: 11, width: 100) == [""],
                "空段落返回一行空串（不丢段）")

        c.check(DocumentExporter.defaultFileName(content: content, ext: "pdf") == "第 3 讲：梯度下降.pdf",
                "全角冒号保留（macOS 文件名合法）",
                DocumentExporter.defaultFileName(content: content, ext: "pdf"))
        var asciiTitle = content
        asciiTitle.title = "第 3 讲: 梯度下降"
        c.check(DocumentExporter.defaultFileName(content: asciiTitle, ext: "docx") == "第 3 讲- 梯度下降.docx",
                "半角冒号换短横（Finder 会把它显示成斜杠）",
                DocumentExporter.defaultFileName(content: asciiTitle, ext: "docx"))
    }

    // MARK: - 工具

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
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
        return StudyNotes(sessionID: UUID(), generatedAt: Date(), model: "deepseek-chat", items: [
            StudyItem(kind: .summary, text: "这节课讲梯度下降与学习率选择。", anchors: [anchor(0)]),
            StudyItem(kind: .keyPoint, text: "负梯度方向是局部下降最快的方向。", anchors: [anchor(42_000)]),
            StudyItem(kind: .examFocus, text: "会考学习率过大/过小的两种现象。", anchors: [anchor(120_000)]),
            StudyItem(kind: .term, text: "梯度下降", anchors: [anchor(5_000)]),
        ])
    }

    private static func answeredQuestion() -> LessonQuestion {
        var q = LessonQuestion(text: "学习率应该怎么选？", rawSentence: "学习率应该怎么选？",
                               startTimeMillis: 42_000, level: 2, status: .answered)
        q.answer = QuestionAnswer(markdown: "看损失曲线，先大后小。",
                                  sources: [AnswerSource(title: "Wikipedia", url: "https://example.com/lr")],
                                  model: "deepseek-chat", searchProvider: "tavily")
        return q
    }

    private static func unaskedQuestion() -> LessonQuestion {
        LessonQuestion(text: "为什么泰勒展开的一阶项能近似原函数？",
                       rawSentence: "为什么泰勒展开的一阶项能近似原函数？",
                       startTimeMillis: 60_000, level: 2, status: .unasked)
    }
}
