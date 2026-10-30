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

    // MARK: - 提问与答案（B 包 §4）

    /// 老师问过的问题。**放在会话文件里而不是单独一个 questions.json**（§4.1）：
    /// 答案必须跟着会话走——删掉一条录音时它的答案也该一起消失，而
    /// `delete()` 的现有语义（删正文文件）天然覆盖了这件事，不需要第二套级联删除。
    ///
    /// 条目量级是几十条、每条答案几 KB，相对已经几百 KB 的 `segments` 不是
    /// 增量级问题；`save` 的原子写仍然是「一条会话一次写」
    var questions: [LessonQuestion] = []

    /// 问题条目的 schema 版本，**缺键视作 0**（= 还没回填过）。见
    /// `backfillQuestions(sensitivity:)` 与 `LessonQuestionSchema`
    var questionSchemaVersion: Int = 0

    // MARK: - 向后兼容

    /// 手写解码而不是用合成的：这几个字段是后加的，磁盘上已有的
    /// 会话 JSON 里没有这些键，合成解码会直接抛 keyNotFound 让
    /// 整条会话读不出来。加字段不能把旧数据读废
    private enum CodingKeys: String, CodingKey {
        case id, startedAt, updatedAt, parts, title, course
        case questions, questionSchemaVersion
    }

    init(id: UUID, startedAt: Date, updatedAt: Date, parts: [RecordingPart],
         title: String = "", course: String = "",
         questions: [LessonQuestion] = [], questionSchemaVersion: Int = 0) {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.parts = parts
        self.title = title
        self.course = course
        self.questions = questions
        self.questionSchemaVersion = questionSchemaVersion
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
        // 缺键 = 「这节课没有问题条目」，不是「这条会话读不出来」。
        // 元素包一层 `LenientElement`：数组里一条坏掉的不许连坐整条会话
        questions = try c.decodeIfPresent([LenientElement<LessonQuestion>].self, forKey: .questions)?
            .compactMap(\.value) ?? []
        questionSchemaVersion = try c.decodeIfPresent(Int.self, forKey: .questionSchemaVersion) ?? 0
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
    /// **被标成提问的段落数**。B 包之前这就是列表上那句「N 个提问」的来源。
    /// 它与 `questions`（去重后的问题条目）不是一回事：同一句话老师问两遍，
    /// 这里算 2、那里算 1。新代码要「提问页里那个 N」请用 `questions.count`，
    /// 或者读 `SessionSummary.questionCount`（那里有一层旧数据的回落，见其注释）
    var questionCount: Int { parts.reduce(0) { $0 + $1.segments.filter(\.isQuestion).count } }
    /// 其中已经有答案的条数（`status == .answered`，与 §5 状态机同一把尺子）
    var answeredQuestionCount: Int { questions.filter { $0.status == .answered }.count }
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
    /// 这一段录音是**用哪个麦**录的（P0-1）。nil = 这条片段存于本包之前，
    /// 或者当时根本没读到设备。
    ///
    /// **跟着片段走，不跟着会话走**：设备是「这一次开始→停止」的属性。挂在会话上
    /// 的话，「接着录」第二段换了麦（换教室、外置麦没带）就记不出来了——而
    /// 那恰恰是最需要第二种记录的场景
    var capture: RecordingCapture?
    /// **这段转录是哪个模型产出的**（P11-1 目标 4）。nil 有两种含义，
    /// 都写在这里免得被读成同一种：
    ///   · 这一段存于本包之前——那时候不记出处（旧存档**不回写**，见下面
    ///     `init(from:)` 的注释）；
    ///   · 这一段是**实时录出来**的，还没重转过。
    /// 实时那条链路固定 medium（`RetranscribeEngine.preferred` 只用于课后重转），
    /// 所以「nil = 实时 medium」在今天是成立的——但**不要把它当字段用**：
    /// 以后实时链路换模型、或者加了第三种来源，nil 就不再等于 medium 了。
    /// 要判断「这份转录是什么产出的」，看这个字段有没有值，别去推
    var transcriptionProvenance: TranscriptionProvenance?

    /// 手写解码：`capture` 是后加的键，磁盘上已有的会话 JSON 里没有它。
    /// 合成解码会抛 keyNotFound 让**整条会话**读不出来——那不是「新字段是空的」，
    /// 是「用户录的这节课消失了」。缺键视作 nil（= 不知道是哪个麦），
    /// 而不是编一个默认设备顶上
    private enum CodingKeys: String, CodingKey {
        case id, fileName, startedAt, durationMillis, offsetMillis, segments, capture
        case transcriptionProvenance
    }

    init(id: UUID, fileName: String?, startedAt: Date, durationMillis: Int,
         offsetMillis: Int, segments: [TranscriptSegment], capture: RecordingCapture? = nil,
         transcriptionProvenance: TranscriptionProvenance? = nil) {
        self.id = id
        self.fileName = fileName
        self.startedAt = startedAt
        self.durationMillis = durationMillis
        self.offsetMillis = offsetMillis
        self.segments = segments
        self.capture = capture
        self.transcriptionProvenance = transcriptionProvenance
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        durationMillis = try c.decode(Int.self, forKey: .durationMillis)
        offsetMillis = try c.decode(Int.self, forKey: .offsetMillis)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        capture = try c.decodeIfPresent(RecordingCapture.self, forKey: .capture)
        // 同 `capture`：老存档里没有这个键，而合成解码会为一个**缺失的新字段**
        // 抛 keyNotFound、把整条会话读废。缺键 = 不知道出处，不是「没有出处」
        transcriptionProvenance = try c.decodeIfPresent(
            TranscriptionProvenance.self, forKey: .transcriptionProvenance
        )
    }

    /// 「这一段是哪个麦」。读不出来时给一句实话，**不编设备名**
    var captureSummary: String {
        guard let capture else { return "未记录（这条片段存于记录设备之前）" }
        var text = "\(capture.device.name)"
        if capture.source == InputDeviceResolution.Source.systemDefault.rawValue {
            text += "（回落自系统默认）"
        }
        for change in capture.changes { text += "\n  · \(change.summary)" }
        return text
    }
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
    /// 本次录制用的是哪个麦（P0-1）。nil = 没读到（不是「没变」）。
    /// 放在 draft 上而不是让 Store 自己去查：查出来的是**此刻**的系统默认设备，
    /// 而这一段的设备是**录制当时**引擎自己报的那一只，两者可以不同
    var capture: RecordingCapture? = nil
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
    /// 老师提问的条数（列表上那句「N 个提问」）。
    ///
    /// **这个字段的含义在 B 包里变了**，而且必须说清楚变在哪：设计稿 §4.5 说
    /// 「新增 `questionCount`」，但这个名字在本仓库**已经存在**（那时它数的是
    /// 「被标成提问的段落数」）。两处指的是同一件产品事实（这节课老师问了多少），
    /// 只是口径不同——段落计不去重，问题条目按 `normalizedText` 去重（§6.4）。
    /// 处理办法见 `SessionSummary.init(session:)` 里那段回落说明
    var questionCount: Int
    /// 其中已经有答案的条数（`status == .answered`，与 §5 状态机同一把尺子）
    var answeredQuestionCount: Int
    var poorCount: Int
    var fairCount: Int
    /// 首段文本的前 30 字。列表光给一个日期看不出是哪节课，
    /// 开头说了什么是最便宜的辨认线索
    var firstText: String
    /// 用户起的名字 / 课程名。摘要里也存一份，是为了列表页不必
    /// 为了读两个名字去解码整条会话正文（正文可能有几百段）
    var title: String
    var course: String
    /// 这条会话第一段音频的文件名（P15-1 波形缩略图要定位 wav）。
    ///
    /// 存文件名而不是让列表去解码会话正文：摘要是「列表只读 index.json」
    /// 这条设计的地基，为了一张缩略图把每条会话的几百段转录全解一遍，
    /// 等于把当初拆正文的理由全扔掉。旧 index.json 没有这个键，
    /// 读出来是 nil，走 `RecordingsStore.audioURL(for:)` 的一次性回落
    var audioFileName: String?

    init(session: RecordingSession) {
        id = session.id
        startedAt = session.startedAt
        updatedAt = session.updatedAt
        durationMillis = session.durationMillis
        partCount = session.parts.count
        segmentCount = session.segmentCount
        // 「N 个提问」的口径切换（§4.5）。**已回填的会话走问题条目数**
        // （提问页里那个 N，去重后）；**没回填过的旧会话回落到段落计数**，
        // 也就是 B 包之前那个数字。
        //
        // 为什么要有这个回落：本包不做全量迁移（§4.6.4），而列表页那句
        // 「N 个提问」读的正是这个数。直接改成条目数的话，用户库里**所有**旧录音
        // 的数字会在下一次 save 之后静默归零——用户不会知道那是「还没回填」，
        // 只会以为 App 把他录的提问弄丢了。回填过的会话一律走条目数，
        // 于是这个回落随着回填逐步消失
        questionCount = session.questionSchemaVersion >= LessonQuestionSchema.current
            ? session.questions.count
            : session.questionCount
        answeredQuestionCount = session.answeredQuestionCount
        poorCount = session.poorCount
        fairCount = session.fairCount
        title = session.title
        course = session.course
        firstText = String(
            session.parts.lazy.compactMap { $0.segments.first?.text }.first?.prefix(30) ?? ""
        )
        // 取第一段**有文件**的 part：续录的会话里理论上每段都有，但历史
        // 数据里可能存在 fileName == nil 的段，不能只看 parts.first
        audioFileName = session.parts.lazy.compactMap(\.fileName).first
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
        case questionCount, answeredQuestionCount, poorCount, fairCount, firstText, title, course
        case audioFileName
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
        // 后加的字段：老 index.json 里没有它。缺键 = 「没有已答的问题」
        answeredQuestionCount = try c.decodeIfPresent(Int.self, forKey: .answeredQuestionCount) ?? 0
        poorCount = try c.decode(Int.self, forKey: .poorCount)
        fairCount = try c.decode(Int.self, forKey: .fairCount)
        firstText = try c.decode(String.self, forKey: .firstText)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        course = try c.decodeIfPresent(String.self, forKey: .course) ?? ""
        // 后加的字段：老 index.json 里没有它。nil = 「还没有可定位的音频」，
        // 列表行会退化成占位直条，不是错误
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
    }
}
