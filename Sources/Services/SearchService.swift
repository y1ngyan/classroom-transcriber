import Foundation

/// 一条搜索结果
struct SearchHit: Codable, Equatable {
    var title: String
    var url: String
    var snippet: String
}

enum SearchError: LocalizedError {
    case missingKey
    case badResponse(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "搜索 API 密钥未配置"
        case .badResponse(let code, let body):
            return "搜索请求失败 (HTTP \(code)): \(body.prefix(200))"
        case .decoding(let detail):
            return "搜索结果解析失败: \(detail)"
        }
    }
}

/// 联网搜索。没有这一层的话，DeepSeek 只能凭记忆作答，
/// 那不是事实核查，是模型的一次表态。
enum SearchService {

    static func search(query: String, maxResults: Int = 5) async throws -> [SearchHit] {
        guard let key = AppConfig.searchAPIKey else { throw SearchError.missingKey }

        switch AppConfig.searchProvider {
        case "serper":
            return try await searchSerper(query: query, key: key, maxResults: maxResults)
        default:
            return try await searchTavily(query: query, key: key, maxResults: maxResults)
        }
    }

    // MARK: - Tavily

    private static func searchTavily(query: String, key: String, maxResults: Int) async throws -> [SearchHit] {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": maxResults,
            "search_depth": "basic",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SearchError.decoding("无 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw SearchError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]]
        else {
            throw SearchError.decoding("缺少 results 字段")
        }

        return results.compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            return SearchHit(
                title: title,
                url: url,
                snippet: (item["content"] as? String) ?? ""
            )
        }
    }

    // MARK: - Serper

    private static func searchSerper(query: String, key: String, maxResults: Int) async throws -> [SearchHit] {
        var request = URLRequest(url: URL(string: "https://google.serper.dev/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-API-KEY")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "q": query,
            "num": maxResults,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SearchError.decoding("无 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw SearchError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organic = root["organic"] as? [[String: Any]]
        else {
            throw SearchError.decoding("缺少 organic 字段")
        }

        return organic.prefix(maxResults).compactMap { item in
            guard let title = item["title"] as? String,
                  let link = item["link"] as? String else { return nil }
            return SearchHit(
                title: title,
                url: link,
                snippet: (item["snippet"] as? String) ?? ""
            )
        }
    }
}
