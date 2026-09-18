import Foundation

/// 术语表条目。
///
/// 存在的理由：中英混合课堂只挂单个 zh-CN 模型（同时挂 zh-CN + en-US
/// 两路结果不会融合，各说各话，见 speechanalyzer-transcription-findings），
/// 于是英文术语会被按读音转写成拉丁字母——实测 "machine learning" 转成
/// "Machin learning"、"gradient descent" 转成 "gredion destent"。
/// 靠一轮 LLM 校正把这些词拉回来，术语表就是校正的锚点。
struct GlossaryEntry: Identifiable, Codable, Equatable {
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

/// 首次启动时的默认术语表。
///
/// 种子取自实测里真实被转错的词，不是凭空编的教学大纲。
///
/// **aliases 只放「同一个词的错误拼写」，不要放中文译名。**
/// 把「梯度下降」写进 `gradient descent` 的 aliases，模型会把转录里
/// 本来正确的中文改写成英文——那不是校正，是破坏。中文怎么说就让它
/// 怎么说，术语表只管把转错的拉丁字母拉回来。
enum GlossaryDefaults {
    static let entries: [GlossaryEntry] = [
        GlossaryEntry(
            term: "machine learning",
            aliases: ["Machin learning", "machine lerning", "machin learning"],
            note: "机器学习"
        ),
        GlossaryEntry(
            term: "gradient descent",
            aliases: ["gredion destent", "gradient decent", "gradient desent"],
            note: "梯度下降"
        ),
        GlossaryEntry(
            term: "stochastic gradient descent",
            aliases: ["stochastic gradient decent", "stochastic gradient desent"],
            note: "随机梯度下降，缩写 SGD 也算正确写法"
        ),
        GlossaryEntry(
            term: "learning rate",
            aliases: ["learning reit", "lerning rate", "learning late"],
            note: "学习率，训练时的超参数"
        ),
        GlossaryEntry(
            term: "loss function",
            aliases: ["lost function", "loss funtion"],
            note: "损失函数"
        ),
        GlossaryEntry(
            term: "backpropagation",
            aliases: ["back propagation", "backpropogation", "back propagasion"],
            note: "反向传播"
        ),
        GlossaryEntry(
            term: "epoch",
            aliases: ["epok", "epochs"],
            note: "训练轮次；复数 epochs 视上下文可保留"
        ),
        GlossaryEntry(term: "MNIST", aliases: ["minist", "M NIST"], note: "手写数字数据集"),
    ]
}
