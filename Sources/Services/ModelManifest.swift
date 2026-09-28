import Foundation

/// 一个**被钉住**的模型：上游 commit + 那个 commit 下的真值。
///
/// 为什么要有这个结构，而不是直接下 `resolve/main/ggml-medium-q5_0.bin`：
/// `main` 是移动目标。上游一更新，两件事会同时发生——同一个 URL 后面的
/// 内容变了，而磁盘上还躺着上一版的半截 `.part`。「续传」于是变成**前半段
/// 旧版本 + 后半段新版本**的拼接。这种文件**大小对得上、ggml 魔数也对得上**，
/// 原来那两条判据一条都查不出来，直到模型跑起来输出乱码才暴露。
///
/// 所以：URL 由 revision 拼出来（`resolve/<commit>/<file>`，请求的是一个
/// 不可变的对象），清单里同时记着 sha256——续传前拿远端和本地两份元数据
/// 对一遍，对不上就老老实实从 0 重下。
struct ModelPin: Equatable, Sendable {
    let file: String
    let repo: String
    let revision: String
    let size: Int64
    let sha256: String
    let isDefault: Bool
    /// 下载地址。**由 revision 拼出来，不是清单里存的**——存一个 `main`
    /// 形式的 URL 就等于把「移动目标」重新引回来
    let url: URL

    static let sourcePrefix = "https://hf-mirror.com"

    /// 清单用这个初始化：URL 从 repo/revision/file 拼。
    ///
    /// 拼不出来（只可能是清单自己写坏了）时抛错而不是 `URL(string:)!`——
    /// 强制解包在这里崩掉的话，表现是「App 一启动就闪退」，和「清单填错」
    /// 这件事在现象上隔了十万八千里
    init(file: String, repo: String, revision: String, size: Int64,
         sha256: String, isDefault: Bool) throws {
        let raw = "\(Self.sourcePrefix)/\(repo)/resolve/\(revision)/\(file)"
        guard let url = URL(string: raw) else {
            throw ModelManifest.LoadError.malformed(reason: "拼不出下载地址：\(raw)")
        }
        self.init(file: file, repo: repo, revision: revision, size: size,
                  sha256: sha256, isDefault: isDefault, url: url)
    }

    /// 夹具/调试用：URL 自己给。`repo` 只用于显示，传空串
    init(file: String, repo: String = "", revision: String, size: Int64,
         sha256: String, isDefault: Bool = false, url: URL) {
        self.file = file
        self.repo = repo
        self.revision = revision
        self.size = size
        self.sha256 = sha256
        self.isDefault = isDefault
        self.url = url
    }

    /// 给人看的短版 commit（前 12 位）
    var shortRevision: String { String(revision.prefix(12)) }
}

/// 随仓库提交的模型清单（`Sources/Resources/model-manifest.json`，
/// 由 `build.sh` 拷进 `Contents/Resources/`）。
///
/// 它是**判据本身**：size 和 sha256 不在代码里写死，也不在下载完之后
/// 才「顺便算一下」，而是从这份文件读出来、拿去比。这样改判据的地方
/// 只有一个，而且那个地方是能 diff、能 review 的。
struct ModelManifest: Sendable {
    var version: Int
    var source: String
    var models: [ModelPin]

    func pin(forFile name: String) -> ModelPin? {
        models.first { $0.file == name }
    }

    /// App 默认下的那个。没有标 default 就退回第一个——**不返回 nil**：
    /// 「清单是空的」这件事由 `load` 去拦，不该表现成「界面上突然没有
    /// 下载按钮了」
    var defaultPin: ModelPin? {
        models.first(where: \.isDefault) ?? models.first
    }

    enum LoadError: Error, Equatable {
        case notBundled(searched: String)
        case unreadable(path: String, reason: String)
        case malformed(reason: String)

        var localizedDescription: String {
            switch self {
            case .notBundled(let searched):
                return "模型清单没有随 App 打包（找过 \(searched)）。清单是校验的判据——"
                    + "没有它就不下载，因为下下来的东西无从判断对不对。跑 ./build.sh 重新打包"
            case .unreadable(let path, let reason):
                return "模型清单读不出来（\(path)）：\(reason)"
            case .malformed(let reason):
                return "模型清单格式不对：\(reason)"
            }
        }
    }

    static let resourceName = "model-manifest"
    static let resourceExtension = "json"

    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: resourceExtension)
    }

    /// 读清单。**任何一步不对都抛错**，不做「读不到就当没有」的降级——
    /// 那会让「清单没打进包」表现成「校验忽然不做了」，而那是这个包里
    /// 最不该出现的一种静默
    static func load(from url: URL) throws -> ModelManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        let raw: RawManifest
        do {
            raw = try JSONDecoder().decode(RawManifest.self, from: data)
        } catch {
            throw LoadError.malformed(reason: error.localizedDescription)
        }
        guard !raw.models.isEmpty else {
            throw LoadError.malformed(reason: "models 是空的")
        }
        var pins: [ModelPin] = []
        for entry in raw.models {
            guard !entry.file.isEmpty, !entry.repo.isEmpty, !entry.revision.isEmpty else {
                throw LoadError.malformed(reason: "有一条缺 file/repo/revision")
            }
            guard entry.size > 0 else {
                throw LoadError.malformed(reason: "\(entry.file) 的 size 不是正数")
            }
            guard entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw LoadError.malformed(reason: "\(entry.file) 的 sha256 不是 64 位十六进制")
            }
            do {
                pins.append(try ModelPin(
                    file: entry.file, repo: entry.repo, revision: entry.revision,
                    size: entry.size, sha256: entry.sha256.lowercased(),
                    isDefault: entry.isDefault ?? false))
            } catch {
                throw LoadError.malformed(reason: (error as? LoadError)?.localizedDescription
                                          ?? error.localizedDescription)
            }
        }
        return ModelManifest(version: raw.version ?? 0, source: raw.source ?? ModelPin.sourcePrefix,
                             models: pins)
    }

    /// 从 bundle 里读。`--model-download-selftest` 会断言它能读出来、
    /// 而且内容与已知的钉法一致——**这条断言是清单没被 build.sh 漏拷的
    /// 唯一保险**（漏拷的话 App 照跑，只有校验悄悄不做了）
    static func loadBundled(in bundle: Bundle = .main) throws -> ModelManifest {
        guard let url = bundledURL(in: bundle) else {
            let searched = bundle.bundleURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent("\(resourceName).\(resourceExtension)").path
            throw LoadError.notBundled(searched: searched)
        }
        return try load(from: url)
    }

    /// 包里那份清单钉的默认模型。读不出来时返回 nil——用它的地方各自决定
    /// 怎么报错，这里**不替它们兜底成「那就不校验了」**
    static var bundledDefaultPin: ModelPin? {
        (try? loadBundled())?.defaultPin
    }

    private struct RawManifest: Decodable {
        var version: Int?
        var source: String?
        var models: [RawModel]
    }

    private struct RawModel: Decodable {
        var file: String
        var repo: String
        var revision: String
        var size: Int64
        var sha256: String
        var isDefault: Bool?
    }
}

/// 远端的身份。**只读得到、也只需要这几个字段**。
///
/// 为什么单开一个探测（HEAD）而不是从下载响应里拿：huggingface 的
/// `resolve/...` 是 **302**，`x-repo-commit` / `x-linked-etag` / `x-linked-size`
/// 只挂在那个 302 上；跟着跳到 CDN 之后，响应头里只剩 CDN 自己的
/// `ETag`（值是它内部的对象 id，不是内容 sha256）。
/// 实测 2026-09-28：
///   HEAD https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin
///   → 302 · x-repo-commit: 5359861c… · x-linked-etag: "19fea4b3…" · x-linked-size: 539212467
///   （同一个 URL 跟到最终 CDN 响应 → ETag: "f2f2b4f1…" ← 完全不同的东西）
/// 所以探测必须在**不跟随跳转**的 session 上做。
struct RemoteIdentity: Equatable, Sendable {
    var revision: String?
    var etag: String?
    var size: Int64?

    var isEmpty: Bool { revision == nil && etag == nil && size == nil }

    /// 远端和本地 `.part` 记录的那一份**是不是同一个版本**。
    ///
    /// 保守方向很明确：**判不出来就重下**。`.part` 半截字节留在盘上不值钱，
    /// 拿它拼出一个「大小对、魔数对、内容是两版拼的」文件才是真损失——
    /// 那种文件所有便宜的判据都过得去。
    ///
    /// 两边都有的字段才能比：远端什么都没报的服务器（自建源、老代理）
    /// 不该因此永远续不上传
    func conflicts(with meta: PartMeta?) -> Bool {
        // 没有版本记录 = 不知道这半截是哪一版的 → 不敢接着写
        guard let meta else { return true }
        // 有记录但三个字段全是空的，等价于「没记」。不这么判的话，
        // 一份空记录会让下面每一条比较都「因为有一边是 nil」而跳过，
        // 最后返回 false——一条**看起来验过了、其实什么都没验**的假绿
        if meta.revision == nil, meta.etag == nil, meta.size == nil { return true }
        if let a = revision, let b = meta.revision, a != b { return true }
        if let a = etag, let b = meta.etag, a != b { return true }
        if let a = size, let b = meta.size, a != b { return true }
        return false
    }

    /// 人话版本的差异描述，用来填「源已更新，重新下载」那句话
    func describeDifference(from meta: PartMeta?) -> String {
        guard let meta else { return "本地没有版本记录" }
        var parts: [String] = []
        if let a = revision, let b = meta.revision, a != b {
            parts.append("revision \(String(b.prefix(12)))… → \(String(a.prefix(12)))…")
        }
        if let a = etag, let b = meta.etag, a != b {
            parts.append("etag \(String(b.prefix(12)))… → \(String(a.prefix(12)))…")
        }
        if let a = size, let b = meta.size, a != b {
            parts.append("大小 \(b) → \(a) 字节")
        }
        return parts.isEmpty ? "远端元数据与本地记录不一致" : parts.joined(separator: "，")
    }

    /// `HEAD` 一下，**不跟随跳转**，读 302/200 上的那三个头。
    static func probe(url: URL) async throws -> RemoteIdentity {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: RedirectBlocker(),
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // 304/3xx 也算「拿到了身份」；4xx/5xx 才是真错
        guard http.statusCode < 400 else {
            throw ModelDownloader.Failure.httpStatus(http.statusCode)
        }

        func header(_ name: String) -> String? {
            guard let raw = http.value(forHTTPHeaderField: name)?
                .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }
        func unquote(_ raw: String?) -> String? {
            guard let raw else { return nil }
            if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
                return String(raw.dropFirst().dropLast())
            }
            return raw
        }

        let linked = header("x-linked-size").flatMap { Int64($0) }
        // `expectedContentLength` 只有在**没跳转**时才是文件大小：
        // 302 的 `content-length` 是那段 HTML 的长度，用它当文件大小会
        // 得出「539MB 的文件只有 1103 字节」这种离谱结论
        let direct = http.statusCode == 200 && http.expectedContentLength > 0
            ? http.expectedContentLength : nil

        return RemoteIdentity(
            revision: header("x-repo-commit"),
            etag: unquote(header("x-linked-etag") ?? header("etag"))?.lowercased(),
            size: linked ?? direct
        )
    }

    /// 拒绝跟随跳转。有了它，`probe` 拿到的才是那个带 `x-repo-commit` 的 302
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// `.part` 旁边那份版本记录。
///
/// 为什么非要有它：`kill -9`、断电、被取消之后，磁盘上只剩一个半截文件，
/// **它自己不知道自己属于哪一版**。没有这份记录，「接着下」就只能是盲猜；
/// 而猜错的表现是前面说的那种拼接文件。记下来之后，续传前拿远端和它对
/// 一遍，对不上就重下——这一步是 S2 那条要求唯一的落点。
struct PartMeta: Codable, Equatable, Sendable {
    var revision: String?
    var etag: String?
    var size: Int64?
    var url: String

    /// `<x>.part` → `<x>.part.meta.json`。**同目录**：清理时要能一起被找到
    static func url(forPart partURL: URL) -> URL {
        partURL.appendingPathExtension("meta.json")
    }

    static func read(forPart partURL: URL) -> PartMeta? {
        guard let data = try? Data(contentsOf: url(forPart: partURL)) else { return nil }
        return try? JSONDecoder().decode(PartMeta.self, from: data)
    }

    func write(forPart partURL: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url(forPart: partURL))
    }

    static func remove(forPart partURL: URL) {
        try? FileManager.default.removeItem(at: url(forPart: partURL))
    }
}
