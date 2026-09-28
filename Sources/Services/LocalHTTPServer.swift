import Foundation
import Network

/// 一个**只够自检用**的 HTTP/1.1 服务器。
///
/// 为什么不用 `URLProtocol` 打桩：要验的恰好是传输层的行为——`Range` 被接受
/// 还是被忽略、连接在半路断掉、字节一点一点地来。`URLProtocol` 活在
/// URLSession 内部，那些东西在它下面，够不着。
///
/// 为什么监听 `127.0.0.1` 的临时端口而不是写死一个：写死端口在并行会话
/// （这个仓库常年好几个）里会互相抢；临时端口由内核分配，天然不撞。
/// **只在自检里起，跑完就停**——它不监听局域网、不对外。
final class LocalHTTPServer: @unchecked Sendable {

    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]

        var rangeStart: Int64? {
            guard let raw = headers["range"], raw.hasPrefix("bytes=") else { return nil }
            let span = raw.dropFirst("bytes=".count)
            guard let start = span.split(separator: "-").first else { return nil }
            return Int64(start)
        }
    }

    struct Response: Sendable {
        var status: Int = 200
        var body: Data = Data()
        var contentType: String = "application/octet-stream"
        /// 支不支持 `Range`。**false 时回 200 + 整份 body**，正是真实世界里
        /// 「源不支持续传」的样子
        var supportsRange: Bool = true
        /// 发到第几个字节就**直接断开**（模拟网络抖动）。nil = 发完
        var dropAfter: Int? = nil
        /// 每块之间等多久（模拟慢速，给「取消」「kill -9」留出下手的时间窗）
        var chunkDelay: TimeInterval = 0
        var chunkSize: Int = 32 * 1024
        /// 额外响应头。夹具靠它冒充 huggingface 的 `x-repo-commit` /
        /// `x-linked-etag` / `x-linked-size`——**续传前的版本比对**那条
        /// 判据全靠这三个头，没有它们就没得比
        var extraHeaders: [String: String] = [:]
        /// 宣告这个 `Content-Length`，却只把 `body` 里那些字节发出去，然后
        /// **干净收尾**（不是 reset）。用来造「服务器说给完了、字节数却对不上」
        /// 那种残缺
        var claimLength: Int? = nil
    }

    private let handler: @Sendable (Request) -> Response
    private let listener: NWListener
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var connections: [NWConnection] = []
    /// 内核分配到的端口。**计算属性**而不是 `let`：它是 `stateUpdateHandler`
    /// 里才知道的，而那个闭包要捕获 `self`——`self` 必须在闭包之前就完全初始化
    private let portBox: PortBox

    var port: UInt16 { portBox.value }

    init(handler: @escaping @Sendable (Request) -> Response) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑回环：这个服务器是自检的夹具，不该出现在局域网上
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        // `stateUpdateHandler` 是 `@Sendable` 闭包：内核分配到的端口号只能
        // 从它里面拿出来，而里面不能mutate捕获的 var。用一个小盒子装——
        // 顺序由下面那个信号量保证，盒子里不需要再加锁
        let box = PortBox()
        self.portBox = box
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                box.value = listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: DispatchQueue(label: "ct.localhttp.listener"))
        // 起不来就**当场失败**，不要拖到断言超时——超时会把「服务器没起来」
        // 和「下载行为不对」混成同一种红，查起来要多绕一圈
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw NSError(domain: "LocalHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "监听 127.0.0.1 失败（5 秒超时）"])
        }
    }

    /// 收到过的请求，按顺序。**重试上限那条判据靠它**：数请求次数，
    /// 而不是数界面上的文案——文案可以骗人，请求次数不会
    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// 打给这个路径的 **GET** 次数。**只数 GET，不数 HEAD**——
    /// 下载器在续传前会先 `HEAD` 一下探版本，把探测也算进来的话，
    /// 「只发了 1 次请求（没有从头重下）」这条判据数的就不是下载次数了
    func requestCount(path: String) -> Int {
        requests.filter { $0.path == path && $0.method == "GET" }.count
    }

    /// 这个路径上**有没有出现过带 `Range` 的请求**。判「到底有没有拿旧字节续」
    /// 只看这个——报告里的 `resumedFrom` 是我们自己算的，`Range` 头是
    /// 真的发出去了的东西
    func sawRangeRequest(path: String) -> Bool {
        requests.contains { $0.path == path && $0.headers["range"] != nil }
    }

    func sawRangeRequest(path: String, prefix: String) -> String? {
        requests.first { $0.path == path && ($0.headers["range"]?.hasPrefix(prefix) ?? false) }?
            .headers["range"]
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: DispatchQueue(label: "ct.localhttp.conn"))
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            // 请求头到 `\r\n\r\n` 就齐了——这个夹具只处理没有 body 的 GET
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let request = Self.parse(head)
                self.lock.lock()
                self._requests.append(request)
                self.lock.unlock()
                self.respond(to: request, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            guard buffer.count < 64 * 1024 else { connection.cancel(); return }
            self.read(connection, buffer: buffer)
        }
    }

    static func parse(_ head: String) -> Request {
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = requestLine.split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return Request(method: parts.first ?? "GET",
                       path: parts.count > 1 ? parts[1] : "/",
                       headers: headers)
    }

    // MARK: - 应答

    private func respond(to request: Request, on connection: NWConnection) {
        let response = handler(request)
        let total = response.body.count
        let start = request.rangeStart ?? 0

        var status = response.status
        var headers: [String: String] = [
            "Content-Type": response.contentType,
            "Connection": "close",
        ]
        var payload = response.body

        if request.rangeStart != nil {
            if response.supportsRange {
                if start >= total {
                    // 请求的起点已经越过文件尾。真实服务器就是这么回 416 的
                    status = 416
                    headers["Content-Range"] = "bytes */\(total)"
                    payload = Data()
                } else {
                    status = 206
                    headers["Accept-Ranges"] = "bytes"
                    headers["Content-Range"] = "bytes \(start)-\(total - 1)/\(total)"
                    payload = response.body.subdata(in: Int(start)..<total)
                }
            } else {
                // **忽略 Range**，回整份。这就是「源不支持续传」的真实形态
                status = 200
                headers["Accept-Ranges"] = "none"
            }
        } else if response.supportsRange {
            headers["Accept-Ranges"] = "bytes"
        }

        // Content-Length 先按**真实要发的那些字节**（或夹具指定的那个数）定下来，
        // 再处理 HEAD——HEAD 只回头不回体，但长度必须照报，否则
        // `expectedContentLength` 会变成 0，「远端说这个文件多大」就没了
        headers["Content-Length"] = "\(response.claimLength ?? payload.count)"
        for (key, value) in response.extraHeaders { headers[key] = value }
        if request.method == "HEAD" { payload = Data() }

        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(payload)

        send(out, on: connection, offset: 0,
             chunkSize: response.chunkSize,
             delay: response.chunkDelay,
             dropAfter: response.dropAfter)
    }

    private func send(_ data: Data, on connection: NWConnection, offset: Int,
                      chunkSize: Int, delay: TimeInterval, dropAfter: Int?) {
        if let dropAfter, offset >= dropAfter {
            // 半路断开：不打招呼、不发 trailer。客户端应当把它当成网络错误
            connection.cancel()
            return
        }
        guard offset < data.count else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let naturalEnd = min(offset + chunkSize, data.count)
        let end = dropAfter.map { min(naturalEnd, $0) } ?? naturalEnd
        let chunk = data.subdata(in: offset..<end)
        let isLast = end >= data.count && dropAfter == nil
        connection.send(content: chunk, contentContext: .defaultMessage, isComplete: isLast,
                        completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.send(data, on: connection, offset: end,
                              chunkSize: chunkSize, delay: delay, dropAfter: dropAfter)
                }
            } else {
                self.send(data, on: connection, offset: end,
                          chunkSize: chunkSize, delay: delay, dropAfter: dropAfter)
            }
        })
    }

    /// `stateUpdateHandler` 里只有端口号要带出来。`@unchecked Sendable` 的依据：
    /// 写入发生在 `ready.signal()` **之前**，读取发生在 `wait()` **之后**，
    /// 中间隔着一个信号量——不存在并发访问
    private final class PortBox: @unchecked Sendable {
        var value: UInt16 = 0
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
