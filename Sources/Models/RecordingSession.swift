import Foundation

/// 一次「课」的完整记录：一条或多段录音 + 各自的转录。
///
/// 为什么需要它：转录结果原本只在 TranscriptionEngine.segments 的内存里，
/// 关掉 App 就全没了；recordings/ 下的 wav 和转录文本之间也没有任何关联。
/// 一条会话把「哪几个 wav 文件」和「它们的转录」钉在一起，这是
/// 「点开一条录音看它的转录」能成立的地基。
struct RecordingSession: Identifiable, Codable, Equatable {
    let id: UUID
    /// 第一段录音开录的墙上时间。列表按它排序和显示
    var startedAt: Date
    var updatedAt: Date
    /// 录音片段。「接着录」一次就追加一条，永远按时间顺序
    var parts: [RecordingPart]

    /// 会话总时长 = 最后一个片段的偏移 + 它自己的时长
    var durationMillis: Int {
        guard let last = parts.last else { return 0 }
        return last.offsetMillis + last.durationMillis
    }

    var segmentCount: Int { parts.reduce(0) { $0 + $1.segments.count } }
    var questionCount: Int { parts.reduce(0) { $0 + $1.segments.filter(\.isQuestion).count } }
    var poorCount: Int { parts.reduce(0) { $0 + $1.segments.filter { $0.qualityGrade == .poor }.count } }
    var fairCount: Int { parts.reduce(0) { $0 + $1.segments.filter { $0.qualityGrade == .fair }.count } }

    /// 一条 segment 在**会话时间轴**上的起止（毫秒）。
    ///
    /// segments 存的是相对各自片段 0 点的时间（引擎吐出来的原样），
    /// 展示层要绝对时间就加片段的 offset——这是「接着录」两段录音
    /// 时间轴拼起来的唯一换算，全在这一处
    static func absoluteRange(of segment: TranscriptSegment, in part: RecordingPart) -> Range<Int> {
        (part.offsetMillis + segment.startTimeMillis)..<(part.offsetMillis + segment.endTimeMillis)
    }
}

/// 一段连续的录音（一次「开始 → 停止」）。
///
/// **为什么 segments 按片段分组、时间存相对值**：「接着录」会在同一条
/// 会话上追加第二段录音，而新录音的转录时间从 0 开始，和已有片段的时间轴
/// 不是一回事。把两段拍平成一个数组的话，要么追加时把新 segments 的时间
/// 整体平移（偏移写死进每条数据，以后改不动），要么时间轴撞车（两个 0 点）。
/// 按片段分组后，每段 segments 保持引擎吐出来的原样，绝对时间靠
/// `offsetMillis` 现算——不丢信息，也不用回头改历史数据。
struct RecordingPart: Identifiable, Codable, Equatable {
    let id: UUID
    /// 只存文件名，不存绝对路径：Application Support 的根会随迁移/换机变，
    /// 文件名 + RecordingStorage.directory 永远能重组出真路径。
    /// nil = 这次录制没开存档（recordsAudio 关着），只有转录没有 wav
    var fileName: String?
    var startedAt: Date
    var durationMillis: Int
    /// 在会话时间轴上的起始偏移（= 之前所有片段的时长之和）。显式存下来，
    /// 追加和换算时不用每次重算整条链
    var offsetMillis: Int
    /// 相对本片段 0 点的转录
    var segments: [TranscriptSegment]
}

/// 引擎 stop() 收尾完成后交给 Store 的快照。引擎不认识 RecordingsStore
/// （Transcription 层不依赖 Stores 层），两者之间就靠这个值类型交接
struct SessionDraft {
    /// nil = 新会话；有值 = 「接着录」，追加到这条会话上
    var sessionID: UUID?
    var recordingFileName: String?
    var startedAt: Date
    var durationMillis: Int
    /// 本次录制新产出的 segments（不含会话里已有的）
    var segments: [TranscriptSegment]
}

/// 列表页用的会话摘要。sessions/index.json 里存的就是它。
///
/// 为什么单独存一份而不是列表时现扫所有会话文件：一条会话的 segments
/// 可能有几百段、几百 KB，一学期几百条会话，「打开列表页」不该付
/// 全量解码的代价。摘要里的统计在 save 时从会话现算，不会漂移
struct SessionSummary: Identifiable, Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var updatedAt: Date
    var durationMillis: Int
    var partCount: Int
    var segmentCount: Int
    var questionCount: Int
    var poorCount: Int
    var fairCount: Int
    /// 首段文本的前 30 字。列表光给一个日期看不出是哪节课，
    /// 开头说了什么是最便宜的辨认线索
    var firstText: String

    init(session: RecordingSession) {
        id = session.id
        startedAt = session.startedAt
        updatedAt = session.updatedAt
        durationMillis = session.durationMillis
        partCount = session.parts.count
        segmentCount = session.segmentCount
        questionCount = session.questionCount
        poorCount = session.poorCount
        fairCount = session.fairCount
        firstText = String(
            session.parts.lazy.compactMap { $0.segments.first?.text }.first?.prefix(30) ?? ""
        )
    }
}
