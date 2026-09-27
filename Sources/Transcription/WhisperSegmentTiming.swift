import Foundation

/// whisper 段的原始时间戳（`whisper_full_get_segment_t0/t1`，单位 10ms）
/// → 段落的时间字段。
///
/// **为什么单独抽成一个类型**：C-4 扫过全项目「谁会造出反向段」，结论是
/// **没有一条代码会自己造**，唯一没有守卫的入口就是这里——whisper 给的
/// 两个数原样乘 10 落进字段，没有 `t1 ≥ t0` 判定。抽成纯函数之后，
/// 喂一个 `t1 < t0` 的桩就能验：转一趟 whisper 要加载 539MB 模型、跑十几秒，
/// 而这条判据关心的只是两个整数。
///
/// **为什么脏的一律落成零长，而不是把整段丢掉**：whisper 给坏的是**时间**，
/// `text` 是它同一趟认出来的东西，两件事。丢掉一个不可信的时间戳是对的，
/// 丢掉正文不是——转录的正文才是产品。零长段（`start == end`）在
/// `RecordingSession.absoluteRange` 那里是**空区间**，那是 C-4 定下并有自检
/// 钉住的语义，下游本来就处理得了；反向段不是。
enum WhisperSegmentTiming {

    /// 一对时间戳出了什么问题。**分档是为了让诊断能指认原因**——
    /// 「有个段坏了」和「whisper 给了个反的区间」在处理时是两条线索
    enum Reason: String, Equatable {
        /// `t1 < t0`：区间是反的
        case reversed
        /// `t0` 或 `t1` 为负：负数毫秒不是「早于开头」，是坏值
        case negative
    }

    /// 判定结果。`reason == nil` 表示干净
    struct Verdict: Equatable {
        var startMillis: Int
        var endMillis: Int
        var reason: Reason?

        var isDirty: Bool { reason != nil }
    }

    /// 纯判定：无 IO、无全局状态、同输入同输出。
    ///
    /// 脏的落成零长，**起点一律取 `t0`**（负数那支先夹到 0）。取 `t0` 不是
    /// 随手挑的：C-4 修 `absoluteRange` 时对反向段也是「把 `start` 原样留在
    /// `lowerBound` 上」，两处保持同一个选择，省得同一份脏数据在不同层
    /// 被摆到不同的位置上。
    ///
    /// 没有「非有限值」那一支：`t0`/`t1` 的类型是 `Int64`
    /// （`whisper_full_get_segment_t0` 的返回类型就是它），`Float.nan` 那种
    /// 值到不了这里——上游给的已经是整数。
    static func resolve(t0: Int64, t1: Int64) -> Verdict {
        let raw0 = Int(t0)
        let raw1 = Int(t1)

        if raw0 < 0 || raw1 < 0 {
            let point = max(0, raw0) * 10
            return Verdict(startMillis: point, endMillis: point, reason: .negative)
        }
        if raw1 < raw0 {
            let point = raw0 * 10
            return Verdict(startMillis: point, endMillis: point, reason: .reversed)
        }
        return Verdict(startMillis: raw0 * 10, endMillis: raw1 * 10, reason: nil)
    }

    /// 落字段前的**唯一出口**：判定 + 脏了就记一条诊断。返回的就是要写进
    /// `WhisperSegment` 的两个值。
    ///
    /// - Parameters:
    ///   - audio: 「哪条音频」。实时链路给窗口起点、文件链路给文件名——
    ///     两处都拿得到。不传的话这条诊断只能说「有个段坏了」，事后翻不回
    ///     是哪条录音的哪一窗
    ///   - segment: 这是这一窗里的第几段
    ///   - textLength: **只记长度，不记正文**。正文是用户内容，日志里绝不出现
    ///   - sink: 可注入是为了自检能拿一个临时目录当出口、再从盘上把那条诊断
    ///     读回来——断言「记了」比断言「返回值是脏的」强，前者验的是整条落盘路径
    static func apply(
        t0: Int64,
        t1: Int64,
        segment: Int32,
        audio: String,
        textLength: Int,
        sink: DiagnosticLogSink = DiagnosticLog.shared
    ) -> (startMillis: Int, endMillis: Int) {
        let verdict = resolve(t0: t0, t1: t1)
        guard let reason = verdict.reason else {
            return (verdict.startMillis, verdict.endMillis)
        }
        sink.log(.warn, .transcription, "whisper 段落时间戳非法，已按零长处理", fields: [
            .init("音频", audio.isEmpty ? "未标注" : audio),
            .init("段", Int(segment)),
            // 原样 t0/t1：诊断的全部价值在「原样」两个字上，转过一道手
            // 就说不清 whisper 到底给的是什么了
            .init("原样t0", Int(t0)),
            .init("原样t1", Int(t1)),
            .init("原因", reason.rawValue),
            .init("落成start", verdict.startMillis),
            .init("落成end", verdict.endMillis),
            .init("文本长度", textLength),
        ])
        return (verdict.startMillis, verdict.endMillis)
    }
}
