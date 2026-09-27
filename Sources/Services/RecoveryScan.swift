import AVFoundation
import Foundation

/// 「有音频，但没有完整会话」的录音——崩溃/强杀/断电留下的东西。
///
/// **只读**：和 `IntegrityScan` 一样，这里没有一处 `write` / `removeItem`。
/// 删不删、恢复不恢复，都交给用户在那个显式的入口上决定。
///
/// 和 `IntegrityScan` 的分工：那个问「库里的数据自不自洽」（七类脏数据，
/// 覆盖会话正文里的段、孤儿、半截 wav）；这个问「哪些录音还没有主」，
/// 是**给人看的、要人做决定的一个列表**。两者共用同一份「谁引用了哪个
/// 文件」的算法（都走 `IntegrityScan.loadSessions` / `listAudioFiles`），
/// 免得两处对「什么算被引用」的理解漂移。
enum RecoveryScan {

    /// 一条待处置的录音
    struct Item: Equatable, Identifiable {
        enum Kind: Equatable {
            /// 有草稿、音频也在 → **可以恢复**（扶正成正式会话）
            case recoverableDraft
            /// 有草稿、但草稿指的音频不在盘上 → 转录还在，音频没了
            case draftWithoutAudio
            /// 草稿的目标会话已经完整落盘了（崩溃发生在落盘之后、删草稿之前）
            /// → 草稿是多余的，扶正它会**造出重复的一份**
            case alreadySaved
            /// 只剩音频：没有会话、也没有草稿。P6-2 体检在本机点出的那 41 个来源
            case audioOnly
        }

        var id: String
        let kind: Kind
        let draft: RecordingDraft?
        let fileName: String?
        let startedAt: Date?
        /// 读的是**实际能读出来的**时长。音频头过期时它比真实时长短，
        /// 所以旁边还要带一份 `headerDefect` 说明为什么会短
        let durationMillis: Int?
        let segmentCount: Int
        /// 这段音频的头有没有毛病（过期 / 全零）。**要在恢复之前就告诉用户**——
        /// 「恢复」这个动作会顺手把它修好（见 `RecordingsStore.recover`），
        /// 用户点之前有权知道
        var headerDefect: WAVHeaderRepair.Defect? = nil

        var isRecoverable: Bool { kind == .recoverableDraft }

        /// 恢复这个动作会顺带做的第二件事。nil = 音频头是好的、不用提。
        ///
        /// 文案从 `WAVHeaderRepair.Defect.userNote` 取，**不在这里另写一份**：
        /// 「给不给用户修」的判据同样在那个属性上（`isRepairable`），
        /// 两处各写一份的话，改了分类而没改提示，界面就会说反话
        var headerRepairNote: String? { headerDefect?.userNote }

        /// 给人看的一行。**时长与段数都写出来**——用户判断「这段值不值得恢复」
        /// 靠的就是「多久、讲了多少」
        var summary: String {
            var bits: [String] = []
            if let durationMillis { bits.append("时长 \(Self.mmss(durationMillis))") }
            if segmentCount > 0 { bits.append("已转写 \(segmentCount) 段") }
            if let fileName { bits.append(fileName) }
            return bits.joined(separator: " · ")
        }

        var kindLabel: String {
            switch kind {
            case .recoverableDraft: "未完成"
            case .draftWithoutAudio: "转录在、音频不在"
            case .alreadySaved: "已落盘（草稿多余）"
            case .audioOnly: "无会话的录音"
            }
        }

        static func mmss(_ millis: Int) -> String {
            let total = max(0, millis) / 1000
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    /// 扫。**报出来的每一条都必须真的没有被任何完整会话认领**——
    /// 把一条正常录完的录音标成「未完成」，比漏掉一条严重得多：
    /// 用户会去点「恢复」，然后得到一份重复的会话
    static func scan(
        sessionsDirectory: URL,
        recordingsDirectory: URL,
        draftsDirectory: URL
    ) -> [Item] {
        let sessions = IntegrityScan.loadSessions(in: sessionsDirectory)
        let audioFiles = IntegrityScan.listAudioFiles(in: recordingsDirectory)
        let drafts = loadDrafts(in: draftsDirectory)

        // 被任何一条**完整**会话引用过的文件名。集合的算法与 `IntegrityScan.scan`
        // 逐字一致（同样遍历 parts、同样只看 fileName）
        var referenced: Set<String> = []
        for (_, session) in sessions {
            for part in session.parts {
                if let name = part.fileName { referenced.insert(name) }
            }
        }
        // 已经落盘的会话按 id 索引，用来识别「草稿其实是多余的」
        var savedByID: [UUID: RecordingSession] = [:]
        for (_, session) in sessions { savedByID[session.id] = session }

        var items: [Item] = []

        for draft in drafts {
            let name = draft.recordingFileName
            let exists = name.map { audioFiles.contains($0) } ?? false

            // 目标会话已经落盘，而且**那一份里已经有这个文件** → 草稿重复了。
            // 只比 id 不够：同一条会话「接着录」会有多段，第二段的草稿
            // 本来就该指着一个已有会话
            if let target = draft.targetSessionID, let session = savedByID[target],
               let name, session.parts.contains(where: { $0.fileName == name }) {
                items.append(Item(
                    id: "saved-\(draft.id)", kind: .alreadySaved, draft: draft,
                    fileName: name, startedAt: draft.startedAt,
                    durationMillis: draft.durationMillis, segmentCount: draft.segments.count
                ))
                continue
            }

            // 没开存档（recordsAudio 关着）的录制合法地没有音频文件，
            // 那种草稿照样能扶正——不能因为 fileName 是 nil 就当成「音频不在」
            let kind: Item.Kind = (name == nil || exists) ? .recoverableDraft : .draftWithoutAudio
            items.append(Item(
                id: "draft-\(draft.id)", kind: kind, draft: draft,
                fileName: name, startedAt: draft.startedAt,
                durationMillis: draft.durationMillis, segmentCount: draft.segments.count,
                // 崩溃留下的音频头多半是过期的（那一秒内被杀就会）。
                // 扫出来，好在用户点「恢复」**之前**告诉他这一下会顺手修什么
                headerDefect: name.flatMap { audioDefect(in: recordingsDirectory, named: $0) }
            ))
        }

        // 只剩音频的：没有任何会话引用、也没有任何草稿认领
        let claimedByDraft = Set(drafts.compactMap(\.recordingFileName))
        for file in audioFiles where !referenced.contains(file) && !claimedByDraft.contains(file) {
            let url = recordingsDirectory.appendingPathComponent(file)
            items.append(Item(
                id: "audio-\(file)", kind: .audioOnly, draft: nil,
                fileName: file, startedAt: nil,
                durationMillis: audioDurationMillis(url), segmentCount: 0,
                headerDefect: audioDefect(in: recordingsDirectory, named: file)
            ))
        }

        // 有时间的（草稿）在前、按时间倒序；只剩音频的排后面按文件名倒序
        // （`课堂-yyyyMMdd-HHmmss` 倒序 == 时间倒序）
        let draftsPart = items.filter { $0.draft != nil }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        let audioPart = items.filter { $0.draft == nil }
            .sorted { ($0.fileName ?? "") > ($1.fileName ?? "") }
        return draftsPart + audioPart
    }

    static func loadDrafts(in directory: URL) -> [RecordingDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(RecordingDraft.self, from: data)
            }
    }

    /// 这个文件的头有没有毛病。**复用 `WAVHeaderRepair.inspect`**，
    /// 不在这里另写一遍判据——修复那边改了识别规则，这里必须跟着变，
    /// 否则会出现「列表说没问题、修的时候说有问题」
    private static func audioDefect(in directory: URL, named name: String) -> WAVHeaderRepair.Defect? {
        WAVHeaderRepair.inspect(directory.appendingPathComponent(name))?.defect
    }

    /// 读 wav 时长。**只读文件头，不播放、不解码、不起子进程**
    /// （和 `IntegrityScan.scanWavDuration` 同一个做法与理由）
    private static func audioDurationMillis(_ url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Int(Double(file.length) / rate * 1000)
    }
}
