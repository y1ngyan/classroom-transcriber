import Foundation

/// 一条学习笔记要点属于哪一类。
///
/// **枚举而不是自由文本**：自检要按类型断言条数（设计稿 §3.1），界面要按类型
/// 分组渲染。模型对同一件事会写出「重点」「核心要点」「Key Point」「知识点」
/// 十几种说法，自由文本一到手就得再猜一次它是什么意思。
enum StudyItemKind: String, Codable, CaseIterable {
    case summary
    case keyPoint
    case todo
    case examFocus
    case term

    /// 界面/报告里的中文名。声明顺序**就是**显示和排序的顺序
    /// （摘要 → 重点 → 待办 → 考点 → 术语）
    var label: String {
        switch self {
        case .summary: return "摘要"
        case .keyPoint: return "重点"
        case .todo: return "待办"
        case .examFocus: return "考点"
        case .term: return "术语"
        }
    }
}

/// 要点指向转录里某个真实段落的三元组。
///
/// **三个字段都要存，不是冗余**：`partID` 定位是哪个录音片段（会话可能有
/// 多段），`segmentID` 是稳定的身份（重排、改名都不动它），`startMillis` 是
/// 会话轴上的起点——界面要拿它跳音频，而每次都从 segmentID 回溯一遍时间
/// 意味着多一次全量查找，且一旦段落被重转就悄悄变了。
///
/// `startMillis` 是**会话轴**（= 片段 offset + 段内 start），和
/// `RecordingSession.absoluteRange` 同一基准。全项目只有那一处换算，
/// 这里不再自己加一次 offset
struct Anchor: Codable, Equatable {
    var partID: UUID
    var segmentID: UUID
    var startMillis: Int
}

/// 一条要点。`anchors` 至少一条——没有锚点的条目根本不会被构造出来，
/// 见 `StudyNotesService` 的校验（设计稿 §1.3 第 2 条：宁可少一条，不许编一条）
struct StudyItem: Codable, Equatable {
    var kind: StudyItemKind
    var text: String
    var anchors: [Anchor]
}

/// 一次生成的用量与耗时。
///
/// 存下来是因为验收判据里有一条是「一堂课 ≤ 0.1 元」（设计稿 §5.3）——
/// 不把 token 数和算它用的单价一起记下来，那个数字第二天就没人能重算了
struct StudyNotesUsage: Codable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    /// 命中的缓存 token。DeepSeek 对命中部分单独计价，不分开记就会把
    /// 费用算高——重复生成同一片时这个数会显著上升
    var cacheHitTokens: Int
    /// 送了几片（= 调了几次模型）
    var sliceCount: Int
    var elapsedSeconds: Double
    /// 按 `StudyNotesCost` 里那套单价估算的费用（元）
    var estimatedYuan: Double
}

/// 一堂课的学习笔记。**独立文件、独立类型，与转录彻底分离**（拍板 3b）。
///
/// 为什么不挂在 `RecordingSession` 里当新字段：转录的内容是「识别器真实输出 +
/// 术语校正」，下游挂着事实核查；而这份东西是模型写过手的。混进同一个对象，
/// 迟早会有人顺手把 `items` 当转录读——`PunctuationService` 立的规矩是
/// 「模型经手过的文本不许混进转录」，物理分开是最省事的守法
struct StudyNotes: Codable, Equatable {
    var sessionID: UUID
    var generatedAt: Date
    /// 产出这份笔记的模型标识（`ModelText.defaultModel`）。同一堂课重跑两次
    /// 结果不同是可预期的，得能查出「这份是谁写的」
    var model: String
    var items: [StudyItem]
    /// 用量与估算费用。**可选**：手工编辑过的、或将来某个不记用量的产出路径
    /// 写出来的文件没有这一段，缺了不该让整份笔记读不出来
    var usage: StudyNotesUsage?

    init(
        sessionID: UUID,
        generatedAt: Date,
        model: String,
        items: [StudyItem],
        usage: StudyNotesUsage? = nil
    ) {
        self.sessionID = sessionID
        self.generatedAt = generatedAt
        self.model = model
        self.items = items
        self.usage = usage
    }

    /// 手写解码，理由和 `TranscriptSegment` 那边一样（见那边的长注释）：
    /// **合成的解码器对「有默认值但 JSON 缺键」的非可选属性不回落默认值**，
    /// 直接抛 `keyNotFound`。这份文件虽然是新格式、眼下不存在「旧文件」，
    /// 但加字段是迟早的事，而笔记读不出来的表现是「用户以为笔记没了」——
    /// 比转录读不出来更难被发现（转录没了列表会少一条，笔记没了只是区块空白）。
    ///
    /// 兜底范围的划法跟那边一致：**一直存在的字段仍然必需**（缺了说明文件
    /// 坏了，该抛出来），只有后加的、本来就可选的才 `decodeIfPresent`
    private enum CodingKeys: String, CodingKey {
        case sessionID, generatedAt, model, items, usage
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        model = try c.decode(String.self, forKey: .model)
        items = try c.decode([StudyItem].self, forKey: .items)
        usage = try c.decodeIfPresent(StudyNotesUsage.self, forKey: .usage)
    }
}
