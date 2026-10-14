import Foundation

/// 假模型的**唯一一份定义**。
///
/// `--model-download-selftest`（进程内起服务器、一条命令跑完）和
/// `--model-fixture-server` + `--model-fetch`（两个进程，给 `kill -9` 那条
/// 探针用）走的是同一份路由。分开写两份的话，「自检里在这个路由上验过的
/// 行为」和「探针里跑的那个路由」迟早会长歪——那时候探针绿了也不说明自检
/// 验过的东西还在。
enum ModelFixture {

    /// 夹具的合格下界。真模型是 500MB，这里压到 200KB：
    /// 要验的是**判定逻辑**，不是磁盘吞吐
    static let minimumBytes: Int64 = 200_000

    /// 正规的假模型：ggml 魔数开头 + 可复现填充
    static let body = ModelDownloadSelfTest.fakeModel(bytes: 300_000)
    /// 魔数对、大小不够 —— 「下到一半」的样子
    static let shortBody = ModelDownloadSelfTest.fakeModel(bytes: 90_000)
    /// 大小够、魔数不对 —— 代理塞进来的错误页长这样
    static let badMagicBody = Data(repeating: 0x41, count: 300_000)

    /// 夹具冒充的「上游 commit」。两个值**只差这一处**，正是为了验
    /// 「远端 revision 变了 → 必须从 0 重下，不许拿旧字节续」
    static let revisionA = "aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000"
    static let revisionB = "bbbb1111bbbb1111bbbb1111bbbb1111bbbb1111"

    /// 复刻镜像 2026-10-13 的症状（见 `ModelURLPlan` 与
    /// `发现-模型下载URL-404-20261013.md`）：同一个 commit，**40 位写法一律
    /// 404**（连非模型文件也 404），而它的 **12 位前缀**照样给件。
    /// 回落链要验的正是这个差别，而真实网络验不了「四种状态码各是什么行为」
    /// ——夹具可以，而且确定性。
    static let fullRevisionRef = revisionA
    static let shortRevisionRef = String(revisionA.prefix(ModelURLPlan.fallbackPrefixLength))

    /// `/truncated` 只发这么多字节，却宣告整份的长度
    static let truncatedBytes = 250_000

    /// huggingface 把「这一版是什么」挂在 302 上的那三个头。夹具照着发，
    /// 续传前的版本比对才有得比
    static func identityHeaders(revision: String, body: Data) -> [String: String] {
        [
            "x-repo-commit": revision,
            "x-linked-etag": "\"\(ModelDownloadSelfTest.sha256(body))\"",
            "x-linked-size": "\(body.count)",
        ]
    }

    static let handler: @Sendable (LocalHTTPServer.Request) -> LocalHTTPServer.Response = { request in
        // ── `/resolve/<ref>/<file>`：清单拼出来的那种形状（P12-1b）──
        //
        // 40 位 ref 一律 404、12 位前缀给件；`denied` 那个文件名在 40 位形状上
        // 回 **403**（鉴权，不是「这个 ref 解析不了」）——「只有 404 才回落」
        // 那条判据靠它：一个见了非 404 也回落的实现会在这里把件取下来
        if request.path.hasPrefix("/resolve/") {
            let rest = request.path.dropFirst("/resolve/".count)
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                return LocalHTTPServer.Response(status: 404, body: Data())
            }
            let (ref, file) = (parts[0], parts[1])
            if ref == fullRevisionRef {
                return file == "denied"
                    ? LocalHTTPServer.Response(status: 403, body: Data())
                    : LocalHTTPServer.Response(status: 404, body: Data())
            }
            guard ref == shortRevisionRef else {
                return LocalHTTPServer.Response(status: 404, body: Data())
            }
            switch file {
            case "model":
                return LocalHTTPServer.Response(
                    body: body, extraHeaders: identityHeaders(revision: revisionA, body: body))
            case "denied":
                // 同一个文件在**短形状**上是能给件的，在长形状上回 403。
                //
                // 这正是九之五要的形状：一个「见了非 404 也回落」的实现会顺着
                // 403 退到这儿、**把件取下来**，于是它栽在「403 那条本该失败却
                // 成功了」上，而不是栽在文案里少了个 403（后者只是症状，不是
                // 「它多取了一次件」这个事实）
                return LocalHTTPServer.Response(
                    body: body, extraHeaders: identityHeaders(revision: revisionA, body: body))
            case "noetag":
                // 只报 revision，不报 etag/大小——和上面那条 `/noetag` 同一个
                // 用途：把「下完之后按 sha256 判」那一条单独隔出来验
                // （回落成功的那一份**也必须过 sha256**，见派单第 2 条）
                return LocalHTTPServer.Response(
                    body: body, extraHeaders: ["x-repo-commit": revisionA])
            default:
                return LocalHTTPServer.Response(status: 404, body: Data())
            }
        }

        switch request.path {
        case "/model":
            return LocalHTTPServer.Response(
                body: body, extraHeaders: identityHeaders(revision: revisionA, body: body))
        case "/moved":
            // 内容与 `/model` **一模一样**，只有 revision 变了。
            // 专供「源已更新」那条判据：内容相同意味着**光看文件根本分不出来**，
            // 只能靠版本元数据判——这正是要验的东西
            return LocalHTTPServer.Response(
                body: body, extraHeaders: identityHeaders(revision: revisionB, body: body))
        case "/truncated":
            // 宣告 300000 字节，只给 250000，然后**干净收尾**（不是 reset）。
            // 250000 > minimumBytes 且魔数对——不看长度就发现不了它残缺
            return LocalHTTPServer.Response(
                body: Data(body.prefix(truncatedBytes)),
                extraHeaders: identityHeaders(revision: revisionA, body: body),
                claimLength: body.count)
        case "/noetag":
            // 只报 revision，不报 etag/大小的源。用来把「下完之后按 sha256 判」
            // 这一条单独隔出来验——不然远端报的 etag 会先把不符的那一份挡在
            // 下载之前，`ModelFile` 里那段 sha256 校验就永远轮不到执行
            return LocalHTTPServer.Response(
                body: body, extraHeaders: ["x-repo-commit": revisionA])
        case "/short":
            return LocalHTTPServer.Response(
                body: shortBody, extraHeaders: identityHeaders(revision: revisionA, body: shortBody))
        case "/badmagic":
            return LocalHTTPServer.Response(
                body: badMagicBody,
                extraHeaders: identityHeaders(revision: revisionA, body: badMagicBody))
        case "/norange":
            // 明确不支持 Range 的源
            return LocalHTTPServer.Response(
                body: body, supportsRange: false,
                extraHeaders: identityHeaders(revision: revisionA, body: body))
        case "/flaky":
            // 每次都在 1000 字节处断线。重试上限那条判据靠它
            return LocalHTTPServer.Response(
                body: body, dropAfter: 1000,
                extraHeaders: identityHeaders(revision: revisionA, body: body))
        case "/slow":
            // 慢慢喂，给「取消」留出下手的时间窗
            return LocalHTTPServer.Response(
                body: body, chunkDelay: 0.02, chunkSize: 8 * 1024,
                extraHeaders: identityHeaders(revision: revisionA, body: body))
        case "/veryslow":
            // 更慢：整份要 7 秒多。`kill -9` 那条探针要的是「下了几万字节
            // 还没下完」这个稳定的中间态，`/slow` 太快，掐不准
            return LocalHTTPServer.Response(
                body: body, chunkDelay: 0.1, chunkSize: 4 * 1024,
                extraHeaders: identityHeaders(revision: revisionA, body: body))
        default:
            return LocalHTTPServer.Response(status: 404, body: Data())
        }
    }
}

/// 把进度回调转成一行行 stdout。
///
/// `@unchecked Sendable` 的依据：`lastEmit` 只在 `lock` 里读写。回调来自
/// session 的后台队列——这是必须的，因为那里不能碰主 actor 的东西。
final class ProgressLineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmit = Date.distantPast

    func report(_ progress: DownloadProgress) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.5 else { lock.unlock(); return }
        lastEmit = now
        lock.unlock()
        let mb = Double(progress.written) / 1_000_000
        if let total = progress.total, total > 0 {
            let totalMB = Double(total) / 1_000_000
            print(String(format: "… %.1f / %.1f MB（%.0f%%）", mb, totalMB, mb / totalMB * 100))
        } else {
            print(String(format: "… %.1f MB", mb))
        }
    }
}
