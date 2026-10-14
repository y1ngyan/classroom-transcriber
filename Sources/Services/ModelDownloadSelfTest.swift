import CryptoKit
import Foundation

/// 模型下载的无头自检。**离线、零花费、不发声、不起 GUI。**
///
/// 它**绝不去碰 huggingface / hf-mirror**，也绝不下那 539MB：所有下载都打给
/// 自己在本机回环上起的一个夹具服务器（`LocalHTTPServer`），夹具的 body 是
/// 几百 KB 的假模型。要验的行为（Range、半路断线、源忽略 Range、取消、
/// 重试上限）全在传输层，用真模型验只会更慢、更不可复现。
///
/// **硬闸**：进程必须带 `CLASSROOM_MODELS_DIR` 起。没有它，`WhisperEngine`
/// 会指向用户真实的 `Application Support/…/models/`（那 1.5GB 是他的东西），
/// 而这个自检会反复写盘、改名、删 `.part`。所以宁可直接拒绝运行，也不
/// 「小心一点」地跑——那正是把真库当草稿纸的开始。
/// 重试通报的收集盒。
///
/// `onRetry` 的参数是 `@Sendable`（它从下载任务的上下文里被调用），所以
/// 闭包里**不能**直接往外面那个 `var [String]` 上 append——Swift 6 会拦。
/// `@unchecked Sendable` 的依据：数组只在 `lock` 里读写
final class NoteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ text: String) {
        lock.lock(); items.append(text); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

enum ModelDownloadSelfTest {

    struct Result {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    // MARK: - 夹具

    /// 假模型：ggml 魔数开头，后面是可复现的伪随机填充。
    ///
    /// 用可复现的填充而不是 `randomBytes`：判据里有一条是「下下来的文件
    /// 与源**逐字节**相等」，夹具自己每次不一样的话，那条判据会自己抖
    static func fakeModel(bytes: Int) -> Data {
        var data = Data(ModelFile.magic)
        data.reserveCapacity(bytes)
        var x: UInt32 = 0x1234_5678
        while data.count < bytes {
            x = x &* 1_103_515_245 &+ 12_345
            data.append(UInt8((x >> 16) & 0xFF))
        }
        return Data(data.prefix(bytes))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256(data)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func size(_ url: URL) -> Int64 {
        ModelDownloader.fileSize(url)
    }

    // MARK: - 入口

    static func run() async -> Result {
        var lines: [String] = []
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        lines.append("模型下载 · 无头自检（离线 · 零花费 · 不发声 · 不起 GUI）")
        lines.append("")

        // ── 硬闸：没重定向就不跑 ──
        let env = ProcessInfo.processInfo.environment["CLASSROOM_MODELS_DIR"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !env.isEmpty else {
            lines.append("❌ 拒绝运行：没有设置 CLASSROOM_MODELS_DIR")
            lines.append("   这个自检会反复写盘、改名、删 .part。不重定向的话，它")
            lines.append("   动的就是 \(WhisperEngine.modelDirectory.path)")
            lines.append("   ——那是你自己的模型库（medium + large-v3 约 1.5GB）。")
            lines.append("   请这样跑：")
            lines.append("     CLASSROOM_MODELS_DIR=$(mktemp -d) \(CommandLine.arguments[0]) --model-download-selftest")
            lines.append("   探针里的调用见 tools/probes/exit_codes.sh。")
            return Result(lines: lines, passed: 0, failed: 1)
        }

        let root = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        lines.append("【〇】目录重定向（本包的可测性前提）")
        check(WhisperEngine.modelDirectory.path == root.path,
              "WhisperEngine.modelDirectory 认 CLASSROOM_MODELS_DIR",
              WhisperEngine.modelDirectory.path)
        check(WhisperEngine.modelPath.path.hasPrefix(root.path),
              "modelPath 落在重定向后的目录里",
              WhisperEngine.modelPath.path)
        lines.append("")

        // ── 夹具服务器：路由与 `--model-fixture-server` 共用同一份 ──
        let body = ModelFixture.body
        let bodySHA = sha256(body)
        let minimum = ModelFixture.minimumBytes

        let server: LocalHTTPServer
        do {
            server = try LocalHTTPServer(handler: ModelFixture.handler)
        } catch {
            lines.append("❌ 起不了本机夹具服务器：\(error.localizedDescription)")
            return Result(lines: lines, passed: passed, failed: failed + 1)
        }
        defer { server.stop() }
        lines.append("夹具服务器：http://127.0.0.1:\(server.port)（只绑回环，跑完就停）")
        lines.append("")

        // 夹具那一版。**形状和真清单一样**（40 位 commit、64 位 sha256），
        // 只有值不同——这样验的是「这套判据」，不是「这两个常量」。
        // URL 直接用夹具的，因为这份 pin 描述的就是夹具上那个文件
        func pin(revision: String = ModelFixture.revisionA,
                 sha256: String? = nil, size: Int64? = nil,
                 path: String = "model") -> ModelPin {
            ModelPin(file: WhisperEngine.modelFileName, repo: "fixture/model",
                     revision: revision, size: size ?? Int64(body.count),
                     sha256: sha256 ?? bodySHA, isDefault: true,
                     url: server.baseURL.appendingPathComponent(path))
        }

        // 占用清单那一节要的是一份**清单**而不是一个 pin：它得能按文件名
        // 去找（medium 和 large-v3 在同一目录里，用 medium 的大小去判
        // large-v3 会把好文件报成残骸）
        let fixtureManifest = ModelManifest(
            version: 1, source: "fixture",
            models: [pin()])

        // ═══ 一、正常下完 → 校验过 → 原子改名 ═══
        lines.append("【一】正常路径：下完 → 校验 → 原子改名")
        let okDir = root.appendingPathComponent("case-ok", isDirectory: true)
        let okDest = okDir.appendingPathComponent(WhisperEngine.modelFileName)
        let okPart = ModelDownloader.partURL(for: okDest)
        do {
            let report = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("model"),
                to: okDest, partURL: okPart, minimumBytes: minimum, pin: pin())
            check(report.attempts == 1, "一次就成，没有多余重试", "attempts=\(report.attempts)")
            check(exists(okDest), "正式文件已就位")
            check(!exists(okPart), "`.part` 已被改名（不是留一份副本）")
            check(sha256(fileAt: okDest) == bodySHA,
                  "内容与源逐字节相同", "sha256 \(sha256(fileAt: okDest)?.prefix(12) ?? "?")…")
            check(report.bytesWritten == Int64(body.count),
                  "字节数等于源", "\(report.bytesWritten) / \(body.count)")
            // 落地之后不能再留版本记录：`.part` 已经改名了，那份记录只会
            // 被占用清单数成一个「未完成的下载」
            check(!exists(PartMeta.url(forPart: okPart)),
                  "`.part` 的版本记录跟着一起清掉了（不留孤儿）")
        } catch {
            check(false, "正常路径不该失败", error.localizedDescription)
        }
        lines.append("")

        // 顺带验一次真·`isModelReady`：把模型下到重定向后的真正位置
        let realDest = WhisperEngine.modelPath
        do {
            _ = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("model"),
                to: realDest, partURL: ModelDownloader.partURL(for: realDest),
                minimumBytes: minimum, pin: pin())
            check(WhisperEngine.isModelReady, "WhisperEngine.isModelReady == true",
                  realDest.path)
            check(ModelFile.isValid(at: realDest, minimumBytes: minimum, pin: pin()),
                  "它是通过校验的那一份（含 sha256）")
        } catch {
            check(false, "下到 modelPath 不该失败", error.localizedDescription)
        }
        lines.append("")

        // ═══ 一之二、随仓库提交的清单本身 ═══
        lines.append("【一之二】模型清单：随仓库提交、被 build.sh 打进包、内容自洽")
        do {
            let manifest = try ModelManifest.loadBundled()
            check(true, "清单能从 bundle 里读出来（build.sh 没漏拷）",
                  ModelManifest.bundledURL()?.path ?? "")
            check(manifest.defaultPin?.file == WhisperEngine.modelFileName,
                  "默认条目就是 App 要下的那个文件",
                  manifest.defaultPin?.file ?? "（没有默认条目）")
            if let p = manifest.defaultPin {
                check(p.revision.count == 40 && p.revision.allSatisfy(\.isHexDigit),
                      "revision 是 40 位 commit（不是 main 这种分支名）",
                      "\(p.shortRevision)…")
                check(p.sha256.count == 64 && p.sha256.allSatisfy(\.isHexDigit),
                      "sha256 是 64 位十六进制", String(p.sha256.prefix(16)) + "…")
                check(p.size >= WhisperEngine.expectedModelBytes,
                      "清单里的 size 不低于代码里那条下界",
                      "\(p.size) ≥ \(WhisperEngine.expectedModelBytes)")
                // 这一条是**结构断言**：URL 必须由 revision 拼出来。
                // 哪天有人「顺手」把它换回 resolve/main，这条立刻红——
                // 而那正是「续传拼出两个版本」那个 bug 的入口
                let url = p.url.absoluteString
                check(url.contains("/resolve/\(p.revision)/"),
                      "下载地址钉在 revision 上，不是 resolve/main",
                      url.replacingOccurrences(of: ModelPin.sourcePrefix, with: ""))
                check(!url.contains("/resolve/main/"), "**没有**回落到 resolve/main")
            }
        } catch {
            check(false, "清单该能读出来", error.localizedDescription)
        }

        // 坏清单必须**抛错**，不许「读不懂就当没有」
        do {
            let bad = root.appendingPathComponent("bad-manifest.json")
            try? Data(#"{"models":[{"file":"x.bin","repo":"a/b","revision":"c","size":1,"sha256":"tooshort"}]}"#.utf8)
                .write(to: bad)
            var threw = false
            do { _ = try ModelManifest.load(from: bad) } catch { threw = true }
            check(threw, "sha256 不是 64 位的清单被拒（不是当没有）")

            let empty = root.appendingPathComponent("empty-manifest.json")
            try? Data(#"{"models":[]}"#.utf8).write(to: empty)
            var threwEmpty = false
            do { _ = try ModelManifest.load(from: empty) } catch { threwEmpty = true }
            check(threwEmpty, "空清单被拒（否则界面上会变成一个「没有下载按钮」的谜）")

            var threwMissing = false
            do {
                _ = try ModelManifest.load(
                    from: root.appendingPathComponent("根本没有这个文件.json"))
            } catch { threwMissing = true }
            check(threwMissing, "清单文件不存在时抛错（不静默降级成「不校验」）")
        }
        lines.append("")

        // ═══ 二、校验失败 → 拒绝改名 + .part 保留 ═══
        lines.append("【二】校验失败：拒绝改名、`.part` 保留、报错说清原因")
        for (path, label, why, usePin) in [
            ("short", "大小不足", "大小不足", false),
            ("badmagic", "魔数不对", "文件头不是 ggml", false),
            // 大小和魔数**都对**，只有内容不是清单那一版。这条只有 sha256
            // 能判出来——大小 + 魔数在它面前是彻底瞎的
            ("noetag", "sha256 不符", "内容 sha256 不对", true),
        ] {
            let dir = root.appendingPathComponent("case-\(path)", isDirectory: true)
            let dest = dir.appendingPathComponent(WhisperEngine.modelFileName)
            let part = ModelDownloader.partURL(for: dest)
            // `noetag` 那条故意给一个**错的** sha256：远端不报 etag，
            // 所以下载前的版本比对不会替我们挡住它，只能靠下完之后的校验
            let casePin = usePin ? pin(sha256: sha256(ModelFixture.badMagicBody), path: path) : nil
            do {
                _ = try await ModelDownloader().download(
                    from: server.baseURL.appendingPathComponent(path),
                    to: dest, partURL: part, minimumBytes: minimum, pin: casePin)
                check(false, "\(label)：本该抛错却成功了")
            } catch let error as ModelDownloader.Failure {
                let text = error.localizedDescription
                check(text.contains(why), "\(label)：报错说清了原因", text.prefix(60) + "…")
                check(!exists(dest), "\(label)：**没有**改名成正式文件")
                check(exists(part), "\(label)：`.part` 保留着（下次可续）",
                      "\(size(part)) 字节")
            } catch {
                check(false, "\(label)：抛的不是声明的错误类型", error.localizedDescription)
            }
        }
        lines.append("")

        // ═══ 三、续传 ═══
        lines.append("【三】断点续传：从已有字节接着下")
        let resumeDir = root.appendingPathComponent("case-resume", isDirectory: true)
        let resumeDest = resumeDir.appendingPathComponent(WhisperEngine.modelFileName)
        let resumePart = ModelDownloader.partURL(for: resumeDest)
        try? FileManager.default.createDirectory(at: resumeDir, withIntermediateDirectories: true)
        // 手工把 `.part` 铺成「上次下到 60000 字节就被掐了」的样子。
        // 这和真被 kill -9 之后磁盘上的状态**是同一种东西**——真 kill 的
        // 那一版在 tools/probes/model_resume.sh 里，两条都跑
        let seedBytes = 60_000
        try? body.prefix(seedBytes).write(to: resumePart)
        // 铺一份**版本记录**，和真被 kill -9 之后盘上的状态一致（版本记录
        // 是第一个字节落地之前就写好的，所以真 kill 之后它一定在）。
        // 没有它的话下面那一步会判成「不知道是哪一版」→ 从 0 重下
        PartMeta(revision: ModelFixture.revisionA, etag: bodySHA,
                 size: Int64(body.count), url: "fixture").write(forPart: resumePart)
        let before = server.requestCount(path: "/model")
        do {
            let report = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("model"),
                to: resumeDest, partURL: resumePart, minimumBytes: minimum, pin: pin())
            check(report.resumedFrom == Int64(seedBytes),
                  "从第 \(seedBytes) 字节接上（不是从 0）", "resumedFrom=\(report.resumedFrom)")
            check(report.rangeAccepted == true, "源接受了 Range（报的是 206）")
            check(sha256(fileAt: resumeDest) == bodySHA,
                  "接完的文件逐字节等于源（没有拼错位）")
            check(server.sawRangeRequest(path: "/model", prefix: "bytes=\(seedBytes)-") != nil,
                  "夹具确实收到了 `Range: bytes=\(seedBytes)-`")
            check(server.requestCount(path: "/model") - before == 1,
                  "只发了 1 次请求（没有从头重下）",
                  "\(server.requestCount(path: "/model") - before) 次")
        } catch {
            check(false, "续传不该失败", error.localizedDescription)
        }
        lines.append("")

        // ═══ 三之二、源已更新 → 从 0 重下（S2 那条硬要求）═══
        //
        // `/moved` 和 `/model` 的内容**一模一样**，只有 revision 变了。
        // 也就是说：光看文件、光看大小、光看魔数，这两版**根本分不出来**——
        // 能分出它们的只有版本元数据。所以这一节验的是「判据真的来自
        // revision 比对」，而不是「恰好内容不同所以碰对了」
        lines.append("【三之二】源已更新：远端 revision 变了 → **从 0 重下**，并说出理由")
        let movedDir = root.appendingPathComponent("case-moved", isDirectory: true)
        let movedDest = movedDir.appendingPathComponent(WhisperEngine.modelFileName)
        let movedPart = ModelDownloader.partURL(for: movedDest)
        try? FileManager.default.createDirectory(at: movedDir, withIntermediateDirectories: true)
        try? body.prefix(seedBytes).write(to: movedPart)
        // 盘上那半截记的是**旧版 A**
        PartMeta(revision: ModelFixture.revisionA, etag: bodySHA,
                 size: Int64(body.count), url: "fixture").write(forPart: movedPart)
        // 现在源上已经是**新版 B** 了（清单也跟着更新到了 B）
        let movedPin = pin(revision: ModelFixture.revisionB, path: "moved")
        let movedRangesBefore = server.sawRangeRequest(path: "/moved")
        do {
            let report = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("moved"),
                to: movedDest, partURL: movedPart, minimumBytes: minimum, pin: movedPin)
            check(report.resumedFrom == 0,
                  "**从 0 重下**（没有拿旧版的 60000 字节续）",
                  "resumedFrom=\(report.resumedFrom)")
            check(!server.sawRangeRequest(path: "/moved"),
                  "整个过程**一个带 Range 的请求都没发**（真的没续）"
                    + (movedRangesBefore ? "（之前有过，是本节之外的）" : ""))
            let notice = report.notices.first { $0.contains("源已更新") }
            check(notice != nil, "明确说出了「源已更新，重新下载」",
                  notice ?? "（没有这句）")
            if let notice {
                check(notice.contains("revision"),
                      "并且说出了**是哪里变了**（revision），不是一句笼统的「源变了」",
                      notice)
            }
            check(sha256(fileAt: movedDest) == bodySHA,
                  "下下来的文件是完整的（没有两版拼接）")
        } catch {
            check(false, "这条路径不该失败", error.localizedDescription)
        }
        lines.append("")

        // ═══ 三之三、没有版本记录的 `.part` → 同样不敢续 ═══
        lines.append("【三之三】`.part` 没有版本记录 → 不猜，从 0 重下并说明")
        let bareDir = root.appendingPathComponent("case-bare", isDirectory: true)
        let bareDest = bareDir.appendingPathComponent(WhisperEngine.modelFileName)
        let barePart = ModelDownloader.partURL(for: bareDest)
        try? FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        try? body.prefix(seedBytes).write(to: barePart)
        // **故意不写 PartMeta**：老版本 App 留下的 `.part` 就长这样
        do {
            let report = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("model"),
                to: bareDest, partURL: barePart, minimumBytes: minimum, pin: pin())
            check(report.resumedFrom == 0, "没有记录就不猜，从 0 下",
                  "resumedFrom=\(report.resumedFrom)")
            let notice = report.notices.first { $0.contains("无法确认") }
            check(notice != nil, "把「为什么重下」说清楚了（不是默默丢掉进度）",
                  notice ?? "（没有这句）")
        } catch {
            check(false, "这条路径不该失败", error.localizedDescription)
        }
        lines.append("")

        // ═══ 三之四、清单钉的版本 ≠ 远端报的版本 → 拒绝下载 ═══
        //
        // 和上面那一节的分别：上面是「本地半截过期了」（重下就好），
        // 这里是「源本身已经不是清单说的那一版了」——那意味着**下完也过不了
        // sha256**，所以要在花掉 539MB 流量之前就停
        lines.append("【三之四】源头漂了：远端 revision ≠ 清单钉的 → 拒绝下载，不白花流量")
        let driftDir = root.appendingPathComponent("case-drift", isDirectory: true)
        let driftDest = driftDir.appendingPathComponent(WhisperEngine.modelFileName)
        let driftGetsBefore = server.requestCount(path: "/moved")
        do {
            _ = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("moved"),
                to: driftDest, partURL: ModelDownloader.partURL(for: driftDest),
                minimumBytes: minimum, pin: pin(path: "moved"))  // 清单仍钉着 A
            check(false, "源漂了本该抛错却成功了")
        } catch let error as ModelDownloader.Failure {
            let text = error.localizedDescription
            check(text.contains("源已不是清单钉的那一版"),
                  "报错点明了是「源不是清单那一版」", text.prefix(50) + "…")
            check(text.contains(ModelFixture.revisionA.prefix(12))
                    && text.contains(ModelFixture.revisionB.prefix(12)),
                  "把**两边**的 revision 都摆出来了（好让人知道该改哪一个）")
            check(server.requestCount(path: "/moved") == driftGetsBefore,
                  "一个字节都没下（GET 次数没涨）",
                  "\(server.requestCount(path: "/moved") - driftGetsBefore) 次")
            check(!exists(driftDest), "没有造出任何文件")
        } catch {
            check(false, "抛的不是声明的错误类型", error.localizedDescription)
        }
        lines.append("")

        // ═══ 三之五、「收少了」这条判据本身 ═══
        //
        // 规则拎出来单独喂三个入参，**不靠构造一个「会骗人的服务器」**——
        // 那种服务器在 URLSession 眼里通常直接是个网络错误，根本走不到
        // 检查那一行，于是这条判据会变成一条永远绿的空断言
        lines.append("【三之五】残缺判据：宣告的长度和实收字节对不上就不放行")
        check(ModelDownloader.incompletenessFailure(written: 100, expected: 200) != nil,
              "收少了 → 判失败", "100 / 200")
        check(ModelDownloader.incompletenessFailure(written: 200, expected: 200) == nil,
              "收够了 → 放行（正常路径不能被误伤）")
        check(ModelDownloader.incompletenessFailure(written: 300, expected: 200) == nil,
              "收多了也放行（多出来的是服务器的问题，不是残缺）")
        check(ModelDownloader.incompletenessFailure(written: 100, expected: nil) == nil,
              "服务器没说长度 → **判不了就不判**，不编一个数出来")
        if case .incomplete(let received, let expected) =
            ModelDownloader.incompletenessFailure(written: 100, expected: 200) {
            check(received == 100 && expected == 200, "报出来的是真实数字", "\(received)/\(expected)")
        } else {
            check(false, "抛的是 incomplete")
        }

        // 端到端那一半：夹具宣告 300000 字节、只给 250000 就收尾。
        // 这 250000 字节**大小过下界、魔数也对**——不判长度根本发现不了
        let truncDir = root.appendingPathComponent("case-truncated", isDirectory: true)
        let truncDest = truncDir.appendingPathComponent(WhisperEngine.modelFileName)
        let truncPart = ModelDownloader.partURL(for: truncDest)
        check(ModelFile.isValid(at: { () -> URL in
            let u = root.appendingPathComponent("truncated-sample.bin")
            try? Data(ModelFixture.body.prefix(ModelFixture.truncatedBytes)).write(to: u)
            return u
        }(), minimumBytes: minimum),
              "（前提）截断的那一份**能过**大小 + 魔数两条判据——所以它确实只能靠长度拦")
        do {
            _ = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("truncated"),
                to: truncDest, partURL: truncPart, minimumBytes: minimum,
                pin: pin(path: "truncated"))
            check(false, "收少了本该抛错却成功了")
        } catch {
            // **如实报出是哪一层拦下的**。这条端到端判据不挑错误类型——
            // URLSession 自己也可能先发现「连接断了」并报 `NSURLError`
            // （那时重试一次，第二次会撞上「大小和清单对不上」）。
            // 真正把「长度对不上」这条规则钉死的是上面那四个纯函数断言，
            // 这里要钉的是**结果**：残缺的那一份绝对不许变成正式文件
            let kind: String
            if case ModelDownloader.Failure.incomplete(let got, let want) = error {
                kind = "我们自己的长度判据拦下的（\(got) / \(want)）"
            } else if let failure = error as? ModelDownloader.Failure {
                kind = "同一次下载里更早的一道判据拦下的：\(failure.localizedDescription.prefix(40))…"
            } else {
                kind = "传输层报错：\((error as NSError).localizedDescription.prefix(40))…"
            }
            check(true, "收少了 → 抛错", kind)
            check(!exists(truncDest), "**没有**把截断的文件改名成正式文件")
            check(exists(truncPart), "`.part` 保留着", "\(size(truncPart)) 字节")
            check(size(truncPart) < Int64(body.count),
                  "留下来的确实是不完整的那一份（不是碰巧已经下完）",
                  "\(size(truncPart)) < \(body.count)")
        }
        lines.append("")

        // ═══ 四、源不支持 Range 的诚实分支 ═══
        lines.append("【四】源不支持 Range：如实说，**不谎称续传**")
        let nrDir = root.appendingPathComponent("case-norange", isDirectory: true)
        let nrDest = nrDir.appendingPathComponent(WhisperEngine.modelFileName)
        let nrPart = ModelDownloader.partURL(for: nrDest)
        try? FileManager.default.createDirectory(at: nrDir, withIntermediateDirectories: true)
        try? body.prefix(seedBytes).write(to: nrPart)
        PartMeta(revision: ModelFixture.revisionA, etag: bodySHA,
                 size: Int64(body.count), url: "fixture").write(forPart: nrPart)
        do {
            let report = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("norange"),
                to: nrDest, partURL: nrPart, minimumBytes: minimum,
                pin: pin(path: "norange"))
            check(report.rangeAccepted == false, "报告里 rangeAccepted == false")
            check(report.resumedFrom == 0, "报告里 resumedFrom == 0（诚实：确实是重头下的）",
                  "resumedFrom=\(report.resumedFrom)")
            let notice = report.notices.first { $0.contains("不支持续传") }
            check(notice == "此源不支持续传，将从 0 开始",
                  "给出了那句明确文案", notice ?? "（没有这句）")
            check(sha256(fileAt: nrDest) == bodySHA,
                  "文件是对的（证明真从头写，而不是把两份拼在一起）")
        } catch {
            check(false, "这条路径不该失败", error.localizedDescription)
        }
        lines.append("")

        // ═══ 五、取消 → .part 保留 ═══
        lines.append("【五】取消：`.part` 保留，下次能接上")
        let cancelDir = root.appendingPathComponent("case-cancel", isDirectory: true)
        let cancelDest = cancelDir.appendingPathComponent(WhisperEngine.modelFileName)
        let cancelPart = ModelDownloader.partURL(for: cancelDest)
        try? FileManager.default.createDirectory(at: cancelDir, withIntermediateDirectories: true)
        do {
            let task = Task {
                try await ModelDownloader().download(
                    from: server.baseURL.appendingPathComponent("slow"),
                    to: cancelDest, partURL: cancelPart, minimumBytes: minimum,
                    pin: pin(path: "slow"))
            }
            // 等它真的写进去一些字节再按停——「还没开始就取消」验不到东西
            var waited = 0
            while size(cancelPart) < 16_000 && waited < 200 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                waited += 1
            }
            let mid = size(cancelPart)
            task.cancel()
            _ = try? await task.value
            let after = size(cancelPart)
            check(mid >= 16_000, "取消前确实下了 \(mid) 字节")
            check(exists(cancelPart), "取消后 `.part` 还在", "\(after) 字节")
            check(after >= mid, "保留的是已经下到的那些字节（没有被清掉）",
                  "\(mid) → \(after)")
            check(!exists(cancelDest), "没有半成品被误当成正式文件")
        }
        lines.append("")

        // ═══ 六、重试上限：第 4 次不再自动重试 ═══
        lines.append("【六】自动重试：上限 \(ModelDownloader.maxAttempts) 次，到顶就停")
        let flakyDir = root.appendingPathComponent("case-flaky", isDirectory: true)
        let flakyDest = flakyDir.appendingPathComponent(WhisperEngine.modelFileName)
        let flakyPart = ModelDownloader.partURL(for: flakyDest)
        let flakyBefore = server.requestCount(path: "/flaky")
        let retryNotes = NoteBox()
        do {
            _ = try await ModelDownloader().download(
                from: server.baseURL.appendingPathComponent("flaky"),
                to: flakyDest, partURL: flakyPart, minimumBytes: minimum,
                pin: pin(path: "flaky"),
                onRetry: { next, max, _ in retryNotes.add("第 \(next)/\(max) 次") })
            check(false, "半路断线的源本该抛错却成功了")
        } catch let error as ModelDownloader.Failure {
            let sent = server.requestCount(path: "/flaky") - flakyBefore
            check(sent == ModelDownloader.maxAttempts,
                  "服务器总共只被打了 \(ModelDownloader.maxAttempts) 次（**没有第 4 次**）",
                  "实际 \(sent) 次")
            if case .retriesExhausted(let attempts, let reason) = error {
                check(attempts == ModelDownloader.maxAttempts,
                      "抛的是「重试到顶」，并且报出了最后一次的原因",
                      "attempts=\(attempts) · \(reason.prefix(40))…")
            } else {
                check(false, "抛的是「重试到顶」而不是别的错", error.localizedDescription)
            }
            check(retryNotes.all.count == ModelDownloader.maxAttempts - 1,
                  "界面收到了 \(ModelDownloader.maxAttempts - 1) 次重试通报（每次都在界面上看得到）",
                  retryNotes.all.joined(separator: " · "))
        } catch {
            check(false, "抛的不是声明的错误类型", error.localizedDescription)
        }
        lines.append("")

        // ═══ 七、不静默降级 ═══
        lines.append("【七】不静默降级：Whisper 缺模型 → 拦住，**不回落到 Apple**")
        let absent = ModelAvailability(path: "/现在/并不存在/ggml-medium-q5_0.bin",
                                       exists: false, sizeBytes: nil, minimumBytes: minimum)
        let blocked = ModelRequirement.decide(
            backend: .whisper, model: absent,
            downloadEntry: ModelRequirement.downloadEntryDescription)
        check(blocked.effectiveBackend == nil,
              "**没有回落到 Apple**（effectiveBackend 是 nil，不是 .apple）",
              String(describing: blocked.effectiveBackend))
        if case .blocked(let reason) = blocked {
            check(reason.contains(absent.path), "拦截文案里有**模型路径**")
            // 断言用的是**从这个模型现状算出来的**那个数，不是写死的「500」。
            // 写死的话夹具一换大小这条就假绿了（第一版就是写死的，红的）
            check(reason.contains(absent.minimumDescription),
                  "拦截文案里有**期望大小**", "≥ \(absent.minimumDescription)")
            check(reason.contains("设置") && reason.contains("hf-mirror"),
                  "拦截文案里有**下载入口**")
            check(reason.contains("不会改用系统识别"), "拦截文案明确说了不会换后端")
        } else {
            check(false, "缺模型时本该是 .blocked", String(describing: blocked))
        }

        // 大小不够的残文件走同一条闸
        let stub = ModelAvailability(path: "/tmp/ggml-medium-q5_0.bin", exists: true,
                                     sizeBytes: 12_345, minimumBytes: minimum)
        let stubDecision = ModelRequirement.decide(backend: .whisper, model: stub,
                                                   downloadEntry: "x")
        check(stubDecision.effectiveBackend == nil, "半截文件同样被拦住（不是放行）")
        if case .blocked(let reason) = stubDecision {
            check(reason.contains("不到"), "并说清是「大小不到」", reason.split(separator: "\n")[0].description)
        }

        // 后端是 Apple 时，模型在不在都不影响——**这是正常路径，不许乱报错**
        let appleDecision = ModelRequirement.decide(backend: .apple, model: absent,
                                                    downloadEntry: "x")
        check(appleDecision == .apple,
              "后端是 Apple 时，模型缺失**不**造成任何拦截（正常路径）")

        // 模型在位 → 放行走 Whisper
        let present = ModelAvailability(path: "/tmp/ggml-medium-q5_0.bin", exists: true,
                                        sizeBytes: 539_212_467, minimumBytes: minimum)
        check(ModelRequirement.decide(backend: .whisper, model: present,
                                      downloadEntry: "x") == .whisper(modelPath: present.path),
              "模型在位 → 裁决为走 Whisper")
        lines.append("")

        // ═══ 八、占用可见可清理 ═══
        //
        // 一个**专门造出来的假目录**：正经模型、下坏的残骸、未完成的下载
        // 各来一份。要验的是三件事——
        //   ① 未完成的下载被**单独列出来**（不是混在一堆文件里）
        //   ② 要释放多少字节**算得对**（残骸算进去，正式文件不算）
        //   ③ 清理**只删我们自己的东西**，用户那两个 `.bin` 一根手指不碰
        lines.append("【八】占用清单：未完成的下载单独列出、算得清、清得干净")
        let cacheDir = root.appendingPathComponent("case-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let intactModel = cacheDir.appendingPathComponent("ggml-medium-q5_0.bin")
        let damagedModel = cacheDir.appendingPathComponent("ggml-large-v3-q5_0.bin")
        let orphanPart = cacheDir.appendingPathComponent("ggml-medium-q5_0.bin.part")
        let orphanMeta = PartMeta.url(forPart: orphanPart)
        let strayPart = cacheDir.appendingPathComponent("ggml-large-v3-q5_0.bin.part")
        // 一份合格的模型 + 一份「大小够但魔数不对」的残骸（用户的文件，
        // 只该被报告、不该被清）
        try? body.write(to: intactModel)
        try? ModelFixture.badMagicBody.write(to: damagedModel)
        try? Data(body.prefix(40_000)).write(to: orphanPart)
        PartMeta(revision: ModelFixture.revisionA, etag: bodySHA,
                 size: Int64(body.count), url: "fixture").write(forPart: orphanPart)
        try? Data(body.prefix(7_000)).write(to: strayPart)

        let cache = ModelCacheReport.scan(directory: cacheDir, manifest: fixtureManifest)
        check(cache.partials.count == 2, "两份未完成的下载都列出来了",
              cache.partials.map(\.url.lastPathComponent).joined(separator: "、"))
        let wantFreeable = Int64(40_000) + Int64(7_000)
            + ModelDownloader.fileSize(orphanMeta)
        check(cache.freeableBytes == wantFreeable,
              "要释放的字节数 = 两个 .part + 版本记录（**不多不少**）",
              "\(cache.freeableBytes) / \(wantFreeable)")
        check(cache.summaryLines.contains { $0 == "Found 2 incomplete download(s)" },
              "报告里有 `Found 2 incomplete download(s)` 这一句",
              cache.summaryLines.first { $0.hasPrefix("Found") } ?? "（没有）")
        // 3 项 = 两个 `.part` + 一份版本记录。**版本记录也占字节、也要跟着删**，
        // 少算它的话确认框上那个数字就是假的（哪怕只差几十字节）
        check(cache.summaryLines.contains { $0.hasPrefix("About to delete 3 item(s)") },
              "报告里有 `About to delete …` 并带上了总字节数",
              cache.summaryLines.first { $0.hasPrefix("About to delete") } ?? "（没有）")
        check(cache.models.count == 1 && cache.damaged.count == 1,
              "正式模型和残骸**分开归类**（残骸不被当成可用模型）")
        check(!cache.freeable.contains { $0.url.lastPathComponent.hasSuffix(".bin") },
              "两个 `.bin` **都不在**「将删除」清单里——用户的文件不归我们清")

        // 确认框里念出来的那几行，必须和真的删掉的是同一份东西
        let plan = cache.plan
        check(plan.lines.contains { $0.contains("About to delete") },
              "确认框里写明了将释放多少", plan.lines.last ?? "")

        // 字节数说人话这件事本身也得有判据——这一档刚抓到过一次
        // 「**文件非空却说成零**」：`--model-cache` 夹具里的 `.part.meta.json`
        // 是 91 字节，`%.0f KB` 把它印成「0 KB」。这句话是用户拿来做
        // 「删不删」决定的，说成 0 就等于说「没占地方」
        // （下面这一条断言的是**性质**「非空就不许印成 0」，不是那 91 这个数
        // ——夹具换个写法这个数就变了，性质不变）
        let metaBytes = ModelDownloader.fileSize(orphanMeta)
        check(metaBytes > 0 && !ModelCache.byteText(metaBytes).hasPrefix("0 "),
              "**非空的小文件不许显示成 0**（曾把 91 字节印成「0 KB」）",
              "\(metaBytes) 字节 → \(ModelCache.byteText(metaBytes))")
        check([Int64(0), 1_500, 539_212_467, 1_081_140_203].map(ModelCache.byteText)
              == ["0 字节", "2 KB", "539 MB", "1.08 GB"],
              "字节数分档：0 / 1.5KB / 539MB / 1.08GB",
              [Int64(0), 1_500, 539_212_467, 1_081_140_203].map(ModelCache.byteText)
                  .joined(separator: " · "))

        do {
            let freed = try cache.clean()
            check(freed == wantFreeable, "实际释放的字节数与计划一致",
                  "\(freed) / \(wantFreeable)")
            check(!exists(orphanPart) && !exists(strayPart) && !exists(orphanMeta),
                  "`.part` 和它的版本记录都被清掉了")
            check(exists(intactModel), "**合格的模型文件还在**")
            check(exists(damagedModel),
                  "**下坏的残骸也还在**（它长得像垃圾，但它是用户的文件）")
            let after = ModelCacheReport.scan(directory: cacheDir, manifest: fixtureManifest)
            check(after.summaryLines.contains { $0 == "Found 0 incomplete download(s)" },
                  "清理后重新扫描：未完成的下载归零")
        } catch {
            check(false, "清理不该失败", error.localizedDescription)
        }

        // 目录不存在时应当是「空报告」而不是崩/报错——第一次跑本来就该是空的
        let emptyReport = ModelCacheReport.scan(
            directory: root.appendingPathComponent("压根没有这个目录"))
        check(emptyReport.items.isEmpty && emptyReport.freeableBytes == 0,
              "目录不存在 → 空报告（不是错误，也不是崩）")

        // 清理在**没有东西可清**时不该报错
        do {
            let freed = try emptyReport.clean()
            check(freed == 0, "没东西可清时返回 0，不抛错")
        } catch {
            check(false, "空清理不该抛错", error.localizedDescription)
        }
        lines.append("")

        // ═══ 九、取件形状的回落（P12-1b）═══
        //
        // 背景（2026-10-13 实测，记录见 `发现-模型下载URL-404-20261013.md`）：
        // 清单把三个模型钉在同一个 40 位 commit 上，而镜像对这个 commit 的
        // **40 位写法**一律 404（连 README.md 也 404），同一个 sha 的
        // **12 位前缀**照样能给件。修法是一条**回落链**：只有 404 时才换成
        // 同一个 commit 的缩写再试一次，别的一律不换。
        //
        // 这一节**全离线**：夹具 `/resolve/<全sha>/…` 复刻 404、
        // `/resolve/<12位>/…` 给件、`/resolve/<全sha>/denied` 复刻 403。
        // 真网络那条在 `tools/probes/model_download_url.sh`——这里不碰它。
        lines.append("【九】取件形状回落：只有 404 才换形状，换了也要过 sha256")

        // ── 九之一：认不认这个响应（纯函数，一行一个状态码）──
        //
        // 表里每一行都是一条判据，而且都是**要能拦人**的那种：403/401 是鉴权、
        // 429 是限流、5xx 是源抖动——换一个 URL 形状不会让它们变好
        for (code, want) in [(404, true), (200, false), (206, false), (403, false),
                             (401, false), (429, false), (500, false), (416, false)] {
            check(ModelURLPlan.shouldFallBack(statusCode: code) == want,
                  "HTTP \(code) → \(want ? "回落" : "**不**回落")")
        }

        // ── 九之二：两条形状怎么生成（同一个 commit，不是换版本）──
        let resolveFullPath = "/resolve/\(ModelFixture.fullRevisionRef)/model"
        let resolveShortPath = "/resolve/\(ModelFixture.shortRevisionRef)/model"
        let resolveFullURL = server.baseURL.appendingPathComponent(resolveFullPath)
        let fullShapePin = ModelPin(file: WhisperEngine.modelFileName, repo: "fixture/model",
                                    revision: ModelFixture.revisionA, size: Int64(body.count),
                                    sha256: bodySHA, isDefault: true, url: resolveFullURL)
        let shapes = ModelURLPlan.variants(for: fullShapePin)
        check(shapes.count == 2, "清单那种形状给出 2 种取件形状（全 sha → 12 位前缀）",
              shapes.map { $0.lastPathComponent }.joined(separator: " → "))
        if shapes.count == 2 {
            check(shapes[0] == fullShapePin.url, "第一种就是清单钉的那个地址（首选不变）")
            let shortRef = ModelURLPlan.resolveRef(of: shapes[1])
            check(shortRef == ModelFixture.shortRevisionRef,
                  "第二种的 ref 是 12 位前缀", shortRef ?? "（读不出）")
            check(shortRef.map { ModelFixture.revisionA.hasPrefix($0) } == true
                    && ModelFixture.shortRevisionRef.count == ModelURLPlan.fallbackPrefixLength,
                  "**它就是清单那个 commit 的缩写**（前缀，不是另一个 ref、更不是 main）",
                  "\(ModelFixture.shortRevisionRef)… ⊂ \(ModelFixture.revisionA.prefix(16))…")
            // 比「除 ref 那一段之外的部分」——`dropLast()` 只去掉文件名，
            // 剩下的正好差在 ref 那一段上（第一版就是这么写错的）
            func withoutRef(_ url: URL) -> [String] {
                var parts = url.pathComponents
                if let i = parts.firstIndex(of: "resolve"), i + 1 < parts.count {
                    parts.remove(at: i + 1)
                }
                return parts
            }
            check(withoutRef(shapes[1]) == withoutRef(shapes[0]),
                  "两条形状的 repo / 文件名一字不差，只有 ref 那一段不同",
                  "/" + withoutRef(shapes[1]).dropFirst().joined(separator: "/"))
            check(!shapes.contains { $0.absoluteString.contains("/resolve/main/") },
                  "**没有**回落到 resolve/main（移动目标，和钉 sha 的初衷冲突）")
        }
        // URL 里根本没有 `resolve/<ref>` 那一段（夹具、自建源）时**不硬凑**
        // 第二种形状——去改一个我们不认识的 URL 比不回落更坏
        check(ModelURLPlan.variants(for: pin()).count == 1,
              "URL 里没有 resolve 段时只有一种形状（不硬凑、也不去改别人的 URL）")

        // 「没有 pin」那条路（`--model-fetch` 就是这个形状）：ref 只能从 URL
        // 自己那段切。**这条单独钉**——2026-10-15 核验者的注入 D 抓到过缺口：
        // 把 `?? resolveRef(of: url)` 整段删掉，121 条**全绿**、什么都不红。
        // 而它是生产可达的（`--model-fetch` 没给 `--expect-*` 时 pin 就是 nil，
        // 而那条入口的回落是**默认开**的）
        let nilPinShapes = ModelURLPlan.variants(url: resolveFullURL, revision: nil)
        check(nilPinShapes.count == 2,
              "没有 pin 时，ref 从 URL 的 /resolve/<ref>/ 段切出来（照样给出第二种形状）",
              "\(nilPinShapes.count) 种")
        if nilPinShapes.count == 2 {
            let derived = ModelURLPlan.resolveRef(of: nilPinShapes[1])
            check(derived == String(ModelFixture.fullRevisionRef.prefix(12)),
                  "第二种的 ref 是**该 URL 自己那个 ref** 的 12 位前缀", derived ?? "（读不出）")
            check(ModelFixture.fullRevisionRef.hasPrefix(derived ?? "!"),
                  "它同样是那个 ref 的前缀（说的是同一个 commit，不是另一个版本）")
        }
        check(ModelURLPlan.variants(url: resolveFullURL, revision: "").count == 2,
              "revision 传空串（清单里没填）时也要退到 URL 那段，而不是没有第二种形状")

        // **清单钉的 revision 优先于 URL 自己那段**。
        //
        // 2026-10-15 核验者的注入 G 抓到过缺口：把这两者的优先级对调，131 条
        // 全绿——因为夹具里每个 pin 的 `url` ref 都**正好等于** `revision`，
        // 两者根本区分不开。生产里 `pin.url` 是 repo+revision+file 拼的，所以
        // 对调没有实际后果，但注释宣称的「清单才是权威」不能只是一句话。
        // 这里故意让 URL 说 aaaa…、pin 说 bbbb…：缩写必须按 **pin** 切
        let splitPin = ModelPin(file: WhisperEngine.modelFileName, repo: "fixture/model",
                                revision: ModelFixture.revisionB, size: Int64(body.count),
                                sha256: bodySHA, isDefault: true, url: resolveFullURL)
        let splitShapes = ModelURLPlan.variants(for: splitPin)
        if splitShapes.count == 2 {
            let ref = ModelURLPlan.resolveRef(of: splitShapes[1])
            check(ref == String(ModelFixture.revisionB.prefix(12)),
                  "URL 与清单说的不是同一版时，缩写按**清单**那版切（清单是权威）",
                  ref ?? "（读不出）")
        } else {
            check(false, "URL 与清单不同源时也应有两种形状", "\(splitShapes.count) 种")
        }

        // **回落开关的契约自己钉一条**（`CLASSROOM_MODEL_URL_FALLBACK`）。
        //
        // 2026-10-15 核验者的注入 F：把 `fromEnvironment` 改成无条件 `return .off`
        // ——离线 131 条全绿、**真网络探针也 8 过 0 红**。因为全仓库只有
        // `App.swift` 一个调用点，而 `download(…, urlFallback: .on)` 的缺省是字面量、
        // 九之四直接传 `.off`，谁都不走 fromEnvironment。于是「默认开、环境变量能关」
        // 这条契约零判据，而它的谎话是当场可见的：探针臂①（**没设**这个变量）
        // 会打印「404 回落：关（CLASSROOM_MODEL_URL_FALLBACK=0）」——自己打自己的脸。
        check(URLFallbackPolicy.fromEnvironment([:]) == .on, "没给环境变量 → 默认开")
        for alias in ["0", "off", "false", "no", "OFF", " 0 "] {
            check(URLFallbackPolicy.fromEnvironment([URLFallbackPolicy.environmentKey: alias]) == .off,
                  "「\(alias.trimmingCharacters(in: .whitespaces))」= 关（大小写与空格都认）")
        }
        for alias in ["1", "on", "true", ""] {
            check(URLFallbackPolicy.fromEnvironment([URLFallbackPolicy.environmentKey: alias]) == .on,
                  "「\(alias)」不是关（只有写明的那几个才算关）")
        }

        // 「12」这个数**自己钉一条**：上面那些 check 用的是
        // `ModelFixture.shortRevisionRef`，而它又是 `prefix(ModelURLPlan.fallbackPrefixLength)`
        // 算出来的——同一个来源，自证。把常数改成 13，那几条照样绿（2026-10-15
        // 核验者实测），只有显示文案里的「12 位」会红一下。所以这里写死数字
        check(ModelURLPlan.fallbackPrefixLength == 12,
              "缩写长度就是 12（git 默认的缩写长度；2026-10-13 镜像给的也是这个形状）",
              "\(ModelURLPlan.fallbackPrefixLength)")

        // ── 九之三：端到端回落：40 位那条 404 → 12 位那条给件 ──
        let fbDir = root.appendingPathComponent("case-url-fallback", isDirectory: true)
        let fbDest = fbDir.appendingPathComponent(WhisperEngine.modelFileName)
        let fbPart = ModelDownloader.partURL(for: fbDest)
        let fbFullBefore = server.requestCount(path: resolveFullPath)
        let fbShortBefore = server.requestCount(path: resolveShortPath)
        do {
            let report = try await ModelDownloader().download(
                from: fullShapePin.url, to: fbDest, partURL: fbPart,
                minimumBytes: minimum, pin: fullShapePin)
            check(report.fallbacks == 1, "回落了 1 次", "fallbacks=\(report.fallbacks)")
            check(server.requestCount(path: resolveFullPath) - fbFullBefore == 1,
                  "全 sha 那条真的被请求过，而且只请求了 1 次",
                  "\(server.requestCount(path: resolveFullPath) - fbFullBefore) 次")
            check(server.requestCount(path: resolveShortPath) - fbShortBefore == 1,
                  "12 位前缀那条被请求了 1 次",
                  "\(server.requestCount(path: resolveShortPath) - fbShortBefore) 次")
            check(report.urlShape?.contains("12 位") == true,
                  "报告里读得出**这次用了哪种形状**", report.urlShape ?? "（没有）")
            let notice = report.notices.first { $0.contains("回落") }
            check(notice != nil, "报告里有一句说明「回落到 12 位前缀」的话", notice ?? "（没有）")
            check(sha256(fileAt: fbDest) == bodySHA && size(fbDest) == Int64(body.count),
                  "**内容身份没降级**：回落取到的那份逐字节等于源",
                  "\(size(fbDest)) 字节 · \(sha256(fileAt: fbDest)?.prefix(12) ?? "?")…")
        } catch {
            check(false, "回落这条路本该成功", ModelDownloader.message(for: error))
        }
        lines.append("")

        // ── 九之四：把回落关掉 → 同一条路必须**失败** ──
        //
        // 「开了才成」这句话要有对照组：没有它，臂①的成功也可能只是「今天镜像
        // 恰好又能认 40 位了」。这一条同时是失败文案的判据——最终那句话必须
        // 说人话（2026-10-13 实测到的是 `…(Failure error 0.)` 这种天书）
        lines.append("【九之四】回落关掉 → 必须失败，而且失败文案说人话")
        let offDir = root.appendingPathComponent("case-url-nofallback", isDirectory: true)
        let offDest = offDir.appendingPathComponent(WhisperEngine.modelFileName)
        let offPart = ModelDownloader.partURL(for: offDest)
        let offShortBefore = server.requestCount(path: resolveShortPath)
        do {
            _ = try await ModelDownloader().download(
                from: fullShapePin.url, to: offDest, partURL: offPart,
                minimumBytes: minimum, pin: fullShapePin, urlFallback: .off)
            check(false, "关掉回落之后本该失败却成功了")
        } catch {
            let text = ModelDownloader.message(for: error)
            check(!exists(offDest), "关掉回落 → 没有落盘任何正式文件")
            check(server.requestCount(path: resolveShortPath) == offShortBefore,
                  "关掉回落之后**一次都没**去请求 12 位那条")
            check(text.contains("服务器返回 HTTP 404"),
                  "失败文案说人话（是「服务器返回 HTTP 404」，不是 error 0. 那种天书）",
                  text.prefix(40) + "…")
            check(text.contains("自动重试已到上限"),
                  "并且说出了「重试已到上限」", text.prefix(50) + "…")
        }
        lines.append("")

        // ── 九之五：**别的状态码不回落** ──
        //
        // 403 是鉴权，不是「这个 ref 解析不了」——换了形状只会把一句明确的话
        // 拖成三次转圈。夹具里 `/resolve/<全sha>/denied` 回 403，而
        // `/resolve/<12位>/denied` 是**能给件**的：一个见了非 404 也回落的
        // 实现会在这里把件取下来，于是这条判据当场变红
        lines.append("【九之五】403 不是「解析不了这个 ref」→ 不许回落")
        let deniedFullPath = "/resolve/\(ModelFixture.fullRevisionRef)/denied"
        let deniedShortPath = "/resolve/\(ModelFixture.shortRevisionRef)/denied"
        let deniedPin = ModelPin(file: WhisperEngine.modelFileName, repo: "fixture/model",
                                 revision: ModelFixture.revisionA, size: Int64(body.count),
                                 sha256: bodySHA, isDefault: true,
                                 url: server.baseURL.appendingPathComponent(deniedFullPath))
        let deniedDir = root.appendingPathComponent("case-url-denied", isDirectory: true)
        let deniedDest = deniedDir.appendingPathComponent(WhisperEngine.modelFileName)
        let deniedShortBefore = server.requestCount(path: deniedShortPath)
        do {
            _ = try await ModelDownloader().download(
                from: deniedPin.url, to: deniedDest,
                partURL: ModelDownloader.partURL(for: deniedDest),
                minimumBytes: minimum, pin: deniedPin)
            check(false, "403 那条本该失败却成功了（回落打过了头）")
        } catch {
            check(!exists(deniedDest), "403 → 没有落盘任何正式文件")
            check(server.requestCount(path: deniedShortPath) == deniedShortBefore,
                  "403 **没有**触发回落（一次都没去请求 12 位那条）")
            check(ModelDownloader.message(for: error).contains("HTTP 403"),
                  "报的是 403 本身", ModelDownloader.message(for: error).prefix(40) + "…")
        }
        lines.append("")

        // ── 九之六：回落成功的那一份**也要过 sha256** ──
        //
        // 派单第 2 条：回落换的只是「取件路径」，不是「信任对象」。夹具那条
        // `/resolve/<12位>/noetag` 只报 revision（不报 etag/大小），所以挡住
        // 一份错误内容的只能是**下完之后**那道 sha256——这正是要单独验的
        lines.append("【九之六】回落取到的那份也要过 sha256（信任对象没换）")
        let wrongDir = root.appendingPathComponent("case-url-wrongsha", isDirectory: true)
        let wrongDest = wrongDir.appendingPathComponent(WhisperEngine.modelFileName)
        let wrongPin = ModelPin(file: WhisperEngine.modelFileName, repo: "fixture/model",
                                revision: ModelFixture.revisionA, size: Int64(body.count),
                                sha256: sha256(ModelFixture.badMagicBody), isDefault: true,
                                url: server.baseURL.appendingPathComponent(
                                    "/resolve/\(ModelFixture.fullRevisionRef)/noetag"))
        do {
            _ = try await ModelDownloader().download(
                from: wrongPin.url, to: wrongDest,
                partURL: ModelDownloader.partURL(for: wrongDest),
                minimumBytes: minimum, pin: wrongPin)
            check(false, "sha256 不符的那一份本该被拒却过了")
        } catch let error as ModelDownloader.Failure {
            check(error.localizedDescription.contains("内容 sha256 不对"),
                  "回落那条路上 sha256 照样在判（没有因为换路径就降级）",
                  error.localizedDescription.prefix(40) + "…")
            check(!exists(wrongDest), "没有把 sha256 不符的那一份改名成正式文件")
        } catch {
            check(false, "抛的不是声明的错误类型", ModelDownloader.message(for: error))
        }
        lines.append("")

        // ── 九之七：两种形状都不成 —— 最终文案与「重试预算怎么花」 ──
        //
        // 两条都是 2026-10-15 核验者的注入抓出来的缺口，注入前后 121 条**全绿**：
        //   · 把 `attempt -= 1` 删掉（让换形状**占**重试预算）→ 什么都不红。
        //     这条行为在派单里是写明的（换形状是「换一条路」而不是「又错一次」，
        //     重试预算管的是同一条路上的重复尝试），却没有任何判据。
        //   · 「两种都试过」那句最终文案：绿色回归里**从不被走到**（只在变异 ②
        //     的输出里第一次露面）——一句从没被验过的用户可见文案就是一句嘴上的话。
        //
        // 判据用的是**请求次数**，不是文案：删掉 `attempt -= 1` 时，第二种形状
        // 只会被请求 2 次（`maxAttempts - 1`），正确实现是 3 次。次数是结构事实，
        // 文案可以改词。
        lines.append("【九之七】两种形状都 404 → 新的那条拿满重试预算，且文案说清「两种都试过」")
        let ghostFullPath = "/resolve/\(ModelFixture.fullRevisionRef)/ghost"
        let ghostShortPath = "/resolve/\(ModelFixture.shortRevisionRef)/ghost"
        let ghostPin = ModelPin(file: WhisperEngine.modelFileName, repo: "fixture/model",
                                revision: ModelFixture.revisionA, size: Int64(body.count),
                                sha256: bodySHA, isDefault: true,
                                url: server.baseURL.appendingPathComponent(ghostFullPath))
        let ghostDir = root.appendingPathComponent("case-url-both404", isDirectory: true)
        let ghostDest = ghostDir.appendingPathComponent(WhisperEngine.modelFileName)
        let ghostFullBefore = server.requestCount(path: ghostFullPath)
        let ghostShortBefore = server.requestCount(path: ghostShortPath)
        do {
            _ = try await ModelDownloader().download(
                from: ghostPin.url, to: ghostDest,
                partURL: ModelDownloader.partURL(for: ghostDest),
                minimumBytes: minimum, pin: ghostPin)
            check(false, "两种形状都 404，本该失败却成功了")
        } catch let error as ModelDownloader.Failure {
            let fullTries = server.requestCount(path: ghostFullPath) - ghostFullBefore
            let shortTries = server.requestCount(path: ghostShortPath) - ghostShortBefore
            check(fullTries == 1, "第一种形状只试 1 次（404 之后就该换形状）", "\(fullTries) 次")
            check(shortTries == ModelDownloader.maxAttempts,
                  "第二种形状拿满重试预算（换形状**不**占预算）",
                  "\(shortTries) 次 / 上限 \(ModelDownloader.maxAttempts)")
            let text = ModelDownloader.message(for: error)
            check(text.contains("已经试过两种取件形状"),
                  "失败文案说清「两种都试过了」——用户不会以为还有一条没试", text.prefix(60) + "…")
            check(text.contains("HTTP 404"), "并且报的是 404 本身", text.prefix(40) + "…")
            check(!exists(ghostDest), "失败后没有落盘任何正式文件")
        } catch {
            check(false, "抛的不是声明的错误类型", ModelDownloader.message(for: error))
        }
        lines.append("")

        // ── 收尾：把自己造的东西清掉 ──
        // 只删自己造的临时根（它由 CLASSROOM_MODELS_DIR 指定）；用户目录
        // 里那 1.5GB 一根手指都不碰
        try? FileManager.default.removeItem(at: root)
        lines.append("（自检自己的临时目录已清理：\(root.path)）")

        return Result(lines: lines, passed: passed, failed: failed)
    }
}
