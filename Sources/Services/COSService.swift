import CryptoKit
import Foundation

/// 腾讯云临时密钥。由后端（SCF）用 STS SDK 签发，客户端不持有永久密钥。
struct COSCredentials: Equatable {
    var secretID: String
    var secretKey: String
    var sessionToken: String
    var expiration: Date?

    var isExpired: Bool {
        guard let expiration else { return false }
        // 留 60 秒余量：正好卡在过期点上请求会被拒
        return expiration.timeIntervalSinceNow < 60
    }
}

enum COSError: LocalizedError {
    case notConfigured
    case stsFailed(Int, String)
    case badCredentials(String)
    case http(Int, String, body: String)
    case missingUploadID
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "COS 缺凭证：填 cosSecretID + cosSecretKey，或填 cosSTSURL"
        case .stsFailed(let code, let body):
            return "临时密钥签发失败 (HTTP \(code)): \(body.prefix(200))"
        case .badCredentials(let detail):
            return "临时密钥格式无法识别: \(detail)"
        case .http(let code, let step, let body):
            return "COS \(step) 失败 (HTTP \(code)): \(body.prefix(200))"
        case .missingUploadID:
            return "COS 未返回 UploadId"
        case .emptyFile:
            return "文件是空的，没有可上传的内容"
        }
    }
}

/// 腾讯云 COS 上传。
///
/// 用官方 XML API 直连，不引入 SDK——Swift 端没有官方 COS SDK，
/// 而分片上传本身只有三个请求，自己实现比接一个 ObjC 桥干净。
///
/// 分片大小 2MB。**所有文件都走分片上传**，哪怕只有一片：
/// 这样暂停/续传的语义是统一的，不用为小文件单开一条「传了一半没法暂停」
/// 的路径。COS 允许单片的分片上传。
enum COSService {

    /// 2MB
    static let sliceSize = 2 * 1024 * 1024

    // MARK: - 临时密钥

    /// 从后端取临时密钥。
    ///
    /// 兼容两种常见返回结构：腾讯云 STS 原生的
    /// `{"Response":{"Credentials":{"TmpSecretId":...}}}`，
    /// 以及官方 COS 示例服务端的 `{"credentials":{"tmpSecretId":...}}`。
    /// 后端是用户自己部署的，不该逼它对齐某一种。
    static func fetchCredentials() async throws -> COSCredentials {
        // 直填永久密钥：没有后端可问，本地直接返回。
        // sessionToken 留空即可——签名的请求头只在它非空时才带
        // x-cos-security-token，而 COS 对永久密钥本来就不要求这个头。
        if let secretID = AppConfig.cosSecretID, let secretKey = AppConfig.cosSecretKey {
            return COSCredentials(
                secretID: secretID,
                secretKey: secretKey,
                sessionToken: "",
                expiration: nil
            )
        }

        guard let endpoint = AppConfig.cosSTSURL,
              let url = URL(string: endpoint)
        else {
            throw COSError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw COSError.stsFailed(code, String(data: data, encoding: .utf8) ?? "")
        }

        return try parseCredentials(data)
    }

    static func parseCredentials(_ data: Data) throws -> COSCredentials {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw COSError.badCredentials("不是 JSON 对象")
        }

        // 往里挖一层：{"Response": {...}} 或 {"credentials": {...}} 或就是平的
        let candidates: [[String: Any]] = [
            root,
            root["Response"] as? [String: Any],
            root["Credentials"] as? [String: Any],
            root["credentials"] as? [String: Any],
            (root["Response"] as? [String: Any])?["Credentials"] as? [String: Any],
        ].compactMap { $0 }

        for container in candidates {
            let secretID = (container["TmpSecretId"] ?? container["tmpSecretId"]
                ?? container["secretId"]) as? String
            let secretKey = (container["TmpSecretKey"] ?? container["tmpSecretKey"]
                ?? container["secretKey"]) as? String
            let token = (container["Token"] ?? container["token"]
                ?? container["sessionToken"] ?? container["SessionToken"]) as? String

            if let secretID, let secretKey, !secretID.isEmpty, !secretKey.isEmpty {
                return COSCredentials(
                    secretID: secretID,
                    secretKey: secretKey,
                    sessionToken: token ?? "",
                    expiration: expirationDate(in: root)
                )
            }
        }

        throw COSError.badCredentials("没找到 TmpSecretId / TmpSecretKey 字段")
    }

    private static func expirationDate(in root: [String: Any]) -> Date? {
        let raw = (root["expiredTime"] ?? root["ExpiredTime"]
            ?? (root["Response"] as? [String: Any])?["ExpiredTime"]) as? NSNumber
        guard let raw else { return nil }
        // 秒级时间戳。腾讯云返回的是秒，不是毫秒
        return Date(timeIntervalSince1970: raw.doubleValue)
    }

    // MARK: - 分片上传

    /// 初始化分片上传，返回 UploadId
    static func initiateMultipart(key: String, credentials: COSCredentials) async throws -> String {
        let response = try await send(
            method: "POST",
            key: key,
            query: ["uploads": ""],
            body: nil,
            credentials: credentials,
            step: "初始化分片"
        )

        guard let uploadID = firstMatch(in: response.body, pattern: "<UploadId>(.*?)</UploadId>") else {
            throw COSError.missingUploadID
        }
        return uploadID
    }

    /// 上传一片，返回 ETag。`onProgress` 报的是**这一片**的进度。
    static func uploadPart(
        key: String,
        uploadID: String,
        number: Int,
        data: Data,
        credentials: COSCredentials,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> String {
        let response = try await send(
            method: "PUT",
            key: key,
            query: ["partNumber": String(number), "uploadId": uploadID],
            body: data,
            credentials: credentials,
            step: "上传第 \(number) 片",
            onProgress: onProgress
        )

        guard let etag = response.headers["Etag"] ?? response.headers["ETag"] else {
            throw COSError.http(response.status, "上传第 \(number) 片", body: "响应缺少 ETag 头")
        }
        // COS 给的 ETag 带引号，拼进 Complete 请求体时必须原样保留
        return etag
    }

    /// 合并分片，完成上传
    static func completeMultipart(
        key: String,
        uploadID: String,
        parts: [Int: String],
        credentials: COSCredentials
    ) async throws {
        let body = parts
            .sorted { $0.key < $1.key }
            .map { "<Part><PartNumber>\($0.key)</PartNumber><ETag>\($0.value)</ETag></Part>" }
            .joined()

        let xml = "<CompleteMultipartUpload>\(body)</CompleteMultipartUpload>"
        _ = try await send(
            method: "POST",
            key: key,
            query: ["uploadId": uploadID],
            body: Data(xml.utf8),
            credentials: credentials,
            step: "合并分片"
        )
    }

    // MARK: - 编排

    /// 一次分片上传的可持久化状态。
    ///
    /// `completedParts` 是断点续传的全部依据：分片在 COS 服务端是有状态的，
    /// 只要还留着 uploadId 和已传分片的 ETag，续传就不用重传前面那些片。
    /// 这也是为什么它要跟着队列一起落盘——App 重启后还能接着传。
    struct UploadState: Codable, Equatable {
        var uploadID: String?
        var completedParts: [Int: String] = [:]
        var uploadedBytes: Int64 = 0
        var totalBytes: Int64 = 0
    }

    /// 执行（或继续）一次分片上传。
    ///
    /// 传进来的 `state` 里若已有 uploadID 和已完成的分片，就从下一片接着传。
    /// 每传完一片回调一次 `onStateChange`，调用方据此落盘——这样即使进程被强杀，
    /// 下次也能从最后一个成功分片继续，而不是从头再来。
    static func upload(
        fileURL: URL,
        key: String,
        state initialState: UploadState = UploadState(),
        credentials: COSCredentials,
        onStateChange: @escaping @Sendable (UploadState) -> Void,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> UploadState {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard total > 0 else { throw COSError.emptyFile }

        var state = initialState
        state.totalBytes = total

        func partBytes(_ number: Int) -> Int64 {
            let offset = Int64((number - 1) * sliceSize)
            return min(Int64(sliceSize), total - offset)
        }

        // 续传时把已传分片的字节数补回来，否则进度条会从 0 开始，看着像重传
        state.uploadedBytes = state.completedParts.keys.reduce(0) { $0 + partBytes($1) }

        if state.uploadID == nil {
            state.uploadID = try await initiateMultipart(key: key, credentials: credentials)
            onStateChange(state)
        }
        guard let uploadID = state.uploadID else { throw COSError.missingUploadID }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let partCount = Int((total + Int64(sliceSize) - 1) / Int64(sliceSize))
        onProgress(state.uploadedBytes, total)

        for number in 1...partCount {
            // 暂停就是取消这个 Task：分片边界是天然的检查点，
            // 已传的片在服务端还在，续传时跳过即可
            try Task.checkCancellation()

            if state.completedParts[number] != nil { continue }

            let offset = UInt64((number - 1) * sliceSize)
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: sliceSize), !chunk.isEmpty else { break }

            let base = Int64(offset)
            let etag = try await uploadPart(
                key: key,
                uploadID: uploadID,
                number: number,
                data: chunk,
                credentials: credentials
            ) { sent, _ in
                onProgress(base + min(sent, Int64(chunk.count)), total)
            }

            state.completedParts[number] = etag
            state.uploadedBytes = min(total, base + Int64(chunk.count))
            onStateChange(state)
            onProgress(state.uploadedBytes, total)
        }

        try Task.checkCancellation()
        try await completeMultipart(
            key: key,
            uploadID: uploadID,
            parts: state.completedParts,
            credentials: credentials
        )

        state.uploadedBytes = total
        state.uploadID = nil
        state.completedParts.removeAll()
        return state
    }

    // MARK: - 请求

    private struct Response {
        var status: Int
        var headers: [String: String]
        var body: String
    }

    private static func send(
        method: String,
        key: String,
        query: [String: String],
        body: Data?,
        credentials: COSCredentials,
        step: String,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> Response {
        guard let endpointString = AppConfig.cosEndpoint,
              let base = URL(string: endpointString)
        else {
            throw COSError.notConfigured
        }

        let path = key.hasPrefix("/") ? key : "/\(key)"
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // query 的编码由签名和 URL 共用同一份，避免两边编码方式不一致导致签名对不上
        let encodedQuery = query
            .map { (key: urlEncode($0.key), value: urlEncode($0.value)) }
            .sorted { $0.key < $1.key }
        if !encodedQuery.isEmpty {
            components?.percentEncodedQuery = encodedQuery
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
        }

        guard let url = components?.url, let host = url.host else {
            throw COSError.notConfigured
        }
        // host 头要带端口（mock 服务用的是非 80 端口），否则签名里的 host 对不上
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        var request = URLRequest(url: url)
        request.httpMethod = method
        // 交给 URLSession 自己决定分块编码，避免签名的 header 列表和实发不一致
        request.httpBody = body
        request.timeoutInterval = 300

        var headers = ["host": hostHeader]
        if !credentials.sessionToken.isEmpty {
            headers["x-cos-security-token"] = credentials.sessionToken
        }

        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        if !credentials.sessionToken.isEmpty {
            request.setValue(credentials.sessionToken, forHTTPHeaderField: "x-cos-security-token")
        }
        request.setValue(
            authorization(
                method: method,
                path: path,
                query: query,
                headers: headers,
                credentials: credentials
            ),
            forHTTPHeaderField: "Authorization"
        )

        let delegate = onProgress.map { UploadProgressDelegate(onProgress: $0) }
        let (data, response): (Data, URLResponse)
        if let delegate {
            (data, response) = try await URLSession.shared.upload(for: request, from: body ?? Data(), delegate: delegate)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? ""

        guard (200..<300).contains(status) else {
            throw COSError.http(status, step, body: text)
        }

        var headerMap: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            if let name = name as? String, let value = value as? String {
                headerMap[name] = value
            }
        }

        return Response(status: status, headers: headerMap, body: text)
    }

    // MARK: - 签名（COS 签名 v5）

    /// 生成 `Authorization` 头。
    ///
    /// 算法：SignKey = HMAC-SHA1(SecretKey, KeyTime)，
    /// StringToSign = "sha1\n" + KeyTime + "\n" + SHA1(HttpString) + "\n"，
    /// Signature = HMAC-SHA1(SignKey, StringToSign)。
    /// 其中 SignKey 是**十六进制字符串**直接当 HMAC 密钥用，不是原始字节——
    /// 这一步搞错的话签名永远是错的，而且看不出错在哪。
    static func authorization(
        method: String,
        path: String,
        query: [String: String],
        headers: [String: String],
        credentials: COSCredentials,
        now: Date = Date()
    ) -> String {
        let start = Int(now.timeIntervalSince1970)
        let keyTime = "\(start);\(start + 3600)"

        // 编码和排序各做一次，后面拼串和列 key 都用这同一份，
        // 避免「拼串时算一遍、列 key 时又算一遍」两边不一致
        let encodedParams = query
            .map { (key: urlEncode($0.key.lowercased()), value: urlEncode($0.value)) }
            .sorted { $0.key < $1.key }
        let encodedHeaders = headers
            .map { (key: urlEncode($0.key.lowercased()), value: urlEncode($0.value)) }
            .sorted { $0.key < $1.key }

        let paramString = encodedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let headerString = encodedHeaders.map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        // 结尾必须多一个空行：HttpString 的最后一段后面跟的是 "\n"
        let httpString = """
        \(method.lowercased())
        \(path)
        \(paramString)
        \(headerString)

        """

        let signKey = hmacSHA1Hex(key: Data(credentials.secretKey.utf8), message: Data(keyTime.utf8))
        let stringToSign = "sha1\n\(keyTime)\n\(sha1Hex(Data(httpString.utf8)))\n"
        let signature = hmacSHA1Hex(key: Data(signKey.utf8), message: Data(stringToSign.utf8))

        return [
            "q-sign-algorithm=sha1",
            "q-ak=\(credentials.secretID)",
            "q-sign-time=\(keyTime)",
            "q-key-time=\(keyTime)",
            "q-header-list=\(encodedHeaders.map(\.key).joined(separator: ";"))",
            "q-url-param-list=\(encodedParams.map(\.key).joined(separator: ";"))",
            "q-signature=\(signature)",
        ].joined(separator: "&")
    }

    /// COS 要求的 URL 编码：只保留 `A-Za-z0-9-_.~`
    static func urlEncode(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA1Hex(key: Data, message: Data) -> String {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// 上报单片上传进度。
///
/// 单独一个类是因为进度只能从 URLSession 的 delegate 回调里拿到，
/// 而那是**非 Sendable 的 ObjC 回调、在后台队列上触发**——按本项目
/// 踩过的坑（见 swift6-objc-callback-isolation-trap），这类对象的
/// 方法必须是 nonisolated，否则从后台线程进来就直接 SIGTRAP。
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}
