import Foundation

/// 笔记服务特有的失败。请求本身失败的情形由 `ModelTextError` 直接抛出。
enum NotesError: LocalizedError {
    case noSegments

    var errorDescription: String? {
        switch self {
        case .noSegments: return "还没有转录内容，无法生成笔记"
        }
    }
}

/// 把整堂课的转录拼成带时间戳的文本，交给 DeepSeek 生成结构化笔记。
enum NotesService {

    /// 跟转录页保持同一套格式。
    ///
    /// 这里同时也是给模型的**输入**：模型会照着输入的样子引用时间戳，
    /// 所以这处和 `TranscriptSegment.formattedTimestamp` 一旦不一致，
    /// 笔记里的时间戳就会跟转录页对不上。
    static func formatTimestamp(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func makeTranscript(_ segments: [TranscriptSegment]) -> String {
        segments
            .map { "[\(formatTimestamp($0.startTimeMillis))] \($0.text)" }
            .joined(separator: "\n")
    }

    static func generate(from segments: [TranscriptSegment]) async throws -> String {
        let usable = segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { throw NotesError.noSegments }

        let transcript = makeTranscript(usable)

        let systemPrompt = """
        你是一位课堂笔记整理助手。你会收到一堂课的完整转录文本，\
        每一段前面带有 [分:秒] 形式的原始时间戳。

        请生成结构化的 Markdown 笔记，必须包含以下三个部分：

        ## 核心知识点大纲
        用层级列表梳理这堂课讲了哪些内容，按逻辑组织，不要照抄原文顺序。

        ## 关键术语解释
        用表格或列表列出课上的专业术语，给出简明解释。

        ## 行动项
        列出需要课后完成的事项（作业、复习重点、待查资料等）。\
        如果转录中确实没有提到任何行动项，就写「本次课未提及」——不要编造。

        硬性要求：
        - **必须保留原始时间戳**。在每一条要点后标注对应的 [分:秒]，\
        格式与输入一致，便于回看录像定位。
        - 只能依据转录内容整理，不要添加转录中没有的信息。\
        如果某个术语在转录里没解释清楚，就基于上下文谨慎概括，不要编造定义。
        - 转录来自语音识别，可能有错别字或把英文术语转写成了拉丁字母\
        （例如 "Machin learning" 实为 "machine learning"）。\
        请根据上下文纠正明显的识别错误，并在术语表中使用正确写法。
        - 直接用 Markdown 正文输出，不要用代码块包裹。
        """

        let userPrompt = """
        以下是这堂课的转录文本：

        \(transcript)
        """

        return try await ModelText.deepSeekChat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.3
        )
    }
}
