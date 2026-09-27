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

    /// 用户给这条录音起的名字。空表示没起过——列表回落到显示
    /// 日期和首段文本。**不给默认名**：自动生成的「未命名录音 3」
    /// 比空更糟，用户得先删掉它才能起自己的名
    var title: String = ""
    /// 课程名，用于分组。空表示未分类
    var course: String = ""

    // MARK: - 向后兼容

    /// 手写解码而不是用合成的：这两个字段是后加的，磁盘上已有的
    /// 会话 JSON 里没有这两个键，合成解码会直接抛 keyNotFound 让
    /// 整条会话读不出来。加字段不能把旧数据读废
    private enum CodingKeys: String, CodingKey {
        case id, startedAt, updatedAt, parts, title, course
    }

    init(id: UUID, startedAt: Date, updatedAt: Date, parts: [RecordingPart],
         title: String = "", course: String = "") {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.parts = parts
        self.title = title
        self.course = course
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        parts = try c.decode([RecordingPart].self, forKey: .parts)
        // 缺键视作空串，和「没起过名」「未分类」是同一个意思
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        course = try c.decodeIfPresent(String.self, forKey: .course) ?? ""
    }

    /// 列表上显示的名字。用户起过就用它，没起过回落到时间——
    /// 不显示空字符串，那在列表里就是一行空白
    var displayTitle: String {
        title.isEmpty ? formattedFallbackTitle : title
    }

    private var formattedFallbackTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: startedAt)
    }

    /// 分组用的课程名。空归到「未分类」而不是空标题——
    /// 列表里一个没有标题的分组会让人以为是渲染坏了
    var displayCourse: String {
        course.isEmpty ? "未分类" : course
    }

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
    ///
    /// **反向段（`end < start`）返回空区间，绝不交给 `..<`。** Swift 6 的
    /// `Range` 那个运算符是**带检查**的，`lower > upper` 直接 SIGTRAP——实测
    /// 退出码 133，且 release 下**一个字都不打印**（`swiftc -O -swift-version 6`
    /// 编 `let a = 9000, b = 1000; let r = a..<b` → 133；同一个进程换成
    /// `Range(uncheckedBounds:)` 正常退出；`9000..<9000` 也正常，`isEmpty` 为真）。
    /// 这个 trap 让「查一条会话的笔记」这种只读操作能整段崩掉，见 `isReversed`。
    ///
    /// **为什么是空区间，不是归一化成 `min..<max`**：归一化要**悄悄改掉起点**，
    /// 而反向段的两个端点里没有一个能声称是「它开始说话的时刻」——取谁都是编。
    /// 空区间说的是实话（「这一段在时间轴上没有长度」），同时把 `start` 原样
    /// 留在 `lowerBound` 上：`StudyNotesService` 的两处锚点要的正是这个起点，
    /// 它们的行为在修前修后完全一致。长度相关的下游行为由各自的调用方定——
    /// `SpeakerMapper` 见到零长区间判「不标」（见那里的 guard）
    static func absoluteRange(of segment: TranscriptSegment, in part: RecordingPart) -> Range<Int> {
        let start = part.offsetMillis + segment.startTimeMillis
        let end = part.offsetMillis + segment.endTimeMillis
        guard end > start else { return start..<start }
        return start..<end
    }

    /// 这一段的时间是不是反的（`end < start`）。**纯判定，不改数据、不打印**。
    ///
    /// 为什么不把它塞进 `absoluteRange` 里记账：那个函数是纯函数（无 IO、
    /// 无全局状态、同输入同输出），自检靠这一点断言。可见性交给调用方按需取——
    /// 见 `reversedSegments(in:)`、`--study-notes` 的告警行，以及
    /// `DiarizationStats.reversedTranscriptSegments`。
    ///
    /// 只看 segment 自己的两个值，不关片段 offset 的事：offset 对两边加的是
    /// 同一个数，反不反向与它无关
    static func isReversed(_ segment: TranscriptSegment) -> Bool {
        segment.endTimeMillis < segment.startTimeMillis
    }

    /// 整条会话里时间反向的段（按片段顺序）。**诊断用**：让「这里有反向段」
    /// 看得见，而不是等某个调用点行为诡异了再回头猜
    static func reversedSegments(in session: RecordingSession) -> [TranscriptSegment] {
        session.parts.flatMap(\.segments).filter(isReversed)
    }
}

// MARK: - 说话人（C 包）

/// 一个 diar 段：某个人在某段区间上说话。**时间轴是会话轴**（helper 按
/// `--offset-ms` 把每个片段摆到会话时间轴上，不是顺序拼接），与
/// `RecordingSession.absoluteRange` 同一个基准——映射时**不要再加一次 offset**。
///
/// `startMillis`/`endMillis` 是半开区间 `[start, end)`：`start == end` 是零长段，
/// 映射时直接丢掉（它不是「说了 0 秒」，是数据不足）。
struct SpeakerSpan: Codable, Equatable {
    /// 原样保留 helper 的 `S1`/`S2`（FluidAudio 的 `TimedSpeakerSegment.speakerId`）。
    /// 节课内编号在 diarize 跑完时分配一次，之后不变
    var speakerId: String
    var startMillis: Int
    var endMillis: Int
    /// helper 给这段打的把握（0–1）。**只用来诊断**，不参与归属判定——
    /// 判定用的是重叠时长，见 `SpeakerMapper`（`qualityScore` 低不代表这段不算数）
    var qualityScore: Double
}

/// 一次说话人识别的完整结果，挂在会话上。**真相来源**：
/// `TranscriptSegment.speakerId` 这些是从它算出来的产物，可重算、可丢。
///
/// 命名避开 FluidAudio 的 `DiarizationResult`：主 App 不链 FluidAudio
/// （helper 是独立进程），同名会让人误以为两者可以互转。
///
/// 两个新类型都用**合成 Codable**，这是刻意的：它们本身就是新类型，
/// 磁盘上不存在「没有这些键的旧文件」，所以没有 `TranscriptSegment` 那种
/// 「缺键 → 整条会话读不出来」的问题。**将来给它们加字段时才需要手写解码**
/// （`decodeIfPresent`），别等到出事才想起来
struct SpeakerDiarization: Codable, Equatable {
    /// helper 信封的 schema 版本。缺键视作 0，而 **0 不当可用**——
    /// 「没版本号」和「版本 1」必须分得开，否则将来加字段时无法判断怎么解
    var schemaVersion: Int
    /// 产出这份结果的 helper 构建标识，写进存档便于回溯「这批标签是谁算的」
    var helperBuild: String
    var ranAt: Date
    /// helper 报的音频总时长（秒）。与本地 `durationMillis` 对不上说明音频被换过
    var audioSeconds: Double
    var speakerCount: Int
    /// 原始 label 按「首次出现时间」升序。节课内编号（`S1,S2…`）就是按它定的
    var speakerOrder: [String]
    var segments: [SpeakerSpan]
    /// 音频指纹（串起各片段的文件名/偏移/时长再哈希）。回答「这份结果还算不算数」：
    /// 重新转录不动音频 → 指纹不变 → 结果继续有效；追加了一段录音 → 指纹变 →
    /// 旧片段保留已物化的标签，新片段一律 nil
    var partFingerprint: String
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
    /// 用户起的名字 / 课程名。摘要里也存一份，是为了列表页不必
    /// 为了读两个名字去解码整条会话正文（正文可能有几百段）
    var title: String
    var course: String

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
        title = session.title
        course = session.course
        firstText = String(
            session.parts.lazy.compactMap { $0.segments.first?.text }.first?.prefix(30) ?? ""
        )
    }

    /// 和 RecordingSession 同一套回落规则，见那边的注释
    var displayTitle: String {
        title.isEmpty ? formattedFallbackTitle : title
    }

    var displayCourse: String {
        course.isEmpty ? "未分类" : course
    }

    private var formattedFallbackTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: startedAt)
    }

    /// 手写解码：title/course 是后加的字段，磁盘上的 index.json
    /// 里没有这两个键，合成解码会让整个索引读不出来（等于所有
    /// 录音消失）。缺键视作空串
    private enum CodingKeys: String, CodingKey {
        case id, startedAt, updatedAt, durationMillis, partCount, segmentCount
        case questionCount, poorCount, fairCount, firstText, title, course
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        durationMillis = try c.decode(Int.self, forKey: .durationMillis)
        partCount = try c.decode(Int.self, forKey: .partCount)
        segmentCount = try c.decode(Int.self, forKey: .segmentCount)
        questionCount = try c.decode(Int.self, forKey: .questionCount)
        poorCount = try c.decode(Int.self, forKey: .poorCount)
        fairCount = try c.decode(Int.self, forKey: .fairCount)
        firstText = try c.decode(String.self, forKey: .firstText)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        course = try c.decodeIfPresent(String.self, forKey: .course) ?? ""
    }
}
