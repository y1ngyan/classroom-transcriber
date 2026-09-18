import Foundation

/// COS 上传链路的无头自检，配合 `tools/mock_cos.py` 使用。
///
/// 全程不碰 `UploadStore`——它是 @MainActor 的，而这里主线程要阻塞在
/// semaphore 上等结果，从 detached task 去碰 MainActor 必然死锁
/// （阶段 2 踩过的坑）。队列的持久化单独用 Codable 往返来验。
enum COSSelfTest {

    /// 「传完第 N 片就停下来」的确定性开关。
    ///
    /// 不用轮询：本地 mock 快到 20ms 一次都抓不住中间态，那只测得出时序运气。
    /// 直接在 `onStateChange` 里取消正在跑的任务——`cancel()` 只是置标志位，
    /// 回调返回后循环顶上的 `checkCancellation()` 才抛，不存在重入问题。
    ///
    /// 先记标志再挂任务：万一回调跑得比 `attach` 还早（理论上可能），
    /// `attach` 里会看到标志已置而补一次取消。
    private final class Stopper: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        /// 存取消动作而不是 Task 本身：上传任务的返回类型是 UploadState，
        /// 存 Task 就得让整个类对返回类型泛型化，没必要
        private var cancelAction: (@Sendable () -> Void)?

        func requestStop() {
            lock.lock()
            stopped = true
            let action = cancelAction
            lock.unlock()
            action?()
        }

        func attach(_ action: @escaping @Sendable () -> Void) {
            lock.lock()
            cancelAction = action
            let alreadyStopped = stopped
            lock.unlock()
            if alreadyStopped { action() }
        }
    }

    /// 跨线程传状态的小盒子
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var state: COSService.UploadState?
        private var progressEvents = 0
        private var lastSent: Int64 = 0

        func record(_ newState: COSService.UploadState) {
            lock.lock(); state = newState; lock.unlock()
        }

        func recordProgress(_ sent: Int64) {
            lock.lock(); progressEvents += 1; lastSent = sent; lock.unlock()
        }

        var current: COSService.UploadState? {
            lock.lock(); defer { lock.unlock() }
            return state
        }

        var events: Int {
            lock.lock(); defer { lock.unlock() }
            return progressEvents
        }

        var sent: Int64 {
            lock.lock(); defer { lock.unlock() }
            return lastSent
        }
    }

    static func run() async -> [String] {
        var lines: [String] = []

        guard let sts = AppConfig.cosSTSURL, let endpoint = AppConfig.cosEndpoint else {
            return [
                "❌ 需要设置环境变量 COS_STS_URL 与 COS_ENDPOINT",
                "   例：COS_STS_URL=http://127.0.0.1:8765/sts \\",
                "       COS_ENDPOINT=http://127.0.0.1:8765 \\",
                "       ./build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber --cos-selftest",
            ]
        }
        lines.append("STS 端点: \(sts)")
        lines.append("COS 端点: \(endpoint)")
        lines.append("分片大小: \(ByteText.text(COSService.sliceSize))")

        await resetMock()

        // ── 1. 临时密钥 ─────────────────────────────
        lines.append("")
        lines.append("【1】取临时密钥")
        let credentials: COSCredentials
        do {
            credentials = try await COSService.fetchCredentials()
            lines.append("  ✅ 已签发")
            lines.append("     secretId: \(credentials.secretID.prefix(12))…（长度 \(credentials.secretID.count)）")
            lines.append("     token: \(credentials.sessionToken.isEmpty ? "无" : "有（\(credentials.sessionToken.count) 字符）")")
            if let expiration = credentials.expiration {
                let remain = Int(expiration.timeIntervalSinceNow)
                lines.append("     有效期剩余 \(remain) 秒")
                lines.append("  \(remain > 0 ? "✅" : "❌") 过期时间解析正确")
            } else {
                lines.append("  ⚠️ 响应里没有过期时间字段")
            }
        } catch {
            lines.append("  ❌ \(error.localizedDescription)")
            return lines
        }

        // ── 2. 完整上传 ─────────────────────────────
        lines.append("")
        lines.append("【2】完整上传（3 片）")
        let testSize = COSService.sliceSize * 2 + 1024 * 1024 + 777
        guard let fileURL = makeTestFile(bytes: testSize) else {
            return lines + ["  ❌ 无法创建测试文件"]
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        lines.append("  测试文件 \(ByteText.text(testSize)) → 期望 3 片（2MB + 2MB + \(ByteText.text(testSize - COSService.sliceSize * 2))）")

        let fullKey = "selftest/full-\(UUID().uuidString.prefix(8).lowercased()).bin"
        let fullBox = Box()
        do {
            let state = try await COSService.upload(
                fileURL: fileURL,
                key: fullKey,
                credentials: credentials,
                onStateChange: { fullBox.record($0) },
                onProgress: { sent, _ in fullBox.recordProgress(sent) }
            )
            lines.append("  ✅ 上传完成")
            lines.append("     已传 \(ByteText.text(state.totalBytes))，进度事件 \(fullBox.events) 次")
            lines.append("  \(state.uploadID == nil ? "✅" : "❌") 完成后 uploadId 已清空（不会误续传一个已完成的会话）")

            let session = await mockSession(byKey: fullKey)
            if let session {
                let parts = (session["parts"] as? [String: Any]) ?? [:]
                let sizes = parts.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
                    .compactMap { parts[$0] as? Int }
                lines.append("  \(sizes.count == 3 ? "✅" : "❌") 服务端收到 \(sizes.count) 片：\(sizes.map(ByteText.text).joined(separator: " + "))")
                lines.append("  \(sizes.reduce(0, +) == testSize ? "✅" : "❌") 分片总字节 \(sizes.reduce(0, +)) 与源文件 \(testSize) 一致")
                lines.append("  \((session["completed"] as? Bool) == true ? "✅" : "❌") 服务端已标记合并完成")
            } else {
                lines.append("  ❌ 读不到 mock 的会话信息")
            }
        } catch {
            lines.append("  ❌ \(error.localizedDescription)")
        }

        // ── 3. 暂停 / 续传 ──────────────────────────
        lines.append("")
        lines.append("【3】传完第 1 片后中断，再续传")
        let resumeKey = "selftest/resume-\(UUID().uuidString.prefix(8).lowercased()).bin"
        let resumeBox = Box()
        let stopper = Stopper()

        let firstLeg = Task {
            try await COSService.upload(
                fileURL: fileURL,
                key: resumeKey,
                credentials: credentials,
                onStateChange: { state in
                    resumeBox.record(state)
                    // 第 1 片一落定就请求中断，等价于用户点了「暂停」
                    if state.completedParts.count == 1 { stopper.requestStop() }
                },
                onProgress: { sent, _ in resumeBox.recordProgress(sent) }
            )
        }
        stopper.attach { firstLeg.cancel() }

        let cancelled = await firstLeg.result
        let partsBefore = resumeBox.current?.completedParts.count ?? 0

        switch cancelled {
        case .failure(let error):
            // 必须确认是「被取消」而不是别的失败：任何错误都当成功的话，
            // 一个 404 也能让这一步显示 ✅，续传路径其实根本没验到
            if error is CancellationError {
                lines.append("  ✅ 中断产生 CancellationError")
            } else {
                lines.append("  ❌ 中断时抛的是别的错误，不是取消：\(error.localizedDescription)")
            }
        case .success:
            lines.append("  ⚠️ 任务没被中断就传完了（文件太小？），续传路径没验到")
        }

        guard let saved = resumeBox.current,
              partsBefore == 1,
              let uploadID = saved.uploadID
        else {
            lines.append("  ❌ 没能在第 1 片后捕获状态（拿到 \(partsBefore) 片）")
            return lines
        }
        lines.append("  中断时已完成 \(partsBefore) 片，uploadId \(uploadID.prefix(8))…，已传 \(ByteText.text(saved.uploadedBytes))")

        do {
            let state = try await COSService.upload(
                fileURL: fileURL,
                key: resumeKey,
                state: saved,
                credentials: credentials,
                onStateChange: { resumeBox.record($0) },
                onProgress: { sent, _ in resumeBox.recordProgress(sent) }
            )
            lines.append("  ✅ 续传完成，共 \(ByteText.text(state.totalBytes))")

            let parts = await mockParts(forUploadID: uploadID)
            let partOneCount = parts.filter { ($0["partNumber"] as? Int) == 1 }.count
            if partOneCount == 1 {
                lines.append("  ✅ 第 1 片在服务端只被写过 1 次（续传没有重传已传部分）")
            } else {
                lines.append("  ❌ 第 1 片被写了 \(partOneCount) 次 —— 续传退化成了重传")
            }

            let session = await mockSession(byKey: resumeKey)
            if let session, let sizes = (session["parts"] as? [String: Any]) {
                let total = sizes.values.compactMap { $0 as? Int }.reduce(0, +)
                lines.append("  \(total == testSize ? "✅" : "❌") 续传后分片总字节 \(total) 与源文件 \(testSize) 一致")
                lines.append("  \((session["completed"] as? Bool) == true ? "✅" : "❌") 服务端已标记合并完成")
            }
        } catch {
            lines.append("  ❌ 续传失败: \(error.localizedDescription)")
        }

        // ── 4. 队列持久化 ───────────────────────────
        lines.append("")
        lines.append("【4】上传队列的 JSON 往返")
        lines.append(contentsOf: queueRoundTrip())

        // ── 5. 对象键派生 ───────────────────────────
        lines.append("")
        lines.append("【5】对象键必须是纯 ASCII")
        lines.append(contentsOf: keyDerivation())

        return lines
    }

    // MARK: - 对象键派生

    /// 键里出现一个中文字符，签名串和实际请求串的百分号编码就会分歧，
    /// 而签名是对整个请求串做哈希的——差一个百分号，整条上传全错。
    /// 这里把「从中文文件名派生键」这条路径钉死。
    private static func keyDerivation() -> [String] {
        var lines: [String] = []

        let cases: [(String, String)] = [
            ("录音文件名是中文", "/x/recordings/课堂-20260918-014607.wav"),
            ("扩展名本身是中文", "/x/课堂.录音"),
            ("没有扩展名", "/x/课堂"),
            ("普通英文名", "/x/lecture.wav"),
        ]

        for (name, path) in cases {
            let key = UploadKey.make(for: URL(fileURLWithPath: path))
            let ascii = key.allSatisfy(\.isASCII)
            lines.append("  \(ascii ? "✅" : "❌") \(name)：\(key)")
        }

        // 同一个文件两次派生必须是两个不同的键，否则后一次会覆盖前一次
        let a = UploadKey.make(for: URL(fileURLWithPath: "/x/课堂.wav"))
        let b = UploadKey.make(for: URL(fileURLWithPath: "/x/课堂.wav"))
        lines.append("  \(a != b ? "✅" : "❌") 两次派生不重复（否则会互相覆盖）")

        return lines
    }

    // MARK: - 队列持久化

    /// 队列靠 Codable 落盘，而 `completedParts` 是 `[Int: String]`——
    /// JSON 的键只能是字符串，这个映射能不能原样回来直接决定续传能不能用。
    private static func queueRoundTrip() -> [String] {
        var lines: [String] = []

        let item = UploadItem(
            filePath: "/tmp/课堂-20260918-013500.wav",
            fileName: "课堂-20260918-013500.wav",
            key: "recordings/20260918-013500-ab12cd34.wav",
            totalBytes: 5_242_880,
            uploadedBytes: 4_194_304,
            status: .paused,
            uploadID: "abc123def456",
            completedParts: [1: "\"etag-one\"", 2: "\"etag-two\""],
            message: "已暂停"
        )

        do {
            let data = try JSONEncoder().encode([item])
            let back = try JSONDecoder().decode([UploadItem].self, from: data)

            lines.append("  \(back.count == 1 ? "✅" : "❌") 解码出 \(back.count) 条")
            guard let restored = back.first else { return lines }

            lines.append("  \(restored.uploadID == item.uploadID ? "✅" : "❌") uploadId 往返一致：\(restored.uploadID ?? "nil")")
            lines.append("  \(restored.completedParts == item.completedParts ? "✅" : "❌") 已完成分片往返一致：\(restored.completedParts.keys.sorted())")
            lines.append("  \(abs(restored.progress - 0.8) < 0.0001 ? "✅" : "❌") 进度 \(Int(restored.progress * 100))%")
            lines.append("  \(restored.status == .paused ? "✅" : "❌") 状态：\(restored.status.label)")
            lines.append("  \(restored.key == item.key ? "✅" : "❌") 对象键往返一致")
        } catch {
            lines.append("  ❌ \(error.localizedDescription)")
        }

        return lines
    }

    // MARK: - mock 交互

    private static func mockURL(_ path: String) -> URL? {
        guard let endpoint = AppConfig.cosEndpoint else { return nil }
        return URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }

    private static func resetMock() async {
        guard let url = mockURL("/__reset") else { return }
        _ = try? await URLSession.shared.data(from: url)
    }

    private static func fetchLog() async -> [String: Any]? {
        guard let url = mockURL("/__log"),
              let (data, _) = try? await URLSession.shared.data(from: url)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func mockSession(byKey key: String) async -> [String: Any]? {
        guard let log = await fetchLog(),
              let sessions = log["sessions"] as? [String: Any]
        else { return nil }
        for value in sessions.values {
            if let session = value as? [String: Any], (session["key"] as? String) == key {
                return session
            }
        }
        return nil
    }

    private static func mockParts(forUploadID uploadID: String) async -> [[String: Any]] {
        guard let log = await fetchLog(),
              let parts = log["parts"] as? [[String: Any]]
        else { return [] }
        return parts.filter { ($0["uploadId"] as? String) == uploadID }
    }

    // MARK: - 测试文件

    /// 造一个确定性的伪随机文件。不用全零：全零的话「传上去的是不是原内容」
    /// 就无从判断了
    private static func makeTestFile(bytes: Int) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cos-selftest-\(UUID().uuidString).bin")

        var data = Data(capacity: bytes)
        var seed: UInt32 = 0x9E3779B9
        for _ in 0..<bytes {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            data.append(UInt8(truncatingIfNeeded: seed >> 16))
        }

        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

private enum ByteText {
    static func text(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func text(_ bytes: Int64) -> String { text(Int(bytes)) }
}
