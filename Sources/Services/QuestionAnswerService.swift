import Foundation

/// 查询的两个阶段。界面上是一行小字：「正在联网检索资料」→「正在整理答案」
/// （设计稿 §2.1 第 8 步）。阶段只影响那**一行**，不是全局状态
enum QuestionAnswerPhase: Equatable {
    case searching
    case composing

    var text: String {
        switch self {
        case .searching: return "正在联网检索资料"
        case .composing: return "正在整理答案"
        }
    }
}

/// 一次查询的结果。**刻意不用 throw**：三种结局里只有两种是「失败」，
/// 而「有资料但没答案」不是错误（§5.2 把它归到 noResults），
/// 用异常见过把它和「模型挂了」混成一档——那正是 B 要防的
enum QuestionAnswerOutcome: Equatable {
    case answered(QuestionAnswer)
    /// 一条资料都没搜到，或搜到了但模型没给出可用答案。
    /// `sources` 非空时界面要把来源列出来，让学生自己点（§2.3）
    case noResults(sources: [AnswerSource])
    case failed(QuestionFailure)
}

/// 「问题 → 带来源的答案」的编排（设计稿 §5.2 / §8.2）。
///
/// 两步：`SearchService` 检索 → DeepSeek 基于**检索到的资料**整理正文。
/// 两条硬约束：
///
/// 1. **来源只能由代码从真实 `SearchHit` 拷贝**（拍板第 5 条）。模型看到
///    的提示词里只有「编号 + 标题 + 摘要」，没有 URL，返回值也只取正文；
///    `QuestionAnswer.sources` 直接由 `SearchHit` 的 `title` / `url` 生成。
///    模型在正文里写什么链接都改变不了来源列表——「编造链接」在结构上
///    不可能发生。这与 `FactCheckService` 的做法**有意不一致**，别去统一。
/// 2. **不让模型兜底**：搜不到资料就不调模型（§1「非目标」）；模型返回的
///    正文是寒暄 / 「我无法回答」时走 noResults，不把它包装成答案。
///
/// 检索与模型调用做成可注入的闭包，`--question-flow-selftest` 才能在不联网
/// 的情况下把每一条分支（空结果、全失败、模型失败、寒暄、来源拷贝）走一遍。
struct QuestionAnswerService {
    var search: @Sendable (_ query: String) async throws -> [SearchHit]
    var chat: @Sendable (_ systemPrompt: String, _ userPrompt: String) async throws -> String
    var model: String
    var searchProvider: String

    /// 生产路径。密钥读取沿用既有 `SearchService` / `ModelText` 的路径
    /// （`AppConfig`），不另开一套
    static let live = QuestionAnswerService(
        search: { query in
            try await SearchService.search(query: query, maxResults: 5)
        },
        chat: { system, user in
            try await ModelText.deepSeekChat(
                systemPrompt: system, userPrompt: user, temperature: 0
            )
        },
        model: ModelText.defaultModel,
        searchProvider: AppConfig.searchProvider
    )

    /// 答案正文的字数上限（拍板第 8 条：**不硬截断**，提示词约束在 400 字以内）。
    /// 这里是给提示词用的，拿到超长正文也完整保存
    static let promptWordBudget = 400

    /// 模型返回的正文算不算「可用答案」（§5.2 的空答案判据）：
    /// 去掉空白后，剥掉「我无法回答 / 没找到」这类否定式前缀，剩余 < 10 字
    /// 就判 noResults。**不把这段模型的话当答案**。
    static func isUsableAnswer(_ text: String) -> Bool {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "抱歉，", "抱歉,", "对不起，", "对不起,",
            "我无法回答", "无法回答", "我不能回答", "不能回答",
            "我没有找到", "没有找到", "我找不到", "找不到",
            "资料不足", "信息不足", "无法确定", "不能确定", "我不知道",
        ]
        // 前缀可能连着出现（「抱歉，我无法回答…」），剥到不再变为止
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where s.hasPrefix(prefix) {
                s.removeFirst(prefix.count)
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return s.count >= 10
    }

    /// 来源列表：**只从这一轮真实的 `SearchHit` 拷贝**，按 URL 去重、保留顺序。
    /// 空 URL 丢掉（它不构成一个能点开的来源）
    static func sources(from hits: [SearchHit]) -> [AnswerSource] {
        var seen = Set<String>()
        var result: [AnswerSource] = []
        for hit in hits {
            let url = hit.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, seen.insert(url).inserted else { continue }
            let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(AnswerSource(title: title.isEmpty ? url : title, url: url))
        }
        return result
    }

    static func systemPrompt() -> String {
        """
        你是一个课堂问题的资料整理助手。根据给定的网页检索结果回答学生的问题。

        要求：
        - 只使用给定检索结果里的信息；资料不足以回答时，直接说「资料不足以回答」，不要猜测或补充常识。
        - 用中文回答，\(promptWordBudget) 字以内，可以使用 Markdown。
        - 引用资料时写编号，例如 [1][2]；不要在正文里写网址。
        - 不要整段复制原文。
        """
    }

    static func userPrompt(question: String, hits: [SearchHit]) -> String {
        var lines = ["问题：\(question)", "", "检索结果："]
        for (index, hit) in hits.enumerated() {
            lines.append("[\(index + 1)] \(hit.title)")
            if !hit.snippet.isEmpty {
                lines.append(hit.snippet)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 主流程。任何一步抛错都映射成 `failed`，且**两类失败分开归类**：
    /// 检索失败 = 通道不通；模型失败 = 通道通了但这一环没成功（§4.4）
    func answer(
        question: String,
        now: Date = Date(),
        onPhase: (@Sendable (QuestionAnswerPhase) -> Void)? = nil
    ) async -> QuestionAnswerOutcome {
        onPhase?(.searching)

        let hits: [SearchHit]
        do {
            hits = try await search(question)
        } catch {
            // 搜索层的所有错误（网络 / 密钥 / HTTP / 解析）都归「通道不通」。
            // 不把错误正文持久化（§4.3：详细错误不落盘），但这里**不吞**它：
            // 调用方可以打日志
            return .failed(.channel)
        }

        let sources = Self.sources(from: hits)
        // 一条资料都没搜到：**不调模型**。让模型凭记忆答就是 §1 明确禁止的
        // 「通道不通时用模型记忆兜底」的变体
        guard !hits.isEmpty else { return .noResults(sources: []) }

        onPhase?(.composing)
        let reply: String
        do {
            reply = try await chat(Self.systemPrompt(),
                                   Self.userPrompt(question: question, hits: hits))
        } catch {
            return .failed(.model)
        }

        let markdown = ModelText.stripCodeFence(reply)
        guard Self.isUsableAnswer(markdown) else {
            // 有资料但没答案：来源仍然列出来（学生自己点），正文一个字都不显示
            return .noResults(sources: sources)
        }

        let answer = QuestionAnswer(
            markdown: markdown,
            sources: sources,
            createdAt: now,
            model: model,
            searchProvider: searchProvider
        )
        return .answered(answer)
    }
}
