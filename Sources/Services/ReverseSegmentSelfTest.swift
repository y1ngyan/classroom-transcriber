import Foundation

/// `--reverse-selftest`：**反向转录段**（`endTimeMillis < startTimeMillis`）的回归。
///
/// 为什么要单独一条自检：这个缺陷的形状是「**只读操作把整个进程干掉**」——
/// `--study-notes <会话 json>` 在 C-4 之前对含反向段的会话是 exit 133、
/// 连一个字都不打印（`Range` 的 `..<` 在 Swift 6 里带检查，`lower > upper`
/// 直接 SIGTRAP；release 下 stdout 还没刷）。用户看到的是「点生成笔记，App 没了」，
/// 而现场什么都没有。判据必须**离线、可打印、可复现**，不依赖听也不依赖真机。
///
/// 全部离线：不加载模型、不联网、不碰麦克风、**不发声**。会话夹具在内存里造，
/// 只读扫真实会话那一段是诊断打印（见 `census`），不断言——见那里的理由。
enum ReverseSegmentSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// 真实会话目录（`RecordingsStore.defaultDirectory` 是 private，这里照抄一份路径）。
    /// **只读**：扫出反向段只报数，不动文件
    private static var sessionsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// `@MainActor`：它要调 `RecordingsStore.selfTest()`（那条路径是本包点名的
    /// 三个调用方之一），而 `RecordingsStore` 是 main-actor 隔离的。整条自检
    /// 是同步的纯计算，跑在哪个 actor 上都不影响结果
    @MainActor
    static func run() -> SelfTestResult {
        var lines: [String] = ["反向转录段自检（离线 · 纯函数与内存夹具 · 不碰音频、不联网、不发声）"]
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        // ── 脚手架 ──
        let stamp = Date(timeIntervalSince1970: 1_858_464_000)

        func segment(_ start: Int, _ end: Int, _ text: String = "t") -> TranscriptSegment {
            TranscriptSegment(
                text: text, isFinal: true,
                startTimeMillis: start, endTimeMillis: end,
                timestamp: stamp, languages: ["zh-CN"]
            )
        }

        func span(_ speakerId: String, _ start: Int, _ end: Int) -> SpeakerSpan {
            SpeakerSpan(speakerId: speakerId, startMillis: start, endMillis: end, qualityScore: 0.9)
        }

        func diarization(_ spans: [SpeakerSpan], speakers: Int = 1) -> SpeakerDiarization {
            SpeakerDiarization(
                schemaVersion: 1, helperBuild: "reverse-selftest", ranAt: stamp,
                audioSeconds: 120, speakerCount: speakers, speakerOrder: [],
                segments: spans, partFingerprint: "reverse-selftest"
            )
        }

        func part(
            offset: Int = 0, duration: Int = 60_000, segments: [TranscriptSegment]
        ) -> RecordingPart {
            RecordingPart(
                id: UUID(), fileName: "reverse.wav", startedAt: stamp,
                durationMillis: duration, offsetMillis: offset, segments: segments
            )
        }

        func session(_ parts: [RecordingPart]) -> RecordingSession {
            RecordingSession(
                id: UUID(), startedAt: stamp, updatedAt: stamp, parts: parts,
                title: "反向段夹具", course: "回归"
            )
        }

        // ── 一、底层：三例都不许 trap，且返回值是定义好的 ──
        //
        // 修之前这三条一条都过不了：`absoluteRange` 里那句 `..<` 对第一例
        // 直接 SIGTRAP，进程连这里都到不了（这就是「判据会红」的证明）
        let reversedSegment = segment(51_600, 51_100)
        let zeroSegment = segment(4_000, 4_000)
        let normalSegment = segment(0, 1_800)

        let reversedRange = RecordingSession.absoluteRange(
            of: reversedSegment, in: part(offset: 8_100, segments: [reversedSegment]))
        check(reversedRange.isEmpty && reversedRange.lowerBound == 59_700,
              "底层：反向段不 trap，返回空区间且起点是它声明的那个",
              "\(reversedRange.lowerBound)–\(reversedRange.upperBound)（offset 8100 + start 51600）")

        let zeroRange = RecordingSession.absoluteRange(
            of: zeroSegment, in: part(offset: 8_100, segments: [zeroSegment]))
        check(zeroRange.isEmpty && zeroRange.lowerBound == 12_100,
              "底层：零长段不 trap，同样是空区间",
              "\(zeroRange.lowerBound)–\(zeroRange.upperBound)")

        let normalRange = RecordingSession.absoluteRange(
            of: normalSegment, in: part(offset: 8_100, segments: [normalSegment]))
        check(normalRange == 8_100..<9_900,
              "底层：正常段照旧（offset + 相对时间）",
              "\(normalRange.lowerBound)–\(normalRange.upperBound)")

        // 反向段**不许被归一化**成 `min..<max`。
        //
        // 判据钉的是「起点还是声明的那个 51600，不是 min(51600, 51100)=51100」——
        // 归一化会把起点悄悄改成 51100，于是锚点跳到一个谁都没说过的位置，
        // 而且**不报错**。这正是派单点名的「不许在底层静默改写数据」。
        // 只断言 `isEmpty` 是拦不住归一化的：归一化之后区间非空，照样「不崩」
        check(reversedRange.lowerBound == 8_100 + 51_600,
              "底层：反向段**不归一化**（起点仍是声明的 start，不是 min）",
              "lowerBound \(reversedRange.lowerBound)，归一化会是 \(8_100 + 51_100)")

        // ── 二、判定与普查 ──
        check(RecordingSession.isReversed(reversedSegment) && !RecordingSession.isReversed(zeroSegment)
                && !RecordingSession.isReversed(normalSegment),
              "判定：反向 true / 零长 false / 正常 false")
        check(RecordingSession.isReversed(segment(-5_000, -9_000)),
              "判定：负时间也照同一把尺子（−5000 → −9000 是反向）")
        check(RecordingSession.reversedSegments(in: session([
            part(offset: 0, segments: [normalSegment, reversedSegment, zeroSegment]),
            part(offset: 60_000, segments: [segment(1_000, 2_000), segment(9_000, 4_000)]),
        ])).count == 2,
              "普查：整条会话里反向段数得对（跨片段）")

        // ── 三、极端值扫描：任何一对 (start, end) 都不许把进程干掉 ──
        //
        // 这条是**结构性**判据：它不挑某一组输入，而是把「同一毫秒、反向 1ms、
        // 反向一整个片段、负数、零」都扫一遍。当初那个 trap 正是「某组数值才会
        // 触发」的形态，只测一组正常值永远发现不了
        let extremes: [(Int, Int)] = [
            (0, 0), (1, 0), (0, 1), (51_600, 51_100), (-1, -2), (-2, -1),
            (Int(Int32.max), Int(Int32.min)), (86_400_000, 86_400_000),
            (7, 6), (86_400_000, 0),
        ]
        var allSane = true
        var worst = ""
        for (start, end) in extremes {
            let range = RecordingSession.absoluteRange(of: segment(start, end), in: part(segments: []))
            // 区间必须构造得出来，且下界不大于上界（空区间两者相等）
            if range.lowerBound > range.upperBound {
                allSane = false
                worst = "\(start)→\(end) 给出 \(range.lowerBound)–\(range.upperBound)"
            }
        }
        check(allSane, "扫描：10 组极端 (start,end) 都不 trap 且 lowerBound ≤ upperBound",
              worst.isEmpty ? "10 组全过" : worst)

        // ── 四、调用方 1：SpeakerMapper.assign ──
        //
        // 夹具刻意让 diar 段**完整覆盖**反向段的两个端点：这样「不标」只可能来自
        // 「这一段没有长度」这一条规则，而不是「碰巧没重叠」。如果哪天有人把
        // `absoluteRange` 改成归一化（非空区间），这条立刻变成「标了 S1」→ 变红
        let reversedWithCover = segment(51_600, 51_100)
        let reversedPart = part(
            offset: 0, duration: 120_000,
            segments: [reversedWithCover, segment(0, 2_000), zeroSegment])
        let reversedAssignments = SpeakerMapper.assign(
            transcript: reversedPart.segments,
            part: reversedPart,
            diarization: diarization([span("S1", 0, 120_000)]),
            sessionAudioMillis: 120_000
        )
        check(reversedAssignments[reversedWithCover.id] == .unlabeled,
              "映射：反向段（被 diar 完整覆盖）仍判不标",
              "拿到 \(reversedAssignments[reversedWithCover.id]?.speakerId ?? "nil")")
        check(reversedAssignments[zeroSegment.id] == .unlabeled,
              "映射：零长段判不标",
              "拿到 \(reversedAssignments[zeroSegment.id]?.speakerId ?? "nil")")
        // 同一批里的正常段必须照旧标上——否则「不崩」可能只是因为整批一起放弃了
        check(reversedAssignments[reversedPart.segments[1].id]?.speakerId == "S1",
              "映射：同一批里的正常段照旧标 S1（不是整批放弃）",
              "拿到 \(reversedAssignments[reversedPart.segments[1].id]?.speakerId ?? "nil")")

        // ── 五、调用方 2：StudyNotesService（锚点索引） ──
        //
        // 这条路径原来**只有** `--study-notes <json>` 一个入口，而那条要联网、
        // 要 key。锚点索引是纯函数，这里直接调，判据才落得下来
        let notesParts = [part(
            offset: 0, duration: 120_000,
            segments: [
                segment(51_600, 51_100, "反向的那一段"),
                segment(70_000, 72_000, "正常的一段"),
            ]
        )]
        let slices = StudyNotesService.sliceByWindow(parts: notesParts)
        check(!slices.isEmpty, "笔记：含反向段的会话切得出片（不崩）",
              "\(slices.count) 片")

        let anchorIndex = StudyNotesService.AnchorIndex(parts: notesParts)
        let reversedAnchor = anchorIndex.anchor(for: NotesService.formatTimestamp(51_600))
        check(reversedAnchor?.startMillis == 51_600,
              "笔记：反向段的锚点落在**声明的起点**上（51600，不是 51100）",
              "锚点 \(reversedAnchor.map { String($0.startMillis) } ?? "不存在")")
        let normalAnchor = anchorIndex.anchor(for: NotesService.formatTimestamp(70_000))
        check(normalAnchor?.startMillis == 70_000,
              "笔记：正常段的锚点不受影响", "锚点 \(normalAnchor.map { String($0.startMillis) } ?? "不存在")")

        // ── 六、调用方 3：RecordingsStore（它自己的自检里有反向段用例） ──
        let storeLines = RecordingsStore.selfTest()
        let storeFailures = storeLines.filter { $0.contains("❌") }
        check(storeFailures.isEmpty,
              "会话存储：RecordingsStore 自检全绿（含它新增的反向段用例）",
              storeFailures.isEmpty ? "\(storeLines.count) 行，无 ❌" : storeFailures[0])

        // ── 七、物化路径：反向段要**看得见** ──
        //
        // 底层给反向段定义了行为（当零长，不崩），代价是它不再喊。这一格就是
        // 那个「喊」：反向段混进 `未标注·无有效重叠` 里就再也分不出
        // 「这节课安静」和「这条会话是坏的」
        let materializeSession = session([part(
            offset: 0, duration: 120_000,
            segments: [segment(51_600, 51_100), segment(0, 2_000)]
        )])
        let (materialized, stats) = SpeakerDiarizationService.materialize(
            session: materializeSession,
            diarization: diarization([span("S1", 0, 120_000)])
        )
        check(stats.reversedTranscriptSegments == 1,
              "物化：反向段被单独计数", "\(stats.reversedTranscriptSegments) 条")
        check(materialized.parts[0].segments[0].speakerId == nil,
              "物化：反向段不标（不是全员 S1）",
              "拿到 \(materialized.parts[0].segments[0].speakerId ?? "nil")")
        let statsLine = DiarizationEvaluation(
            session: materialized, diarization: nil, failure: nil, stats: stats
        ).report().joined(separator: "\n")
        check(statsLine.contains("反向转录段 1"),
              "物化：报告里打得出「反向转录段 N」这一格",
              statsLine.split(separator: "\n").last.map(String.init) ?? "")

        // 反向段 0 条时那一格**不许出现**：正常会话的报告行必须一个字节都不变，
        // 否则 C-3-1 已核验的那三行格式就漂了
        let (cleanSession, cleanStats) = SpeakerDiarizationService.materialize(
            session: session([part(offset: 0, duration: 120_000, segments: [segment(0, 2_000)])]),
            diarization: diarization([span("S1", 0, 120_000)])
        )
        let cleanLine = DiarizationEvaluation(
            session: cleanSession, diarization: nil, failure: nil, stats: cleanStats
        ).report().joined(separator: "\n")
        check(cleanStats.reversedTranscriptSegments == 0 && !cleanLine.contains("反向转录段"),
              "物化：反向段 0 条时报告行不多打那一格（C-3-1 的格式没漂）")

        // ── 八、真实会话普查（**只读**，只报数，不断言） ──
        //
        // 为什么不设成判据：这一格读的是**用户自己的录音**。真出现反向段时，
        // 一条会变红的判据拦不住它，只会让这条自检从此长期是红的、然后被无视
        // ——那是「判据没人看」的老路。所以这里报数，断言交给内存夹具。
        // 想让它变成判据的话，正确的做法是先有「解码时挡/修」的策略，见派单 item 4
        lines.append(contentsOf: census())

        lines.append(failed == 0
            ? "✅ 反向段自检通过（\(passed) 条）"
            : "❌ 反向段自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }

    /// 只读扫一遍真实会话目录，报「多少段反向、多少段零长」。读不动就跳过，不报错
    private static func census() -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: sessionsDirectory.path) else {
            return ["     真实会话普查：读不了 \(sessionsDirectory.path)，跳过"]
        }
        var sessions = 0, segments = 0, reversed = 0, zero = 0
        for name in names.sorted() where name.hasSuffix(".json") && name != "index.json" {
            let url = sessionsDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(RecordingSession.self, from: data)
            else { continue }
            sessions += 1
            segments += decoded.segmentCount
            reversed += RecordingSession.reversedSegments(in: decoded).count
            zero += decoded.parts.flatMap(\.segments)
                .filter { $0.endTimeMillis == $0.startTimeMillis }.count
        }
        return [
            "     真实会话普查（只读）：\(sessions) 条会话 · \(segments) 段"
                + " · 反向 \(reversed) 段 · 零长 \(zero) 段",
        ]
    }
}
