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

    /// 规格给定的提示词原文，后面接术语表。
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
}
