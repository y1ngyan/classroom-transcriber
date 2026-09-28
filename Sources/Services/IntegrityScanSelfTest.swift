import AVFoundation
import CryptoKit
import Foundation

/// `--integrity-selftest`：P6-2 两件事的离线自检——
/// ① whisper 段落的 `t1 ≥ t0` 守卫；② 全库脏数据体检。
///
/// **全部离线**：不联网、不花钱、不加载模型、不碰麦克风、**不发声**。
/// 所有读写都落在自己造的临时目录里——**用户真实的 sessions/ 、recordings/、
/// logs/ 一个字节都不碰**。
///
/// 判据验过会红：
/// - 把 `WhisperSegmentTiming.resolve` 里 `raw1 < raw0` 那一支删掉 → 反向段
///   那几条立刻红（见 `~/ClassroomTranscriber-design/P6-2核验记录.md` §五）；
/// - 把体检里「干净会话不出现」的前提破坏（给 clean 会话塞一个反向段）
///   → 零误报那条红。
enum IntegrityScanSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-integrity-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 入口

    static func run() -> SelfTestResult {
        var lines: [String] = ["脏数据自检（离线 · 临时目录 · 不联网、不发音）"]
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
            lines.append("  ❌ 造不出临时目录：\(error.localizedDescription)")
            return SelfTestResult(lines: lines, passed: 0, failed: 1)
        }

        lines.append("")
        lines.append("─── A. whisper 段落时间戳守卫 ───")
        checkWhisperTiming(root: root, check: check)

        lines.append("")
        lines.append("─── B. 全库脏数据体检 ───")
        checkScan(root: root, check: check)

        lines.append("")
        lines.append("总结：\(failed == 0 ? "✅ 全部通过" : "❌ 有失败")（\(passed) 过 / \(failed) 败）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }

    // MARK: - A. whisper 守卫

    private static func checkWhisperTiming(root: URL, check: (Bool, String, String) -> Void) {
        // 干净的一对：原样乘 10
        let clean = WhisperSegmentTiming.resolve(t0: 100, t1: 300)
        check(clean.reason == nil && clean.startMillis == 1_000 && clean.endMillis == 3_000,
              "干净的一对原样乘 10", "\(clean.startMillis)→\(clean.endMillis) reason=\(clean.reason?.rawValue ?? "nil")")

        // 反向：t1 < t0
        let reversed = WhisperSegmentTiming.resolve(t0: 900, t1: 100)
        check(reversed.reason == .reversed, "t1 < t0 判成 reversed", reversed.reason?.rawValue ?? "nil")
        check(reversed.endMillis >= reversed.startMillis,
              "反向的一对**绝不落成反向段**", "\(reversed.startMillis)→\(reversed.endMillis)")
        check(reversed.startMillis == reversed.endMillis && reversed.startMillis == 9_000,
              "反向的落成零长、起点取 t0（与 absoluteRange 的选择一致）",
              "\(reversed.startMillis)")

        // 负数：t0 / t1 任一为负
        let negLow = WhisperSegmentTiming.resolve(t0: -5, t1: 300)
        let negBoth = WhisperSegmentTiming.resolve(t0: -5, t1: -1)
        check(negLow.reason == .negative && negBoth.reason == .negative,
              "任一为负判成 negative", "\(negLow.reason?.rawValue ?? "nil")/\(negBoth.reason?.rawValue ?? "nil")")
        check(negLow.startMillis == 0 && negLow.endMillis == 0,
              "负数夹到 0，不落出负的毫秒", "\(negLow.startMillis)→\(negLow.endMillis)")

        // 零长不是「反向」：t0 == t1 是合法输入
        let zero = WhisperSegmentTiming.resolve(t0: 200, t1: 200)
        check(zero.reason == nil && zero.startMillis == 2_000 && zero.endMillis == 2_000,
              "t0 == t1 是干净的零长，不算脏", "reason=\(zero.reason?.rawValue ?? "nil")")

        // 穷举一小片输入面：脏的**永远**不是反向段
        var dirtCount = 0
        var allNonReversed = true
        for t0 in Int64(-3)...3 {
            for t1 in Int64(-3)...3 {
                let v = WhisperSegmentTiming.resolve(t0: t0, t1: t1)
                if v.isDirty { dirtCount += 1 }
                if v.endMillis < v.startMillis { allNonReversed = false }
            }
        }
        check(allNonReversed, "7×7 输入面上没有一条落成反向段",
              "钉住 \(dirtCount) 条脏的，反向 0 条")

        // ③ 正常片段一个字节都不受影响：一串干净值逐一核对
        let cleanCases: [(Int64, Int64, Int, Int)] = [
            (0, 0, 0, 0), (0, 500, 0, 5_000),
            (1_234, 5_678, 12_340, 56_780),
        ]
        let cleanOK = cleanCases.allSatisfy { t0, t1, s, e in
            let v = WhisperSegmentTiming.resolve(t0: t0, t1: t1)
            return !v.isDirty && v.startMillis == s && v.endMillis == e
        }
        check(cleanOK, "干净片段逐值不受影响（没有「顺手全丢」）",
              "\(cleanCases.count) 组原样通过")

        // 脏的 → 盘上真有一条诊断
        do {
            let dir = root.appendingPathComponent("whisper-log", isDirectory: true)
            let sink = DiagnosticLogSink(directory: dir, minimumLevel: .debug, mirrorToOSLog: false)
            _ = WhisperSegmentTiming.apply(
                t0: 900, t1: 100, segment: 3, audio: "探针.wav · 窗口@0ms",
                textLength: 7, sink: sink
            )
            let written = LogRingWriter(directory: dir).recent(limit: 10)
            let hit = written.first { $0.contains("时间戳非法") }
            check(hit != nil, "脏的一对在盘上留下了诊断", "写到 \(written.count) 条")
            check(hit?.contains("原样t0=900") == true && hit?.contains("原样t1=100") == true,
                  "诊断里带着**原样** t0/t1", hit.map { String($0.suffix(60)) } ?? "无")
            check(hit?.contains("reversed") == true, "诊断里带着原因", "reversed")
            check(hit?.contains("文本长度=7") == true && hit?.contains("探针.wav") == true,
                  "诊断里带音频与文本长度", "（不带正文）")

            // 干净的**一个字都不能写**——否则一次转写几十段，日志会被没坏的那些刷满
            let cleanDir = root.appendingPathComponent("whisper-log-clean", isDirectory: true)
            let cleanSink = DiagnosticLogSink(directory: cleanDir, minimumLevel: .debug, mirrorToOSLog: false)
            for i in 0..<20 {
                _ = WhisperSegmentTiming.apply(
                    t0: Int64(i * 10), t1: Int64(i * 10 + 50), segment: Int32(i),
                    audio: "干净.wav", textLength: 5, sink: cleanSink
                )
            }
            let cleanWritten = LogRingWriter(directory: cleanDir).recent(limit: 100)
            check(cleanWritten.isEmpty, "20 条干净的记录**一条日志都不写**",
                  "写到 \(cleanWritten.count) 条")
        }
    }

    // MARK: - B. 体检

    /// 造一撮会话：2 条干净的 + 5 条各带一类脏（反向 / 零长+空文本 / 音频缺失 /
    /// 空会话 / 半截 wav）+ 1 个孤儿音频
    private static func checkScan(root: URL, check: (Bool, String, String) -> Void) {
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let cleanA = UUID(), cleanB = UUID()
        let dirtyReversed = UUID(), dirtyZero = UUID()
        let dirtyMissing = UUID(), dirtyEmpty = UUID(), dirtyShort = UUID()

        // ── 两条干净的 ──
        writeWav(recordingsDir, "干净A.wav", seconds: 4.0)
        writeWav(recordingsDir, "干净B.wav", seconds: 6.0)
        writeSession(sessionsDir, cleanA, parts: [
            part(fileName: "干净A.wav", durationMillis: 4_000, offsetMillis: 0, segments: [
                seg("这是一句正常的话", 0, 3_000),
                seg("这也是正常的", 3_000, 4_000),
            ]),
        ])
        writeSession(sessionsDir, cleanB, parts: [
            part(fileName: "干净B.wav", durationMillis: 6_000, offsetMillis: 0, segments: [
                seg("这一段的音频在", 0, 5_000),
            ]),
            // 没有音频的片段是**合法**的（recordsAudio 关着），不是脏数据
            RecordingPart(id: UUID(), fileName: nil, startedAt: Date(),
                          durationMillis: 1_000, offsetMillis: 6_000,
                          segments: [seg("这条没有 wav 也正常", 0, 900)]),
        ])

        // ── ① 反向段 ──
        writeWav(recordingsDir, "反向.wav", seconds: 5.0)
        writeSession(sessionsDir, dirtyReversed, parts: [
            part(fileName: "反向.wav", durationMillis: 5_000, offsetMillis: 0, segments: [
                seg("正常的一句", 0, 1_000),
                seg("时间反了的一句", 4_000, 2_000),
            ]),
        ])

        // ── ② 零长段 + ③ 空文本段 ──
        writeWav(recordingsDir, "零长.wav", seconds: 3.0)
        writeSession(sessionsDir, dirtyZero, parts: [
            part(fileName: "零长.wav", durationMillis: 3_000, offsetMillis: 0, segments: [
                seg("起止一样长的一句", 1_500, 1_500),
                seg("   ", 2_000, 2_500),
            ]),
        ])

        // ── ④ 音频缺失 ──
        writeSession(sessionsDir, dirtyMissing, parts: [
            part(fileName: "根本没有这个文件.wav", durationMillis: 2_000, offsetMillis: 0,
                 segments: [seg("文件不在盘上了", 0, 1_000)]),
        ])

        // ── ⑤ 孤儿会话（一个片段都没有）──
        writeSession(sessionsDir, dirtyEmpty, parts: [])

        // ── ⑥ 半截 wav：声明 30 秒，盘上只有 3 秒 ──
        writeWav(recordingsDir, "半截.wav", seconds: 3.0)
        writeSession(sessionsDir, dirtyShort, parts: [
            part(fileName: "半截.wav", durationMillis: 30_000, offsetMillis: 0,
                 segments: [seg("录音被打断了", 0, 2_000)]),
        ])

        // ── 孤儿音频：盘上有，没有任何会话引用 ──
        writeWav(recordingsDir, "没人认领.wav", seconds: 2.0)

        // ── 扫描前后逐文件比对 sha256：**只读**的机器判据 ──
        let before = digests(of: [sessionsDir, recordingsDir])
        let report = IntegrityScan.scan(sessionsDirectory: sessionsDir,
                                       recordingsDirectory: recordingsDir)
        let after = digests(of: [sessionsDir, recordingsDir])

        check(before == after && !before.isEmpty,
              "体检是只读的：扫前扫后每个文件的 sha256 逐个一致",
              "\(before.count) 个文件")

        // ── 每一类都点名了该点的那条会话 ──
        func names(_ kind: IntegrityScan.Kind) -> Set<UUID> {
            Set(report.findings(of: kind).compactMap(\.sessionID))
        }
        check(names(.reversedSegment) == [dirtyReversed],
              "反向段：点名且只点名那一条", "\(names(.reversedSegment))")
        check(names(.zeroLengthSegment) == [dirtyZero],
              "零长段：点名且只点名那一条", "\(names(.zeroLengthSegment))")
        check(names(.emptyTextSegment) == [dirtyZero],
              "空文本段：点名且只点名那一条", "\(names(.emptyTextSegment))")
        check(names(.missingAudio) == [dirtyMissing],
              "音频缺失：点名且只点名那一条", "\(names(.missingAudio))")
        check(names(.emptySession) == [dirtyEmpty],
              "孤儿会话：点名且只点名那一条", "\(names(.emptySession))")
        check(names(.truncatedWav) == [dirtyShort],
              "半截 wav：点名且只点名那一条", "\(names(.truncatedWav))")
        check(report.findings(of: .orphanAudio).map(\.fileName) == ["没人认领.wav"],
              "孤儿音频：点名且只点名那一个",
              "\(report.findings(of: .orphanAudio).map { $0.fileName ?? "?" })")

        // ── 零误报：两条干净的会话，一条都不许被点名 ──
        let named = Set(report.findings.compactMap(\.sessionID))
        check(!named.contains(cleanA) && !named.contains(cleanB),
              "干净会话零误报（误报同样是 bug）",
              "被点名的会话 \(named.count) 条，干净的两条都不在其中")
        // 2 条干净的 + 5 条各带一类脏 = 7；音频 6 个（其中「没人认领.wav」是孤儿）
        check(report.sessionCount == 7 && report.audioFileCount == 6,
              "扫的规模与造的一致",
              "会话 \(report.sessionCount) 条 · 音频 \(report.audioFileCount) 个")

        // ── 点名要具体到「哪一段哪一句」，不是只说「有几条」──
        let reversedDetail = report.findings(of: .reversedSegment).first?.detail ?? ""
        check(reversedDetail.contains("第 1 段") && reversedDetail.contains("第 2 句")
                && reversedDetail.contains("4000→2000"),
              "点名细到片段/句子/原值", reversedDetail)

        // ── 汇总行七类都在（不许有一类静默消失）──
        check(report.summaryLines.count == IntegrityScan.Kind.allCases.count,
              "报告七类逐条列出（没有一类被漏掉）",
              "\(report.summaryLines.count) 行")
    }

    // MARK: - 夹具

    private static func seg(_ text: String, _ start: Int, _ end: Int) -> TranscriptSegment {
        TranscriptSegment(text: text, isFinal: true,
                          startTimeMillis: start, endTimeMillis: end, languages: ["zh-CN"])
    }

    private static func part(
        fileName: String?, durationMillis: Int, offsetMillis: Int, segments: [TranscriptSegment]
    ) -> RecordingPart {
        RecordingPart(id: UUID(), fileName: fileName, startedAt: Date(),
                      durationMillis: durationMillis, offsetMillis: offsetMillis, segments: segments)
    }

    private static func writeSession(_ dir: URL, _ id: UUID, parts: [RecordingPart]) {
        let session = RecordingSession(id: id, startedAt: Date(), updatedAt: Date(), parts: parts)
        // **不能改日期策略**：`RecordingsStore` 用的是 `JSONEncoder()` 的默认值
        // （`deferredToDate`），体检这边也是。夹具若换成 `.iso8601`，写出来的
        // 会话体检根本解不出来——那样测的是夹具，不是体检
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: dir.appendingPathComponent("\(id.uuidString).json"))
    }

    /// 写一个静音的 wav。**不发声**：这里只写文件头和数据块，喇叭一动不动
    private static func writeWav(_ dir: URL, _ name: String, seconds: Double) {
        let url = dir.appendingPathComponent(name)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                         channels: 1, interleaved: false) else { return }
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return }
        let frames = AVAudioFrameCount(seconds * 48_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        try? file.write(from: buffer)
    }

    /// 目录下每个文件的 sha256。**只读**那条判据靠它
    private static func digests(of directories: [URL]) -> [String: String] {
        var out: [String: String] = [:]
        for dir in directories {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            )) ?? []
            for url in files {
                guard let data = try? Data(contentsOf: url) else { continue }
                out[url.path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return out
    }
}
