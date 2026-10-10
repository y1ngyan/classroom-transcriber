import Foundation

/// **这条转录是哪个模型产出的**——跟着片段走，写进会话存档（P11-1 目标 4）。
///
/// 为什么非有不可：课后重转从 medium 换成了 large-v3，从今天起同一个库里
/// 会同时躺着两种产物。没有这个字段的话，「这份转录准不准」就只能靠
/// 回忆或时间戳猜——而用户看到的是一份**看不出出处的文本**。
/// 这和 B-1 的「来源是数据属性」（`LessonQuestion.source`）是同一条思路：
/// 出处是数据，不是一句口头承诺。
///
/// 四个键就是派单点名的四样：模型文件名 / 上游 revision / 字节数 / 重转时间。
/// **字节数是当下 stat 到的真实大小**，不是清单里那个期望值——清单钉的是
/// 「那个 revision 下应该多大」，而这个字段回答的是「这次实际喂给 whisper 的
/// 是多大的一份」。两者对不上时（有人在下载之后动过文件），看这个数才发现得了
struct TranscriptionProvenance: Codable, Equatable {
    /// 模型文件名（`ggml-large-v3-q5_0.bin`）。反查是哪一档靠它
    var modelFile: String
    /// 上游 commit（`ModelPin.revision`）。**不是 `main`**——见 `ModelPin` 的注释
    var revision: String
    /// 重转时磁盘上那个模型的字节数
    var bytes: Int64
    /// 这次重转完成的时间
    var retranscribedAt: Date

    /// 界面上那行出处。句子里**不带「可能」「大概」**：这四个值全是
    /// 跑的时候抄下来的事实，不是推断
    var summary: String {
        "\(modelFile) · \(Self.shortRevision(revision))… · \(ModelAvailability.mbText(bytes)) · \(Self.stamp(retranscribedAt))"
    }

    /// 给用户看的那一档（命中的枚举档位）。认不出来返回 nil——**不猜**，
    /// 见 `RetranscribeEngine.parse` 的同一条理由
    var engine: RetranscribeEngine? {
        RetranscribeEngine.allCases.first { $0.fileName == modelFile }
    }

    private static func shortRevision(_ revision: String) -> String {
        String(revision.prefix(12))
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
