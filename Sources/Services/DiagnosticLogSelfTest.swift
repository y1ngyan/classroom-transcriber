import Foundation

/// `--log-selftest`：本地诊断日志（P6-1）的离线自检。
///
/// **全部离线**：不联网、不花钱、不加载模型、不碰麦克风、**不发声**。
/// 所有写入都落在自己造的临时目录里——**用户真实的 `logs/` 一个字都不碰**
/// （同 `StudyNotesStore.selfTest` 立的那条规矩：自检不该污染用户数据）。
///
/// 判据**验过会红**：把 `LogRingPolicy.shouldRotate` 改成恒 `false`
/// （＝关掉轮转），「环形」那五条立刻红，同时「总字节封顶」跟着红——
/// 见验收记录。
enum DiagnosticLogSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// 造一个临时目录。**不用 `NSTemporaryDirectory()/固定名`**：
    /// 两个自检同时跑会互相清对方的文件，而那种失败看起来像逻辑错
    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-log-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func run() -> SelfTestResult {
        var lines: [String] = ["诊断日志自检（离线 · 临时目录 · 不联网、不发音）"]
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        let root: URL
        do {
            root = try makeTempDirectory()
        } catch {
            check(false, "准备临时目录", "\(error.localizedDescription)")
            return SelfTestResult(lines: lines, passed: passed, failed: failed)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        /// 每个用例自己一个子目录：`recent` 是跨文件读的，
        /// 共用一个目录的话上一条用例的残留会混进下一条的结果里
        func freshDirectory(_ name: String) -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// 从磁盘读回全部内容。**判据一律钉在它上面，不钉内存里的那行**——
        /// 「我格式化出来的串是干净的」证明不了「落到盘上的是干净的」，
        /// 中间还隔着脱敏和一次 `write`
        func diskText(_ dir: URL) -> String {
            let w = LogRingWriter(directory: dir)
            return w.recent(limit: 1_000_000).joined(separator: "\n")
        }

        // ══════════ 一、格式与级别（纯函数）══════════

        check(LogLevel.allCases.map(\.tag) == ["DEBUG", "INFO ", "WARN ", "ERROR"],
              "级别标签定宽 5 字符（grep 得动、列对得齐）",
              LogLevel.allCases.map(\.tag).joined(separator: "|"))

        check(LogLevel.error > LogLevel.warn && LogLevel.warn > LogLevel.info && LogLevel.info > LogLevel.debug,
              "级别顺序：error > warn > info > debug")

        let oneLine = DiagnosticLog.format(
            level: .warn, category: .data, message: "第一行\n第二行\r\n第三行\t带制表符",
            fields: [], timestamp: "T")
        check(!oneLine.contains("\n") && !oneLine.contains("\r") && !oneLine.contains("\t"),
              "一条日志永远是一行（换行/制表符被摊平）",
              oneLine)
        check(oneLine.components(separatedBy: "\n").count == 1,
              "摊平之后 split 出来还是 1 行（上面那条不是靠 split 自证的）")

        // 中文值里没有 ASCII 空格，所以它**不加引号**是对的——判据要把
        // 两种形状摆在一起，否则「加引号」这条只证明了我写了个加引号的分支
        let kv = DiagnosticLog.format(
            level: .error, category: .diarization, message: "失败",
            fields: [.init("exitCode", 5), .init("reason", "说话人模型不在"), .init("detail", "a b")],
            timestamp: "T")
        check(kv.contains("exitCode=5"), "数字值不加引号（`grep exitCode=5` 命中）", kv)
        check(kv.contains("reason=说话人模型不在 "), "无空格的值不加引号（中文值不该被引号包起来）", kv)
        check(kv.contains("detail=\"a b\""), "含空格的值加引号", kv)
        check(!kv.contains("detail=a b "), "加引号确实加了（对照上面那条）")

        let categoriesOK = LogCategory.allCases.allSatisfy { category in
            DiagnosticLog.format(level: .info, category: category, message: "m", fields: [], timestamp: "T")
                .contains(category.rawValue)
        }
        check(categoriesOK, "每个类别都能出现在行里", "\(LogCategory.allCases.count) 个")

        // ══════════ 二、级别过滤（落盘）══════════

        do {
            let dir = freshDirectory("level")
            let sink = DiagnosticLogSink(directory: dir, minimumLevel: .warn, mirrorToOSLog: false)
            sink.log(.info, .app, "不该出现的 info")
            sink.log(.debug, .app, "不该出现的 debug")
            sink.log(.warn, .app, "该出现的 warn")
            sink.log(.error, .app, "该出现的 error")
            let text = diskText(dir)
            check(!text.contains("不该出现的 info") && !text.contains("不该出现的 debug"),
                  "低于门槛的级别不落盘")
            check(text.contains("该出现的 warn") && text.contains("该出现的 error"),
                  "达到门槛的级别落盘")

            sink.minimumLevel = .debug
            sink.log(.debug, .app, "改门槛之后的 debug")
            check(diskText(dir).contains("改门槛之后的 debug"),
                  "门槛改了立刻生效（不是构造时读一次的常量）")
        }

        // ══════════ 三、脱敏 ══════════
        //
        // 判据一律是「**读回来的文件里 grep 不到原文**」，不是「内存里的串干净」。

        do {
            let dir = freshDirectory("redact")
            let sink = DiagnosticLogSink(directory: dir, minimumLevel: .debug, mirrorToOSLog: false)

            let secrets: [(String, String)] = [
                ("具名 sk- 前缀", "sk-abcdefghijklmnopqrstuvwxyz012345"),
                ("具名 tvly- 前缀", "tvly-dev-abc123XYZ789def456"),
                ("腾讯云 AKID", "AKID_TEST_FIXTURE_NOT_A_SECRET"),
                ("Authorization 头", "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"),
                ("赋值形态 apiKey", "apiKey=9f8e7d6c5b4a39281706f5e4"),
                ("赋值形态 secretKey", "\"secretKey\": \"2f4b6c8d0e1a3b5c7d9e1f3a5b7c9d0e\""),
                ("预签名 URL 查询串", "https://x.cos.ap-guangzhou.myqcloud.com/a.wav?q-signature=abcdef1234567890&q-ak=AKIDqqqqqqqqqqqq"),
                ("无前缀长令牌", "Zx9Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk0Lm"),
            ]
            for (_, secret) in secrets {
                sink.log(.error, .network, "调用失败：\(secret)")
            }
            let text = diskText(dir)
            for (name, secret) in secrets {
                check(!text.contains(secret), "脱敏：\(name) 不出现在文件里", secret.prefix(12) + "…")
            }
            check(text.contains(DiagnosticLog.redactedMarker),
                  "脱敏是「换掉」不是「整行丢掉」（标记确实写进去了）")

            // 判据自身的对照：脱敏函数对原文应当报 true
            check(DiagnosticLog.containsSecretShape("sk-abcdefghijklmnopqrstuvwxyz012345"),
                  "对照：containsSecretShape 对原始密钥串报 true（否则上面那几条是假绿）")
            check(!DiagnosticLog.containsSecretShape("普通一句话，没有密钥"),
                  "对照：containsSecretShape 对普通文本报 false")

            // UUID 不该被那条「32 字符以上」的安全网误伤——sessionId
            // 是这份日志里最常用的一列，被吃掉等于日志白留。
            // **这条要能抓住的正是「只从第二个字符起才匹配」那种写法**
            // （见 `redactionRules` 第 ⑤ 条的注释）：断言的是整个 UUID
            // 原文在场，不是「有 36 个字符在场」
            let id = UUID().uuidString
            sink.log(.info, .storage, "会话已落盘", fields: [.init("sessionId", id)])
            check(diskText(dir).contains(id), "UUID 不被安全网误伤（sessionId 仍可读）", id)

            // 反过来：纯十六进制摘要**会被一起吃掉**。这是安全网那条规则的
            // 已知取舍（漏一个真密钥 ≫ 丢一个摘要），钉一条判据在这里，
            // 免得将来有人以为「摘要能进日志」而把现场建在它上面
            let digest = String(repeating: "a1b2c3d4", count: 8)   // 64 位十六进制
            check(DiagnosticLog.redact("摘要 \(digest)").contains(DiagnosticLog.redactedMarker)
                  && !DiagnosticLog.redact("摘要 \(digest)").contains(digest),
                  "已知取舍：64 位十六进制摘要也会被安全网吃掉（别把现场建在摘要上）")
        }

        do {
            // 用户正文：正则认不出「正文」，靠的是键名。这里把键名清单里
            // 每一个都塞一遍——只挑几个的话，将来往清单里加一个键、
            // 忘了它会被换掉，就没有判据兜着
            let dir = freshDirectory("content")
            let sink = DiagnosticLogSink(directory: dir, minimumLevel: .debug, mirrorToOSLog: false)
            let body = "梯度下降是一种一阶最优化算法"
            for key in DiagnosticLog.sensitiveKeys.sorted() {
                sink.log(.info, .notes, "生成失败", fields: [.init(key, body)])
            }
            let text = diskText(dir)
            check(!text.contains(body),
                  "用户正文经敏感键名一律不落盘",
                  "\(DiagnosticLog.sensitiveKeys.count) 个键全试过")
            let masked = DiagnosticLog.sensitiveKeys.filter { text.contains("\($0)=\(DiagnosticLog.redactedMarker)") }
            check(masked.count == DiagnosticLog.sensitiveKeys.count,
                  "每一个敏感键都被换成了标记（不是「整条日志被丢了」）",
                  "\(masked.count)/\(DiagnosticLog.sensitiveKeys.count)")
        }

        // ══════════ 四、环形与上限 ══════════
        //
        // 纯算术先来（不用写盘就能推演），再上真的写。

        let p = LogRingPolicy(maxFileBytes: 100, maxArchives: 3)
        check(!p.shouldRotate(currentBytes: 0, incomingBytes: 10_000),
              "空文件永不轮转（否则超长行会每写一次推走一份归档）")
        check(!p.shouldRotate(currentBytes: 60, incomingBytes: 40),
              "正好写满上限不轮转（判据是 `>`，不是 `>=`）")
        check(p.shouldRotate(currentBytes: 60, incomingBytes: 41),
              "超出上限一个字节就轮转")
        check(p.totalByteCap == 400 && p.maxFileCount == 4,
              "上限 = maxFileBytes × (maxArchives + 1)",
              "\(p.totalByteCap) 字节 / \(p.maxFileCount) 个文件")

        let tight = LogRingPolicy(maxFileBytes: 2048, maxArchives: 3)
        do {
            let dir = freshDirectory("ring")
            let writer = LogRingWriter(directory: dir, policy: tight)
            let payload = String(repeating: "abcdefgh", count: 8)   // 64 字节/条
            var written: [String] = []

            for i in 0..<500 {
                let line = "第 \(i) 条 \(payload)"
                written.append(line)
                writer.append(line)
            }

            check(writer.fileCount <= tight.maxFileCount,
                  "文件数封顶（不随写入量增长）",
                  "\(writer.fileCount) ≤ \(tight.maxFileCount)")
            check(writer.totalBytes <= tight.totalByteCap,
                  "总字节封顶",
                  "\(writer.totalBytes) 字节 ≤ \(tight.totalByteCap)")
            check(writer.fileCount == tight.maxFileCount,
                  "写完 500 条之后确实用满了归档位（封顶是真的在轮转，不是没写进去）",
                  "\(writer.fileCount) 个")

            let text = diskText(dir)
            check(text.contains("第 499 条"), "最新的那条还在")
            check(!text.contains("第 0 条 "), "最老的已经被丢掉")

            // 顺序：跨轮转边界之后仍然是「老 → 新」。这条要是错了，
            // `tail` 出来的「最后 N 条」就不是最后 N 条
            let back = writer.recent(limit: 40)
            let numbers = back.compactMap { line -> Int? in
                guard let r = line.range(of: "第 "), let e = line.range(of: " 条") else { return nil }
                return Int(line[r.upperBound..<e.lowerBound])
            }
            check(numbers.count == 40, "recent(limit: 40) 返回 40 条", "\(numbers.count)")
            check(numbers == numbers.sorted() && numbers.last == 499,
                  "跨轮转边界读回顺序正确（老→新，最后一条是第 499 条）",
                  "\(numbers.first ?? -1)…\(numbers.last ?? -1)")
        }

        do {
            // 超长行：单条比 maxFileBytes 还长。上限**在字节上兜不住它**
            // （谁也兜不住一条比上限还长的记录），但文件数必须还是封顶的——
            // 「绝不无限增长」在这里的含义是「不会每写一条就多一个文件」
            let dir = freshDirectory("oversize")
            let writer = LogRingWriter(directory: dir, policy: tight)
            let huge = "L" + String(repeating: "Z", count: 5000)
            for _ in 0..<50 { writer.append(huge) }
            check(writer.fileCount <= tight.maxFileCount,
                  "超长行不会让文件数增长",
                  "\(writer.fileCount) ≤ \(tight.maxFileCount)")
            check(writer.recent(limit: 1).first == huge,
                  "超长行本身写得进去（不会被轮转逻辑丢掉）")
        }

        // ══════════ 五、崩溃后回读 ══════════

        do {
            let dir = freshDirectory("recent")
            let writer = LogRingWriter(directory: dir, policy: .default)
            for i in 0..<30 { writer.append("E\(i)") }

            check(writer.recent(limit: 0).isEmpty, "recent(limit: 0) 返回空")
            check(writer.recent(limit: -5).isEmpty, "recent(limit: 负数) 返回空（不 trap）")
            let tail = writer.recent(limit: 10)
            check(tail == (20..<30).map { "E\($0)" },
                  "recent(limit: 10) 正好是最后 10 条、顺序正确",
                  "\(tail.first ?? "-")…\(tail.last ?? "-")")
            check(writer.recent(limit: 10_000).count == 30,
                  "limit 大于总数时返回全部", "\(writer.recent(limit: 10_000).count)")
        }

        do {
            let dir = freshDirectory("empty")
            check(LogRingWriter(directory: dir).recent(limit: 10).isEmpty,
                  "空目录读回空列表（不报错、不崩）")
        }

        // ══════════ 六、真实出口不落测试串 ══════════

        check(DiagnosticLog.defaultDirectory.path.hasSuffix("/ClassroomTranscriber/logs"),
              "全局出口的目录在 App 自有目录下（与 models/、study-notes/ 同级）",
              DiagnosticLog.defaultDirectory.path)
        check(LogRingPolicy.default.totalByteCap == 1024 * 1024,
              "默认上限约 1 MB（256 KB × 4）",
              "\(LogRingPolicy.default.totalByteCap) 字节")

        // 全局出口在无头入口里必须是**丢弃出口**，这条不是修辞：
        // `--diarize-ui-selftest` 会真的走到「说话人识别失败」并记一条日志，
        // 落在真实目录里就是把用户昨晚的真现场挤掉（环形只有 1 MB）。
        //
        // 这条断言是**确定的**（不是「通常成立」）：本自检只在无头入口里跑，
        // 而无头进程里 `HeadlessEntry.isActive` 恒为 true。反过来说，
        // 谁要是把那个判断去掉，这一跑就会往真实目录写一行并当场变红
        DiagnosticLog.error(.app, "这条必须被丢掉")
        check(DiagnosticLog.shared.fileCount == 0 && DiagnosticLog.shared.totalBytes == 0,
              "无头进程里的全局出口是丢弃出口（自检不往用户 logs/ 里写）",
              "fileCount=\(DiagnosticLog.shared.fileCount)")

        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }
}
