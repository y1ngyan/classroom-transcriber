import Foundation

/// 录制**途中**的周期性快照。
///
/// 和 `SessionDraft` 的分工（两个名字像，但用途完全不同）：
/// - `SessionDraft` 是引擎在**收尾那一刻**交给 Store 的一次完整录制，
///   一条会话只会出现一次，落盘走 `RecordingsStore.ingest`；
/// - `RecordingDraft` 是录制**进行中**每隔一段时间写一份的保险，
///   崩溃时它是唯一还记得「这堂课讲了什么」的东西。
///
/// **为什么草稿保的是转录而不是音频**：音频早就流式落盘了（`WAVRecorder`
/// 写盘到 1 秒以内），崩溃丢不掉。真正会「录了两小时的东西没了」的是
/// **转录文本、片段划分、时间轴、课程归属**——它们原先只在停止时写一次。
/// 所以草稿要装的正是这几样。
///
/// 草稿**不放进 `sessions/`**：那个目录的语义是「完整的会话」，
/// `RecordingsStore` 的列表、`IntegrityScan` 的七类判据都按这个语义写的。
/// 半成品混进去会让每个读那个目录的地方都得多判一次「这条算不算数」。
struct RecordingDraft: Codable, Equatable {

    /// 草稿自己的文件键（`sessions/drafts/<id>.json`）。
    /// **和 `targetSessionID` 分开**：一次「接着录」的草稿属于一条已有会话，
    /// 但草稿文件本身必须有自己的身份，否则扶正和丢弃会互相覆盖
    var id: UUID
    /// 「接着录」时要追加到哪条会话；nil = 这是一次全新录制
    var targetSessionID: UUID?
    /// 存档文件名（`WAVRecorder` 写的那个）。nil = 本次没开存档
    var recordingFileName: String?
    var startedAt: Date
    var durationMillis: Int
    /// **只装本次录制新产生的段**（`segments[sessionSegmentBase...]`），
    /// 和 `completeSession` 交给 `ingest` 的那一批完全同源——
    /// 扶正时才能直接走 `ingest`，不必为草稿另写一条落盘路径
    var segments: [TranscriptSegment]
    /// 最后一次写入时间（墙上时间）。恢复界面按它排序，
    /// 也用来告诉用户「这份草稿停在什么时候」
    var savedAt: Date
    /// 草稿结构版本。**手写解码而不是用合成的**：加字段不能把已写下的草稿读废
    /// ——崩溃现场只出现一次，读不出来就等于没写
    var version: Int

    init(
        id: UUID,
        targetSessionID: UUID?,
        recordingFileName: String?,
        startedAt: Date,
        durationMillis: Int,
        segments: [TranscriptSegment],
        savedAt: Date,
        version: Int = RecordingDraft.currentVersion
    ) {
        self.id = id
        self.targetSessionID = targetSessionID
        self.recordingFileName = recordingFileName
        self.startedAt = startedAt
        self.durationMillis = durationMillis
        self.segments = segments
        self.savedAt = savedAt
        self.version = version
    }

    static let currentVersion = 1

    private enum CodingKeys: String, CodingKey {
        case id, targetSessionID, recordingFileName, startedAt, durationMillis, segments, savedAt, version
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        targetSessionID = try c.decodeIfPresent(UUID.self, forKey: .targetSessionID)
        recordingFileName = try c.decodeIfPresent(String.self, forKey: .recordingFileName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        durationMillis = try c.decode(Int.self, forKey: .durationMillis)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? startedAt
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    /// 扶正成正式会话用的那一次交接。**就是 `completeSession` 构造的那个值**，
    /// 一个字段都不多不少——恢复走的是和正常停止完全相同的那条落盘路径，
    /// 这样「恢复出来的会话」和「正常录完的会话」不可能有结构差别
    var asSessionDraft: SessionDraft {
        SessionDraft(
            sessionID: targetSessionID,
            recordingFileName: recordingFileName,
            startedAt: startedAt,
            durationMillis: durationMillis,
            segments: segments
        )
    }
}
