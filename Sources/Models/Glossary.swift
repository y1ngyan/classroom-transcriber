import Foundation

/// 术语表条目。
///
/// 存在的理由：中英混合课堂只挂单个 zh-CN 模型（同时挂 zh-CN + en-US
/// 两路结果不会融合，各说各话，见 speechanalyzer-transcription-findings），
/// 于是英文术语会被按读音转写成拉丁字母——实测 "machine learning" 转成
/// "Machin learning"、"gradient descent" 转成 "gredion destent"。
/// 靠一轮 LLM 校正把这些词拉回来，术语表就是校正的锚点。
/// `Sendable`：`CoursePresets.all` 是 `static let`，Swift 6 下非 Sendable
/// 类型的全局常量会直接编译不过。所有存储属性都是值类型，承诺成立。
struct GlossaryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// 正确写法
    var term: String
    /// 已知的误转写形式。留空也能用（模型自己会判断），填了更准
    var aliases: [String]
    /// 释义或上下文，帮模型区分同名不同义的词
    var note: String

    init(id: UUID = UUID(), term: String, aliases: [String] = [], note: String = "") {
        self.id = id
        self.term = term
        self.aliases = aliases
        self.note = note
    }
}

/// 一处术语校正的前后对照。
///
/// 只给校正后的全文，用户没法判断该不该采纳——实测模型偶尔会把
/// 本来正确的词也「顺手改一下」，所以必须能看到到底动了哪里。
struct GlossaryCorrection: Identifiable, Equatable {
    let id = UUID()
    let segmentID: UUID
    /// `12:03` 形式，方便回看录像定位
    let timestamp: String
    let before: String
    let after: String
}

/// 校正产出：新片段数组 + 变化清单。
struct GlossaryOutcome {
    var segments: [TranscriptSegment]
    var corrections: [GlossaryCorrection]

    var changedCount: Int { corrections.count }
}

/// 首次启动时种进 `glossary.json` 的那一包词。
///
/// 内容搬去了 `CoursePresets.machineLearning`——默认词表只是「课程预设」里
/// 被标为 default 的那一个，没有独立的第二份数据，否则两边会漂移。
/// 这里留一层壳是因为 `GlossaryStore.load()` 按名字引它。
///
/// **aliases 只放「同一个词的错误拼写」，不要放中文译名。**
/// 把「梯度下降」写进 `gradient descent` 的 aliases，模型会把转录里
/// 本来正确的中文改写成英文——那不是校正，是破坏。中文怎么说就让它
/// 怎么说，术语表只管把转错的拉丁字母拉回来。
enum GlossaryDefaults {
    static var entries: [GlossaryEntry] { CoursePresets.default.entries }
}
