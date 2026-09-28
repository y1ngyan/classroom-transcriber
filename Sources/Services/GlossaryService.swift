import Foundation

/// 术语校正特有的失败。请求本身失败的情形由 `ModelTextError` 直接抛出。
enum GlossaryError: LocalizedError {
    case noSegments
    case emptyGlossary

    var errorDescription: String? {
        switch self {
        case .noSegments: return "还没有转录内容，无法校正"
        case .emptyGlossary: return "术语表是空的，先加几个术语再校正"
        }
    }
}

/// 转录完成后的一轮术语校正。
///
/// 为什么需要：中文课堂只挂单个 zh-CN 模型（多模块不融合），英文术语
/// 会被按读音转写成拉丁字母。这一轮把术语表当锚点，只改拼写，
/// 不改写其他内容。
enum GlossaryService {

    /// 提示词原文（迁移前那版沿用下来的），后面接术语表。
    static let basePrompt = "以下是一段课堂转录文本，可能存在发音相似词的混淆。请根据提供的术语表进行校正，只修改明显错误的术语，不要改写其他内容。术语表："

    /// 把术语表渲染成提示词里的清单。
    static func makeGlossaryText(_ entries: [GlossaryEntry]) -> String {
        entries
            .filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
            .enumerated()
            .map { index, entry in
                var lines = ["\(index + 1). \(entry.term)"]
                let aliases = entry.aliases
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !aliases.isEmpty {
                    lines.append("   实测误转写：\(aliases.joined(separator: "、"))")
                }
                let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    lines.append("   说明：\(note)")
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    /// 渲染成带行号的待校正文本。
    ///
    /// 刻意不带时间戳：让模型把时间戳原样传回来是个没必要的风险，
    /// 解析时从原 segment 重新贴上，它就永远没机会改坏时间轴。
    static func render(_ segments: [TranscriptSegment]) -> String {
        segments
            .enumerated()
            .map { "#\($0.offset + 1) \($0.element.text)" }
            .joined(separator: "\n")
    }

    /// 解析模型返回的 `#N 文本` 行，得到 0-based 下标 → 校正后文本。
    ///
    /// 解析不出来的行直接不放进结果里，调用方遇到缺行就保留原文——
    /// 宁可少改，也不能因为模型少吐一行就把后面的内容整体错位。
    static func parse(_ response: String, expectedCount: Int) -> [Int: String] {
        var parsed: [Int: String] = [:]

        for rawLine in response.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }

            let rest = line.dropFirst()
            guard let separator = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }

            guard let number = Int(rest[rest.startIndex..<separator]),
                  number >= 1,
                  number <= expectedCount
            else { continue }

            let text = String(rest[separator...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            parsed[number - 1] = text
        }

        return parsed
    }

    /// 对一段转录做术语校正。返回新片段数组和变化清单。
    ///
    /// 不改动入参：片段 id 必须保持稳定，核查结果是按 segmentID 关联的，
    /// 换掉 id 会让已有的核查结果全变成孤儿。
    static func correct(
        _ segments: [TranscriptSegment],
        entries: [GlossaryEntry]
    ) async throws -> GlossaryOutcome {
        let usableEntries = entries.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usableEntries.isEmpty else { throw GlossaryError.emptyGlossary }

        // 空段不送模型：白占 token，还会让行号对不齐
        let targetOffsets = segments.indices.filter {
            !segments[$0].text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !targetOffsets.isEmpty else { throw GlossaryError.noSegments }

        let targets = targetOffsets.map { segments[$0] }

        let systemPrompt = """
        \(basePrompt)
        \(makeGlossaryText(usableEntries))

        硬性要求：
        - 输出每一行都以 `#序号 ` 开头，序号必须与输入**完全一致**，不许增删、合并或调换行。
        - 只改术语本身的拼写，不要改动语气、标点、语序，不要润色，不要改写非术语部分。
        - 术语表里的词如果原文已经写对，原样保留；原文用的中文说法也不要翻译成英文。
        - 拿不准的地方一律保持原样——宁可漏改，不要误改。
        - 直接输出校正后的文本，不要任何解释、前言或代码块围栏。
        """

        let response = try await ModelText.deepSeekChat(
            systemPrompt: systemPrompt,
            userPrompt: render(targets),
            temperature: 0,
            timeout: 180
        )

        let parsed = parse(response, expectedCount: targets.count)

        var corrected = segments
        var corrections: [GlossaryCorrection] = []

        for (position, offset) in targetOffsets.enumerated() {
            // 缺行 → 保持原样。模型吞行时全线错位的代价比漏改一个大得多
            guard let text = parsed[position] else { continue }
            let before = segments[offset].text
            guard text != before else { continue }

            corrected[offset].text = text
            corrections.append(
                GlossaryCorrection(
                    segmentID: segments[offset].id,
                    timestamp: segments[offset].formattedTimestamp,
                    before: before,
                    after: text
                )
            )
        }

        return GlossaryOutcome(segments: corrected, corrections: corrections)
    }

    // MARK: - 从转录内容里提词

    /// 提词时喂给模型的转录文本上限（字符）。
    ///
    /// 超长的课要截断，但不能只取开头——一门课的主题词是**均匀分布**在
    /// 整堂课里的，只看前几分钟会漏掉后半程才引入的术语。
    /// 所以按等间隔抽段，覆盖全程，而不是从头截。
    static let extractionBudget = 6000

    /// 从等间隔抽出的片段拼出提词用的正文。
    static func sample(_ segments: [TranscriptSegment], budget: Int = extractionBudget) -> String {
        let bodies = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !bodies.isEmpty else { return "" }

        let total = bodies.reduce(0) { $0 + $1.count }
        guard total > budget else { return bodies.joined(separator: "\n") }

        // 每隔 step 段取一段，直到把预算用完。step 至少为 1。
        let step = max(1, total / budget)
        var picked: [String] = []
        var used = 0
        var index = 0
        while index < bodies.count, used < budget {
            picked.append(bodies[index])
            used += bodies[index].count
            index += step
        }
        return picked.joined(separator: "\n")
    }

    /// 从一段转录里提取课程术语。
    ///
    /// **这个结果救不了它自己那场课。** `contextualStrings` 是开录前喂给
    /// 识别器的先验，音频过完就已经改不了了——提取出来的词只能用于
    /// 1) 同一场课的事后校正，2) 下一场同类课开录前的词表。
    /// UI 上必须说清楚，否则用户会以为点一下就能把刚录坏的那场修好。
    ///
    /// 第二列是「原文里出现过的错误写法」，这是有实测价值的一列：
    /// 模型能看着 "cludelod Clod" 反推出 Claude，用户采纳后就变成一条
    /// 带真实证据的 alias，正好符合别名「实测误转写」的定义。
    static func extractTerms(from segments: [TranscriptSegment]) async throws -> [GlossaryEntry] {
        let body = sample(segments)
        guard !body.isEmpty else { throw GlossaryError.noSegments }

        let systemPrompt = """
        下面是一段中英混合的课堂转录。识别器只挂了中文模型，英文术语会被按读音 \
        转写成走样的拉丁字母。

        请找出这堂课里**反复出现、且属于专业术语或专有名词**的英文词，给出它们的正确写法。

        硬性要求：
        - 只提**英文或拉丁字母**的词（Claude、Kubernetes、eigenvalue 这种）。
          中文词一律不要提。
        - 必须是正文里**真实出现过**的词，不许补充这堂课没讲到的相关术语。
        - 不要提常见词（the、data、model、problem、example 这类）。
        - 挑最值得校正的，最多 40 条，多了反而稀释效果。
        - 每行输出一条，格式固定为三列，用 `|` 分隔：
          `正确写法|正文里出现过的错误写法（没有就留空）|一句话说明`
        - 不要编号，不要表头，不要解释，不要代码块围栏。
        """

        let response = try await ModelText.deepSeekChat(
            systemPrompt: systemPrompt,
            userPrompt: body,
            temperature: 0,
            timeout: 180
        )

        return parseTerms(response)
    }

    /// 解析提词返回的行。
    ///
    /// 和 `parse` 一样走宽容策略：解析不出来的行直接丢，不因为模型多吐了
    /// 一句解释就整体失败。
    ///
    /// 列数决定语义，不靠内容猜：`词|误转写|说明` 三列，
    /// `词|说明` 两列，光一个词也能收。
    static func parseTerms(_ response: String, limit: Int = 40) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        var seen = Set<String>()

        func accept(term rawTerm: String, aliases: [String], note: String) {
            // 有的返回会写成 `1. Claude|...`，把行首编号剥掉
            let term = rawTerm
                .replacingOccurrences(of: #"^\d+[.、)]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, term.count <= 60 else { return }
            // 只要拉丁字母的词：模型偶尔会把中文术语也列进来，那不是我们要的
            guard term.contains(where: { $0.isLetter && $0.isASCII }) else { return }
            guard seen.insert(term.lowercased()).inserted else { return }

            entries.append(
                GlossaryEntry(
                    term: term,
                    aliases: aliases.filter { !$0.isEmpty && $0.lowercased() != term.lowercased() },
                    note: note
                )
            )
        }

        for rawLine in response.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("```") else { continue }

            let columns = line
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            switch columns.count {
            case 1:
                // 模型没按格式吐、只给了一个词。限制得死一点，
                // 免得把「以上就是这堂课的重点词汇」这种整句话当成术语收进来。
                let bare = columns[0]
                guard bare.count <= 40, bare.split(separator: " ").count <= 3 else { continue }
                accept(term: bare, aliases: [], note: "")
            case 2:
                accept(term: columns[0], aliases: [], note: columns[1])
            default:
                accept(term: columns[0], aliases: [columns[1]], note: columns[2])
            }

            if entries.count >= limit { break }
        }

        return entries
    }
}
