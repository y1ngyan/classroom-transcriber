import CryptoKit
import Foundation

/// ggml 模型文件的**内容**判据。
///
/// 为什么不能只看大小：514MB 的残文件、被代理塞进来的 HTML 错误页、
/// 下到一半被截断的 `.part`——都可能「大小看着差不多」。而 ggml 文件头
/// 是**定长常量**，换不来也猜不出，是这一类里最便宜又最硬的判据。
///
/// 但魔数只是**底线**，不是终点：它判不出「是不是我要的那个型号」，也判不出
/// 「是不是前半段旧版本 + 后半段新版本拼出来的」——后者的魔数、大小全对。
/// 所以有清单的时候还要比 sha256（`ModelPin.sha256`），那才是判据。
enum ModelFile {

    /// ggml 文件头魔数，**磁盘上的前 4 个字节**。
    ///
    /// `GGML_FILE_MAGIC = 0x67676d6c`（whisper.cpp 的 ggml 头），按小端写出来
    /// 就是字节序列 `6c 6d 67 67`（拼成 ASCII 是 "lmgg"，不是 "ggml"——
    /// 直觉反了很容易写错，所以在这里写死字节而不是写个整数再转换）。
    ///
    /// 实测（本机 `~/Library/Application Support/ClassroomTranscriber/models/`，
    /// 只读前 16 字节，未改动这两个文件）：
    ///   `ggml-medium-q5_0.bin`  → `6c6d6767 99ca0000 dc050000 00040000`
    ///   `ggml-large-v3-q5_0.bin`→ `6c6d6767 9aca0000 dc050000 00050000`
    /// 两者魔数相同，后面的差异是 vocab/超参——所以魔数只能判「这是不是一个
    /// ggml 文件」，判不出「是不是我要的那个型号」。**型号靠大小兜**：
    /// medium-q5_0 是 539,212,467 字节，`expectedModelBytes` 取 500,000,000
    /// 作下界，large-v3 的 1.08GB 也能过这条下界——所以最终判据是
    /// 「大小 ≥ 下界 **且** 魔数对」，两条都过才算数。
    static let magic: [UInt8] = [0x6c, 0x6d, 0x67, 0x67]

    /// 校验一个**已经下完**的文件。返回 nil = 通过，否则是给人看的原因。
    ///
    /// 四步，从便宜到贵：大小 → 文件头 → sha256。传了 `pin` 就按清单里的
    /// **精确**大小和 sha256 判，没传才退回 `minimumBytes` 这条下界。
    ///
    /// 为什么 sha256 放在最后：它要把整个文件读一遍（539MB 约几秒），
    /// 而前面两步是瞬时的。便宜的判据能挡掉的，不值得让用户等 sha256。
    ///
    /// **不把整个文件读进内存**：分开读、喂给流式 hasher。539MB 一次性
    /// `Data(contentsOf:)` 会让下载刚成功那一刻内存冲高 500MB 以上——
    /// 而那一刻正好是用户最不该看见 App 卡住的时候。
    static func validationFailure(at url: URL, minimumBytes: Int64,
                                  pin: ModelPin? = nil) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int64 else {
            return "读不出文件大小（\(url.path)）"
        }
        if let pin {
            guard size == pin.size else {
                return "大小不对：\(size) 字节，清单里 \(pin.file) 是 \(pin.size) 字节"
            }
        } else {
            guard size >= minimumBytes else {
                return "大小不足：\(size) 字节 < 期望下界 \(minimumBytes) 字节"
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "打不开文件（\(url.path)）"
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: magic.count)) ?? Data()
        guard head.count == magic.count, Array(head) == magic else {
            let got = head.map { String(format: "%02x", $0) }.joined()
            let want = magic.map { String(format: "%02x", $0) }.joined()
            return "文件头不是 ggml：读到 \(got.isEmpty ? "（空）" : got)，期望 \(want)"
        }
        if let pin, let actual = sha256(fileAt: url) {
            guard actual == pin.sha256 else {
                return "内容 sha256 不对：读到 \(actual.prefix(16))…，清单里是 \(pin.sha256.prefix(16))…"
            }
        }
        return nil
    }

    static func isValid(at url: URL, minimumBytes: Int64, pin: ModelPin? = nil) -> Bool {
        validationFailure(at: url, minimumBytes: minimumBytes, pin: pin) == nil
    }

    /// 流式 sha256。**不整份读进内存**（见 `validationFailure` 的注释）。
    ///
    /// 读不出来返回 nil，不返回一个「空输入的 sha256」——后者是个合法的
    /// 64 位十六进制串，拿去比会得到「不相等」，于是「文件读不了」这件事
    /// 会伪装成「内容不对」，排起来要多绕一圈
    static func sha256(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        while true {
            // 「读完了」和「读出错了」必须分开：都退化成 `try?` 的 nil 的话，
            // 读到一半失败会返回一个**基于半份内容算出来的 sha256**——它是
            // 一个合法的 64 位串，比下去只会得到「不相等」，于是「盘坏了」
            // 这件事伪装成「内容不对」
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 4 * 1024 * 1024) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            read += Int64(chunk.count)
        }
        guard read > 0 else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 一次下载的进度快照。给界面用的，字段都是「界面上要显示什么」。
struct DownloadProgress: Equatable, Sendable {
    /// 已经落盘的字节数（含续传接上的那一段）
    var written: Int64
    /// 总大小。源没给 `Content-Length` 时为 nil——**这时不许显示百分比**，
    /// 分母是编的
    var total: Int64?
    /// 本次是从第几个字节接上的。0 = 从头下的
    var resumedFrom: Int64
    var bytesPerSecond: Double

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1.0, Double(written) / Double(total))
    }

    var remainingSeconds: Double? {
        guard let total, bytesPerSecond > 1 else { return nil }
        return max(0, Double(total - written) / bytesPerSecond)
    }
}

/// 一次下载跑完（或失败）之后的报告。
struct DownloadReport: Equatable, Sendable {
    var bytesWritten: Int64
    var resumedFrom: Int64
    /// 源接不接受 `Range`。nil = 这次没问过（本地文件、或从头开始且没续传需求）
    var rangeAccepted: Bool?
    /// 实际发起过几次请求（含重试）。自动重试上限是 `ModelDownloader.maxAttempts`
    var attempts: Int
    /// 必须原样显示给用户的诚实提示，例如「此源不支持续传，将从 0 开始」
    var notices: [String]
}

/// 模型下载。**只管搬字节**：要不要下、下完了拿它干什么，由调用方决定。
///
/// 三条硬性质（每一条都有对应的自检）：
/// ① `.part` 是唯一的工作文件，**校验过了才原子改名**——中途失败、被取消、
///    进程被 `kill -9`，用户手里留下的都是一个可以接着用的 `.part`；
/// ② 续传靠 HTTP `Range`，**源不支持时如实说出来**，不许假装在续传；
/// ③ 自动重试有上限（`maxAttempts`），每次都要能被界面看见。
final class ModelDownloader: NSObject, @unchecked Sendable {

    /// 自动重试上限。**是「总共试几次」不是「额外再试几次」**——
    /// 「最多重试 3 次」这种说法两种读法都讲得通，所以这里连类型一起定死。
    /// 到顶之后抛 `Failure.retriesExhausted`，**不再自动往下试**：
    /// 无限自动重试会把「源挂了」变成一个永远转圈的界面，用户既不知道
    /// 出了什么事，也没有停下来的办法。
    static let maxAttempts = 3

    /// 目标文件（正式名）与工作文件（`.part`）。
    ///
    /// 两者**同目录**：`promote` 用的是 `moveItem`，同卷才是原子的。
    /// 跨卷会退化成「拷贝 + 删除」，那中间就有半截状态可被别人看见
    static func partURL(for destination: URL) -> URL {
        destination.appendingPathExtension("part")
    }

    enum Failure: Error, Equatable {
        /// 试满了 `attempts` 次仍然失败。reason 是**最后一次**的原因
        case retriesExhausted(attempts: Int, reason: String)
        /// HTTP 状态码不是 200/206/416
        case httpStatus(Int)
        /// 服务器返回的 `Content-Range` 起点和我们请求的对不上——
        /// 那说明对面在乱给，接着写会把文件拼错
        case rangeMismatch(requested: Int64, got: String)
        /// 校验没过（大小不足 / 魔数不对）。`.part` 保留
        case validationFailed(reason: String)
        /// 目标位置已经有文件了，而且没通过校验。**不覆盖**——
        /// 用户目录里的东西不归我们删
        case destinationOccupied(path: String, reason: String)
        /// 远端报出来的版本和清单钉的不是同一个。**不下载**：下下来的一定
        /// 过不了 sha256，而那时 539MB 已经白花了。停在这里更早、更省事
        case sourceDrift(file: String, pinned: String, got: String, detail: String)
        /// 服务器宣告的长度和实际给到的字节数对不上就被关掉了。
        ///
        /// 这是「静默返回残缺」最后一道网：大小下界和魔数都可能被一个
        /// **截断但够长**的响应骗过去（清单里那条精确 size/sha256 才是
        /// 主判据，但没清单的路径上就只剩它了）
        case incomplete(received: Int64, expected: Int64)

        var localizedDescription: String {
            switch self {
            case .retriesExhausted(let attempts, let reason):
                return "自动重试已到上限（共 \(attempts) 次），最后一次失败原因：\(reason)"
            case .httpStatus(let code):
                return "服务器返回 HTTP \(code)"
            case .rangeMismatch(let requested, let got):
                return "续传位置对不上：请求从 \(requested) 开始，服务器给的 Content-Range 是「\(got)」"
            case .validationFailed(let reason):
                return "下载完成但校验不通过：\(reason)"
            case .destinationOccupied(let path, let reason):
                return "\(path) 已存在且未通过校验（\(reason)）。为不动你已有的文件，这里不覆盖——"
                    + "要重新下载请先自行把它移走"
            case .sourceDrift(let file, let pinned, let got, let detail):
                return "源已不是清单钉的那一版：\(file) 清单里 revision \(pinned)，"
                    + "远端现在报 \(got)（\(detail)）。不拿新版本冒充旧版本——"
                    + "要么更新清单（Sources/Resources/model-manifest.json），要么换源"
            case .incomplete(let received, let expected):
                return "连接中断，只收到 \(received) / \(expected) 字节（差了 \(expected - received)）——"
                    + "残缺的模型文件比没有更坏，这里不放行"
            }
        }
    }

    /// 下载 `url` 到 `partURL`，校验通过后原子改名成 `destination`。
    ///
    /// - Parameters:
    ///   - pin: 清单里那一版（revision + 精确大小 + sha256）。**传 nil 是
    ///     一条明确的降级路径**，不是「忘了传」：那样只剩大小下界 + 魔数
    ///     两条判据，报告里会记一条 notice 说明这次校验降级了
    ///   - onRetry: 每次**即将重试**时回调（第几次、为什么）。界面靠它把
    ///     「正在自动重试」这件事显示出来——不回调就等于静默重试
    ///   - onProgress: 进度。**可能很密集**（每个网络回包一次），调用方自己节流
    func download(
        from url: URL,
        to destination: URL,
        partURL: URL,
        minimumBytes: Int64,
        pin: ModelPin? = nil,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void = { _ in },
        onRetry: @Sendable @escaping (Int, Int, String) -> Void = { _, _, _ in }
    ) async throws -> DownloadReport {

        // 目标位置已经有东西、而且它不通过校验 → 直接停。**绝不动它**
        if FileManager.default.fileExists(atPath: destination.path),
           let reason = ModelFile.validationFailure(at: destination, minimumBytes: minimumBytes,
                                                    pin: pin) {
            throw Failure.destinationOccupied(path: destination.path, reason: reason)
        }
        // 已经有一个合格的模型了，没必要再下一遍
        if FileManager.default.fileExists(atPath: destination.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            return DownloadReport(bytesWritten: size, resumedFrom: size, rangeAccepted: nil,
                                  attempts: 0, notices: ["模型已在位，未重新下载"])
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        var notices: [String] = []
        if pin == nil {
            notices.append("没有清单，本次只做大小与文件头检查（没有 sha256 判据）")
        }
        var lastReason = "未知"
        var attempt = 0

        while attempt < Self.maxAttempts {
            attempt += 1
            do {
                let report = try await singleAttempt(
                    from: url, destination: destination, partURL: partURL,
                    minimumBytes: minimumBytes, pin: pin,
                    attempt: attempt, onProgress: onProgress, notices: &notices
                )
                return report
            } catch is CancellationError {
                // 用户按了取消：**不是失败，不要重试**，`.part` 原样留着
                throw CancellationError()
            } catch let error as Failure {
                // 这四个重试多少次结果都一样，立刻停：
                // 校验不过 / 位置被占 / 源漂了 / 收少了。
                //
                // 「收少了」为什么不重试：注意它和「网络断了」不是一回事——
                // 网络断了会走 URLSession 的错误分支（`NSURLError…`），那条
                // 路径照样重试、照样从 `.part` 接着下。走到 `incomplete` 的是
                // **服务器自己说「给完了」而字节数对不上**——它在（对
                // Content-Length 这件事）撒谎，或者中间有个东西在改包。
                // 对同一个源再问三遍不会问出不一样的答案，只会把一句
                // 明确的话拖成 90 秒的转圈
                switch error {
                case .validationFailed, .destinationOccupied, .sourceDrift, .incomplete:
                    throw error
                default:
                    lastReason = error.localizedDescription
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastReason = (error as NSError).localizedDescription
            }

            if attempt < Self.maxAttempts {
                onRetry(attempt + 1, Self.maxAttempts, lastReason)
            }
        }

        throw Failure.retriesExhausted(attempts: attempt, reason: lastReason)
    }

    // MARK: - 单次尝试

    private func singleAttempt(
        from url: URL,
        destination: URL,
        partURL: URL,
        minimumBytes: Int64,
        pin: ModelPin?,
        attempt: Int,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void,
        notices: inout [String]
    ) async throws -> DownloadReport {

        func note(_ text: String) {
            // 同一个提示只记一次（重试会把同一句话说第二遍）
            if !notices.contains(text) { notices.append(text) }
        }

        // ── 续传的起点：`.part` 现在有多少字节 ──
        //
        // 注意这里**不校验** `.part` 的内容：它天生是个半截文件，大小一定不够。
        // 要判的是它**属于哪一版**，那件事由下面那段专门做
        var resumedFrom = Self.fileSize(partURL)
        let existingMeta = resumedFrom > 0 ? PartMeta.read(forPart: partURL) : nil

        // ── 探测远端，决定「接着下」还是「从头下」 ──
        //
        // 只在真的有半截文件、或者有清单要核对时才去 HEAD 一下：没有 `.part`
        // 的时候这次探测对结果没有任何影响，白白多一个来回
        //
        // **每次都探**，哪怕这次是从 0 开始。理由：探到的版本要写进 `.part`
        // 旁边那份记录里，供**下一次**续传比对；只在有 `.part` 时才探的话，
        // 第一次下载记不下版本，第二次续传就成了一次盲猜。多花的是一个
        // HEAD 往返，相对 539MB 可以忽略。
        //
        // 探测失败**不致命**：源不支持 HEAD、临时网络抖动，都不该让整个
        // 下载停摆。拿不到身份就按「判不出来」处理——而「判不出来」在
        // `conflicts` 里的答案是「重下」，方向是保守的那一边
        let identity = try? await RemoteIdentity.probe(url: url)
        // 探测没拿到东西时退到清单：清单里的 revision/sha256/size 是**离线也
        // 知道**的权威值，`.part` 旁边那份记录当初就是照着它写的。两边一致
        // 就说明那半截确实是这一版，接着下是安全的
        let reference = identity ?? pin.map {
            RemoteIdentity(revision: $0.revision, etag: $0.sha256, size: $0.size)
        }

        if let pin, let identity, !identity.isEmpty {
            // 清单钉的是一个**不可变的对象**（URL 里带着 commit）。远端却报出
            // 别的版本，说明镜像没照着 revision 给、或者中间有人改了东西。
            // 这种时候下完也过不了 sha256，早点停
            if let got = identity.revision, got != pin.revision {
                throw Failure.sourceDrift(file: pin.file, pinned: pin.shortRevision,
                                          got: String(got.prefix(12)) + "…",
                                          detail: "远端 x-repo-commit")
            }
            if let got = identity.etag, got != pin.sha256 {
                throw Failure.sourceDrift(file: pin.file, pinned: String(pin.sha256.prefix(12)) + "…",
                                          got: String(got.prefix(12)) + "…",
                                          detail: "远端内容 etag 与清单 sha256")
            }
            if let got = identity.size, got != pin.size {
                throw Failure.sourceDrift(file: pin.file, pinned: "\(pin.size) 字节",
                                          got: "\(got) 字节", detail: "远端 x-linked-size")
            }
        }

        // ── 接着下，还是从头下 ──
        //
        // 这是本包最要紧的一处判断。拿旧字节续一个**已经不是那一版**的文件，
        // 拼出来的东西大小对、魔数对、所有便宜的判据全过——直到模型跑起来
        // 输出乱码。所以只要有一丝判不出来，就从头下
        if resumedFrom > 0 {
            var restart: String?
            if existingMeta == nil {
                // 老版本 App 留下的 `.part` 就长这样：有字节、没记录
                restart = "已下载的部分没有版本记录，无法确认它属于哪一版，重新下载"
            } else if let reference, reference.conflicts(with: existingMeta) {
                restart = "源已更新，重新下载（\(reference.describeDifference(from: existingMeta))）"
            } else if reference == nil {
                // 既没探到远端、手里又没有清单——对那半截是哪一版一无所知
                restart = "拿不到远端版本信息，无法确认已下载的部分属于哪一版，重新下载"
            }
            if let restart {
                try? FileManager.default.removeItem(at: partURL)
                PartMeta.remove(forPart: partURL)
                resumedFrom = 0
                note(restart)
            }
        }

        // 记下「这份 `.part` 属于哪一版」。写在这里而不是收完之后：被
        // `kill -9` 掐掉时没有任何代码有机会再执行，版本记录必须**先于
        // 第一个字节**落到盘上，否则下次续传就没有东西可比
        PartMeta(revision: reference?.revision, etag: reference?.etag,
                 size: reference?.size, url: url.absoluteString).write(forPart: partURL)

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if resumedFrom > 0 {
            request.setValue("bytes=\(resumedFrom)-", forHTTPHeaderField: "Range")
        }

        // ── 一次尝试 = 一个 delegate 收字节、一个 continuation 收结果 ──
        let collector = try await ByteCollector.run(
            request: request, partURL: partURL,
            resumedFrom: resumedFrom, onProgress: onProgress
        )

        if let notice = collector.notice { note(notice) }

        // 416：请求的起点已经等于或超过文件总长——多半是上次其实下完了，
        // 只是没来得及改名。交给下面的校验去判，不在这里自作主张
        if collector.statusCode == 416 {
            let size = Self.fileSize(partURL)
            if let reason = ModelFile.validationFailure(at: partURL, minimumBytes: minimumBytes,
                                                        pin: pin) {
                throw Failure.validationFailed(reason: reason + "（服务器报 416）")
            }
            try Self.promote(partURL: partURL, to: destination)
            PartMeta.remove(forPart: partURL)
            return DownloadReport(bytesWritten: size, resumedFrom: collector.actualResumedFrom,
                                  rangeAccepted: true, attempts: attempt, notices: notices)
        }

        guard collector.statusCode == 200 || collector.statusCode == 206 else {
            throw Failure.httpStatus(collector.statusCode)
        }

        // ── 收少了：服务器宣告的长度和实际字节数对不上 ──
        //
        // 这条必须挡在改名之前。少了字节的文件照样可能满足「≥ 下界」和
        // 「魔数对」，一路走到 promote 就变成「录完一节课一个字没有」
        if let failure = Self.incompletenessFailure(written: collector.writtenBytes,
                                                    expected: collector.expectedTotal) {
            throw failure
        }

        // ── 校验：**先校验，通过了才改名** ──
        if let reason = ModelFile.validationFailure(at: partURL, minimumBytes: minimumBytes,
                                                    pin: pin) {
            throw Failure.validationFailed(reason: reason)
        }

        try Self.promote(partURL: partURL, to: destination)
        // `.part` 已经不在了，旁边那份版本记录留着没有意义，而且会被
        // 「占用清单」数成一个未完成的下载——清掉
        PartMeta.remove(forPart: partURL)

        return DownloadReport(
            bytesWritten: Self.fileSize(destination),
            resumedFrom: collector.actualResumedFrom,
            rangeAccepted: collector.rangeAccepted,
            attempts: attempt,
            notices: notices
        )
    }

    /// 「这一次收够了没有」——单独拎出来是为了让这条判据**能被单独验**。
    ///
    /// 为什么值得单拎：它藏在传输层和一个只有真出错才会走到的分支里，混在
    /// `singleAttempt` 里就只能靠「构造一个收少了的服务器」去验，而那种
    /// 服务器在 URLSession 眼里往往直接是个网络错误（`didCompleteWithError`
    /// 带着 error 回来），根本走不到这一行——于是这条判据会变成一条
    /// **永远绿的空断言**。拎出来之后，自检可以直接把三个入参喂给它。
    ///
    /// 三个分支各有各的意义，都不是凑数：
    ///   written == expected → 收够了（正常路径，必须放行）
    ///   written <  expected → 收少了（要拦的那个）
    ///   expected == nil     → 服务器没说长度，**判不了就不判**。
    ///                         这里编一个数出来才是真的坏
    static func incompletenessFailure(written: Int64, expected: Int64?) -> Failure? {
        guard let expected, written < expected else { return nil }
        return .incomplete(received: written, expected: expected)
    }

    /// 校验过了才走这一步。`moveItem` 在同一个卷上是原子的——不存在
    /// 「改名改到一半」这个状态，所以别的进程要么看见 `.part`、要么看见成品
    static func promote(partURL: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partURL, to: destination)
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

// MARK: - 收字节的那一层

/// 把 `URLSessionDataTask` 的回包写进 `.part`。
///
/// 单独一个类而不是把逻辑摊在 `download` 里：`URLSessionDataDelegate` 的
/// 回调是 ObjC block、在 session 自己的队列上跑（Swift 6 下不能继承 actor
/// 隔离，见 `MicTap` 的同类处理），所以这里用一个 `@unchecked Sendable`
/// 的壳把「只在 session 队列上碰」这件事显式承诺下来。
private final class ByteCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let partURL: URL
    private let resumedFrom: Int64
    private let onProgress: @Sendable (DownloadProgress) -> Void

    private var handle: FileHandle?
    private var written: Int64 = 0
    private var total: Int64?
    private var started = Date()
    /// 最后一次响应的 HTTP 状态码。调用方要拿它区分 200/206/416
    private(set) var statusCode = 0

    /// 源是否接受 `Range`。nil = 这次没请求续传，没问过
    private(set) var rangeAccepted: Bool?
    /// 这次**实际**从第几个字节接上的。源忽略 `Range` 时会被打回 0——
    /// 报告里必须用这个值，不能用请求前算的那个，否则「接着下的」这句话
    /// 在 200 分支上就是假的
    private(set) var actualResumedFrom: Int64 = 0
    /// 必须原样告诉用户的诚实提示
    private(set) var notice: String?

    /// 这次总共应该落多少字节（206 取 `Content-Range` 的总长，200 取
    /// `Content-Length`）。nil = 服务器没说——**那时不编一个数出来**，
    /// 「收少了」这条判据也就无从谈起（宁可少一条判据，不要一条假判据）
    var expectedTotal: Int64? {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    /// 收完之后 `.part` 上实际的字节数（含续传接上的那一段）
    var writtenBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false

    /// 保护 `finished` / `continuation` / `handle`。
    ///
    /// 为什么需要锁：`finish` 会从三个不同的地方被调用——session 自己的
    /// 串行 delegate 队列（正常收完 / 网络断）、以及 `onCancel`（**任意
    /// 线程**，外层 Task 被取消时触发）。两处可能同时到，而 continuation
    /// 被 resume 两次是直接崩，不是「结果不对」。
    private let lock = NSLock()

    private init(partURL: URL, resumedFrom: Int64,
                 onProgress: @Sendable @escaping (DownloadProgress) -> Void) {
        self.partURL = partURL
        self.resumedFrom = resumedFrom
        self.actualResumedFrom = resumedFrom
        self.onProgress = onProgress
    }

    static func run(
        request: URLRequest, partURL: URL,
        resumedFrom: Int64,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void
    ) async throws -> ByteCollector {
        let collector = ByteCollector(partURL: partURL, resumedFrom: resumedFrom, onProgress: onProgress)
        return try await collector.start(request: request)
    }

    private func start(request: URLRequest) async throws -> ByteCollector {
        // 自己开一条 session：delegate 是 per-session 的，用 `.shared` 会把
        // 别的请求（COS 上传、事实核查）也导到这里来
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // 取消可能**先于**这一行到达（外层 Task 在启动前就已经被
                // cancel 了）：那时 cancel() 已经把 finished 立起来、却没有
                // continuation 可 resume。不在这里补一次就会永久挂住
                lock.lock()
                if finished {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                continuation = cont
                lock.unlock()

                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
            return self
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        finish(with: CancellationError())
    }

    private func finish(with error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        let openHandle = handle
        handle = nil
        lock.unlock()

        // 关掉 handle 会把还压在缓冲区里的字节刷下去——`.part` 因此
        // **每一刻都是完整的**，`kill -9` 之后接着用它不会有半截数据
        try? openHandle?.close()
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: URLError(.badServerResponse))
            return
        }
        statusCode = http.statusCode

        switch http.statusCode {
        case 206:
            // 服务器接受了 Range。**核对起点**：起点对不上就停，
            // 否则「文件中间少了一段」这种错会一路写到校验那一步才暴露
            rangeAccepted = true
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard Self.contentRangeStart(contentRange) == resumedFrom else {
                completionHandler(.cancel)
                finish(with: ModelDownloader.Failure.rangeMismatch(
                    requested: resumedFrom, got: contentRange))
                return
            }
            // 接着写
            if !FileManager.default.fileExists(atPath: partURL.path) {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            lock.lock()
            total = Self.contentRangeTotal(contentRange)
            handle = try? FileHandle(forWritingTo: partURL)
            _ = try? handle?.seekToEnd()
            written = resumedFrom
            lock.unlock()

        case 200:
            // 服务器**忽略了** Range。这就是「假续传」的来源：如果我们不
            // 察觉，就会把整份文件追加到已有的半截后面，拼出一个大小对、
            // 内容错的文件。所以这里必须把 .part 清空重写，**并且说出来**
            if resumedFrom > 0 {
                rangeAccepted = false
                actualResumedFrom = 0
                notice = "此源不支持续传，将从 0 开始"
            }
            try? FileManager.default.removeItem(at: partURL)
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let length = http.expectedContentLength
            lock.lock()
            handle = try? FileHandle(forWritingTo: partURL)
            written = 0
            total = length > 0 ? length : nil
            lock.unlock()

        default:
            completionHandler(.allow)
            return
        }

        started = Date()
        onProgress(DownloadProgress(written: written, total: total,
                                    resumedFrom: resumedFrom, bytesPerSecond: 0))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let handle else { lock.unlock(); return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            lock.unlock()
            finish(with: error)
            return
        }
        written += Int64(data.count)
        let writtenNow = written
        let totalNow = total
        lock.unlock()
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        onProgress(DownloadProgress(
            written: writtenNow, total: totalNow, resumedFrom: resumedFrom,
            bytesPerSecond: Double(writtenNow - resumedFrom) / elapsed
        ))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // 用户取消 → 也走这里。`.part` **不删**（下一次从这里续）
            if (error as NSError).code == NSURLErrorCancelled || Task.isCancelled {
                finish(with: CancellationError())
            } else {
                finish(with: error)
            }
            return
        }
        finish(with: nil)
    }

    // MARK: Content-Range 解析

    /// `bytes 100-999/1000` → 100。解析不了返回 nil
    static func contentRangeStart(_ raw: String) -> Int64? {
        guard let range = raw.split(separator: " ").last else { return nil }
        guard let span = range.split(separator: "/").first else { return nil }
        guard let start = span.split(separator: "-").first else { return nil }
        return Int64(start)
    }

    static func contentRangeTotal(_ raw: String) -> Int64? {
        guard let tail = raw.split(separator: "/").last, tail != "*" else { return nil }
        return Int64(tail)
    }
}
