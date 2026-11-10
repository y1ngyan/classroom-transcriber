import Foundation

/// 术语表的导入 / 导出（和同学换词表用）。
///
/// 格式上做两个取舍：
/// - **导出用 CSV**（UTF-8 BOM）：同学大概率在 Excel / WPS 里打开看一眼再导入，
///   JSON 对他们不友好；BOM 不带，Windows 侧会串码。
/// - **导入三种都吃**：我们导出的 CSV、我们导出的 JSON（同构）、以及从 Excel
///   复制出来的制表符文本。这三种是这个场景里真会出现的东西，少一种就会
///   「我把文件给他了，他导不进去」。
///
/// 合并规则只有一条：**按 `term` 去重，保留本地已有条目**。
/// 理由是本地那条可能被人手改过（误听写法、释义），而导进来的多半是没动过的模板；
/// 冲突时覆盖本地等于悄悄丢掉他的编辑
enum GlossaryTransfer {

    struct ParseResult: Equatable {
        var entries: [GlossaryEntry]
        /// 格式不对、被丢掉的条数（不是重复，是压根解析不出来）
        var rejected: Int = 0
        /// 文件内自身重复的条数（同一个 term 出现两次）
        var selfDuplicates: Int = 0
    }

    struct MergeResult: Equatable {
        var entries: [GlossaryEntry]
        var added: Int
        var skipped: Int
    }

    // MARK: - 导出

    /// CSV：术语, 误听写法, 释义。误听写法用 `|` 分隔（逗号会撞上 CSV 的列分隔符）
    static func csv(_ entries: [GlossaryEntry]) -> String {
        var lines = ["术语,误听写法,释义"]
        for entry in entries {
            let term = escape(entry.term)
            let aliases = escape(entry.aliases.joined(separator: "|"))
            let note = escape(entry.note)
            lines.append("\(term),\(aliases),\(note)")
        }
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    /// 给人直接粘进聊天框的版本：制表符分隔，没有表头噪音
    static func shareText(_ entries: [GlossaryEntry]) -> String {
        entries.map { entry in
            var line = entry.term
            if !entry.aliases.isEmpty { line += "（误听：\(entry.aliases.joined(separator: "、"))）" }
            if !entry.note.isEmpty { line += " — \(entry.note)" }
            return line
        }.joined(separator: "\n")
    }

    /// JSON：和我们盘上的 `glossary.json` 同一个结构，导回去不需要转换
    static func json(_ entries: [GlossaryEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func escape(_ field: String) -> String {
        let cleaned = field
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "”")
        // 含逗号或首尾空格才需要引号包裹；引号已在上面换成中文引号，不会打架
        if cleaned.contains(",") || cleaned.hasPrefix(" ") || cleaned.hasSuffix(" ") {
            return "\"" + cleaned + "\""
        }
        return cleaned
    }

    // MARK: - 导入

    /// 自动识别三种格式：JSON（首字符是 `[` 或 `{`）、制表符（有一行里出现 `\t`）、
    /// 其余按逗号 CSV 处理。BOM 先吃掉——Excel 与我们的导出都会带
    static func parse(_ raw: String) -> ParseResult {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParseResult(entries: []) }

        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return parseJSON(trimmed)
        }
        let separator: Character = trimmed.contains("\t") ? "\t" : ","
        return parseDelimited(trimmed, separator: separator)
    }

    private static func parseJSON(_ text: String) -> ParseResult {
        guard let data = text.data(using: .utf8) else { return ParseResult(entries: [], rejected: 1) }
        if let entries = try? JSONDecoder().decode([GlossaryEntry].self, from: data) {
            return dedupe(entries)
        }
        // 也接受「一个对象包着数组」的写法（有人会手工包一层）
        if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = wrapper["entries"] as? [[String: Any]] {
            var entries: [GlossaryEntry] = []
            for item in list {
                guard let term = (item["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !term.isEmpty else { continue }
                entries.append(GlossaryEntry(term: term,
                                             aliases: (item["aliases"] as? [String]) ?? [],
                                             note: (item["note"] as? String) ?? ""))
            }
            return dedupe(entries)
        }
        return ParseResult(entries: [], rejected: 1)
    }

    private static func parseDelimited(_ text: String, separator: Character) -> ParseResult {
        var entries: [GlossaryEntry] = []
        var rejected = 0
        var isFirstLine = true

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let fields = split(line, separator: separator)
            if isFirstLine {
                isFirstLine = false
                // 表头识别：第一格是「术语」或 term 就跳过
                let head = fields.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                if head == "术语" || head == "term" || head == "terms" { continue }
            }
            guard let term = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !term.isEmpty else {
                rejected += 1
                continue
            }
            let aliases = fields.count > 1
                ? fields[1].split(whereSeparator: { $0 == "|" || $0 == "、" || $0 == ";" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : []
            var note = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
            note = note.replacingOccurrences(of: "（误听：", with: "")
            entries.append(GlossaryEntry(term: term, aliases: aliases, note: note))
        }
        let deduped = dedupe(entries)
        return ParseResult(entries: deduped.entries, rejected: rejected,
                           selfDuplicates: deduped.selfDuplicates)
    }

    /// 按分隔符切，但尊重双引号包裹（Excel 导出的 `"机器学习, 深度学习"` 是一格）
    private static func split(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character == separator && !inQuotes {
                fields.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        fields.append(current)
        return fields
    }

    private static func dedupe(_ entries: [GlossaryEntry]) -> ParseResult {
        var seen = Set<String>()
        var kept: [GlossaryEntry] = []
        var duplicates = 0
        for entry in entries {
            let key = normalizeKey(entry.term)
            guard !key.isEmpty else { continue }
            if seen.insert(key).inserted {
                kept.append(entry)
            } else {
                duplicates += 1
            }
        }
        return ParseResult(entries: kept, rejected: 0, selfDuplicates: duplicates)
    }

    // MARK: - 合并

    /// 合并进本地词表：本地已有的 term 一律保留（哪怕导入的释义更长），
    /// 只追加本地没有的。返回新的完整列表与计数，UI 用它报「新增 N / 跳过 M」
    static func merge(existing: [GlossaryEntry], incoming: [GlossaryEntry]) -> MergeResult {
        var keys = Set(existing.map { normalizeKey($0.term) })
        var merged = existing
        var added = 0
        var skipped = 0
        for entry in incoming {
            let key = normalizeKey(entry.term)
            guard !key.isEmpty else { continue }
            if keys.contains(key) {
                skipped += 1
            } else {
                keys.insert(key)
                merged.append(entry)
                added += 1
            }
        }
        return MergeResult(entries: merged, added: added, skipped: skipped)
    }

    /// 去重键：去首尾空白 + 小写（`GPU` 与 `gpu` 是同一个词），中文不受影响
    static func normalizeKey(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
