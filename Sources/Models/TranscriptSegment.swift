import Foundation

/// 转录片段。对应迁移前那版 TS/RN App 里的 `TranscriptSegment`（**那份 spec 不在本仓库**）。
///
/// `languages` 记录这段文字由哪个语言模型产出——因为中英混合是挂载
/// 多个 SpeechTranscriber（zh-CN / en-US）分别识别，同一时刻可能多个
/// 模型都有输出，靠这个字段区分来源。
struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var isFinal: Bool
    var startTimeMillis: Int
    var endTimeMillis: Int
    var timestamp: Date
    var languages: [String]

    /// 课堂提问检测的命中等级：0 = 不是提问，1 = 点名/祈使预警，2 = 确认的提问。
    /// 只在段落定稿时判定一次（见 TranscriptionEngine.upsert）——未定稿的文本
    /// 还在被反复改写，对半成品跑规则只会报出一会有一会没的假信号。
    var questionLevel = 0
    /// 剥掉课堂口头禅和称呼之后的问题本体。level > 0 时有值
    var coreQuestion: String?

    var isQuestion: Bool { questionLevel > 0 }

    /// 转录质量自评，由识别器的逐字符置信度（transcriptionConfidence）
    /// 算出，只在定稿时取一次——未定稿结果还会被反复改写。
    /// nil 表示没评（识别器没给置信度 / 还没定稿）。
    var qualityGrade: TranscriptGrade?

    // MARK: - 说话人（C 包）
    //
    // 三个字段都是「映射的产物」，真相来源是 `RecordingSession.diarization`：
    // 重新转录、重新映射都能把它们整批重算出来。所以它们可以丢、可以空，
    // 丢了不算数据事故——但**不能读不出来**（见下面的手写解码）。

    /// 归属的说话人标签（`S1` / `S2`…，节课内编号）。
    ///
    /// **`nil` 是「没标」，且「没标」只由它表达。** 不要把 `speakerOverlapRatio == 0`
    /// 或 `speakerMixed` 反推成「没标」——那是两件事，混用会让「覆盖恰好为 0」
    /// 和「判定为不标」再也分不开。界面按这个字段决定显不显示说话人
    /// （拍板第 6 条：置信低就不显示，不显示错的是诚实的）。
    var speakerId: String?
    /// winner 覆盖率。**只有 `speakerId != nil` 时有意义**；没标时为 nil。
    ///
    /// 用 Optional 而不是「没标时写 0」：0 是一个合法的覆盖率读数，用它兼职
    /// 「没有值」会让下游分不清「算出来是 0」和「没算」。
    var speakerOverlapRatio: Double?
    /// 本段内第二个人也占了可观时长（判定见 `SpeakerMapper`）。
    /// 与 `speakerId` 相互独立：可以「有归属 + 多人」，也可以「无归属 + 多人」
    var speakerMixed: Bool = false

    init(
        id: UUID = UUID(),
        text: String,
        isFinal: Bool,
        startTimeMillis: Int,
        endTimeMillis: Int,
        timestamp: Date = Date(),
        languages: [String]
    ) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.startTimeMillis = startTimeMillis
        self.endTimeMillis = endTimeMillis
        self.timestamp = timestamp
        self.languages = languages
    }

    // MARK: - 向后兼容

    /// 手写解码。**不能用合成的**，这条是 C 包里最容易翻车的地方。
    ///
    /// Swift 合成的解码器对「有默认值但 JSON 缺键」的非可选属性**不会回落默认值**，
    /// 直接抛 `keyNotFound`——合成器只认属性是不是 Optional，不认等号后面那个默认值。
    /// 实测：`struct S: Codable { var text: String; var questionLevel = 0 }` 解 `{"text":"hi"}` 会失败。
    ///
    /// 为什么这次非要兜住：`RecordingPart.segments` 是硬解，一段失败整条会话就读不出来，
    /// 用户看到的是「那条录音从列表里消失了」——而这条会话明明还在磁盘上。
    /// C 包之前的实际影响是 0（现存 1686/1686 段都有 `questionLevel`），但这次要加
    /// 3 个字段，新写的会话必然带它们，**旧会话必然不带**，所以兜底是必须的。
    ///
    /// 兜底范围的划法：**一直存在的字段仍然必需**（缺了说明文件坏了，该抛出来），
    /// 只有「后加的、有默认值的」才 `decodeIfPresent`。范围就下面这几个，别顺手扩大——
    /// 把必需字段也兜成默认值，等于把「文件坏了」变成「读出一些空段」，那是更坏的失败。
    private enum CodingKeys: String, CodingKey {
        case id, text, isFinal, startTimeMillis, endTimeMillis, timestamp, languages
        case questionLevel, coreQuestion, qualityGrade
        case speakerId, speakerOverlapRatio, speakerMixed
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        isFinal = try c.decode(Bool.self, forKey: .isFinal)
        startTimeMillis = try c.decode(Int.self, forKey: .startTimeMillis)
        endTimeMillis = try c.decode(Int.self, forKey: .endTimeMillis)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        languages = try c.decode([String].self, forKey: .languages)

        // 后加的非可选字段：缺键回落到属性默认值
        questionLevel = try c.decodeIfPresent(Int.self, forKey: .questionLevel) ?? 0
        speakerMixed = try c.decodeIfPresent(Bool.self, forKey: .speakerMixed) ?? false
        // 后加的可选字段：缺键就是 nil（也正是「没标」「没评」的原意）
        coreQuestion = try c.decodeIfPresent(String.self, forKey: .coreQuestion)
        qualityGrade = try c.decodeIfPresent(TranscriptGrade.self, forKey: .qualityGrade)
        speakerId = try c.decodeIfPresent(String.self, forKey: .speakerId)
        speakerOverlapRatio = try c.decodeIfPresent(Double.self, forKey: .speakerOverlapRatio)
    }

    var durationMillis: Int { max(0, endTimeMillis - startTimeMillis) }

    /// `00:12:03` 形式的时间戳。
    ///
    /// 原 TS 版写的是 HH:MM，但纯 HH:MM 会把秒丢掉——一节课里同一分钟
    /// 常常有好几段，它们会显示成同一个时间，反而没法定位。带上秒
    /// 既满足 HH:MM 的读法，又不丢信息。
    var formattedTimestamp: String {
        let total = max(0, startTimeMillis) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// 核查引用的来源。原 TS 版的 tool schema 里没有这个字段，
/// 但 UI 要显示「来源链接」，所以补上。
struct FactCheckSource: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var title: String
    var url: String
}

/// 事实核查结果。对应原 TS 版里的 `FactCheckResult`。
struct FactCheckResult: Identifiable, Equatable {
    enum Status: String, Codable {
        case verified
        case disputed
        case unverifiable

        var label: String {
            switch self {
            case .verified: return "已证实"
            case .disputed: return "存疑"
            case .unverifiable: return "无法核实"
            }
        }

        /// verified 用 #30D158，unverifiable 用 #FF9F0A
        var symbol: String {
            switch self {
            case .verified: return "✓"
            case .disputed: return "?"
            case .unverifiable: return "✗"
            }
        }
    }

    enum Phase: Equatable {
        case searching
        case analyzing
        case done
        case failed(String)
    }

    var id: UUID { segmentID }
    let segmentID: UUID
    /// 被核查的原句，UI 要显示
    var claim: String
    var status: Status
    var explanation: String
    var confidence: Double
    var sources: [FactCheckSource] = []
    var phase: Phase = .done

    /// 要不要显示「把握 xx%」。
    ///
    /// 「无法核实」不该带百分比：它表达的是「我没找到能判定的来源」，
    /// 不是「我对这个结论有多确信」。挂个 100% 在旁边，用户读到的是
    /// 「结论很可信」——跟它实际的意思正好相反。
    var showsConfidence: Bool {
        phase == .done && (status == .verified || status == .disputed)
    }
}

/// 图片附件。对应原 TS 版里的 `ImageAttachment`。
///
/// 相比原 TS 版多了一个 `timestampMillis`：图片要绑定到转录时间轴上的
/// 某个位置，才能在对应段落旁边显示缩略图。原来的 `timestamp` 是
/// 墙上时间（Date），无法跟转录的 startTimeMillis 对齐。
struct ImageAttachment: Identifiable, Equatable {
    let id: UUID
    /// 已复制到 App 文档目录的永久路径
    var url: URL
    var originalName: String
    /// 绑定到转录时间轴的位置（毫秒）
    var timestampMillis: Int
    var addedAt: Date

    init(
        id: UUID = UUID(),
        url: URL,
        originalName: String,
        timestampMillis: Int,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.originalName = originalName
        self.timestampMillis = timestampMillis
        self.addedAt = addedAt
    }

    var formattedTimestamp: String {
        let total = max(0, timestampMillis) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
