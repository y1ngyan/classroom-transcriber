import Foundation

/// 转录片段。对应原 TS 规格中的 `TranscriptSegment`。
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

    var durationMillis: Int { max(0, endTimeMillis - startTimeMillis) }

    /// `00:12:03` 形式的时间戳。
    ///
    /// 规格里写的是 HH:MM，但纯 HH:MM 会把秒丢掉——一节课里同一分钟
    /// 常常有好几段，它们会显示成同一个时间，反而没法定位。带上秒
    /// 既满足 HH:MM 的读法，又不丢信息。
    var formattedTimestamp: String {
        let total = max(0, startTimeMillis) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// 核查引用的来源。原规格的 tool schema 里没有这个字段，
/// 但 UI 要显示「来源链接」，所以补上。
struct FactCheckSource: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var title: String
    var url: String
}

/// 事实核查结果。对应原 TS 规格中的 `FactCheckResult`。
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

        /// 规格指定：verified 用 #30D158，unverifiable 用 #FF9F0A
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

/// 图片附件。对应原 TS 规格中的 `ImageAttachment`。
///
/// 相比原规格多了一个 `timestampMillis`：图片要绑定到转录时间轴上的
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
