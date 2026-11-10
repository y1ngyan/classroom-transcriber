import Foundation

/// 把一节课导出成 Obsidian vault 里的一组笔记：主笔记 + 术语页 + 课程索引。
///
/// 为什么单独一套而不是复用 `StudyNotesMarkdown`：那份是**单文件可读文本**，
/// 导出去是为了「打开就能读」；Obsidian 要的是**能被链接的碎片**——frontmatter 让
/// 它进 Dataview 表、`[[术语]]` 让它进关系图、按课程分目录让它能被整课拖进 git。
/// 两者的判据不一样，硬合成一份，两边都不好用。
///
/// **全部是纯函数**（`render` 系列不碰磁盘），落盘只在 `write` 一处：
/// 这样「导出的内容对不对」能离线自检，「写到哪、要不要覆盖」单独测。
enum ObsidianExporter {

    // MARK: - 输入

    /// 会话元信息。刻意不复用整棵 `SessionSummary`：导出只需要这几项，
    /// 传整棵树会让自检为了造夹具去拼一个完整的会话。
    struct Meta: Equatable {
        var course: String
        var title: String
        var startedAt: Date
        var durationMillis: Int
        var recordingName: String?
        /// 会计进 vault 的标签（除固定的「课堂笔记」外）
        var extraTags: [String] = []

        init(course: String, title: String, startedAt: Date,
             durationMillis: Int, recordingName: String? = nil, extraTags: [String] = []) {
            self.course = course
            self.title = title
            self.startedAt = startedAt
            self.durationMillis = durationMillis
            self.recordingName = recordingName
            self.extraTags = extraTags
        }

        var courseFolder: String {
            let trimmed = course.trimmingCharacters(in: .whitespacesAndNewlines)
            return ObsidianExporter.sanitize(trimmed.isEmpty ? "未分类" : trimmed)
        }
    }

    /// 一份待写文件：相对 vault 的路径 + 内容
    struct Document: Equatable {
        var relativePath: String
        var content: String
    }

    struct Options: Equatable {
        /// 每条术语单独建一页（`术语/词.md`），主笔记里用 `[[词]]` 链过去
        var glossaryPages: Bool = true
        /// 课程索引页（`<课程>/<课程>.md`）里追加这讲的链接
        var courseIndex: Bool = true

        init(glossaryPages: Bool = true, courseIndex: Bool = true) {
            self.glossaryPages = glossaryPages
            self.courseIndex = courseIndex
        }
    }

    // MARK: - 渲染

    static func documents(meta: Meta,
                          notes: StudyNotes?,
                          questions: [LessonQuestion],
                          glossary: [GlossaryEntry],
                          options: Options = Options()) -> [Document] {
        var docs: [Document] = []
        let folder = meta.courseFolder
        let lectureName = sanitize(lectureFileName(meta: meta)) + ".md"

        docs.append(Document(relativePath: "\(folder)/\(lectureName)",
                             content: noteMarkdown(meta: meta, notes: notes, questions: questions,
                                                   glossary: glossary, options: options)))

        if options.glossaryPages {
            // 只给「这节笔记里真的提到过」的术语建页：把整份词表都倒进 vault，
            // 关系图会被一堆从没出现过的词污染，反而看不出这节课讲了什么
            let referenced = Set(notes?.items.filter { $0.kind == .term }.map(\.text) ?? [])
            for entry in glossary where referenced.contains(entry.term) {
                docs.append(Document(relativePath: "\(folder)/术语/\(sanitize(entry.term)).md",
                                     content: glossaryMarkdown(entry: entry, meta: meta)))
            }
        }

        if options.courseIndex {
            docs.append(Document(relativePath: "\(folder)/\(folder).md",
                                 content: courseIndexMarkdown(meta: meta, lectureFileName: lectureName)))
        }
        return docs
    }

    /// 主笔记正文
    static func noteMarkdown(meta: Meta,
                             notes: StudyNotes?,
                             questions: [LessonQuestion],
                             glossary: [GlossaryEntry],
                             options: Options = Options()) -> String {
        var out: [String] = []
        out.append(frontmatter(meta: meta, notes: notes, questions: questions))
        out.append("")
        out.append("# \(meta.title.isEmpty ? meta.courseFolder : meta.title)")
        out.append("")

        // 抬头一行：这节课是什么时候的、多长。没有它，三个月后打开 vault
        // 分不清这份笔记对应哪次课
        let dateText = dayFormatter.string(from: meta.startedAt)
        out.append("> \(dateText) · \(durationText(meta.durationMillis))"
                   + (meta.recordingName.map { " · 录音 `\($0)`" } ?? ""))
        out.append("")

        if let notes {
            for kind in StudyItemKind.allCases where kind != .term {
                let group = notes.items.filter { $0.kind == kind }
                guard !group.isEmpty else { continue }
                out.append("## \(kind.label)")
                out.append("")
                for item in group {
                    out.append("- \(linkified(item.text, glossary: glossary))")
                }
                out.append("")
            }
            let terms = notes.items.filter { $0.kind == .term }
            if !terms.isEmpty {
                out.append("## \(StudyItemKind.term.label)")
                out.append("")
                for item in terms {
                    out.append("- \(linkified(item.text, glossary: glossary))")
                }
                out.append("")
            }
        }

        if !questions.isEmpty {
            out.append("## 课堂提问")
            out.append("")
            for q in questions {
                out.append(questionLine(q))
            }
            out.append("")
        }

        out.append("---")
        out.append("")
        out.append("返回 [[\(meta.courseFolder)]]")
        out.append("")
        return out.joined(separator: "\n")
    }

    /// 一条提问：时间戳 + 问题 + 状态；有答案时缩进一段引用
    static func questionLine(_ q: LessonQuestion) -> String {
        let stamp = timestamp(q.startTimeMillis)
        var head = "- `\(stamp)` \(q.text) — \(statusText(q.status))"
        if let answer = q.answer, !answer.markdown.isEmpty {
            let body = answer.markdown
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  > \($0)" }
                .joined(separator: "\n")
            head += "\n" + body
            if let first = answer.sources.first {
                head += "\n  > 来源：[\(first.title)](\(first.url))"
            }
        }
        return head
    }

    static func statusText(_ status: QuestionStatus) -> String {
        switch status {
        case .unasked: return "未查"
        case .searching: return "查询中"
        case .answered: return "有答案"
        case .noResults: return "查不到"
        case .failed: return "失败"
        }
    }

    /// 术语页
    static func glossaryMarkdown(entry: GlossaryEntry, meta: Meta) -> String {
        var out: [String] = []
        out.append("---")
        out.append("title: \(quoted(entry.term))")
        out.append("tags: [术语, \(quoted(meta.courseFolder))]")
        out.append("---")
        out.append("")
        out.append("# \(entry.term)")
        out.append("")
        if !entry.note.isEmpty {
            out.append(entry.note)
            out.append("")
        }
        if !entry.aliases.isEmpty {
            out.append("**常见误听**：" + entry.aliases.joined(separator: "、"))
            out.append("")
        }
        out.append("出现在：[[\(sanitize(lectureFileName(meta: meta)))]]")
        out.append("")
        return out.joined(separator: "\n")
    }

    /// 课程索引页
    static func courseIndexMarkdown(meta: Meta, lectureFileName: String) -> String {
        let link = "- [[\(lectureFileName.replacingOccurrences(of: ".md", with: ""))]]"
        var out: [String] = []
        out.append("---")
        out.append("title: \(quoted(meta.courseFolder))")
        out.append("tags: [课程索引]")
        out.append("---")
        out.append("")
        out.append("# \(meta.courseFolder)")
        out.append("")
        out.append("## 课时")
        out.append("")
        out.append(link)
        out.append("")
        return out.joined(separator: "\n")
    }

    /// 课程索引是**追加式**的：每次导出加一条，已存在就不重复加。
    ///
    /// 为什么不整页重写：vault 是用户的，他可能在里面手写了复习计划、
    /// 插了别的链接；我们从 `documents` 拿到的只有「这一讲」，
    /// 整页重写等于把用户写的东西擦掉
    static func appendingIndex(existing: String?, lectureLink: String) -> String {
        guard let existing, !existing.isEmpty else { return lectureLink + "\n" }
        if existing.contains(lectureLink) { return existing }
        var text = existing
        if !text.hasSuffix("\n") { text += "\n" }
        return text + lectureLink + "\n"
    }

    // MARK: - 落盘

    enum WriteError: LocalizedError {
        case emptyVault
        case notADirectory(String)

        var errorDescription: String? {
            switch self {
            case .emptyVault: return "还没选 Obsidian vault 目录"
            case .notADirectory(let path): return "这个路径不是文件夹：\(path)"
            }
        }
    }

    /// 写到 vault。`overwrite == false` 时已存在的文件原样跳过（返回 skipped）。
    ///
    /// 索引页单独走追加逻辑：它天生是「累积一节课一条」的文件，
    /// 用覆盖语义会每导一次只剩最后一讲
    @discardableResult
    static func write(_ docs: [Document],
                      to vault: URL,
                      overwrite: Bool,
                      courseIndexPath: String? = nil) throws -> (written: [URL], skipped: [URL]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir) else {
            throw WriteError.notADirectory(vault.path)
        }
        guard isDir.boolValue else { throw WriteError.notADirectory(vault.path) }

        var written: [URL] = []
        var skipped: [URL] = []
        for doc in docs {
            let url = vault.appendingPathComponent(doc.relativePath)
            let isIndex = (doc.relativePath == courseIndexPath)
            if FileManager.default.fileExists(atPath: url.path) {
                if isIndex {
                    let old = try? String(contentsOf: url, encoding: .utf8)
                    let link = doc.content
                        .split(separator: "\n")
                        .first { $0.hasPrefix("- [[") }
                        .map(String.init) ?? ""
                    let merged = appendingIndex(existing: old, lectureLink: link)
                    try merged.write(to: url, atomically: true, encoding: .utf8)
                    written.append(url)
                } else if overwrite {
                    try doc.content.write(to: url, atomically: true, encoding: .utf8)
                    written.append(url)
                } else {
                    skipped.append(url)
                }
                continue
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try doc.content.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }
        return (written, skipped)
    }

    // MARK: - 小工具

    static func sanitize(_ raw: String) -> String {
        // Obsidian 不支持文件名里的 / \ : * ? " < > |；换行会把路径整段拆坏
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var cleaned = raw.components(separatedBy: banned).joined(separator: "-")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.contains("--") { cleaned = cleaned.replacingOccurrences(of: "--", with: "-") }
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)) }
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    /// YAML 值：含这些字符就必须加引号，否则 frontmatter 解析失败
    /// （最常见的是标题里带冒号，比如「第 3 讲：梯度下降」）
    static func quoted(_ value: String) -> String {
        let needsQuote = value.contains(":") || value.contains("#") || value.contains("\"")
            || value.contains("[") || value.contains("]") || value.contains(",")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return needsQuote ? "\"\(escaped)\"" : value
    }

    static func frontmatter(meta: Meta, notes: StudyNotes?, questions: [LessonQuestion]) -> String {
        var tags = ["课堂笔记"] + meta.extraTags + [meta.courseFolder]
        // 去重但保序：`tags` 在 Obsidian 侧是有序的，重复项会让 Dataview 计数翻倍
        var seen = Set<String>()
        tags = tags.filter { seen.insert($0).inserted }

        let answered = questions.filter { $0.status == .answered }.count
        var lines: [String] = ["---"]
        lines.append("title: \(quoted(meta.title.isEmpty ? meta.courseFolder : meta.title))")
        lines.append("course: \(quoted(meta.courseFolder))")
        lines.append("date: \(dayFormatter.string(from: meta.startedAt))")
        lines.append("duration: \(durationText(meta.durationMillis))")
        lines.append("tags: [\(tags.map { quoted($0) }.joined(separator: ", "))]")
        if let recording = meta.recordingName {
            lines.append("recording: \(quoted(recording))")
        }
        lines.append("questions: \(questions.count)")
        lines.append("answered: \(answered)")
        if let notes {
            lines.append("model: \(quoted(notes.model))")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    static func lectureFileName(meta: Meta) -> String {
        let day = dayFormatter.string(from: meta.startedAt)
        let title = meta.title.isEmpty ? "课堂记录" : meta.title
        return "\(day) \(title)"
    }

    static func durationText(_ millis: Int) -> String {
        let total = max(0, millis) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func timestamp(_ millis: Int) -> String {
        let total = max(0, millis) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 正文里的术语替换成 `[[术语]]`。
    ///
    /// 逐字符扫描而不是 `replacingOccurrences`：后者会**替换进已经生成的链接里**
    /// ——先替「梯度下降法」，再替「梯度下降」，就得到 `[[[[梯度下降]]法]]`，
    /// 而 Obsidian 把 `[[` 当链接起点，多一层括号整句都显示成乱码。
    /// 扫描版顺带保证长词优先（术语表按长度降序，第一个前缀命中就跳过去）
    static func linkified(_ text: String, glossary: [GlossaryEntry]) -> String {
        let terms = glossary.map(\.term).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !terms.isEmpty else { return text }

        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            // 已经是一个链接：原样抄过去，绝不往里再嵌
            if text[index...].hasPrefix("[["), let end = text.range(of: "]]", range: index..<text.endIndex) {
                out += text[index..<end.upperBound]
                index = end.upperBound
                continue
            }
            if let hit = terms.first(where: { text[index...].hasPrefix($0) }) {
                out += "[[\(hit)]]"
                index = text.index(index, offsetBy: hit.count)
                continue
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    private static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }
}
