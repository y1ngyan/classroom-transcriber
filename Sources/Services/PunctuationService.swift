import Foundation

/// 补标点特有的失败。请求本身失败的情形由 `ModelTextError` 直接抛出。
enum PunctuationError: LocalizedError {
    case noSegments

    var errorDescription: String? {
        switch self {
        case .noSegments: return "还没有足够长的转录内容，无法补标点"
        }
    }
}

/// 输出校验的判定结果。枚举而不仅是 Bool：自检要断言「是因为什么被拒的」，
/// 调用方也能把失败原因透给用户，而不是一句含糊的「失败」。
enum PunctuationValidation: Equatable {
    case ok
    /// 输入是空的（或剥掉标点后是空的）
    case emptyInput
    /// 模型返回是空的（或剥掉标点后是空的）
    case emptyOutput
    /// 剥掉标点后长度差超过容忍——模型加料或吞字的指纹
    case lengthDrift
    /// 剥掉标点后逐字比对不一致——模型改了内容（大小写、错别字、加字、加空格）
    case modified
}

/// 给无标点的转录文本补标点（DeepSeek）。
///
/// **为什么需要这一步**：SpeechTranscriber 原生不产出标点——它的
/// TranscriptionOption 只有 etiquetteReplacements 一个值，没有 punctuation
/// 选项（那是 DictationTranscriber 的，而听写引擎实测对低电平长音频会
/// 整段放弃，已被淘汰）。所以实时/文件转录出来的长段都是连续无标点文字，
/// 这是引擎能力边界，只能靠事后补。
///
/// **为什么必须内建校验**：模型有几个可预测的失效模式（压力测试抓出来的）——
/// 擅自纠正英文大小写（python → Python）、给数字乱加分隔（314 → 3 14）、
/// 极短输入时把任务当对话回应。所以每一段的返回都要过 `validate`：
/// 剥掉标点后必须和原文逐字一致才落地，不一致就回退原文。
/// 宁可这一段没标点，也不能让模型经手过的、改过的文本混进转录——
/// 转录下游挂着事实核查，核查的根据必须是识别器真实输出（加术语校正），
/// 不能是模型自由发挥过的版本。
enum PunctuationService {

    /// 短于这个长度（剥掉标点后）的段不送模型。
    ///
    /// 实测：极短输入会触发模型的对话本能——输入「好」，它回
    /// 「好的，我准备好了。请发送需要补全标点的文本。」。
    /// 校验能挡住这种返回，但白烧一次请求；而且短段本来就是
    /// 可读的，补不补标点无所谓。
    static let minInputLength = 8

    /// 长度差容忍：剥掉标点后，输出比输入长/短超过这个比例直接拒。
    ///
    /// 注意它和逐字比对是冗余的——逐字一致必然等长。留它是因为它是
    /// 更便宜的第一道闸，而且能给出一个和「改了字」不同的诊断：
    /// 超长通常是模型把任务当对话、开始自由发挥（见 minInputLength）。
    static let maxLengthDrift = 0.12

    // MARK: - 校验（纯函数）

    /// 剥掉所有 Unicode 标点，得到参与比对的「字骨架」。
    ///
    /// `CharacterSet.punctuationCharacters` 覆盖整个 Unicode P* 类别，
    /// 全角半角都在里面——所以「模型把半角逗号换成全角」不会被误判成
    /// 改动，这正是剥掉标点再比对的用意。
    ///
    /// **空白刻意保留、参与比对。** 规格原文是「去掉标点和空白后比对」，
    /// 但那样挡不住实测到的失效模式「314 → 3 14」：剥掉空白后两边都是
    /// "314"，恰好相等，错误落地。保留空白后，模型乱加的任何空格都会
    /// 让比对失败、回退原文——加空格本来就越过了「只加标点」的授权。
    /// 代价是模型在英文词两侧「规范化」空格也会被拒，那种段保持原文，
    /// 用户没有损失。
    static func skeleton(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 校验模型返回是否守住了「只加标点」。
    static func validate(input: String, output: String) -> PunctuationValidation {
        let before = skeleton(input)
        let after = skeleton(output)

        guard !before.isEmpty else { return .emptyInput }
        guard !after.isEmpty else { return .emptyOutput }

        let drift = abs(after.count - before.count)
        let tolerance = max(2, Int((Double(before.count) * maxLengthDrift).rounded(.up)))
        guard drift <= tolerance else { return .lengthDrift }

        return before == after ? .ok : .modified
    }

    // MARK: - 批量补标点

    /// 对整场转录补标点。一次请求批量送所有段，按段校验、按段落地。
    ///
    /// 返回的 segments 保持 id / 时间戳不变（同 applyCorrections 的约束：
    /// 核查结果按 segmentID 关联）。每段三种结局：校验通过 → 换成补过标点
    /// 的文本；校验失败 / 模型吞行 → 保持原文；太短 → 根本没送。
    static func punctuate(_ segments: [TranscriptSegment]) async throws -> PunctuationOutcome {
        // 空段和短段不送：空段白占 token 还会让行号对不齐，
        // 短段触发模型的对话本能（见 minInputLength）
        let targetOffsets = segments.indices.filter {
            skeleton(segments[$0].text).count >= minInputLength
        }
        guard !targetOffsets.isEmpty else { throw PunctuationError.noSegments }

        let targets = targetOffsets.map { segments[$0] }
        let skippedShort = segments.count - targets.count

        let systemPrompt = """
        你是一台标点补全器。任务：给课堂转录文本补上标点符号。

        硬约束（违反任何一条都会导致整段被丢弃）：
        - 只添加标点符号。不得修改、删除、重排任何原有字符。
        - 英文的大小写必须原样保留（python 就是 python，不许改成 Python）。
        - 数字必须原样保留，不许加分隔、不许改写（314 不许写成 3 14）。
        - 不许纠正错别字，不许润色，不许翻译，不许补全你认为缺了的内容。
        - 这不是对话：不要回应文本的内容，不要打招呼，不要解释，
          只输出补全标点后的文本本身。

        输入的每一行以 `#序号 ` 开头。输出的每一行也必须以相同的 `#序号 ` 开头，
        序号必须与输入完全一致，不许增删、合并或调换行。
        """

        let response = try await ModelText.deepSeekChat(
            // render 复用术语校正那个 `#N 文本` 格式——刻意不带时间戳，
            // 让模型没机会改坏时间轴（理由见 GlossaryService.render）
            systemPrompt: systemPrompt,
            userPrompt: GlossaryService.render(targets),
            temperature: 0,
            timeout: 180
        )

        // parse 同样是术语校正那个宽容解析器：解析不出来的行不收，
        // 缺行就保留原文——宁可少补，不能错位
        let parsed = GlossaryService.parse(response, expectedCount: targets.count)

        var result = segments
        var applied = 0
        var rejected = 0

        for (position, offset) in targetOffsets.enumerated() {
            guard let text = parsed[position] else { continue }
            let before = segments[offset].text
            guard text != before else { continue }

            guard validate(input: before, output: text) == .ok else {
                rejected += 1
                continue
            }
            result[offset].text = text
            applied += 1
        }

        return PunctuationOutcome(
            segments: result,
            applied: applied,
            skippedShort: skippedShort,
            rejected: rejected
        )
    }

    // MARK: - 自检

    /// `--punct-selftest`。纯本地：校验是纯函数，切分器也是纯函数，
    /// **不发任何网络请求**——补标点本身不进自检。
    static func selfTest() -> [String] {
        var lines: [String] = ["补标点自检（校验纯函数 + 切分器标点优先，不联网）"]
        var allPassed = true

        // MARK: 校验函数

        @discardableResult
        func check(
            _ name: String,
            input: String,
            output: String,
            expect: PunctuationValidation
        ) -> Bool {
            let actual = validate(input: input, output: output)
            let ok = actual == expect
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") \(name)：期望 \(expect)，实际 \(actual)")
            return ok
        }

        lines.append("输出校验：")
        check(
            "纯标点差异 → 通过",
            input: "今天我们讲梯度下降它是一种优化算法",
            output: "今天我们讲梯度下降，它是一种优化算法。",
            expect: .ok
        )
        check(
            "全角半角标点转换 → 通过（标点不参与比对）",
            input: "结果是99.5%,对吗",
            output: "结果是99.5%，对吗。",
            expect: .ok
        )
        check(
            "改了英文大小写 → 拒绝",
            input: "用 python 写代码很简单大家试试",
            output: "用 Python 写代码很简单，大家试试。",
            expect: .modified
        )
        check(
            "加了字 → 拒绝",
            input: "今天我们讲梯度下降",
            output: "今天我们讲梯度下降算法。",
            expect: .modified
        )
        check(
            "数字被加了分隔 → 拒绝（空白参与比对就是为了挡这个）",
            input: "圆周率约等于31415926大家记住",
            output: "圆周率约等于 3 1415926，大家记住。",
            expect: .modified
        )
        check(
            "模型自由发挥加料 → 按长度漂移拒绝",
            input: "今天我们讲梯度下降",
            output: "今天我们讲梯度下降，它是一种非常重要的优化算法，大家一定要掌握。",
            expect: .lengthDrift
        )
        check(
            "空输入 → 拒绝",
            input: "",
            output: "。",
            expect: .emptyInput
        )
        check(
            "空输出 → 拒绝",
            input: "今天我们讲梯度下降",
            output: "",
            expect: .emptyOutput
        )

        // MARK: 切分器：标点优先

        lines.append("切分器（标点优先）：")

        func segment(_ text: String) -> TranscriptSegment {
            TranscriptSegment(
                text: text, isFinal: true,
                startTimeMillis: 0, endTimeMillis: 10_000,
                languages: ["zh-CN"]
            )
        }

        @discardableResult
        func run(
            _ name: String,
            _ text: String,
            expectPieces: Int? = nil,
            expectMinPieces: Int? = nil,
            cutsOnlyAtPunctuation: Bool = false
        ) -> [TranscriptSegment] {
            let pieces = TranscriptSplitter.split(segment(text))
            var failures: [String] = []
            if let expectPieces, pieces.count != expectPieces {
                failures.append("期望 \(expectPieces) 段，实际 \(pieces.count) 段")
            }
            if let expectMinPieces, pieces.count < expectMinPieces {
                failures.append("期望至少 \(expectMinPieces) 段，实际 \(pieces.count) 段")
            }
            if pieces.map(\.text).joined() != text {
                failures.append("拼接后有字符丢失或改动")
            }
            // 「严格按标点切」的判定：每个切点的前一个字符必须是标点。
            // 语气词/话语标记造成的切点前一个字符是汉字，这一条就能抓住
            if cutsOnlyAtPunctuation {
                let chars = Array(text)
                var pos = 0
                for piece in pieces.dropLast() {
                    pos += piece.text.count
                    let before = chars[pos - 1]
                    if !CharacterSet.punctuationCharacters.contains(String(before).unicodeScalars.first!) {
                        failures.append("切点 \(pos) 落在「\(before)」后，不是标点边界")
                    }
                }
            }

            let ok = failures.isEmpty
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") \(name)(\(text.count) 字 → \(pieces.count) 段)"
                + (ok ? "" : "：\(failures.joined(separator: "；"))"))
            for piece in pieces {
                lines.append("      \(piece.text)")
            }
            return pieces
        }

        // 「对吧」在句子中间。旧的启发式会被确认式短语命中、从句子中间砍开
        // （「老师问大家这个公式对吧 / 是怎么推导出来的。」）；带标点时必须
        // 只认标点，整句保留
        run(
            "带标点 + 句中确认式短语（启发式不许插手）",
            "老师问大家这个公式对吧是怎么推导出来的。",
            expectPieces: 1,
            cutsOnlyAtPunctuation: true
        )

        // 带标点的长段：所有切点都在标点上，句中的「呢」「吧」不产生切点。
        // 逗号是次级边界，前段够长就会断（「解决这个问题要先构造损失函数，」
        // 14 字 ≥ minClauseLength）——所以是 4 段不是 3 段
        run(
            "带标点长段（严格按标点切）",
            "我们来看这个例子呢它说的是一个二分类问题。解决这个问题要先构造损失函数，然后用梯度下降去优化它。大家现在应该明白了吧。",
            expectPieces: 4,
            cutsOnlyAtPunctuation: true
        )

        // 完全无标点：退回启发式兜底，这条路不能因为标点优先而被堵死
        run(
            "无标点长段（退回启发式）",
            "比如生活可能一点参加据我们是不为例了我们到年底的时候啊我觉得我会进行这个就生活就是就是一度拖费",
            expectMinPieces: 2
        )

        lines.append(allPassed ? "全部通过 ✅" : "存在失败用例 ❌")
        return lines
    }
}

/// 一轮补标点的结果汇总。每段的去向都在这里有个数，
/// UI 照实报给用户——「校验失败回退」不是耻辱，是防线在工作。
struct PunctuationOutcome {
    var segments: [TranscriptSegment]
    /// 校验通过、换成补过标点文本的段数
    var applied: Int
    /// 太短没送模型的段数
    var skippedShort: Int
    /// 模型返回了但没通过校验、回退原文的段数
    var rejected: Int
}
