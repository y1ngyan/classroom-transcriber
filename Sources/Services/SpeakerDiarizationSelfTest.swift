import Foundation

// MARK: - 离线自检（`--diarize-selftest`）

/// 说话人识别的离线自检。**独立成文件**是因为它比实现本身还长：
/// 5 条校验各自要有一条会红的注入，加上真进程（桩 helper）的退出码/信号/超时路径。
///
/// **离线**：不联网、不加载模型、不碰麦克风、**不发声**。所有 helper 都是临时目录里的
/// 桩脚本，读写都在临时目录。判据全部是**可打印的量**——铁律：不许依赖「听」。
extension SpeakerDiarizationService {

    struct SelfTestResult {
        var lines: [String] = []
        var passed = 0
        var failed = 0
    }

    // MARK: 脚手架

    /// 写一个桩 helper。
    ///
    /// 用**真的 shell 脚本 + 真的 `Process`**，不是把 runner 打桩：这一层要验的恰恰是
    /// 「退出码怎么归类」「信号怎么归类」「看门狗开不开枪」——把 `Process` 换掉，
    /// 这些就全成了自说自话。脚本本身没有依赖，也不需要模型
    private static func writeStub(
        at url: URL,
        envelope: String? = nil,
        exitCode: Int32 = 0,
        sleepSeconds: Double = 0,
        killSelf: Bool = false,
        dumpArgvTo: URL? = nil
    ) throws {
        var lines = ["#!/bin/sh"]
        if sleepSeconds > 0 { lines.append("exec sleep \(Int(sleepSeconds))") }
        if killSelf { lines.append("exec kill -9 $$") }
        if let dumpArgvTo {
            lines.append("printf '%s\\n' \"$@\" > '\(dumpArgvTo.path)'")
        }
        lines.append("out=\"\"")
        lines.append("prev=\"\"")
        lines.append("for a in \"$@\"; do")
        lines.append("  if [ \"$prev\" = \"--output\" ]; then out=\"$a\"; fi")
        lines.append("  prev=\"$a\"")
        lines.append("done")
        if let envelope {
            lines.append("if [ -n \"$out\" ]; then")
            lines.append("  cat > \"$out\" <<'CTEOF'")
            lines.append(envelope)
            lines.append("CTEOF")
            lines.append("fi")
        }
        lines.append("exit \(exitCode)")
        try lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// 手工拼信封。**不引 helper 的 `Envelope` 类型**：App 侧解的是
    /// `DiarizationEnvelope`，这里要能手写出**它解不开的**信封（坏 schema、缺 result），
    /// 用能编码的类型去构造，恰好构造不出那些畸形样本
    private static func envelopeJSON(
        audioSeconds: Double,
        speakerCount: Int,
        segments: [(id: String, start: Int, end: Int, quality: Double)],
        schemaVersion: Int = 1,
        status: String = "ok",
        includeResult: Bool = true
    ) -> String {
        let encodedSegments = segments.map { segment -> String in
            "{\"speakerId\":\"\(segment.id)\",\"startMillis\":\(segment.start),"
                + "\"endMillis\":\(segment.end),\"qualityScore\":\(segment.quality)}"
        }.joined(separator: ",")
        let result = "{\"audioSeconds\":\(audioSeconds),\"speakerCount\":\(speakerCount),"
            + "\"segments\":[\(encodedSegments)]}"
        let resultPart = includeResult ? ",\"result\":\(result)" : ""
        return "{\"schemaVersion\":\(schemaVersion),\"status\":\"\(status)\","
            + "\"helperBuild\":\"stub\",\"mode\":\"offline\"\(resultPart)}"
    }

    // MARK: 夹具

    private static func segment(_ start: Int, _ end: Int, id: UUID = UUID()) -> TranscriptSegment {
        TranscriptSegment(
            id: id, text: "t", isFinal: true,
            startTimeMillis: start, endTimeMillis: end,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000), languages: ["zh-CN"])
    }

    private static func part(
        fileName: String? = "课堂-selftest.wav",
        offset: Int = 0,
        duration: Int,
        segments: [TranscriptSegment]
    ) -> RecordingPart {
        RecordingPart(
            id: UUID(), fileName: fileName,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            durationMillis: duration, offsetMillis: offset, segments: segments)
    }

    private static func session(_ parts: [RecordingPart]) -> RecordingSession {
        RecordingSession(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            parts: parts)
    }

    /// 主夹具：120 秒、4 个转录段，恰好覆盖「已标注 / 无多数派 / 无有效重叠」三桶
    ///
    /// ```
    /// t1 [0,10000)      S1 全覆盖                        → 标注 S1，ratio 1.0
    /// t2 [10000,20000)  S1/S2 各 5000ms（等重叠）        → 标注 S1（三级决胜③），mixed
    /// t3 [20000,30000)  S1 4500 / S2 3500 → ratio 0.45   → 不标（无多数派），mixed
    /// t4 [30000,40000)  没有任何 diar 段                 → 不标（无有效重叠）
    /// ```
    private static func mainFixture() -> (RecordingSession, String) {
        let s = session([part(duration: 120_000, segments: [
            segment(0, 10_000), segment(10_000, 20_000),
            segment(20_000, 30_000), segment(30_000, 40_000),
        ])])
        let envelope = envelopeJSON(
            audioSeconds: 120, speakerCount: 2,
            segments: [
                ("S1", 0, 10_000, 0.9),
                ("S1", 10_000, 15_000, 0.8),
                ("S2", 15_000, 20_000, 0.8),
                ("S1", 20_000, 24_500, 0.7),
                ("S2", 24_500, 28_000, 0.7),
            ])
        return (s, envelope)
    }

    // MARK: 自检本体

    static func selfTest() async -> SelfTestResult {
        var r = SelfTestResult()
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { r.passed += 1; r.lines.append("  ✅ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
            else { r.failed += 1; r.lines.append("  ❌ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ct-diarize-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            check(false, "准备临时目录", "\(error.localizedDescription)")
            return r
        }

        /// 跑一个桩：把信封写进临时文件 → 真 `Process` 跑 → 交给 `evaluate`。
        /// 走的是**生产同一条路**（`DiarizeHelperRunner`），没有第二套调用方式
        func runStub(
            session: RecordingSession,
            envelope: String? = nil,
            exitCode: Int32 = 0,
            sleepSeconds: Double = 0,
            killSelf: Bool = false,
            timeout: Double = 30,
            timeoutOverride: Double? = nil,
            dumpArgvTo: URL? = nil,
            executable: URL? = nil
        ) async -> DiarizationEvaluation {
            let stub = executable ?? root.appendingPathComponent("stub-\(UUID().uuidString)")
            if executable == nil {
                do {
                    try writeStub(at: stub, envelope: envelope, exitCode: exitCode,
                                  sleepSeconds: sleepSeconds, killSelf: killSelf,
                                  dumpArgvTo: dumpArgvTo)
                } catch {
                    return evaluate(session: session, run: DiarizeHelperRun(
                        termination: nil, envelopeData: nil, stderrTail: "", wallSeconds: 0,
                        timedOut: false, launchError: "桩写不出来：\(error.localizedDescription)"))
                }
            }
            let report = await diarize(
                session: session, helper: stub, modelsDirectory: root,
                timeoutOverrideSeconds: timeoutOverride ?? timeout)
            return report.evaluation
        }

        // ═══════════ ① 正常路径：标注率、分桶、编号 ═══════════

        let (mainSession, mainEnvelope) = mainFixture()
        let happy = await runStub(session: mainSession, envelope: mainEnvelope)
        check(happy.isOK, "正常路径：5 条校验全过", happy.failure.map { "\($0.reason.rawValue)" } ?? "ok")
        check(happy.diarization != nil, "正常路径：产出 SpeakerDiarization")
        check(happy.stats.transcriptSegments == 4,
              "正常路径：转录段数=4", "\(happy.stats.transcriptSegments)")
        check(happy.stats.labeled == 2, "正常路径：已标注 2 段", "\(happy.stats.labeled)")
        check(happy.stats.unlabeledNoMajority == 1,
              "正常路径：无多数派 1 段（t3 ratio 0.45 → 不标）", "\(happy.stats.unlabeledNoMajority)")
        check(happy.stats.unlabeledNoOverlap == 1,
              "正常路径：无有效重叠 1 段（t4 没有任何 diar 段）", "\(happy.stats.unlabeledNoOverlap)")
        check(happy.stats.mixed == 2, "正常路径：含多人 2 段", "\(happy.stats.mixed)")
        check(abs(happy.stats.annotationRate - 0.5) < 1e-9,
              "正常路径：标注率 50%", "\(happy.stats.annotationRate)")
        check(happy.stats.speakerCount == 2, "正常路径：说话人 2 人", "\(happy.stats.speakerCount)")
        check(happy.stats.spanCount == 5, "正常路径：diar 段 5 个", "\(happy.stats.spanCount)")

        // 物化到段上的三个字段
        let materialized = happy.session.parts[0].segments
        check(materialized[0].speakerId == "S1", "物化：t1 标成 S1", materialized[0].speakerId ?? "nil")
        check(materialized[0].speakerOverlapRatio == 1.0,
              "物化：t1 覆盖率 1.0", "\(materialized[0].speakerOverlapRatio ?? -1)")
        check(materialized[0].speakerMixed == false, "物化：t1 不是多人")
        check(materialized[1].speakerId == "S1",
              "物化：t2 等重叠时按三级决胜取 S1", materialized[1].speakerId ?? "nil")
        check(materialized[1].speakerMixed == true, "物化：t2 标了归属且含多人")
        check(materialized[2].speakerId == nil,
              "低置信不显示：t3 赢家只占 45%（<0.5）→ 不标", materialized[2].speakerId ?? "nil")
        check(materialized[2].speakerOverlapRatio == nil,
              "低置信不显示：没标时覆盖率必须是 nil，不是 0（0 是合法读数）",
              "\(materialized[2].speakerOverlapRatio.map { "\($0)" } ?? "nil")")
        check(materialized[2].speakerMixed == true,
              "低置信不显示：没标也要保留「这段有两人」这个事实")
        check(materialized[3].speakerId == nil, "物化：t4 没覆盖 → 不标")

        // 报告行本身也要看一眼：`report()` 是给人读的那一份，而它**没有任何别的判据**。
        // 2026-09-27 真实端到端第一次跑，打出来的是「音频 %.1f 秒」——参数没传进去，
        // 而上面所有断言看的都是 `stats` 的字段，谁也没看渲染出来的那一行。
        //
        // 判据是「没展开的**格式符**」，不是「有没有 `%`」：报告里本来就有合法的
        // 百分号（「已标注 2（50.0%）」），按裸 `%` 判会把它一起打红——那种判据
        // 红了也说不清是谁的错。格式符的形状是 `%` 紧跟字母或 `.`，百分号后面
        // 跟的是全角括号或行尾，两者分得开
        func hasUnexpandedFormatSpecifier(_ text: String) -> Bool {
            let chars = Array(text)
            for (index, character) in chars.enumerated() where character == "%" {
                guard index + 1 < chars.count else { continue }
                let next = chars[index + 1]
                if next.isLetter || next == "." { return true }
            }
            return false
        }
        let reportText = happy.report().joined(separator: "\n")
        check(!hasUnexpandedFormatSpecifier(reportText),
              "报告：渲染出来的行里没有没展开的格式符（`%.1f` 原样打出来过）",
              reportText.split(separator: "\n")
                .first { hasUnexpandedFormatSpecifier(String($0)) }.map { String($0) } ?? "干净")

        // 原始 label 存在 diarization 里，说话人编号只在物化时归一
        check(happy.diarization?.speakerOrder == ["S1", "S2"],
              "编号：speakerOrder 记的是首次出现顺序",
              "\(happy.diarization?.speakerOrder ?? [])")

        // ═══════════ ② 编号从 S1 起（原始 label 乱序时）═══════════

        // 原始 label 是 S7（先开口）/ S3（后开口）：归一是按**首次出现**重编，
        // 不是按原始编号排序。用 helper 的原始编号的话，这里第一段会标成 S7
        let numbering = session([part(duration: 30_000, segments: [
            segment(0, 10_000), segment(10_000, 20_000),
        ])])
        let renumbered = await runStub(
            session: numbering,
            envelope: envelopeJSON(audioSeconds: 30, speakerCount: 2, segments: [
                ("S7", 0, 10_000, 0.9), ("S3", 10_000, 20_000, 0.9),
            ]))
        check(renumbered.session.parts[0].segments[0].speakerId == "S1",
              "编号：课内编号从 S1 起（原始 S7 先开口 → S1）",
              renumbered.session.parts[0].segments[0].speakerId ?? "nil")
        check(renumbered.session.parts[0].segments[1].speakerId == "S2",
              "编号：第二个开口的人 → S2（原始是 S3）",
              renumbered.session.parts[0].segments[1].speakerId ?? "nil")
        check(renumbered.diarization?.speakerOrder == ["S7", "S3"],
              "编号：speakerOrder 保留原始 label，物化时才换",
              "\(renumbered.diarization?.speakerOrder ?? [])")

        // ═══════════ ③ speakerCount == 1 是阳性结果，不是失败 ═══════════

        let single = session([part(duration: 60_000, segments: [segment(0, 5_000)])])
        let singleEval = await runStub(
            session: single,
            envelope: envelopeJSON(audioSeconds: 60, speakerCount: 1,
                                   segments: [("S5", 0, 5_000, 0.95)]))
        check(singleEval.isOK, "单人：speakerCount == 1 校验照样全过（阳性结果）",
              singleEval.failure?.reason.rawValue ?? "ok")
        check(singleEval.session.parts[0].segments[0].speakerId == "S1",
              "单人：标成 S1", singleEval.session.parts[0].segments[0].speakerId ?? "nil")
        check(singleEval.diarization?.speakerCount == 1, "单人：speakerCount 记 1")

        // 0 个说话人 + 没有够长的转录段 = 近静音，**正常结果**（C-1 裁决 2）
        let nearSilence = session([part(duration: 60_000, segments: [segment(0, 400)])])
        let silenceEval = await runStub(
            session: nearSilence,
            envelope: envelopeJSON(audioSeconds: 60, speakerCount: 0, segments: []))
        check(silenceEval.isOK, "近静音：0 个说话人且没有 ≥1 秒的转录段 → 正常结果，不是失败",
              silenceEval.failure?.reason.rawValue ?? "ok")
        check(silenceEval.stats.labeled == 0, "近静音：一个标签都没有")
        check(silenceEval.stats.speakerCount == 0, "近静音：说话人数 0")

        // ═══════════ ④ 5 条校验各自的失败注入 ═══════════

        var failureInjections: [(String, DiarizationEvaluation, DiarizationFailureReason)] = []

        func record(_ title: String, _ evaluation: DiarizationEvaluation,
                    _ expected: DiarizationFailureReason) {
            check(evaluation.failure?.reason == expected, title,
                  evaluation.failure.map { "\($0.reason.rawValue) · \($0.detail)" } ?? "居然成功了")
            failureInjections.append((title, evaluation, expected))
        }

        // 第 1 条：进程必须干净退出
        record("校验1·注入：退出码 7 → 推理失败",
               await runStub(session: mainSession, exitCode: 7), .inferenceFailed)
        record("校验1·注入：被 SIGKILL → 崩溃",
               await runStub(session: mainSession, killSelf: true), .crashed)
        record("校验1·注入：退出码 1（不在分类里）→ 崩溃",
               await runStub(session: mainSession, exitCode: 1), .crashed)

        // 第 2 条：信封
        record("校验2·注入：退出码 0 但没有输出文件 → 信封不合法",
               await runStub(session: mainSession), .envelopeInvalid)
        // 这几条注入**必须只在目标那条校验上翻车**，别的一律要能满足——
        // 否则「把某一条校验拿掉，判据会不会变红」这件事就证明不了：
        // 一条挑不出毛病的信封，只可能是被那**一条**校验拦下的
        let innocentEnvelope = envelopeJSON(
            audioSeconds: 120, speakerCount: 2,
            segments: [("S1", 0, 60_000, 0.9), ("S2", 60_000, 120_000, 0.9)])

        record("校验2·注入：schemaVersion 2 → 信封不合法",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(
                                audioSeconds: 120, speakerCount: 2,
                                segments: [("S1", 0, 60_000, 0.9), ("S2", 60_000, 120_000, 0.9)],
                                schemaVersion: 2)),
               .envelopeInvalid)
        record("校验2·注入：status 不是 ok → 信封不合法",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(
                                audioSeconds: 120, speakerCount: 2,
                                segments: [("S1", 0, 60_000, 0.9), ("S2", 60_000, 120_000, 0.9)],
                                status: "error")),
               .envelopeInvalid)
        record("校验2·注入：没有 result 键 → 信封不合法",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(audioSeconds: 120, speakerCount: 2,
                                                    segments: [("S1", 0, 60_000, 0.9),
                                                               ("S2", 60_000, 120_000, 0.9)],
                                                    includeResult: false)),
               .envelopeInvalid)
        record("校验2·注入：speakerCount 与 segments 里的说话人数对不上 → 信封不合法",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(audioSeconds: 120, speakerCount: 3,
                                                    segments: [("S1", 0, 60_000, 0.9),
                                                               ("S2", 60_000, 120_000, 0.9)])),
               .envelopeInvalid)

        // 第 3 条：音频时长。段只占 10 秒、只报 1 个人，5 条里**只有时长那条**
        // 挑得出毛病
        record("校验3·注入：helper 报 999 秒（会话 120 秒）→ 时长对不上",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(audioSeconds: 999, speakerCount: 1,
                                                    segments: [("S1", 0, 10_000, 0.9)])),
               .audioSecondsMismatch)

        // 对照：把上面那些「只差一个毛病」的信封原样喂进去必须变绿。
        // 没有这一条，上面那些红可能是别的原因造成的
        let innocent = await runStub(session: mainSession, envelope: innocentEnvelope)
        check(innocent.isOK, "对照：无瑕信封 → 通过（证明上面的红是被那条校验拦的）",
              innocent.failure?.reason.rawValue ?? "ok")

        // 第 4 条：段边界
        record("校验4·注入：零长 diar 段（end == start）→ 越界",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(audioSeconds: 120, speakerCount: 1,
                                                    segments: [("S1", 5_000, 5_000, 0.9)])),
               .segmentOutOfRange)
        record("校验4·注入：段尾超出音频总长 → 越界",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(audioSeconds: 120, speakerCount: 1,
                                                    segments: [("S1", 0, 500_000, 0.9)])),
               .segmentOutOfRange)
        record("校验4·注入：负数起点 → 越界",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(audioSeconds: 120, speakerCount: 1,
                                                    segments: [("S1", -100, 5_000, 0.9)])),
               .segmentOutOfRange)

        // 第 5 条：前后矛盾
        record("校验5·注入：有 ≥1 秒的转录段却报 0 个说话人 → 前后矛盾",
               await runStub(session: mainSession,
                             envelope: envelopeJSON(audioSeconds: 120, speakerCount: 0,
                                                    segments: [])),
               .speakerCountContradiction)

        // ═══════════ ⑤ 失败不许伪装成「全员 S1」═══════════

        // 这条是**不变量**，扫过上面每一条失败注入：任何一条失败路径上，
        // 一个说话人标签都不许出现。只断言「返回了失败」是不够的——
        // 失败的同时顺手贴一个 S1，界面上看起来就是「识别成功了」
        var disguised: [String] = []
        for (title, evaluation, _) in failureInjections {
            if evaluation.diarization != nil { disguised.append("\(title)：居然有 diarization") }
            for part in evaluation.session.parts {
                for segment in part.segments where segment.speakerId != nil {
                    disguised.append("\(title)：段上出现了 \(segment.speakerId ?? "")")
                }
            }
        }
        check(disguised.isEmpty,
              "不变量：\(failureInjections.count) 条失败路径没有一条留下说话人标签（不是全员 S1）",
              disguised.isEmpty ? "\(failureInjections.count) 条全扫过" : disguised.joined(separator: " / "))

        // 失败时也**不许**留下半分「覆盖率」——三个字段是一组，清就一起清
        let staleRatio = failureInjections.contains { _, evaluation, _ in
            evaluation.session.parts.contains { $0.segments.contains { $0.speakerOverlapRatio != nil } }
        }
        check(!staleRatio, "不变量：失败路径上 speakerOverlapRatio 也一起清空")

        // 反过来也要成立：把「失败注入」关掉（同一份输入、只是退出码换成 0），
        // 结果必须变绿。**没有这一条，上面那些红可能是别的原因造成的**
        let controlEnvelope = envelopeJSON(
            audioSeconds: 120, speakerCount: 2,
            segments: [("S1", 0, 10_000, 0.9), ("S2", 10_000, 20_000, 0.9)])
        let control = await runStub(session: mainSession, envelope: controlEnvelope)
        check(control.isOK, "对照：同样的会话，桩吐一个合法信封 → 立刻变绿",
              control.failure?.reason.rawValue ?? "ok")

        // ═══════════ ⑥ 超时 / 找不到 helper / 退出码分布 ═══════════

        let timedOut = await runStub(session: mainSession, sleepSeconds: 30, timeoutOverride: 1)
        check(timedOut.failure?.reason == .timeout, "超时：看门狗到点终止 → timeout",
              timedOut.failure?.reason.rawValue ?? "居然成功了")
        check(timedOut.session.parts.allSatisfy { $0.segments.allSatisfy { $0.speakerId == nil } },
              "超时：不许伪装成全员 S1")

        let missing = await runStub(
            session: mainSession,
            executable: root.appendingPathComponent("不存在-\(UUID().uuidString)"))
        check(missing.failure?.reason == .helperMissing, "找不到 helper → helperMissing",
              missing.failure?.reason.rawValue ?? "居然成功了")

        // 退出码 → 原因 的映射逐条走一遍（helper 的分类码在设计稿 §2.5）
        for (code, reason) in [(Int32(2), DiarizationFailureReason.badInvocation),
                               (3, .audioUnreadable), (4, .audioUnsupported),
                               (5, .modelMissing), (6, .modelLoadFailed),
                               (8, .outputWriteFailed), (9, .timeout)] {
            let evaluation = await runStub(session: mainSession, exitCode: code)
            check(evaluation.failure?.reason == reason,
                  "退出码 \(code) → \(reason.rawValue)",
                  evaluation.failure?.reason.rawValue ?? "居然成功了")
        }
        check(DiarizationFailureReason(helperExitCode: 99) == .crashed,
              "没见过的退出码归「崩溃」，不归到某个已知失败上")

        // 超时公式（纯函数，与 helper 侧同一份）
        check(DiarizeTimeoutPolicy.timeoutSeconds(audioSeconds: 0) == 300,
              "超时公式：短音频取下限 300 秒",
              "\(DiarizeTimeoutPolicy.timeoutSeconds(audioSeconds: 0))")
        check(DiarizeTimeoutPolicy.timeoutSeconds(audioSeconds: 3600) == 810,
              "超时公式：3600 秒音频 → 90 + 720 = 810 秒",
              "\(DiarizeTimeoutPolicy.timeoutSeconds(audioSeconds: 3600))")

        // ═══════════ ⑦ 退化输入不崩 ═══════════

        let emptySession = session([])
        let emptyEval = await runStub(session: emptySession, envelope: mainEnvelope)
        check(emptyEval.failure?.reason == .noAudio,
              "退化·空会话（0 个片段）→ noAudio，不是崩溃",
              emptyEval.failure?.reason.rawValue ?? "居然成功了")

        let noArchive = session([part(fileName: nil, duration: 60_000, segments: [segment(0, 5_000)])])
        let noArchiveEval = await runStub(session: noArchive, envelope: mainEnvelope)
        check(noArchiveEval.failure?.reason == .noAudio,
              "退化·片段没开录音存档 → noAudio（拍板第 1 条要求一次吃整节课，缺一段就喂不进去）",
              noArchiveEval.failure?.reason.rawValue ?? "居然成功了")

        // 零长转录段：映射那边要除 (b−a)，这里不拦住就是除零
        let zeroLength = session([part(duration: 60_000, segments: [segment(500, 500)])])
        let zeroLengthEval = await runStub(
            session: zeroLength,
            envelope: envelopeJSON(audioSeconds: 60, speakerCount: 1,
                                   segments: [("S1", 0, 5_000, 0.9)]))
        check(zeroLengthEval.isOK, "退化·零长转录段不崩",
              zeroLengthEval.failure?.reason.rawValue ?? "ok")
        check(zeroLengthEval.session.parts[0].segments[0].speakerId == nil,
              "退化·零长转录段不标（不是除零，也不是乱标）")

        // 极短会话：0 秒的片段 + 空 segments。`audioSeconds` 容差是 max(2s, 1%)
        let tiny = session([part(duration: 0, segments: [])])
        let tinyEval = await runStub(
            session: tiny, envelope: envelopeJSON(audioSeconds: 0, speakerCount: 0, segments: []))
        check(tinyEval.isOK, "退化·0 秒会话不崩（容差下限 2 秒兜住）",
              tinyEval.failure?.reason.rawValue ?? "ok")
        check(tinyEval.stats.transcriptSegments == 0, "退化·0 秒会话：转录段 0 个")

        // 没带任何 segments 的片段 + 逆序时间（start > end）
        let reversed = session([part(duration: 60_000, segments: [segment(9_000, 1_000)])])
        let reversedEval = await runStub(
            session: reversed,
            envelope: envelopeJSON(audioSeconds: 60, speakerCount: 1,
                                   segments: [("S1", 0, 5_000, 0.9)]))
        check(reversedEval.isOK, "退化·逆序时间（start > end）不崩",
              reversedEval.failure?.reason.rawValue ?? "ok")
        check(reversedEval.session.parts[0].segments[0].speakerId == nil,
              "退化·逆序时间不标（`b ≤ a` 直接不标）")

        // ═══════════ ⑧ 整节课一次喂进去（拍板第 1 条）═══════════

        let multiPart = session([
            part(fileName: "课堂-第一段.wav", offset: 0, duration: 60_000,
                 segments: [segment(0, 5_000)]),
            part(fileName: "课堂-第二段.wav", offset: 60_000, duration: 60_000,
                 segments: [segment(0, 5_000)]),
        ])
        let argvFile = root.appendingPathComponent("argv-\(UUID().uuidString).txt")
        let multiEval = await runStub(
            session: multiPart,
            envelope: envelopeJSON(audioSeconds: 120, speakerCount: 1,
                                   segments: [("S1", 0, 120_000, 0.9)]),
            dumpArgvTo: argvFile)
        check(multiEval.isOK, "多片段：整节课一次调用成功",
              multiEval.failure?.reason.rawValue ?? "ok")

        // 真进程真的收到了两个 --input + 两个 --offset-ms（看桩自己 dump 出来的 argv）：
        // 断言「拼字符串的函数对了」不等于「子进程收到了」——中间还隔着 runner
        let dumpedArgv = ((try? Data(contentsOf: argvFile))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "")
            .split(separator: "\n").map(String.init)
        check(dumpedArgv.filter { $0 == "--input" }.count == 2,
              "多片段：子进程收到 2 个 --input（整节课一次喂）",
              "\(dumpedArgv.filter { $0 == "--input" }.count) 个")
        check(dumpedArgv.filter { $0 == "--offset-ms" }.count == 2,
              "多片段：子进程收到 2 个 --offset-ms")
        check(dumpedArgv.contains("60000"),
              "多片段：第二个片段的 offset 是 60000（会话时间轴，不是顺序拼接）")
        check(dumpedArgv.contains("--no-network"),
              "多片段：生产恒带 --no-network（helper 因此绝不会自己去下模型）")
        check(dumpedArgv.contains("--models-dir") && dumpedArgv.contains(root.path),
              "多片段：--models-dir 指向 App 传入的目录，不是硬编码的 spike 路径")
        check(multiEval.session.parts[0].segments[0].speakerId == "S1"
                && multiEval.session.parts[1].segments[0].speakerId == "S1",
              "多片段：节课内编号一致（两段都是 S1，不是各标各的）")

        // ═══════════ ⑨ 模型就位（首跑搬运）═══════════

        let provisionRoot = root.appendingPathComponent("models-\(UUID().uuidString)")
        let provisionDestination = provisionRoot.appendingPathComponent("models/speaker-diarization")
        let provisionLegacy = provisionRoot.appendingPathComponent("legacy/speaker-diarization")
        try? fm.createDirectory(at: provisionLegacy, withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 4096)
            .write(to: provisionLegacy.appendingPathComponent("Segmentation.mlmodelc"))

        let moved = SpeakerModelStore.provision(
            destination: provisionDestination, legacySource: provisionLegacy)
        if case .moved(let bytes, let seconds) = moved {
            check(bytes > 0, "模型就位：从 FluidAudio 旧位置搬过来，报了实际体积",
                  "\(bytes) 字节 · \(String(format: "%.3f", seconds)) 秒")
        } else {
            check(false, "模型就位：首跑应从旧位置搬过来", "\(moved)")
        }
        check(fm.fileExists(atPath: provisionDestination
                .appendingPathComponent("Segmentation.mlmodelc").path),
              "模型就位：目标位置真的有了那个文件")
        check(!fm.fileExists(atPath: provisionLegacy.path),
              "模型就位：搬移是移动（旧位置不留下第二份，不会让 App 和别的工具各用各的）")

        let second = SpeakerModelStore.provision(
            destination: provisionDestination, legacySource: provisionLegacy)
        check(second == .inPlace, "模型就位：第二跑什么都不做（稳态不碰用户的模型目录）",
              "\(second)")

        let nothing = SpeakerModelStore.provision(
            destination: provisionRoot.appendingPathComponent("empty/speaker-diarization"),
            legacySource: provisionRoot.appendingPathComponent("nope/speaker-diarization"))
        if case .unavailable(let reason) = nothing {
            check(reason.contains("download"),
                  "模型就位：没得搬时响亮失败，并说清怎么补（不许静默去用别处的模型）", reason)
        } else {
            check(false, "模型就位：没得搬时应报 unavailable", "\(nothing)")
        }

        // ═══════════ ⑩ helper 在 app bundle 里（构建产物级判据）═══════════

        // 这一条其实在验 build.sh：helper 没被放进 Contents/MacOS/ 的话，
        // 真机上点「识别说话人」只会得到一句「找不到 helper」
        if let located = DiarizeHelperLocator.locate() {
            check(true, "helper 定位：在 app bundle 里找到了", located.path)
            let size = ((try? fm.attributesOfItem(atPath: located.path))?[.size] as? NSNumber)?.intValue ?? 0
            check(size > 1_000_000, "helper 定位：二进制是真货（>1MB）", "\(size) 字节")
        } else {
            check(false, "helper 定位：app bundle 里没有 diarize-helper（build.sh 没放进去？）")
        }

        return r
    }
}
