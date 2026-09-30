import CoreAudio
import CryptoKit
import Foundation

/// 采集设备（P0-1）的无头自检。**离线、不开麦、不发声、不起 GUI、零花费。**
///
/// 「这一节课用的是哪个麦」这件事，真验法只有一种：上课时录一段。而那个
/// 反馈周期（一节课）不是一个能用的验证方式。所以这里把整条链拆成三段
/// **纯函数/纯值类型**，各自用构造出来的输入钉住：
///
///   1. `InputDeviceResolution`  —— 「该记哪一只」（注入一张假设备表）
///   2. `InputDeviceTracker`     —— 「中途换了没有」（喂一串脚本化的设备序列）
///   3. `RecordingPart/Session`  —— 「写进去、读回来」（临时目录，含旧格式）
///
/// **唯一没被覆盖的就是「真设备的名字读得对不对」**——那一条由 `--audio-devices`
/// 对着真机报，以及用户上课录一段来确认。这一条写在交付说明里，不假装验过。
///
/// 硬闸：全程只写 `NSTemporaryDirectory()` 下的自建目录，**一次都不碰**
/// `Application Support/ClassroomTranscriber/`。
enum MicDeviceSelfTest {

    struct Result {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    // MARK: - 夹具

    private static let builtinMic = InputDeviceInfo(
        name: "MacBook Neo麦克风", uid: "BuiltInMicrophoneDevice", channels: 1, sampleRate: 48000
    )
    private static let externalMic = InputDeviceInfo(
        name: "外置麦克风", uid: "BuiltInHeadphoneInputDevice", channels: 1, sampleRate: 48000
    )

    /// 假设备表。**两个 ID 都必须和真机上的不一样**——用真 ID 的话，
    /// 注入和不注入会长得一样，判据就分不出自己测的是哪一条路了
    private static let fakeEngineID: AudioDeviceID = 9001
    private static let fakeDefaultID: AudioDeviceID = 9002

    private static func fakeTable(_ id: AudioDeviceID) -> InputDeviceInfo? {
        switch id {
        case fakeEngineID: return externalMic
        case fakeDefaultID: return builtinMic
        default: return nil
        }
    }

    // MARK: - 入口

    @MainActor
    static func run(legacySessionPath: String?) -> Result {
        var lines: [String] = []
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        lines.append("采集设备 · 无头自检（离线 · 不开麦 · 不发声 · 不起 GUI）")
        lines.append("")

        // ── 一、「该记哪一只」 ──

        lines.append("【一】该记哪一只（InputDeviceResolution，注入假设备表）")

        let engineWins = InputDeviceResolution.resolveFromCatalog(
            engineDeviceID: fakeEngineID,
            engineInfo: fakeTable,
            defaultInfo: fakeTable,
            systemDefaultID: { fakeDefaultID }
        )
        check(engineWins?.info == externalMic, "引擎报的能在表里找到 → 记引擎那一只",
              engineWins?.info.name ?? "nil")
        check(engineWins?.source == .engine, "来源记成 engine",
              engineWins?.source.rawValue ?? "nil")

        // 这条是**变异 ② 的靶子**：把「先看引擎报的」改成「直接看系统默认」，
        // 结果会变成内建麦、source 变成 default，上面两条立刻变红。
        // 光断言「不是 nil」是抓不住的——引擎的和默认的那两只都读得出来
        check(engineWins?.info.uid != builtinMic.uid,
              "**引擎报的与系统默认不是同一只时，取的是引擎的**（变异②靶子）",
              "引擎 \(externalMic.name) / 默认 \(builtinMic.name)")

        // 引擎报的是 CoreAudio 自己造的那只默认聚合容器。
        //
        // **它读得出来名字、也查得到声道数**，所以「在设备表里找得到」这一条
        // 拦不住它——而它的 uid 里带着进程 pid，进程一退就没了，写进存档等于
        // 写了个事后对不上的名字。这条判据是 2026-09-30 实测逼出来的：
        // 光构造一个 AVAudioEngine 就会造出它，而引擎报的正是它
        let aggregate = InputDeviceInfo(
            name: "CADefaultDeviceAggregate-68686-0",
            uid: "CADefaultDeviceAggregate-68686-0", channels: 1, sampleRate: 48000
        )
        let viaAggregate = InputDeviceResolution.resolveFromCatalog(
            engineDeviceID: fakeEngineID,
            engineInfo: { _ in aggregate },
            defaultInfo: fakeTable,
            systemDefaultID: { fakeDefaultID }
        )
        check(viaAggregate?.info == builtinMic,
              "引擎报的是 CoreAudio 默认聚合容器 → **不记它**，回落系统默认",
              viaAggregate?.info.name ?? "nil")
        check(viaAggregate?.source == .systemDefault, "这一种也要记成 default（不是 engine）",
              viaAggregate?.source.rawValue ?? "nil")
        check(aggregate.isCoreAudioDefaultAggregate, "聚合容器的判别（uid 前缀）认得出来")
        check(!externalMic.isCoreAudioDefaultAggregate,
              "**用户自己建的聚合/普通设备不被误伤**（这条是上一条的边界）")

        // 引擎报了一个指不上设备的 ID（0，或已经被拔掉的那只）
        let placeholder = InputDeviceResolution.resolveFromCatalog(
            engineDeviceID: 121,
            engineInfo: fakeTable,
            defaultInfo: fakeTable,
            systemDefaultID: { fakeDefaultID }
        )
        check(placeholder?.info == builtinMic, "引擎报的查不到（占位值）→ 回落系统默认",
              placeholder?.info.name ?? "nil")
        check(placeholder?.source == .systemDefault, "来源记成 default（不是 engine）",
              placeholder?.source.rawValue ?? "nil")
        check(placeholder?.engineDeviceID == 121, "引擎报的那个 ID 原样留在存档里（可对账）",
              "\(placeholder?.engineDeviceID ?? 0)")

        let nothing = InputDeviceResolution.resolveFromCatalog(
            engineDeviceID: 0,
            engineInfo: { _ in nil },
            defaultInfo: { _ in nil },
            systemDefaultID: { 0 }
        )
        check(nothing == nil, "两边都读不到 → nil（**不编一个默认设备顶上**）")
        lines.append("")

        // ── 二、中途换了没有 ──

        lines.append("【二】中途换了没有（InputDeviceTracker）")

        var tracker = InputDeviceTracker()
        tracker.start(with: externalMic)
        check(tracker.changes.isEmpty, "开录时定下第一只，**不算一次「变化」**")

        check(tracker.observe(externalMic, atMillis: 1000) == nil, "同一只 → nil")
        check(tracker.changes.isEmpty, "同一只不产生记录")

        let first = tracker.observe(builtinMic, atMillis: 4200)
        check(tracker.changes.count == 1, "换了一只 → 一条记录", "\(tracker.changes.count)")
        check(first?.from == externalMic && first?.to == builtinMic, "记的是「从谁到谁」")
        // 派单书 ② 要求的那句话
        check(first?.summary == "设备已变：外置麦克风 → MacBook Neo麦克风，发生在第 4 秒",
              "summary 是派单书要的那句话", first?.summary ?? "nil")

        // **只记一条就够了吗**：换回来必须是第二条，否则「前半段 A、后半段 B、
        // 又插回来」的课会被记成「全程 A」
        tracker.observe(externalMic, atMillis: 9100)
        check(tracker.changes.count == 2, "换回来 → **第二条**（不是覆盖第一条）",
              "\(tracker.changes.count)")

        // 外置麦被拔掉且系统没回落：读到的是「无」。当成「没变」就会静默丢掉现场
        tracker.observe(nil, atMillis: 12000)
        check(tracker.changes.count == 3, "变成「读不到」也算一次变化", "\(tracker.changes.count)")
        check(tracker.changes.last?.to == nil, "那一条的「到」是 nil，不是编出来的设备")
        let stillNil = tracker.observe(nil, atMillis: 13000)
        check(stillNil == nil, "连续两次都读不到 → 只记第一条（不刷屏）")

        var fresh = InputDeviceTracker()
        fresh.start(with: nil)
        check(fresh.observe(nil, atMillis: 500) == nil, "全程读不到设备 → 一条记录都没有")
        lines.append("")

        // ── 三、写进去、读回来 ──

        lines.append("【三】写进去、读回来（临时目录，不碰真实库）")

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mic-device-selftest-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 真实库的围栏：自检自己的临时目录**不许**落在真实库里面
        check(RecordingStorage.libraryContainmentRejection(sessionsDir) != nil
                || !RecordingStorage.directory.path.hasPrefix(root.path),
              "自检的工作目录不在真实库里", root.path)

        let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)

        var capture = RecordingCapture(
            device: externalMic, source: "engine", gain: "x3", backend: "whisper", changes: []
        )
        capture.changes = [InputDeviceChange(atMillis: 4200, from: externalMic, to: builtinMic)]

        let draft = SessionDraft(
            sessionID: nil,
            recordingFileName: "p01-fixture.wav",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            durationMillis: 60_000,
            segments: [],
            capture: capture
        )
        let session = store.ingest(draft)
        check(session.parts.count == 1, "会话落了盘")

        // **断言落在磁盘上的字节里**，不是断言内存里那个对象。
        // 只查内存的话，「写的时候没带上这个字段」这种缺陷一个字都抓不到
        let sessionURL = sessionsDir.appendingPathComponent("\(session.id.uuidString).json")
        let raw = (try? Data(contentsOf: sessionURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(raw.contains(externalMic.name), "会话 JSON 字节里有设备名", externalMic.name)
        check(raw.contains(externalMic.uid), "会话 JSON 字节里有 UID", externalMic.uid)
        check(raw.contains("\"capture\""), "会话 JSON 字节里有 capture 键")
        check(raw.contains("4200"), "会话 JSON 字节里有中途换设备那条的毫秒数")

        let decoder = JSONDecoder()
        // **直接从磁盘解码**，不走 store 的内存缓存：缓存里那份是刚写下去的对象，
        // 拿它比对等于拿内存验内存。「写进文件了没有」只有从文件读才算数
        let fromDisk = (try? Data(contentsOf: sessionURL))
            .flatMap { try? decoder.decode(RecordingSession.self, from: $0) }
        check(fromDisk?.parts.first?.capture == capture, "从磁盘读回来和写下去的**逐字段相等**")
        check(fromDisk?.parts.first?.capture?.changes.count == 1, "换设备那一跳也读得回来")
        let summary = fromDisk?.parts.first?.captureSummary ?? ""
        check(summary.contains("设备已变"), "存档摘要里那句换设备的话拼得出来", summary)

        // ── 旧格式：磁盘上已有的会话 JSON 里没有 capture 这个键 ──
        //
        // 这条是**最要紧的一条**：合成解码遇到缺键会抛 keyNotFound，
        // 而那个异常会让**整条会话读不出来**——用户看到的是「我录的这节课没了」，
        // 不是「设备字段是空的」
        let legacyID = UUID()
        let legacyJSON = """
        {
          "id": "\(legacyID.uuidString)",
          "startedAt": 776000000,
          "updatedAt": 776000100,
          "parts": [
            {
              "id": "\(UUID().uuidString)",
              "fileName": "legacy.wav",
              "startedAt": 776000000,
              "durationMillis": 30000,
              "offsetMillis": 0,
              "segments": []
            }
          ],
          "title": "旧存档",
          "course": ""
        }
        """
        let legacySession = try? decoder.decode(RecordingSession.self, from: Data(legacyJSON.utf8))
        check(legacySession != nil, "**旧格式会话（无 capture 键）读得出来**，不是整条消失")
        check(legacySession?.parts.count == 1, "旧格式的片段还在")
        check(legacySession?.parts.first?.capture == nil,
              "缺键 → capture 是 nil（**不是编一个默认设备**）")
        check(legacySession?.parts.first?.captureSummary.contains("未记录") == true,
              "界面上给的是「未记录」这句实话", legacySession?.parts.first?.captureSummary ?? "")

        // 旧草稿同理：崩溃现场只出现一次，读不出来就等于没写
        let legacyDraftJSON = """
        {
          "id": "\(UUID().uuidString)",
          "startedAt": 776000000,
          "durationMillis": 8000,
          "segments": [],
          "savedAt": 776000010,
          "version": 1
        }
        """
        let legacyDraft = try? decoder.decode(RecordingDraft.self, from: Data(legacyDraftJSON.utf8))
        check(legacyDraft != nil, "**旧格式草稿（无 capture 键）读得出来**")
        check(legacyDraft?.capture == nil, "旧草稿的 capture 取到 nil 默认值")
        check(legacyDraft?.asSessionDraft.capture == nil, "扶正成会话时 capture 一路带过去（这里是 nil）")

        // 新草稿带 capture 往返
        let newDraft = RecordingDraft(
            id: UUID(), targetSessionID: session.id, recordingFileName: "d.wav",
            startedAt: Date(timeIntervalSince1970: 1_800_000_100), durationMillis: 9000,
            segments: [], savedAt: Date(), capture: capture
        )
        let draftData = try? JSONEncoder().encode(newDraft)
        let draftBack = draftData.flatMap { try? decoder.decode(RecordingDraft.self, from: $0) }
        check(draftBack?.capture == capture, "新草稿的 capture 编码/解码往返一致")
        check(draftBack?.asSessionDraft.capture == capture, "新草稿扶正后 capture 不丢")
        lines.append("")

        // ── 四、电平判据的算法 ──

        lines.append("【四】峰值 / 底噪 / 动态范围 / 削顶（构造波形）")

        let rate = 48000.0

        // 已知幅度的正弦：峰值应当正好是 20·log10(0.5) = -6.02 dBFS。
        // 用**算得出来**的输入验，而不是拿一段真录音说「看着差不多」
        let sine = (0..<48000).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / rate)) }
        let sineReading = MicLevelMetrics.analyze(samples: sine, sampleRate: rate)
        check(abs(sineReading.peakDBFS - (-6.02)) < 0.05, "0.5 幅度正弦 → 峰值 -6.02 dBFS",
              String(format: "%.2f", sineReading.peakDBFS))
        check(sineReading.clippedSamples == 0, "没到 0.999 → 削顶计数 0")

        // 全零：0 映射到 -120 而不是 -inf，否则表里对齐不了
        let silence = [Float](repeating: 0, count: 48000)
        let silenceReading = MicLevelMetrics.analyze(samples: silence, sampleRate: rate)
        check(silenceReading.peakDBFS == -120, "全零 → 峰值 -120 dBFS（不是 -inf）",
              String(format: "%.1f", silenceReading.peakDBFS))
        check(silenceReading.clippedSamples == 0, "全零不是削顶")
        check(silenceReading.windows.first?.quality == .noSpeech, "全零窗口判成「几乎没人说话」")

        // 削顶方波：**连续**满幅。只看总计数分不出「零星碰顶」和「整段糊成方波」，
        // 所以要连 longestClipRun 一起钉
        let square = (0..<48000).map { $0 % 2 == 0 ? Float(1.0) : Float(-1.0) }
        let squareReading = MicLevelMetrics.analyze(samples: square, sampleRate: rate)
        check(squareReading.clippedSamples == square.count,
              "满幅方波 → 每一个样本都算削顶", "\(squareReading.clippedSamples)/\(square.count)")
        check(squareReading.longestClipRun == square.count,
              "最长连续削顶 = 全长（这就是「糊成方波」的指纹）", "\(squareReading.longestClipRun)")

        // 边界：0.998 不该算削顶，0.999 该算。阈值写错一位这两种就会串
        let justUnder = [Float](repeating: 0.998, count: 1000)
        let justOver = [Float](repeating: 0.999, count: 1000)
        check(MicLevelMetrics.analyze(samples: justUnder, sampleRate: rate).clippedSamples == 0,
              "0.998 → 不算削顶（阈值是 0.999，不是 0.99）")
        check(MicLevelMetrics.analyze(samples: justOver, sampleRate: rate).clippedSamples == 1000,
              "0.999 → 算削顶（**闭区间**：≥ 而不是 >）")

        // 窗口数：3 秒音频切 3 行。切窗按帧不按样本，整段和逐窗才用同一批帧
        let threeSeconds = [Float](repeating: 0.1, count: Int(rate) * 3)
        let windowed = MicLevelMetrics.analyze(samples: threeSeconds, sampleRate: rate)
        check(windowed.windows.count == 3, "3 秒 → 3 行窗口表", "\(windowed.windows.count)")
        check(windowed.windows.first?.start == 0, "第一行从 0 秒开始")

        // 底噪读数的口径：一段「安静 + 一段响」的拼接，底噪必须落在安静那一段上，
        // 而不是被响的那一段拉高。这是 p5 分位数的全部意义
        var mixed = [Float](repeating: 0.001, count: Int(rate) * 2)
        mixed.append(contentsOf: [Float](repeating: 0.5, count: Int(rate) * 2))
        let mixedReading = MicLevelMetrics.analyze(samples: mixed, sampleRate: rate)
        check(mixedReading.noiseFloorDBFS < -50,
              "一半安静一半响 → 底噪仍取到安静那半（p5，不是平均）",
              String(format: "%.1f dBFS", mixedReading.noiseFloorDBFS))
        check(mixedReading.peakDBFS > -7, "同一条的峰值取到响的那半",
              String(format: "%.1f dBFS", mixedReading.peakDBFS))
        lines.append("")

        // ── 五、真存档的只读副本（可选） ──

        if let legacySessionPath {
            lines.append("【五】真存档的只读副本（--legacy-session）")
            let url = URL(fileURLWithPath: (legacySessionPath as NSString).expandingTildeInPath)
            let before = sha256(fileAt: url)
            if let data = try? Data(contentsOf: url),
               let real = try? decoder.decode(RecordingSession.self, from: data) {
                check(true, "真实旧存档读得出来", url.lastPathComponent)
                check(real.parts.allSatisfy { $0.capture == nil },
                      "它全部片段的 capture 取到 nil 默认值（旧存档没有这个键）",
                      "\(real.parts.count) 段")
                check(real.segmentCount >= 0, "段数读得出来", "\(real.segmentCount)")
            } else {
                check(false, "真实旧存档读不出来", url.path)
            }
            let after = sha256(fileAt: url)
            check(before != nil && before == after, "**跑完 sha256 一个字节没变**（读路径不写回）",
                  "\(before?.prefix(12) ?? "nil")")
        } else {
            lines.append("【五】真存档的只读副本：跳过（没给 --legacy-session）")
        }

        return Result(lines: lines, passed: passed, failed: failed)
    }

    // MARK: - 小工具

    static func sha256(fileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
