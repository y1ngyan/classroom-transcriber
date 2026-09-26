import Foundation

/// 一次模型调用的返回值：正文 + 用量。
///
/// 为什么要单独一个类型：`usage` 一直在响应里，但原来的 `deepSeekChat` 把它
/// 丢掉了。学习笔记的验收判据里有一条「一堂课 ≤ 0.1 元」（设计稿 §5.3），
/// 那要求 token 数可追溯——不返回它，费用就只能靠估字符数猜，而估出来的
/// 数字没法复核。**这里只加类型、不改既有函数的行为**，见 `deepSeekChat`
struct ModelTextReply {
    var content: String
    /// 有的响应没有 `usage`（上游改动、代理剥掉），所以是可选的——
    /// 缺了只影响报告里那几行数字，不该让整次调用失败
    var usage: ModelTextUsage?
}

/// DeepSeek 的 `usage` 字段。缓存命中单独记：DeepSeek 对命中部分按另一个
/// 单价计费（见 `StudyNotesCost`），只记 total 会把费用算高
struct ModelTextUsage {
    var promptTokens: Int
    var completionTokens: Int
    var cacheHitTokens: Int
}

/// 各家模型服务共用的返回文本清洗。
enum ModelText {

    /// 全项目唯一的模型标识。写进笔记存档里，回答「这份是谁写的」
    static let defaultModel = "deepseek-chat"

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
        try await deepSeekChatWithUsage(
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            temperature: temperature, timeout: timeout
        ).content
    }

    /// 同 `deepSeekChat`，但把 `usage` 一起带回来。
    ///
    /// 拆成两个函数而不是给原来那个加一个 out 参数：既有的四个调用方
    /// （术语校正 / 补标点 / 笔记 / 事实核查）都不关心用量，让它们全部改签名
    /// 只为了一个用不上的字段，是把改动面积铺到没必要的地方
    static func deepSeekChatWithUsage(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        timeout: TimeInterval = 120
    ) async throws -> ModelTextReply {
        guard let key = AppConfig.deepSeekAPIKey else { throw ModelTextError.missingKey }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": defaultModel,
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

        return ModelTextReply(content: stripCodeFence(content), usage: usage(from: root))
    }

    /// 从响应根对象里取 `usage`。取不到就返回 nil——用量是报告用的，
    /// 缺了不该让一次成功的调用变成失败（见 `ModelTextReply.usage`）
    private static func usage(from root: [String: Any]) -> ModelTextUsage? {
        guard let usage = root["usage"] as? [String: Any],
              let prompt = usage["prompt_tokens"] as? Int,
              let completion = usage["completion_tokens"] as? Int
        else { return nil }
        // 字段名在实测响应里是 prompt_cache_hit_tokens；老响应/别的部署没有它，
        // 缺了就记 0（记 0 的含义是「没有缓存命中」= 全部按未命中计价，偏保守）
        let hit = (usage["prompt_cache_hit_tokens"] as? Int) ?? 0
        return ModelTextUsage(promptTokens: prompt, completionTokens: completion, cacheHitTokens: hit)
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
