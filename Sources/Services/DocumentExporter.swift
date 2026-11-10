import Foundation
import CoreGraphics
import CoreText

/// 导出 Word（.docx）与 PDF。
///
/// 两条产物共用一个中间结构 `DocumentContent`：**先算内容，再谈格式**。
/// 这样「导出的是不是用户看到的那份」只需要验一次（结构层），
/// 两种格式各自只负责排版，不会各拼一份正文然后慢慢漂移。
///
/// `.docx` 走**最小 OOXML**（三个部件，手工拼 XML，用系统 `zip` 打包）：
/// 引入一个 docx 库只是为了写几个段落，代价是几万行依赖和一份新的许可证义务。
/// `.pdf` 走 CoreGraphics + CoreText（A4，PingFang SC，按宽度自动折行、自动分页），
/// 全程不需要界面，因此可以在无头自检里真生成一份出来。
enum DocumentExporter {

    // MARK: - 中间结构

    struct Block: Equatable {
        var heading: String?
        var lines: [String]
    }

    struct DocumentContent: Equatable {
        var title: String
        var subtitle: String
        var blocks: [Block]
    }

    // MARK: - 内容

    /// 从笔记/提问/术语拼出一份文档内容。
    static func content(meta: ObsidianExporter.Meta,
                        notes: StudyNotes?,
                        questions: [LessonQuestion],
                        glossary: [GlossaryEntry]) -> DocumentContent {
        var blocks: [Block] = []

        if let notes {
            // 术语单独成节（下面从词表取释义），这里跳过，否则会出现两个「术语」标题
            for kind in StudyItemKind.allCases where kind != .term {
                let items = notes.items.filter { $0.kind == kind }
                guard !items.isEmpty else { continue }
                blocks.append(Block(heading: kind.label, lines: items.map(\.text)))
            }
        }

        let asked = questions.filter { $0.status == .answered && $0.answer != nil }
        if !asked.isEmpty {
            var lines: [String] = []
            for q in asked {
                lines.append("\(stamp(q.startTimeMillis)) \(q.text)")
                if let answer = q.answer {
                    for line in answer.markdown.split(separator: "\n", omittingEmptySubsequences: false) {
                        lines.append("    " + line)
                    }
                    if let source = answer.sources.first {
                        lines.append("    来源：\(source.title)（\(source.url)）")
                    }
                }
            }
            blocks.append(Block(heading: "课堂提问", lines: lines))
        }

        let usedTerms = Set(notes?.items.filter { $0.kind == .term }.map(\.text) ?? [])
        let terms = glossary.filter { usedTerms.contains($0.term) && !$0.note.isEmpty }
        if !terms.isEmpty {
            blocks.append(Block(heading: "术语",
                                lines: terms.map { "\($0.term)：\($0.note)" }))
        }

        let dateText = dateFormatter.string(from: meta.startedAt)
        let minutes = max(0, meta.durationMillis) / 60_000
        let subtitle = "\(dateText) · \(minutes) 分钟"
            + (meta.recordingName.map { " · 录音：\($0)" } ?? "")

        return DocumentContent(title: meta.title.isEmpty ? meta.courseFolder : meta.title,
                               subtitle: subtitle,
                               blocks: blocks)
    }

    // MARK: - Word（.docx）

    enum WriteError: LocalizedError {
        case zipFailed(String)
        case pdfContextFailed

        var errorDescription: String? {
            switch self {
            case .zipFailed(let detail): return "打包 .docx 失败：\(detail)"
            case .pdfContextFailed: return "生成 PDF 失败（无法创建 PDF 上下文）"
            }
        }
    }

    /// 三个部件的相对路径 → 内容。**纯函数**，可离线断言。
    static func docxParts(_ content: DocumentContent) -> [String: String] {
        var paragraphs: [String] = []
        paragraphs.append(paragraph(content.title, size: 20, bold: true))
        paragraphs.append(paragraph(content.subtitle, size: 10, color: "595959"))
        for block in content.blocks {
            if let heading = block.heading {
                paragraphs.append(paragraph(heading, size: 13, bold: true))
            }
            for line in block.lines {
                paragraphs.append(paragraph(line, size: 11))
            }
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        \(paragraphs.joined(separator: "\n"))
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr>
        </w:body>
        </w:document>
        """

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """

        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        return [
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": rels,
            "word/document.xml": document,
        ]
    }

    static func writeDocx(_ content: DocumentContent, to url: URL) throws {
        let parts = docxParts(content)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for (path, text) in parts {
            let target = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: target, atomically: true, encoding: .utf8)
        }

        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -X 去掉多余属性；-r 把三个部件收进去；工作目录切到暂存目录，路径才是相对路径
        process.arguments = ["-q", "-r", "-X", url.path, "."]
        process.currentDirectoryURL = staging
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WriteError.zipFailed(detail.isEmpty ? "zip 退出码 \(process.terminationStatus)" : detail)
        }
    }

    private static func paragraph(_ text: String, size: Int, bold: Bool = false, color: String? = nil) -> String {
        let runProps = "<w:rPr>"
            + (bold ? "<w:b/>" : "")
            + "<w:sz w:val=\"\(size * 2)\"/>"
            + (color.map { "<w:color w:val=\"\($0)\"/>" } ?? "")
            + "</w:rPr>"
        return "<w:p><w:r>\(runProps)<w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r></w:p>"
    }

    static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - PDF

    /// A4 竖版，四周 20mm 边距
    private static let pageWidth: CGFloat = 595.28
    private static let pageHeight: CGFloat = 841.89
    private static let margin: CGFloat = 56

    static func writePDF(_ content: DocumentContent, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw WriteError.pdfContextFailed
        }
        let textWidth = pageWidth - margin * 2
        var y: CGFloat = 0

        func beginPage() {
            ctx.beginPDFPage(nil)
            y = pageHeight - margin
        }
        func ensure(_ needed: CGFloat) {
            if y - needed < margin {
                ctx.endPDFPage()
                beginPage()
            }
        }

        beginPage()
        for (text, font, size, spacingAfter) in flatten(content) {
            let lines = wrap(text, font: font, size: size, width: textWidth)
            for line in lines {
                ensure(size + 4)
                draw(line, font: font, size: size, atY: y, ctx: ctx)
                y -= size + 4
            }
            y -= spacingAfter
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// 把内容摊平成「一段文字 + 字体 + 字号 + 段后间距」的序列，排版只管这一串
    private static func flatten(_ content: DocumentContent)
        -> [(String, CTFont, CGFloat, CGFloat)] {
        let regular = CTFontCreateWithName("PingFangSC-Regular" as CFString, 11, nil)
        let bold = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 11, nil)
        var out: [(String, CTFont, CGFloat, CGFloat)] = []
        out.append((content.title, CTFontCreateWithName("PingFangSC-Semibold" as CFString, 20, nil), 20, 8))
        out.append((content.subtitle, regular, 9, 18))
        for block in content.blocks {
            if let heading = block.heading {
                out.append((heading, CTFontCreateWithName("PingFangSC-Semibold" as CFString, 13, nil), 13, 6))
            }
            for line in block.lines {
                out.append((line, regular, 11, 2))
            }
            out.append(("", bold, 4, 6))
        }
        return out
    }

    private static func draw(_ text: String, font: CTFont, size: CGFloat, atY y: CGFloat, ctx: CGContext) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0.08, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.textPosition = CGPoint(x: margin, y: y)
        CTLineDraw(line, ctx)
    }

    /// 按像素宽度折行。中文按字符断，英文尽量在空格断——不追求 hyphenation，
    /// 课堂笔记里长英文串多是术语与链接，硬断反而更难读
    static func wrap(_ text: String, font: CTFont, size: CGFloat, width: CGFloat) -> [String] {
        guard !text.isEmpty else { return [""] }
        var lines: [String] = []
        var current = ""
        for character in text {
            let candidate = current + String(character)
            if measure(candidate, size: size) > width, !current.isEmpty {
                lines.append(current)
                current = String(character)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func measure(_ text: String, size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // MARK: - 文件名

    static func defaultFileName(content: DocumentContent, ext: String) -> String {
        let safe = content.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return (safe.isEmpty ? "课堂记录" : safe) + "." + ext
    }

    private static func stamp(_ millis: Int) -> String {
        let total = max(0, millis) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}
