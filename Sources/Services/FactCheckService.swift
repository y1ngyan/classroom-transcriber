import Foundation

enum FactCheckError: LocalizedError {
    case missingKey
    case badResponse(Int, String)
    case noToolCall(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "DeepSeek 密钥未配置"
        case .badResponse(let code, let body):
            return "DeepSeek 请求失败 (HTTP \(code)): \(body.prefix(200))"
        case .noToolCall(let detail):
            return "模型未返回结构化结果: \(detail)"
        case .decoding(let detail):
            return "结果解析失败: \(detail)"
        }
    }
}

/// 事实核查：先从转录文本中抽取可核查的陈述，联网搜索取回真实来源，
/// 再让 DeepSeek **基于这些来源**判断。
///
/// 关键设计：模型被明确要求只依据给定来源作答，来源覆盖不到就返回
/// unverifiable。否则它会凭记忆编一个听起来很确定的答案。
enum FactCheckService {

    static func check(
        segmentID: UUID,
        claim: String,
        onPhase: @escaping @Sendable (FactCheckResult.Phase) -> Void
    ) async throws -> FactCheckResult {

        guard let key = AppConfig.deepSeekAPIKey else { throw FactCheckError.missingKey }

        // 1. 联网搜索
        onPhase(.searching)
        let hits = (try? await SearchService.search(query: claim)) ?? []

        // 2. 把来源整理成上下文
        let sourcesBlock: String
        if hits.isEmpty {
            sourcesBlock = "（没有检索到任何来源）"
        } else {
            sourcesBlock = hits.enumerated().map { index, hit in
                """
                [\(index + 1)] \(hit.title)
                URL: \(hit.url)
                摘要: \(hit.snippet)
                """
            }.joined(separator: "\n\n")
        }

        // 3. 让 DeepSeek 基于来源判断
        onPhase(.analyzing)
        let arguments = try await callDeepSeek(
            systemPrompt: """
            你是一个严谨的事实核查助手。你会收到一段待核查的陈述，以及从网络上检索到的真实来源。

            核查规则：
            - 只能依据提供的来源判断，不要使用你自己的记忆或推测。
            - 如果来源不足以支撑或反驳该陈述，必须返回 unverifiable，不要勉强下结论。
            - confidence 表示「你对本次判断的把握」，不是「该陈述为真的概率」。
            - explanation 用中文，简洁说明依据，并引用来源编号。
            - sources 只填写你实际依据的来源，从给定来源中原样复制标题和 URL。
            """,
            userPrompt: """
            待核查的陈述：
            \(claim)

            检索到的来源：
            \(sourcesBlock)
            """,
            apiKey: key
        )

        return parseArguments(arguments, segmentID: segmentID, claim: claim, hits: hits)
    }

    // MARK: - DeepSeek 调用

    private static func callDeepSeek(
        systemPrompt: String,
        userPrompt: String,
        apiKey: String
    ) async throws -> [String: Any] {

        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "report_fact_check",
                "description": "提交事实核查结论",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "status": [
                            "type": "string",
                            "enum": ["verified", "disputed", "unverifiable"],
                            "description": "核查结论",
                        ],
                        "explanation": [
                            "type": "string",
                            "description": "中文解释，引用来源编号",
                        ],
                        "confidence": [
                            "type": "number",
                            "description": "本次判断的把握，0 到 1",
                        ],
                        // 原规格的 schema 缺了这个字段，但 UI 要显示来源链接，故补上
                        "sources": [
                            "type": "array",
                            "description": "实际依据的来源",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "title": ["type": "string"],
                                    "url": ["type": "string"],
                                ],
                                "required": ["title", "url"],
                            ],
                        ],
                    ],
                    // 原规格也漏了 required，不写的话模型可能省略字段
                    "required": ["status", "explanation", "confidence"],
                ],
            ],
        ]

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "tools": [tool],
            "tool_choice": [
                "type": "function",
                "function": ["name": "report_fact_check"],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FactCheckError.decoding("无 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw FactCheckError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]],
              let function = toolCalls.first?["function"] as? [String: Any],
              let arguments = function["arguments"] as? String
        else {
            let preview = String((String(data: data, encoding: .utf8) ?? "").prefix(300))
            throw FactCheckError.noToolCall(preview)
        }

        guard let parsed = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else {
            throw FactCheckError.decoding("arguments 不是合法 JSON: \(arguments.prefix(200))")
        }

        return parsed
    }

    // MARK: - 解析

    private static func parseArguments(
        _ arguments: [String: Any],
        segmentID: UUID,
        claim: String,
        hits: [SearchHit]
    ) -> FactCheckResult {

        let rawStatus = (arguments["status"] as? String) ?? "unverifiable"
        let status = FactCheckResult.Status(rawValue: rawStatus) ?? .unverifiable

        let explanation = (arguments["explanation"] as? String) ?? "（模型未给出解释）"

        let confidence: Double
        if let value = arguments["confidence"] as? Double {
            confidence = value
        } else if let value = arguments["confidence"] as? Int {
            confidence = Double(value)
        } else {
            confidence = 0
        }

        var sources: [FactCheckSource] = []
        if let rawSources = arguments["sources"] as? [[String: Any]] {
            sources = rawSources.compactMap { item in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else { return nil }
                return FactCheckSource(title: title, url: url)
            }
        }

        // 模型没给来源时，退回到实际检索到的来源，保证 UI 有链接可显示
        if sources.isEmpty {
            sources = hits.prefix(3).map { FactCheckSource(title: $0.title, url: $0.url) }
        }

        return FactCheckResult(
            segmentID: segmentID,
            claim: claim,
            status: status,
            explanation: explanation,
            confidence: confidence,
            sources: sources,
            phase: .done
        )
    }
}
