import Foundation
import Observation

/// 历史会话（录音 + 转录）的持久化和列表数据源。
///
/// **存储选型：一会话一文件 + 一个轻量 index.json，不用单 JSON。**
/// 会话只增不减（一学期几百条），而一条会话的 segments 可能有几百段、
/// 几百 KB。单 JSON 意味着每次落盘都全量重写、每次启动都全量解码，
/// 越用越慢且一次写坏全灭。按文件拆开后：保存只写被动过的那一条，
/// 列表只读 index.json 里的摘要，正文按需解码。
///
/// 目录布局（Application Support/ClassroomTranscriber/sessions/）：
///   index.json      —— [SessionSummary]，列表数据源
///   <uuid>.json     —— 一条 RecordingSession 的正文
@MainActor
@Observable
final class RecordingsStore {

    /// 列表数据源，新的在前。视图绑定它，不用碰会话正文
    private(set) var summaries: [SessionSummary] = []
    private(set) var statusMessage = ""

    /// 解码过的会话正文缓存。详情页反复进出不该每次读盘；
    /// 会话条数有限，全缓存也占不了多少内存，不做 LRU
    private var cache: [UUID: RecordingSession] = [:]

    private let directory: URL
    /// wav 所在目录（删除音频时用）。可注入是为了自检不碰真实存档
    private let recordingsDirectory: URL

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    init(
        directory: URL? = nil,
        recordingsDirectory: URL = RecordingStorage.directory
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.recordingsDirectory = recordingsDirectory
        loadIndex()
    }

    // MARK: - 读取

    /// 按需求取一条会话的完整正文。列表用 summaries，详情才走这里
    func session(id: UUID) -> RecordingSession? {
        if let cached = cache[id] { return cached }
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RecordingSession.self, from: data)
        else { return nil }
        cache[id] = decoded
        return decoded
    }

    // MARK: - 写入

    /// 接收引擎的录音快照：新会话就建，「接着录」就追加片段。
    ///
    /// 返回会话 id ——引擎要拿它记在身上，下一次 stop 才知道自己
    /// 属于哪条会话
    @discardableResult
    func ingest(_ draft: SessionDraft) -> RecordingSession {
        var session: RecordingSession
        if let id = draft.sessionID, let existing = self.session(id: id) {
            session = existing
        } else {
            // draft 带了 sessionID 但会话找不到（被删了/拷来的草稿），
            // 按新会话建——数据落盘比「忠于引用」重要，丢了就找不回来
            session = RecordingSession(
                id: UUID(), startedAt: draft.startedAt, updatedAt: draft.startedAt, parts: []
            )
        }

        let offset = session.parts.last.map { $0.offsetMillis + $0.durationMillis } ?? 0
        let part = RecordingPart(
            id: UUID(),
            fileName: draft.recordingFileName,
            startedAt: draft.startedAt,
            durationMillis: draft.durationMillis,
            offsetMillis: offset,
            segments: draft.segments
        )
        session.parts.append(part)
        session.updatedAt = Date()

        save(session)
        return session
    }

    /// 保存/更新一条会话：写正文文件 + 同步 index 里的摘要
    func save(_ session: RecordingSession) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: fileURL(for: session.id), options: .atomic)
        } catch {
            statusMessage = "❌ 会话保存失败: \(error.localizedDescription)"
            return
        }

        cache[session.id] = session
        let summary = SessionSummary(session: session)
        if let index = summaries.firstIndex(where: { $0.id == session.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort { $0.startedAt > $1.startedAt }
        persistIndex()
    }

    // MARK: - 删除

    /// 删除会话记录，**保留 wav**。
    ///
    /// 为什么默认留音频：wav 是原始素材，误删不可恢复；转录记录是从素材
    /// 派生的，真删错了还能拿 --transcribe-file 重转一份。删东西的时候，
    /// 「可恢复的那个先走」是默认答案
    func delete(id: UUID) {
        cache.removeValue(forKey: id)
        summaries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        persistIndex()
    }

    /// 删除会话记录**并删掉对应的 wav 文件**。
    ///
    /// 拆成独立方法而不是 delete 的一个参数：调用点必须把这行字完整
    /// 打出来，不存在「顺手传了个 true」的余地。只有确定音频也是垃圾
    /// （录废的、隐私内容）时才该调它
    func deleteWithAudio(id: UUID) {
        // 先拿正文再删：片段的文件名只在会话里，删了会话就找不到 wav 了
        let fileNames = session(id: id)?.parts.compactMap(\.fileName) ?? []
        for name in fileNames {
            try? FileManager.default.removeItem(
                at: recordingsDirectory.appendingPathComponent(name)
            )
        }
        delete(id: id)
    }

    // MARK: - 索引

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persistIndex() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summaries).write(to: indexURL, options: .atomic)
        } catch {
            statusMessage = "❌ 会话索引保存失败: \(error.localizedDescription)"
        }
    }

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([SessionSummary].self, from: data) {
            summaries = decoded.sorted { $0.startedAt > $1.startedAt }
            return
        }
        // index 不在/坏了：扫会话文件重建。摘要是派生数据，
        // 正文才是事实，重建代价是每次事故一次性的全量解码
        rebuildIndex()
    }

    private func rebuildIndex() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        var rebuilt: [SessionSummary] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "index.json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(RecordingSession.self, from: data)
            else { continue }
            rebuilt.append(SessionSummary(session: session))
        }
        summaries = rebuilt.sorted { $0.startedAt > $1.startedAt }
        if !rebuilt.isEmpty { persistIndex() }
    }

    // MARK: - 自检

    /// `--session-selftest`：Codable 往返、追加的时间轴、删除语义。
    /// 全程在临时目录里跑，不碰真实的 sessions/ 和 recordings/
    static func selfTest() -> [String] {
        var lines: [String] = ["会话持久化自检（临时目录，不碰真实数据）"]
        var allPassed = true

        func report(_ ok: Bool, _ name: String, _ detail: String = "") {
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-selftest-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = scratch.appendingPathComponent("sessions", isDirectory: true)
        let recordingsDir = scratch.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // ── 1. Codable 往返：字段逐个过，尤其 UUID / Date(带小数秒) / 枚举 ──
        let stamp = Date(timeIntervalSince1970: 1_858_464_000.123) // 2028-11-22, 带毫秒
        let segmentsA = [
            TranscriptSegment(
                text: "今天我们讲梯度下降。", isFinal: true,
                startTimeMillis: 0, endTimeMillis: 2600,
                timestamp: stamp, languages: ["zh-CN"]
            ),
            TranscriptSegment(
                text: "谁来回答一下，学习率为什么不能太大？", isFinal: true,
                startTimeMillis: 2600, endTimeMillis: 5400,
                timestamp: stamp, languages: ["zh-CN"]
            ),
            TranscriptSegment(
                text: "Machin learning 的课先到这里。", isFinal: true,
                startTimeMillis: 5400, endTimeMillis: 8100,
                timestamp: stamp, languages: ["zh-CN", "en-US"]
            ),
        ]
        var s1 = segmentsA[1]
        s1.questionLevel = 2
        s1.coreQuestion = "学习率为什么不能太大？"
        var s2 = segmentsA[2]
        s2.qualityGrade = .poor
        let builtSegments = [segmentsA[0], s1, s2]

        let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
        let session = store.ingest(SessionDraft(
            sessionID: nil,
            recordingFileName: "课堂-20281122-100000.wav",
            startedAt: stamp,
            durationMillis: 8_100,
            segments: builtSegments
        ))

        report(session.parts.count == 1, "新会话建立", "1 个片段")
        report(session.parts[0].offsetMillis == 0, "首片段偏移为 0")

        // 换一个全新 Store 实例读回（走磁盘，不吃缓存）
        let reread = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
        let back = reread.session(id: session.id)
        report(back != nil, "重新打开后能取到会话")
        if let back {
            let got = back.parts[0].segments
            report(got == builtSegments, "segments 逐字段往返一致", "\(got.count) 段（含 UUID/Date/枚举/数组）")
            report(got[1].questionLevel == 2 && got[1].coreQuestion == "学习率为什么不能太大？",
                   "提问标记往返")
            report(got[2].qualityGrade == .poor && got[2].languages == ["zh-CN", "en-US"],
                   "质量分档 + 多语言往返")
            report(got[0].timestamp == stamp, "Date 精度往返（带小数秒）")
            report(back.startedAt == stamp, "会话 startedAt 往返")
        }

        // ── 2. 追加（接着录）：第二段录音进来，两段都在、时间轴拼得上 ──
        let segmentsB = [
            TranscriptSegment(
                text: "接着刚才的，梯度怎么求？", isFinal: true,
                startTimeMillis: 0, endTimeMillis: 1800,
                timestamp: stamp, languages: ["zh-CN"]
            ),
        ]
        let updated = reread.ingest(SessionDraft(
            sessionID: session.id,
            recordingFileName: "课堂-20281122-101500.wav",
            startedAt: stamp.addingTimeInterval(900),
            durationMillis: 3_000,
            segments: segmentsB
        ))

        report(updated.parts.count == 2, "追加后 2 个片段")
        report(updated.id == session.id, "追加落在同一条会话上（id 不变）")
        let offsetOK = updated.parts[1].offsetMillis == updated.parts[0].durationMillis
        report(offsetOK, "片段 2 偏移 = 片段 1 时长",
               "\(updated.parts[1].offsetMillis)ms")
        if let segB = updated.parts[1].segments.first {
            let range = RecordingSession.absoluteRange(of: segB, in: updated.parts[1])
            // 片段 1 长 8100ms，片段 2 这段相对 0–1800 → 绝对 8100–9900
            report(range == 8_100..<9_900, "绝对时间轴正确",
                   "相对 \(segB.startTimeMillis)–\(segB.endTimeMillis) → 绝对 \(range.lowerBound)–\(range.upperBound)")
        }
        report(updated.segmentCount == 4, "两段的 segments 都在", "共 4 段")

        // 追加后再换实例读回，确认落盘的不只是内存态
        let reread2 = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
        report(reread2.session(id: session.id)?.parts.count == 2, "追加结果已落盘")

        // ── 3. 索引摘要：列表页看到的数据必须和正文一致 ──
        let summary = reread2.summaries.first { $0.id == session.id }
        report(reread2.summaries.count == 1 && summary != nil, "索引里有且只有这条会话")
        if let summary {
            report(
                summary.segmentCount == 4 && summary.questionCount == 1
                    && summary.poorCount == 1 && summary.partCount == 2,
                "摘要统计正确",
                "4 段 · 1 提问 · 1 不可信 · 2 片段"
            )
            report(summary.firstText == String(segmentsA[0].text.prefix(30)), "摘要首段文本正确")
        }

        // ── 4. 删除：默认保留 wav，显式才删音频 ──
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        for name in ["课堂-20281122-100000.wav", "课堂-20281122-101500.wav"] {
            FileManager.default.createFile(
                atPath: recordingsDir.appendingPathComponent(name).path,
                contents: Data([0x00])
            )
        }

        reread2.delete(id: session.id)
        let wavKept = FileManager.default.fileExists(
            atPath: recordingsDir.appendingPathComponent("课堂-20281122-100000.wav").path
        )
        report(reread2.session(id: session.id) == nil, "delete 后会话取不到")
        report(wavKept, "delete 保留 wav（原始素材，默认不删）")
        report(reread2.summaries.isEmpty, "delete 后索引同步移除")

        // 再来一条，走显式删音频
        let session2 = reread2.ingest(SessionDraft(
            sessionID: nil,
            recordingFileName: "课堂-20281122-101500.wav",
            startedAt: stamp, durationMillis: 1_000,
            segments: segmentsB
        ))
        reread2.deleteWithAudio(id: session2.id)
        let wavGone = !FileManager.default.fileExists(
            atPath: recordingsDir.appendingPathComponent("课堂-20281122-101500.wav").path
        )
        report(reread2.session(id: session2.id) == nil, "deleteWithAudio 后会话取不到")
        report(wavGone, "deleteWithAudio 删掉 wav（显式调用才发生）")

        lines.append(allPassed ? "全部通过 ✅" : "存在失败用例 ❌")
        return lines
    }
}
