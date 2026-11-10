import Foundation

/// 把一节课导出成 Anki 能直接导入的制卡文件（CSV，制表符分隔）。
///
/// 为什么**只做有答案的提问和有释义的术语**：卡片背面必须有可信内容。
/// 考点那一栏是模型写的一句话摘要，把它当答案翻出来，学生背的是模型的措辞
/// 而不是老师的说法——这比「少几张卡」代价大得多。宁缺不编。
///
/// 为什么是 CSV 而不是 `.apkg`：`.apkg` 是一个带 SQLite 元数据和媒体清单的 zip，
/// 生成它要复刻 Anki 的库结构与版本兼容规则，任何一处对不上就是「导入失败」，
/// 而 CSV 是 Anki 官方长期支持的入口（文件 → 导入，选分隔符即可）。
/// 代价是用户要自己选一次牌组与字段映射，这一步写进导出后的提示里。
enum AnkiExporter {

    struct Card: Equatable {
        var front: String
        var back: String
        /// Anki 的标签用 `::` 分层（`机器学习::2026-11-10`）
        var tags: [String]
    }

    struct Options: Equatable {
        /// 是否在文件头写 UTF-8 BOM。Windows 版 Anki 与 Excel 不带 BOM 会串码，
        /// macOS 版读不读都行——默认带上，代价只有一个不可见字符
        var bom: Bool = true
        /// 卡片里是否附来源（有 URL 的提问答案）
        var includeSources: Bool = true
        /// 是否写一行表头。**默认不写**：Anki 默认把每一行都当卡片，
        /// 表头会变成一张「正面/背面/标签」的垃圾卡，用户还得手动跳首行
        var includeHeader: Bool = false

        init(bom: Bool = true, includeSources: Bool = true, includeHeader: Bool = false) {
            self.bom = bom
            self.includeSources = includeSources
            self.includeHeader = includeHeader
        }
    }

    enum ExportError: LocalizedError {
        case noCards

        var errorDescription: String? {
            switch self {
            case .noCards:
                return "这节课还没有可制卡的内容（需要「有答案的提问」或「有释义的术语」）"
            }
        }
    }

    // MARK: - 制卡

    static func cards(questions: [LessonQuestion],
                      glossary: [GlossaryEntry],
                      options: Options = Options()) -> [Card] {
        var out: [Card] = []
        var seen = Set<String>()

        for q in questions {
            guard q.status == .answered, let answer = q.answer else { continue }
            let body = answer.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let key = "q:" + q.normalizedText
            guard seen.insert(key).inserted else { continue }

            var back = body
            if options.includeSources {
                let links = answer.sources.prefix(2).map { "\($0.title)（\($0.url)）" }
                if !links.isEmpty {
                    back += "\n\n来源：" + links.joined(separator: "；")
                }
            }
            out.append(Card(front: q.text, back: back, tags: ["提问"]))
        }

        for entry in glossary {
            let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
            // 没有释义的术语不建卡：背面空白等于让用户背一个空壳
            guard !note.isEmpty else { continue }
            let key = "g:" + entry.term
            guard seen.insert(key).inserted else { continue }
            var back = note
            if !entry.aliases.isEmpty {
                back += "\n\n常见误听：" + entry.aliases.joined(separator: "、")
            }
            out.append(Card(front: "「\(entry.term)」是什么？", back: back, tags: ["术语"]))
        }
        return out
    }

    // MARK: - 渲染

    /// 生成 CSV 文本。三列：正面 / 背面 / 标签（Anki 导入时把它映射成 Tags 字段）。
    ///
    /// 转义只有三条，但缺一条就会毁掉整份文件：
    /// - 字段内换行 → `<br>`（裸换行会把一张卡拆成两行，后面全错位）
    /// - 字段内制表符 → 空格（制表符是分隔符）
    /// - 字段首尾的引号由 Anki 的 CSV 规则处理；这里统一换成中文引号，避免半角引号
    ///   与 Anki 的引号包裹规则打架（Anki 支持双引号包裹，但只在字段含分隔符时才需要，
    ///   我们已把分隔符消掉，所以不需要包裹）
    static func render(_ cards: [Card], deck: String, options: Options = Options()) -> String {
        var lines: [String] = []
        if options.includeHeader {
            lines.append(["正面", "背面", "标签"].joined(separator: "\t"))
        }
        for card in cards {
            let tags = ([deck] + card.tags).filter { !$0.isEmpty }.joined(separator: "::")
            lines.append([escape(card.front), escape(card.back), escape(tags)].joined(separator: "\t"))
        }
        let text = lines.joined(separator: "\n") + "\n"
        return options.bom ? "\u{FEFF}" + text : text
    }

    static func escape(_ field: String) -> String {
        field
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\"", with: "”")
    }

    /// 默认文件名：`机器学习-2026-11-10-anki.csv`
    static func defaultFileName(course: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = course.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = name.isEmpty ? "未分类" : name.replacingOccurrences(of: "/", with: "-")
        return "\(safe)-\(formatter.string(from: date))-anki.csv"
    }

    /// 牌组名：课程名（Anki 支持 `父::子` 分层）
    static func deckName(course: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = course.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "未分类" : name) + "::" + formatter.string(from: date)
    }
}
