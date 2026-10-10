import AVFoundation
import CryptoKit
import Foundation

/// `--retranscribe-store-selftest`：**界面那条路真正调用的那份 store 代码**
/// （`RecordingsStore.performRetranscribe`）的无头判据。
///
/// 为什么必须有这一条：`--retranscribe` 那个入口走的是 `RetranscribeRun`，
/// 而用户点「重新转录」走的是 store——**两条路**。入口跑绿只能说明重转这段
/// 算得对，说明不了「取消之后旧转录还在不在」这句话，而那是本包唯一一处
/// 会**悄悄毁掉用户已看过的内容**的地方（覆盖率、字数那些都是加出来的东西，
/// 坏了看得出来；旧转录被半份新结果盖掉，看不出来）。
///
/// 判据分两组：
///   【一】正常跑完 —— 两段都换成新结果、出处写进存档、状态里出现「已重转」；
///   【二】中途取消 —— **存档文件的 sha256 前后一个字节都不变**。
/// 第二组是重点，也是这个包最该有的那条判据。
///
/// 夹具说明：
///   · 会话存档、录音、模型全部落在**自己造的临时目录**里（store 的
///     `directory` / `recordingsDirectory` 都可以注入，见它的 init）。
///     用户真实的库一个字节都不碰——这条自检**不读也不写**真实库里的任何东西；
///   · 音频用 `say -v Tingting`（macOS 自带）合成一句课堂话，48kHz 单声道
///     16-bit WAV——和 `CLAUDE.md` §9 那条「合成一段干净语音」同一条路子。
///     用它而不是截一段真实录音：真实录音的**开头可能是静音**，转不出东西，
///     那会让「跑完了」这一组变成一条偶发的假红；
///   · 它**不碰麦克风、不发声、不联网**（`say -o` 是写文件，不是放音）。
@MainActor
enum RetranscribeStoreSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// 夹具音频时长。取 22 秒左右（`say` 那句话量出来的）：
    /// large 跑它要三四十秒，**取消才来得及落在第一段的中途**——
    /// 太短的话取消会落在「都跑完了」之后，第二组判据就变成了空转
    static let fixtureText = "同学们，我们这节课讲梯度下降。大家先看这个函数的导数，"
        + "它在每一点上告诉我们函数上升最快的方向。那么问题来了，学习率如果太大，会发生什么？"
        + "我们来看这个例子，如果步子迈得太大，就会直接跨过最低点，甚至越走越远。"

    /// 取消的**触发条件**是进度里第一次出现「（第 N 窗）」——那一行只有窗口回调
    /// 才会写，也就是「引擎已经加载完、第一段真的转出至少一窗了」。第一段有
    /// 二十几秒音频、要好几窗才跑完，所以停在这里必然落在**第一段的中途**：
    /// 这是「取消会不会留下半份」唯一有意义的时刻。
    ///
    /// 这个秒数只是**兜底的保险丝**（模型加载比预期慢很多时才用得上），
    /// 不是触发条件——用时间当触发条件的话，机器快一点慢一点就会落进
    /// 「两段都跑完了」或者「还没开始」，两种都让这条判据变成空转
    static let cancelDeadlineSeconds = 120.0

    static func run() async -> SelfTestResult {
        var lines: [String] = ["课后重转 · store 路径自检（临时库夹具 · 不碰真实库 · 不碰麦克风）"]
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }
        func note(_ text: String) { lines.append("  \(text)") }

        // 模型：这条自检说的就是 large 那条路，缺它就没有可测的东西。
        // **响亮失败，不回落**——和 store 里那条裁决同一个态度
        let engine = RetranscribeEngine.preferred
        let decision = RetranscribeRequirement.resolve(engine: engine)
        guard case .ready(let modelPath, _, _) = decision else {
            if case .blocked(let reason) = decision { lines.append(reason) }
            lines.append("❌ 课后重转 store 自检未通过：模型不可用，这条自检测不了（过 0 / 红 1）")
            return SelfTestResult(lines: lines, passed: 0, failed: 1)
        }
        note("模型：\(modelPath)")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ct-retranscribe-store-\(UUID().uuidString)", isDirectory: true)
        let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        let recordingsDirectory = root.appendingPathComponent("recordings", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        // 闸：夹具目录**不许**和真实库有任何包含关系。这条不是洁癖——
        // 下面会写会话、写录音，指错地方就是往用户的库里灌夹具
        if let rejection = RecordingStorage.libraryContainmentRejection(root) {
            lines.append("❌ 夹具目录落在真实库里（\(rejection)）——拒绝运行")
            lines.append("❌ 课后重转 store 自检未通过（过 0 / 红 1）")
            return SelfTestResult(lines: lines, passed: 0, failed: 1)
        }

        do {
            try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        } catch {
            lines.append("❌ 造夹具目录失败：\(error.localizedDescription)")
            lines.append("❌ 课后重转 store 自检未通过（过 0 / 红 1）")
            return SelfTestResult(lines: lines, passed: 0, failed: 1)
        }

        // 合成夹具音频。`say` 是 macOS 自带的，失败就是失败——不静默跳过，
        // 否则这条自检在跑不了的机器上会变成一片绿
        let audioA = recordingsDirectory.appendingPathComponent("fixture-a.wav")
        let audioB = recordingsDirectory.appendingPathComponent("fixture-b.wav")
        do {
            try synthesizeSpeech(to: audioA)
            try synthesizeSpeech(to: audioB)
        } catch {
            lines.append("❌ 合成夹具音频失败：\(error.localizedDescription)")
            lines.append("❌ 课后重转 store 自检未通过（过 0 / 红 1）")
            return SelfTestResult(lines: lines, passed: 0, failed: 1)
        }
        let fixtureSeconds = (try? AVAudioFile(forReading: audioA).length)
            .map { Double($0) / 48_000 } ?? 0
        note(String(format: "夹具音频：两段各 %.1f 秒（say 合成，48kHz 单声道 16-bit）", fixtureSeconds))

        // ── 【一】正常跑完 ──

        lines.append("")
        lines.append("── 一、正常跑完（两段都换新结果 + 出处写进存档）──")
        let sessionA = makeFixtureSession()
        let fileA = sessionsDirectory.appendingPathComponent("\(sessionA.id.uuidString).json")
        do {
            try JSONEncoder().encode(sessionA).write(to: fileA, options: .atomic)
        } catch {
            lines.append("❌ 写夹具会话失败：\(error.localizedDescription)")
        }

        // 预计时长（派单目标 3 的第一条）。纯函数，跑之前就该有
        let storeA = RecordingsStore(directory: sessionsDirectory, recordingsDirectory: recordingsDirectory)
        let estimate = storeA.retranscribeEstimate(for: sessionA)
        check(estimate.contains("预计约"), "跑之前就报出预计时长", estimate)

        let startedA = ContinuousClock.now
        storeA.retranscribe(sessionID: sessionA.id, engine: engine)
        check(storeA.isRetranscribing, "刚点下去就报「在跑」（模型裁决 + 加载引擎那几秒界面不能是死的）")
        let finishedA = await waitForCompletion(storeA, timeout: 600)
        check(finishedA, "这一轮跑完了（没有卡住）",
              String(format: "%.1f 秒", seconds(since: startedA)))

        let afterA = decode(fileA)
        if let afterA {
            check(afterA.parts.count == 2, "两段都还在")
            let first = afterA.parts[0]
            let second = afterA.parts[1]
            check(!first.segments.isEmpty && !second.segments.isEmpty, "两段都拿到了新转录",
                  "第 1 段 \(first.segments.count) 段 / 第 2 段 \(second.segments.count) 段")
            // 「旧转录被换掉了」——用旧段那句独有的文本当标记，比数段数更硬
            let oldTexts = Set(sessionA.parts.flatMap { $0.segments.map(\.text) })
            let newTexts = Set(afterA.parts.flatMap { $0.segments.map(\.text) })
            check(newTexts.isDisjoint(with: oldTexts), "旧的占位转录已经被换掉",
                  "旧文本「\(oldTexts.first ?? "")」不在新结果里")
            // 出处（目标 4 的界面侧）
            let provenances = afterA.parts.compactMap(\.transcriptionProvenance)
            check(provenances.count == 2, "两段都记上了出处")
            check(provenances.allSatisfy { $0.modelFile == engine.fileName },
                  "出处记的是 \(engine.fileName)")
            check(provenances.allSatisfy { $0.engine == engine }, "出处能反查出档位")
            check(afterA.updatedAt > sessionA.updatedAt, "动了内容就更新 updatedAt")
            check(storeA.statusMessage.hasPrefix("✅"), "状态里报出结果", storeA.statusMessage)
        } else {
            check(false, "重转之后能从夹具库里读回会话")
        }
        // 存档只落在夹具目录里——真实库那一边由 `libraryContainmentRejection`
        // 那道闸保证（上面已经查过），这里再确认文件确实写在夹具里
        check(fileManager.fileExists(atPath: fileA.path),
              "存档写在夹具的 sessions/ 里（不是真实库）", fileA.path)

        // ── 【二】中途取消：存档一个字节都不许变 ──

        lines.append("")
        lines.append("── 二、中途取消（存档 sha256 前后一致 = 不许留下半个转录）──")
        let sessionB = makeFixtureSession()
        let fileB = sessionsDirectory.appendingPathComponent("\(sessionB.id.uuidString).json")
        try? JSONEncoder().encode(sessionB).write(to: fileB, options: .atomic)
        let beforeB = sha256(fileB)

        let storeB = RecordingsStore(directory: sessionsDirectory, recordingsDirectory: recordingsDirectory)
        storeB.retranscribe(sessionID: sessionB.id, engine: engine)
        // 等到「第一段真的转出了至少一窗」再按停。**停在一个转了一半的时刻**
        // 是这条判据的全部意义：太早就变成「还没开始就取消了」那个空转，
        // 太晚（两段都跑完）那时文件本来就该变。所以下面还要检查
        // 「确实停在第一段的中途」——不然这条判据可能在空转中还是一片绿
        var waited = 0.0
        var sawWindow = false
        while storeB.isRetranscribing, waited < cancelDeadlineSeconds {
            if storeB.retranscribeProgress.contains("窗") { sawWindow = true; break }
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        let progressAtCancel = storeB.retranscribeProgress
        check(sawWindow, "取消的时机落在了第一段转了一半的时候（不是空转）", progressAtCancel)
        storeB.cancelRetranscribe()
        check(storeB.retranscribeProgress.contains("取消"),
              "按下取消之后状态立刻变了", storeB.retranscribeProgress)
        let finishedB = await waitForCompletion(storeB, timeout: 600)
        check(finishedB, "取消之后那一轮真的收尾了（没有卡住）")
        note(String(format: "取消发生在 %.1f 秒时，当时进度：%@", waited, progressAtCancel))

        let afterB = sha256(fileB)
        check(afterB == beforeB, "存档 sha256 前后一致（旧转录一个字都没动）",
              "\(beforeB.prefix(12))… → \(afterB.prefix(12))…")
        if let decodedB = decode(fileB) {
            let oldTexts = Set(sessionB.parts.flatMap { $0.segments.map(\.text) })
            let nowTexts = Set(decodedB.parts.flatMap { $0.segments.map(\.text) })
            check(nowTexts == oldTexts, "旧转录原样还在",
                  "\(decodedB.parts.reduce(0) { $0 + $1.segments.count }) 段")
            check(decodedB.parts.allSatisfy { $0.transcriptionProvenance == nil },
                  "被取消的那一段**没有**记上出处（记了就等于说它是 large 转的）")
            check(decodedB.updatedAt == sessionB.updatedAt, "没有内容变化就不更新 updatedAt")
        } else {
            check(false, "取消之后能从夹具库里读回会话")
        }
        check(!storeB.isRetranscribing, "取消之后「正在重转」的标记已经清掉")
        check(storeB.statusMessage.contains("取消") || storeB.statusMessage.contains("保留"),
              "状态里说清了这次是被取消的", storeB.statusMessage)

        lines.append("")
        lines.append(failed == 0
            ? "✅ 课后重转 store 自检通过（\(passed) 条）"
            : "❌ 课后重转 store 自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }

    // MARK: - 夹具

    /// 两段，各带一句「旧的占位转录」——取消/失败那两条判据拿它当标记：
    /// 只要它还在，就说明那一份没被半成品盖掉
    private static func makeFixtureSession() -> RecordingSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func part(_ fileName: String, offset: Int) -> RecordingPart {
            RecordingPart(
                id: UUID(), fileName: fileName, startedAt: start, durationMillis: 23_000,
                offsetMillis: offset,
                segments: [
                    TranscriptSegment(
                        text: "旧的占位转录", isFinal: true,
                        startTimeMillis: 0, endTimeMillis: 1_000, languages: ["zh-CN"]
                    )
                ]
            )
        }
        return RecordingSession(
            id: UUID(), startedAt: start, updatedAt: start,
            parts: [part("fixture-a.wav", offset: 0), part("fixture-b.wav", offset: 23_000)],
            title: "自检夹具", course: "自检"
        )
    }

    /// `say -o` 写一个 48kHz 单声道 16-bit 的 WAV。**不是放音**：`-o` 是写文件，
    /// 一个字也传不到扬声器上（「不许自造声」那条针对的是麦克风验证，
    /// 这里是文件夹具，路子同 `CLAUDE.md` §9 那条合成语音）
    private static func synthesizeSpeech(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Tingting", "-o", url.path,
                             "--data-format=LEI16@48000", fixtureText]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw FixtureError.say(message ?? "say 退出码 \(process.terminationStatus)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.say("say 报成功但没写出文件")
        }
    }

    private enum FixtureError: LocalizedError {
        case say(String)
        var errorDescription: String? {
            switch self {
            case .say(let message): return "合成夹具音频失败：\(message)"
            }
        }
    }

    // MARK: - 小工具

    /// 等这一轮重转收尾。**用一个上限而不是无限等**：卡住的话这条自检要红，
    /// 而不是把无头进程挂在 semaphore 上等一节课
    private static func waitForCompletion(_ store: RecordingsStore, timeout: Double) async -> Bool {
        var waited = 0.0
        while store.isRetranscribing {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
            if waited > timeout { return false }
        }
        return true
    }

    private static func decode(_ url: URL) -> RecordingSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingSession.self, from: data)
    }

    private static func sha256(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "（读不出来）" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
