import Foundation
import Speech

/// 段落转录质量的三档判定。
///
/// 值的来源是识别器自己的逐字符置信度（`transcriptionConfidence`），
/// 不是文本统计启发式——2026-09-20 实测虚词密度方案会把正常口语
/// （虚词占比天然 40%+）误判成崩坏，而废掉了。识别器自己知道每个字
/// 有多可信，这个问题本来就不需要猜。
enum TranscriptGrade: String {
    /// 可信：置信度和准确转录一个水平
    case good
    /// 存疑：部分字符识别器自己也没把握
    case fair
    /// 不可信：大面积低置信，识别器处于「连蒙带猜」状态
    case poor

    var label: String {
        switch self {
        case .good: return "可信"
        case .fair: return "存疑"
        case .poor: return "不可信"
        }
    }
}

/// 逐字符置信度 → 段落质量档位。纯函数，无网络、无模型、无状态。
///
/// 分档依据（2026-09-20 实测，confprobe 逐字符验证）：
///
/// ```
///   合成语音（转录准确）  平均 0.962 · 低置信(<0.5)字符占比  3%（1/34）
///   录二崩坏·段一        平均 0.585 · 低置信占比          40%（19/47）
///   录二崩坏·段二        平均 0.570 · 低置信占比          44%（23/52）
/// ```
///
/// 好 0.96 对坏 0.57，中间隔着 0.4 的空档；低置信占比 3% 对 40%+，
/// 隔着一个数量级。两个统计量都用，因为它们回答的是不同的问题：
/// 平均值回答「整体把握多大」，低置信占比回答「有多少字是在蒙」——
/// 一段大部分字很有把握、但关键术语全在蒙的文本，平均值会偏好看，
/// 占比不会。
enum TranscriptQualityAssessor {

    /// 低置信阈值：confprobe 实测里，准确文本几乎全部字符 ≥0.9，
    /// 崩坏文本的蒙猜字符落在 0.5 以下。0.5 是两堆之间的空档
    static let lowConfidenceThreshold = 0.5

    /// good 下限 / poor 上限。实测好的 0.962、坏的 0.57–0.585，
    /// 分档线取空档的两端附近，给两边的波动都留出余地
    static let goodAverageFloor = 0.85
    static let poorAverageCeiling = 0.70
    /// 低置信占比的分档线，同理（实测 3% 对 40%+）
    static let goodLowRatioCeiling = 0.15
    static let poorLowRatioFloor = 0.30

    /// 按逐字符置信度分档。空数组返回 nil（没拿到置信度，不乱判）。
    static func grade(confidences: [Double]) -> TranscriptGrade? {
        guard !confidences.isEmpty else { return nil }
        let average = confidences.reduce(0, +) / Double(confidences.count)
        let lowRatio = Double(confidences.filter { $0 < lowConfidenceThreshold }.count)
            / Double(confidences.count)
        return grade(averageConfidence: average, lowConfidenceRatio: lowRatio)
    }

    /// 两个统计量都已知时的判定。拆出来是为了自检能直接喂实测数字，
    /// 不用为了造一个平均值去凑一串假字符置信度
    static func grade(averageConfidence average: Double, lowConfidenceRatio lowRatio: Double) -> TranscriptGrade {
        // poor 的两个条件是「或」：整体崩了当然不可信；整体还行但有
        // 三成字在蒙，同样不该被当成可信——那三成往往就是术语
        if average < poorAverageCeiling || lowRatio > poorLowRatioFloor {
            return .poor
        }
        if average >= goodAverageFloor && lowRatio <= goodLowRatioCeiling {
            return .good
        }
        return .fair
    }

    /// 从识别结果的 AttributedString 上抽逐字符置信度。
    ///
    /// 注意写法：必须 `attr[run.range].characters`，`run.characters`
    /// 编译不过（踩过）。标点等没有置信度属性的字符跳过——
    /// 它们不参与统计，也不该被当成「低置信」
    static func confidences(from text: AttributedString) -> [Double] {
        var result: [Double] = []
        for run in text.runs {
            guard let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
            else { continue }
            for _ in text[run.range].characters {
                result.append(confidence)
            }
        }
        return result
    }

    // MARK: - 自检

    /// 纯函数自检：喂「实测拿到的统计量」，验证分档逻辑。
    ///
    /// 为什么不拿音频文件跑：置信度来自识别器，测「识别器给不给置信度、
    /// 给得准不准」是 Apple 那边的事，而且需要音频文件、模型下载、
    /// 几十秒运行时间，不适合做随手跑的自检。这条链路里属于**我们**的
    /// 部分只有「置信度 → 档位」这一个纯函数，所以钉死它。
    /// 端到端验证走 `--transcribe-file`（它的输出现在带每段平均置信度）。
    static func selfTest() -> [String] {
        var lines: [String] = ["转录质量自评自检（置信度分档 · 数值来自 2026-09-20 confprobe 实测）"]
        var allPassed = true

        func check(_ name: String, average: Double, lowRatio: Double, expect: TranscriptGrade) {
            let got = grade(averageConfidence: average, lowConfidenceRatio: lowRatio)
            let ok = got == expect
            allPassed = allPassed && ok
            lines.append(String(
                format: "  %@ %@ → %@（期望 %@）· 平均 %.3f · 低置信占比 %.0f%%",
                ok ? "✅" : "❌", name, got.label, expect.label, average, lowRatio * 100
            ))
        }

        // 实测锚点：好与坏的真实数值，必须落在正确档位
        check("实测·合成语音（准确）", average: 0.962, lowRatio: 0.03, expect: .good)
        check("实测·录二崩坏段一", average: 0.585, lowRatio: 0.40, expect: .poor)
        check("实测·录二崩坏段二", average: 0.570, lowRatio: 0.44, expect: .poor)

        // 边界：分档线两侧各压一条，防止「调了一个数，边界悄悄移动」
        check("边界·good 下限压线", average: 0.85, lowRatio: 0.15, expect: .good)
        check("边界·good 下限之下", average: 0.84, lowRatio: 0.15, expect: .fair)
        check("边界·poor 平均压线", average: 0.70, lowRatio: 0.30, expect: .fair)
        check("边界·poor 平均之下", average: 0.69, lowRatio: 0.30, expect: .poor)

        // 「平均值好看但三成字在蒙」必须判 poor：崩坏段落里术语全在蒙时
        // 就是这种分布，平均值会被大量高置信虚词拉上去
        check("平均尚可但三成在蒙", average: 0.75, lowRatio: 0.35, expect: .poor)

        // 空输入：没拿到置信度时必须返回 nil，而不是默认某个档位
        do {
            let got = grade(confidences: [])
            let ok = got == nil
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") 空置信度数组 → nil（期望 nil）")
        }

        lines.append(allPassed ? "✅ 转录质量自评自检通过" : "❌ 转录质量自评自检未通过")
        return lines
    }
}
