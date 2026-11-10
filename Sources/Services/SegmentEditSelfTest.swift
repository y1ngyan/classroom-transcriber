import Foundation

/// `--selftest` 里的「人工改错」一节（P17）。
///
/// 三条硬要求来自派单：
///   1. 改错 → 持久化 → 重新加载，文本一致；
///   2. `edited == true`；
///   3. 旧 JSON（没有 `edited` 键）解析后 `edited == false`。
///
/// 另外两条是这里补的，它们各自对应一个会静默出错的方向：
///   · 撤销必须把 `edited` 一起退回（只退文本会留下一条「人工修改」角标，
///     而内容其实已经是识别器原话）；
///   · 重转保留只认 `edited == true`、且时间上真重叠的段（见
///     `SegmentEditPreserver`），没改过的段不许被旧文本污染。
///
/// **全程临时目录**：绝不碰用户 `Application Support` 里的真实会话库。
@MainActor
enum SegmentEditSelfTest {

    struct Result {
        let lines: [String]
        let passed: Int
        let failed: Int
    }

    static func run() -> Result {
        var lines: [String] = []
        var passed = 0
        var failed = 0
        func report(_ ok: Bool, _ label: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("   \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  \(detail)")")
        }

        let stamp = Date(timeIntervalSince1970: 1_858_464_000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-edit-selftest-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let audioDir = root.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalSegments = [
            TranscriptSegment(text: "今天讲梯度下降。", isFinal: true,
                              startTimeMillis: 0, endTimeMillis: 3_000,
                              timestamp: stamp, languages: ["zh-CN"]),
            TranscriptSegment(text: "学习率太大会震荡。", isFinal: true,
                              startTimeMillis: 3_000, endTimeMillis: 6_000,
                              timestamp: stamp, languages: ["zh-CN"]),
            TranscriptSegment(text: "太小会收敛得很慢。", isFinal: true,
                              startTimeMillis: 6_000, endTimeMillis: 9_000,
                              timestamp: stamp, languages: ["zh-CN"]),
        ]

        let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: audioDir)
        let session = store.ingest(SessionDraft(
            sessionID: nil,
            recordingFileName: nil,
            startedAt: stamp,
            durationMillis: 9_000,
            segments: originalSegments
        ))
        guard let part = session.parts.first else {
            report(false, "夹具会话建立")
            return Result(lines: lines, passed: passed, failed: failed)
        }

        // ── 1. 改一句 → 落盘 → 换实例重新加载 ──
        let target = originalSegments[1]
        let editedText = "学习率太大会震荡，太小收敛很慢。"
        let wrote = store.updateSegmentText(
            sessionID: session.id, partID: part.id,
            segmentID: target.id, text: editedText
        )
        report(wrote, "人工改错写入", "（目标段 \(target.formattedTimestamp)）")

        let reread = RecordingsStore(directory: sessionsDir, recordingsDirectory: audioDir)
        let reloaded = reread.session(id: session.id)
        let reloadedSegments = reloaded?.parts.first?.segments ?? []
        report(reloadedSegments.count == originalSegments.count,
               "重新加载后段数不变",
               "（实得 \(reloadedSegments.count)）")
        if let back = reloadedSegments.first(where: { $0.id == target.id }) {
            report(back.text == editedText, "改错 → 持久化 → 重新加载文本一致",
                   "（「\(back.text)」）")
            report(back.edited, "人工改过的段 edited == true")
        } else {
            report(false, "重新加载后能找到被改的那一段")
            report(false, "人工改过的段 edited == true")
        }
        let untouched = reloadedSegments.filter { $0.id != target.id }
        report(untouched.count == 2 && untouched.allSatisfy { !$0.edited && $0.text != editedText },
               "其余两段没有被连带标记或改写")

        // ── 2. 旧存档：JSON 里没有 edited 键，必须读成 false ──
        //
        // 整条会话都走一遍（不只解一个 segment）：旧会话在下一次 save
        // 之前都还是这种形状，而它读不出来时用户看到的是「录音从列表消失」
        do {
            let encoded = try JSONEncoder().encode(session)
            let object = try JSONSerialization.jsonObject(with: encoded)
            let legacy = try JSONSerialization.data(withJSONObject: stripEditedKeys(object))
            let decoded = try JSONDecoder().decode(RecordingSession.self, from: legacy)
            let segments = decoded.parts.first?.segments ?? []
            report(segments.count == originalSegments.count, "旧 JSON（无 edited 键）整条会话能解")
            report(segments.allSatisfy { !$0.edited }, "旧 JSON 解析后 edited == false")
            report(segments.first?.text == originalSegments[0].text, "旧 JSON 文本原样保留")
        } catch {
            report(false, "旧 JSON（无 edited 键）能解析", "（\(error.localizedDescription)）")
        }

        // ── 3. 撤销上一步 ──
        report(store.undoLastSegmentEdit(), "撤销上次修改")
        let afterUndo = RecordingsStore(directory: sessionsDir, recordingsDirectory: audioDir)
            .session(id: session.id)?.parts.first?.segments.first { $0.id == target.id }
        report(afterUndo?.text == target.text, "撤销后文本回到改之前")
        report(afterUndo?.edited == false, "撤销后 edited 也回到 false")

        // ── 4. 重转保留：纯函数，直接喂两轮识别结果 ──
        var human = TranscriptSegment(text: "梯度下降（人工改）", isFinal: true,
                                      startTimeMillis: 0, endTimeMillis: 4_800,
                                      timestamp: stamp, languages: ["zh-CN"])
        human.edited = true
        var untouchedOld = TranscriptSegment(text: "没改过", isFinal: true,
                                             startTimeMillis: 5_200, endTimeMillis: 8_000,
                                             timestamp: stamp, languages: ["zh-CN"])
        untouchedOld.edited = false
        let fresh = [
            TranscriptSegment(text: "梯度下降", isFinal: true,
                              startTimeMillis: 200, endTimeMillis: 5_100,
                              timestamp: stamp, languages: ["zh-CN"]),
            TranscriptSegment(text: "另一个说法", isFinal: true,
                              startTimeMillis: 5_200, endTimeMillis: 8_000,
                              timestamp: stamp, languages: ["zh-CN"]),
            TranscriptSegment(text: "最后一句", isFinal: true,
                              startTimeMillis: 12_000, endTimeMillis: 15_000,
                              timestamp: stamp, languages: ["zh-CN"]),
        ]
        let merged = SegmentEditPreserver.merge(new: fresh, old: [human, untouchedOld])
        report(merged.preserved.count == 1, "重转只保留 1 句命中的人工修改",
               "（实得 \(merged.preserved.count)）")
        report(merged.segments[0].text == human.text && merged.segments[0].edited,
               "重叠段用的是人工文本，且标记为 edited")
        report(merged.segments[1].text == "另一个说法" && !merged.segments[1].edited,
               "没改过的旧段不覆盖新识别结果")
        report(merged.segments[2].text == "最后一句", "没有重叠的新段保持原样")

        return Result(lines: lines, passed: passed, failed: failed)
    }

    /// 把 JSON object 里所有 `edited` 键删掉，模拟 P17 之前的存档
    private static func stripEditedKeys(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            dictionary.removeValue(forKey: "edited")
            return dictionary.mapValues(stripEditedKeys)
        }
        if let array = value as? [Any] {
            return array.map(stripEditedKeys)
        }
        return value
    }
}
