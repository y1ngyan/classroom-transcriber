import Foundation

/// 各家模型服务共用的返回文本清洗。
enum ModelText {

    /// 模型偶尔会把整段内容包在 ```markdown / ``` 里，去掉外层围栏。
    ///
    /// 只在「首行是围栏、末行也是围栏」时才剥——有些返回里正文本身
    /// 含代码块，无条件按 ``` 切会把正文切碎。
    static func stripCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count > 2 else { return trimmed }

        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// DeepSeek chat/completions 的调用与取值。
    ///
    /// 笔记和术语校正走的是同一个端点，只有提示词不同，
    /// 所以请求构造和 `choices[0].message.content` 的取值放在这里共用。
    static func deepSeekChat(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        timeout: TimeInterval = 120
    ) async throws -> String {
        guard let key = AppConfig.deepSeekAPIKey else { throw ModelTextError.missingKey }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": temperature,
            "stream": false,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelTextError.badResponse(-1, "无 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw ModelTextError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ModelTextError.empty
        }

        return stripCodeFence(content)
    }
}

enum ModelTextError: LocalizedError {
    case missingKey
    case badResponse(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey: return "DeepSeek 密钥未配置"
        case .badResponse(let code, let body):
            return "DeepSeek 请求失败 (HTTP \(code)): \(body.prefix(200))"
        case .empty: return "模型返回了空内容"
        }
    }
}
