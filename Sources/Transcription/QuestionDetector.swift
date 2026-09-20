import Foundation

/// 提问检测灵敏度。词表和判定逻辑移植自水课帮（QuestionRules.kt / QuestionDetector.kt），
/// 参数与词表照搬，不自行「优化」——那张表是人家在真实课堂上迭代出来的，
/// 每删一个词都是拿误报率换的。
///
/// 判定思路（宁少勿滥）：强疑问结构直接确认；弱疑问词需要第二证据
/// （句末语气 / 点名短语 / 位于句首句末）且没被讲课框架词否决；
/// 点名祈使是 L1 预警；自问自答（疑问锚点后紧跟解答引导词）压制。
enum QuestionSensitivity: String, CaseIterable, Identifiable {
    case high
    case normal
    case low
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "高"
        case .normal: return "标准（推荐）"
        case .low: return "低"
        case .off: return "关闭"
        }
    }

    var hint: String {
        switch self {
        case .high: return "弱疑问词也算提问，软祈使也算点名——更全，误报更多"
        case .normal: return "强疑问结构和句末「吗」算提问，弱疑问词需要旁证"
        case .low: return "只有最硬的疑问结构才算，几乎不误报"
        case .off: return "不检测课堂提问"
        }
    }

    /// 认不出来的配置值一律回落 NORMAL：配置里躺着笔误时，用户该拿到的
    /// 是默认行为，而不是「静默地一个提问都不检测」——后者从界面上看不出来。
    static func of(_ id: String?) -> QuestionSensitivity {
        guard let id, let value = QuestionSensitivity(rawValue: id) else { return .normal }
        return value
    }
}

/// 提问检测结果。
///
/// level 1 = 可能被提问（点名 / 祈使预警，话还没问完）；
/// level 2 = 确认的提问（可以回溯原句）。
struct QuestionDetection: Equatable {
    let level: Int
    /// 命中的规则词，排查误报时第一眼要看的东西
    let hitKeyword: String?
    let rawSentence: String
    /// 剥掉课堂口头禅和称呼之后的问题本体
    let coreQuestion: String
}

/// 轻量规则提问检测器：纯本地、无模型、无网络。
///
/// 只负责「这一句是不是面向全班的提问」。跨句的自问自答（上一句问、下一句
/// 老师自己答）不在这里做——那需要延迟确认门，超出一句话的视野。
struct QuestionDetector {

    var sensitivity: QuestionSensitivity = .normal

    func detect(_ rawInput: String) -> QuestionDetection? {
        guard sensitivity != .off else { return nil }
        let raw = TextNorm.normalize(rawInput)
        guard !raw.isEmpty else { return nil }
        let english = TextNorm.isMostlyEnglish(raw)
        if tooShort(raw, english: english) { return nil }

        return english ? detectEn(raw) : detectZh(raw)
    }

    // MARK: - 中文

    private func detectZh(_ raw: String) -> QuestionDetection? {
        let hasQuestionMark = raw.contains("?")
        let strong = Rules.zhStrong.first { raw.contains($0) }
        let strongSoft = Rules.zhStrongSoft.first { raw.contains($0) }
        let weak = Rules.zhWeak.first { raw.contains($0) }
        let inLecture = Rules.zhLecture.contains { raw.contains($0) }
        let callStrong = Rules.zhCallStrong.first { raw.contains($0) }
        let callWeak = Rules.zhCallWeak.first { raw.contains($0) }

        // 自问自答：疑问结构之后紧跟解答引导词、且句末不是问号 → 老师在自己讲解
        let anchor = strong ?? strongSoft
        let selfAnswered = anchor != nil && !hasQuestionMark && isSelfAnswered(raw, anchor: anchor!)

        let body = raw.trimmingTrailingCharacters(in: [".", "。", "!", "！", ",", "，", "?", " ", "呢", "吧", "吗"])
        let lastChar = raw.trimmingTrailingCharacters(in: [".", "。", "!", "！", ",", "，", " "]).last.map(String.init)
        let tailMa = lastChar == Rules.zhTailMa
        let tailSoft = lastChar != nil && Rules.zhTailSoft.contains(lastChar!)

        // 旁证1：特定弱词（有没有/是不是…）位于句首（容许 1 个字发语词）
        var weakAtHead = false
        var weakAtTail = false
        if let weak, let range = raw.range(of: weak) {
            let head = raw.distance(from: raw.startIndex, to: range.lowerBound)
            let weakLen = weak.count
            weakAtHead = Rules.zhWeakHeadEligible.contains(weak) && head <= 1
            // 旁证2：弱疑问词落在句末（"结果等于多少""你选哪个"类）
            weakAtTail = body.count - (head + weakLen) <= 3
        }
        let weakCorroborated = !inLecture && !selfAnswered && weak != nil
            && (tailSoft || callStrong != nil || weakAtHead || weakAtTail)
        // 自问自答时强疑问结构同样不成立（带问号的真问句除外）
        let strongHolds = !selfAnswered

        let confirmed: Bool
        switch sensitivity {
        case .high:
            confirmed = hasQuestionMark || tailMa
                || (strongHolds && (strong != nil || strongSoft != nil || weak != nil))
                || callStrong != nil
        case .normal:
            confirmed = hasQuestionMark || tailMa
                || (strongHolds && (strong != nil || strongSoft != nil))
                || weakCorroborated
        case .low:
            confirmed = hasQuestionMark || tailMa || (strongHolds && strong != nil)
        case .off:
            confirmed = false
        }

        let core = extractZhCore(raw)
        if confirmed {
            return QuestionDetection(
                level: 2,
                hitKeyword: strong ?? strongSoft ?? weak ?? callStrong ?? (tailMa ? "吗" : "?"),
                rawSentence: raw,
                coreQuestion: core.isEmpty ? raw : core
            )
        }
        // L1 点名预警：硬点名短语任意档可用；软祈使仅 HIGH
        if let callStrong {
            return l1(callStrong, raw: raw, core: core)
        }
        if let callWeak, sensitivity == .high {
            return l1(callWeak, raw: raw, core: core)
        }
        return nil
    }

    /// 疑问锚点之后（至少隔一个字）是否出现解答引导词
    private func isSelfAnswered(_ raw: String, anchor: String) -> Bool {
        guard let anchorRange = raw.range(of: anchor) else { return false }
        let after = anchorRange.upperBound
        return Rules.zhAnswerCue.contains { cue in
            guard let range = raw.range(of: cue, range: after..<raw.endIndex) else { return false }
            return range.lowerBound > after
        }
    }

    private func l1(_ hit: String, raw: String, core: String) -> QuestionDetection {
        QuestionDetection(
            level: 1,
            hitKeyword: hit,
            rawSentence: raw,
            coreQuestion: core.isEmpty ? raw : core
        )
    }

    private func extractZhCore(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
            .trimmingTrailingCharacters(in: ["?", "？", ".", "。", "!", "！", ",", "，"])
        // 反复剥前缀：口头禅会叠着出现（「那么，请这位同学…」）
        var changed = true
        while changed {
            changed = false
            for prefix in Rules.zhPrefixStrip {
                let cleaned = prefix.trimmingTrailingCharacters(in: [",", "，"])
                if s.hasPrefix(cleaned) {
                    s = String(s.dropFirst(cleaned.count))
                        .trimmingLeadingCharacters(in: [" ", ",", "，", "、", ":"])
                        .trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        // 剥后缀，但不能剥到低于噪声阈值——剥完只剩两三个字的东西不是问题了
        var ended = true
        while ended {
            ended = false
            for suffix in Rules.zhSuffixStrip {
                if s.hasSuffix(suffix), s.count - suffix.count >= Rules.zhMinLen {
                    s = String(s.dropLast(suffix.count))
                        .trimmingTrailingCharacters(in: [" ", ",", "，"])
                    ended = true
                }
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 英文

    private func detectEn(_ raw: String) -> QuestionDetection? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let hasQuestionMark = raw.contains("?")
        let words = lower.components(separatedBy: Rules.enWordSeparator.inverted)
            .filter { !$0.isEmpty }
        guard let firstWord = words.first else { return nil }

        let whInside = Rules.enWH.first { words.contains($0) }
        let whAtStart = Rules.enWH.contains(firstWord)
        let auxInversion = Rules.enAux.contains(firstWord)
        let inLecture = Rules.enLecture.contains { lower.contains($0) }
        let callStrong = Rules.enCallStrong.first { lower.contains($0) }
        let callWeak = Rules.enCallWeak.first { lower.contains($0) }

        let confirmed: Bool
        switch sensitivity {
        case .high:
            confirmed = hasQuestionMark || whInside != nil || auxInversion || callStrong != nil
        // NORMAL/LOW：句中 Wh 词但属于讲课陈述（this is what…）不判
        case .normal, .low:
            confirmed = hasQuestionMark || whAtStart || auxInversion
                || (!inLecture && whInside != nil && hasQuestionMark)
        case .off:
            confirmed = false
        }

        let core = extractEnCore(raw)
        if confirmed {
            let keyword: String?
            if whAtStart || whInside != nil {
                keyword = whInside ?? firstWord
            } else if auxInversion {
                keyword = firstWord
            } else {
                keyword = callStrong
            }
            return QuestionDetection(
                level: 2,
                hitKeyword: keyword,
                rawSentence: raw,
                coreQuestion: core.isEmpty ? raw : core
            )
        }
        if let callStrong {
            return l1(callStrong, raw: raw, core: core)
        }
        if let callWeak, sensitivity == .high {
            return l1(callWeak, raw: raw, core: core)
        }
        return nil
    }

    private func extractEnCore(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
            .trimmingTrailingCharacters(in: ["?", ".", "!", ","])
        let lower = s.lowercased()
        for prefix in Rules.enPrefixStrip where lower.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
                .trimmingLeadingCharacters(in: [" ", ","])
            s = s.prefix(1).uppercased() + s.dropFirst()
            break
        }
        for suffix in Rules.enSuffixStrip where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func tooShort(_ raw: String, english: Bool) -> Bool {
        if english {
            return raw.split(whereSeparator: { $0.isWhitespace }).count < Rules.enMinWords
        }
        // 只数非标点非空白的字。和 Kotlin 的 \p{Punct} 对齐——ASCII 标点，
        // 全角标点在归一化那一步已经折成半角了
        let meaningful = raw.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
        }
        return meaningful.count < Rules.zhMinLen
    }

    // MARK: - 自检

    /// 离线自检：纯规则计算，不依赖任何设备状态。
    ///
    /// 要防的是移植走样——词表抄漏一条、`raw.range(of:)` 的边界算错一位，
    /// 检测器不会报错，只会从此多报或少报某一类提问，而课堂上没人会去
    /// 数「这节课是不是少标了一个」。所以把每一类判定都钉一条用例在这里。
    static func selfTest() -> [String] {
        var lines: [String] = ["提问检测自检 · 灵敏度 normal（另测 high/low 差异档）"]
        var allPassed = true

        func check(_ name: String, _ sentence: String, expect: Int?, at level: QuestionSensitivity = .normal) {
            let hit = QuestionDetector(sensitivity: level).detect(sentence)
            let got = hit?.level
            let ok = got == expect
            allPassed = allPassed && ok
            let detail = hit.map { "L\($0.level) 命中「\($0.hitKeyword ?? "-")」· 核心「\($0.coreQuestion)」" } ?? "未命中"
            lines.append("  \(ok ? "✅" : "❌") \(name)：\(detail)（期望 \(expect.map { "L\($0)" } ?? "不命中")）")
        }

        // 强疑问结构：任意灵敏度都该判 L2
        check("强疑问结构", "什么是梯度下降", expect: 2)
        check("强疑问结构（low 档也判）", "为什么会过拟合呢", expect: 2, at: .low)
        // 次强结构「如何」：normal 判、low 不判
        check("次强结构如何", "如何选择学习率", expect: 2)
        check("次强结构如何（low 档不判）", "如何选择学习率", expect: nil, at: .low)
        // 弱疑问词：单独不判，要有第二证据
        // （「什么东西」落在句末本身就是旁证，不算「无旁证」——这是规则表的设计，
        //   所以无旁证的用例得让弱词待在句子中间）
        check("弱词无旁证不判", "这件事怎么处理是一个问题", expect: nil)
        check("弱词加句末语气词", "这个结果对多少呢", expect: 2)
        check("弱词位于句末", "最后的结果等于多少", expect: 2)
        // 句末「吗」直接 L2
        check("句末吗", "大家都听懂了吗", expect: 2)
        // 讲课框架词否决弱信号
        check("讲课框架否决弱词", "下面我们看看这个定理有什么用", expect: nil)
        // 自问自答压制
        check("自问自答压制", "什么是过拟合，就是模型把噪声也学进去了", expect: nil)
        check("自问自答带问号不压制", "什么是过拟合？就是模型把噪声也学进去了", expect: 2)
        // 点名：句中带强疑问词（哪位）的点名按 L2 确认问题处理；
        // 不带疑问词的纯祈使才是 L1 预警。软祈使仅 high 档判
        check("点名带强疑问词", "哪位同学来回答一下这个问题", expect: 2)
        check("硬点名", "请你来回答一下这个问题", expect: 1)
        check("弱词加硬点名旁证", "谁能复述一下这个定义呢", expect: 2)
        check("软祈使仅 high 判", "找一个同学谈谈你的看法", expect: 1, at: .high)
        check("软祈使 normal 档不判", "找一个同学谈谈你的看法", expect: nil)
        // 英文
        check("英文句首 Wh", "What is gradient descent", expect: 2)
        check("英文助动词倒装", "Can you see the result on the screen", expect: 2)
        check("英文讲课陈述否决", "This is what we call overfitting in machine learning", expect: nil)
        // 长度噪声
        check("太短不判", "什么", expect: nil)
        // 灵敏度 off
        check("off 档全不判", "什么是梯度下降", expect: nil, at: .off)

        // 核心问题提取：口头禅前缀和语气后缀要剥掉
        do {
            let hit = QuestionDetector(sensitivity: .normal).detect("那么，请这位同学回答一下，梯度下降为什么能收敛呢")
            let core = hit?.coreQuestion ?? ""
            let ok = hit != nil && !core.hasPrefix("那么") && !core.hasPrefix("请") && !core.hasSuffix("呢")
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") 核心问题剥口头禅：「\(core)」")
        }

        lines.append(allPassed ? "✅ 提问检测自检通过" : "❌ 提问检测自检未通过")
        return lines
    }
}

/// 文本归一化：全半角、空白、标点统一。不做语义改写。
private enum TextNorm {

    static func normalize(_ input: String) -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let mapped = input.map { ch -> Character in
            switch ch {
            case "？": return "?"
            case "！": return "!"
            case "，": return ","
            case "。": return "."
            case "：": return ":"
            case "；": return ";"
            case "（": return "("
            case "）": return ")"
            case "【": return "["
            case "】": return "]"
            case "“", "”": return "\""
            case "‘", "’": return "'"
            default: return ch
            }
        }
        return String(mapped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 是否主要由 ASCII（英文/数字）构成，用于选择中英规则。
    /// 阈值 0.6：中英混合的句子按字符占比归到一边，而不是两边规则都跑。
    static func isMostlyEnglish(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        let asciiLetters = text.unicodeScalars.filter { $0.value >= 65 && $0.value <= 122 }
        return Double(asciiLetters.count) / Double(letters.count) > 0.6
    }
}

/// 规则词表。逐条照搬 QuestionRules.kt，注释也只写「为什么是这样分组」。
private enum Rules {

    // ---- 中文：核心强疑问结构（最硬，LOW/NORMAL/HIGH 均判 L2） ----
    static let zhStrong = [
        "什么是", "什么叫", "叫什么", "是什么", "为什么", "为何", "为啥",
        "怎么会", "怎么办", "怎样",
        "是谁", "哪位", "哪里", "哪儿", "哪个", "哪些", "哪一",
        "什么样", "几点", "多大",
    ]

    // ---- 中文：次强结构（NORMAL/HIGH 判 L2，LOW 不判；"如何"也常用于讲解引导） ----
    static let zhStrongSoft = ["如何"]

    // ---- 中文：弱疑问词（单独不判，需第二证据；讲课陈述高频，务必保守） ----
    static let zhWeak = [
        "什么", "怎么", "谁", "哪", "多少", "几个",
        "是否", "能否", "能不能", "可不可以", "是不是", "有没有",
        "对不对", "好不好", "区别",
    ]

    // ---- 弱词中只有这些"位于句首"才像面向全班提问 ----
    static let zhWeakHeadEligible: Set<String> = [
        "是否", "能否", "能不能", "可不可以", "是不是", "有没有",
    ]

    // ---- 中文：句末强 / 弱语气词 ----
    static let zhTailMa = "吗"
    static let zhTailSoft = ["呢", "吧"]

    // ---- 中文：讲课/陈述框架词，命中则弱疑问词不成立（不影响强信号） ----
    static let zhLecture = [
        "也就是说", "这就是", "所谓", "指的是", "是什么意思",
        "我们今天", "下面我们", "下面", "接下来", "上节课", "本节课", "这一节", "本章", "这章",
        "区别在于", "分为", "分别是", "主要有", "包括以下",
        "大家可以", "我们知道", "都知道", "换句话说", "简单来说", "总的来说",
        "我来", "给大家", "我们先", "我们再", "刚才讲", "前面讲", "之前讲",
        "如图", "可以看到", "注意看",
    ]

    // ---- 中文：自问自答的"解答引导词" ----
    // 强疑问结构之后若出现这些词（先抛问题、紧接着自己给答案），属于自问自答式讲解
    static let zhAnswerCue = [
        "就是", "是指", "指的是", "所谓", "也就是", "其实就是", "其实是",
        "它是", "这是", "即是", "即为", "定义为", "称之为", "被称为", "被称作",
        "说的是", "讲的是", "意思是", "答案是", "我们把它",
    ]

    // ---- 中文：硬点名/祈使短语（明确要求学生作答，NORMAL 即判 L1） ----
    static let zhCallStrong = [
        "回答一下", "回答下", "来回答", "请回答", "你来回答", "起来回答", "举手回答",
        "哪位同学", "哪个同学", "谁来", "谁能", "谁说", "你来", "你来说",
        "站起来说", "起来说", "我点个同学", "点个同学", "随机点",
    ]

    // ---- 中文：软祈使（老师也常对自己说，仅 HIGH 档判 L1） ----
    static let zhCallWeak = [
        "说一下", "说一说", "讲一下", "讲一讲", "解释一下", "解释下",
        "介绍一下", "谈谈", "谈一谈", "复述", "描述一下", "给大家讲", "给大家说",
    ]

    // ---- 中文：剥除的前缀（课堂口头禅/称呼） ----
    static let zhPrefixStrip = [
        "那么", "那个", "来,", "来,", "好,", "好", "嗯", "呃", "这个", "就是说",
        "请你", "请", "你", "这位同学", "这名同学", "那位同学", "哪位同学来",
        "哪位同学", "谁来", "你来", "我想让你", "大家想一想,", "大家想想,",
    ]

    // ---- 中文：剥除的后缀 ----
    static let zhSuffixStrip = [
        "一下", "好不好", "好吗", "行吗", "行不", "啊", "呀", "呢", "吧", "嘛", "哈",
    ]

    // ---- 英文 ----
    static let enWH = ["what", "why", "how", "when", "where", "which", "who", "whom", "whose"]
    static let enAux = [
        "do", "does", "did", "is", "are", "was", "were", "am", "can", "could",
        "would", "should", "shall", "will", "may", "might", "must", "have", "has", "had",
    ]
    static let enCallStrong = [
        "who can", "anyone", "anybody", "could you", "can you", "would you",
        "please answer", "answer the question",
    ]
    static let enCallWeak = ["explain", "describe", "tell me"]
    static let enLecture = [
        "this is what", "that is what", "we know what", "we will", "i will",
        "let us", "let's", "as we", "which means", "that is why",
    ]
    static let enPrefixStrip = [
        "please", "ok", "okay", "well", "now", "so", "i want you to",
        "could you", "would you", "can you", "can anyone",
    ]
    static let enSuffixStrip = ["please", "ok", "okay"]

    /// 英文分词：a-z 和撇号是词内字符，其余都算分隔
    static let enWordSeparator = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz'")

    // 最短长度阈值（低于则视为噪声，不提醒）
    static let zhMinLen = 4
    static let enMinWords = 3
}

private extension String {
    /// 去掉**尾部**属于集合的字符。Swift 标准库只有 CharacterSet 版本，
    /// 而中文语气词放不进 CharacterSet 的语义里（它是按 Unicode 类别来的），
    /// 所以按字符串集合自己剥。
    func trimmingTrailingCharacters(in set: [String]) -> String {
        var s = self
        while let last = s.last, set.contains(String(last)) {
            s.removeLast()
        }
        return s
    }

    func trimmingLeadingCharacters(in set: [String]) -> String {
        var s = self
        while let first = s.first, set.contains(String(first)) {
            s.removeFirst()
        }
        return s
    }
}
