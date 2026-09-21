import Foundation

/// 转录段的语义切分器。纯函数,无状态,不依赖网络和模型。
///
/// **为什么是派生数据而不是改 segments 本身**:Apple 的 SpeechTranscriber
/// 只在长静音处切段,课堂连续说话十几秒会出一整段无标点文字——这是
/// 分段粒度问题,不是识别错误。但 segments 下游挂着一串按「段」工作的
/// 模块(ClaimExtractor 抽句核查、NotesService 拼全文、applyCorrections
/// 按 id 回写、提问检测打标),它们都不需要更细的段。所以切分只在
/// 展示层做:segments 原样保留,这里把一段派生成若干子段供显示和复制。
///
/// **为什么长度只当兜底**:按字数硬切会把「机器学习」切成「机器」和
/// 「学习」,断错的比一坨更难读。所以切点只取语义边界(标点、句末
/// 语气词、话语标记、确认式短语),长度上限只负责「太长了必须在最近
/// 的语义边界收一刀」;整段找不到语义边界就原样返回——切不动不硬切。
enum TranscriptSplitter {

    // MARK: - 档位

    /// 短于这个长度直接不切。短段本来就是用户想要的粒度
    static let minSplitLength = 16
    /// 次级/弱边界生效所需的最小前段长度。小于它说明前面只是个词头
    /// (比如「那」开头的老习惯,「那」后面才跟了两个字),这时候断
    /// 出来的都是碎渣
    static let minClauseLength = 10
    /// 兜底上限。超过它才强制在最近语义边界断开
    static let maxClauseLength = 45
    /// 切出来的子段短于这个长度就并入相邻段。「对吧」「好的。」这类
    /// 尾巴没有独立语义,单独成行只会显得碎
    static let minSubLength = 8

    // MARK: - 切分

    /// 把一段切成若干子段。不切时返回 `[segment]` 本身。
    ///
    /// 子段继承原段的 id / isFinal / 提问和质量标记——它们是同一段的
    /// 不同「行」,不是新的数据实体;起止时间按字符数比例分摊原段的
    /// 时间范围(Apple 不给段内时间信息,比例分摊是唯一可行的办法)。
    static func split(_ segment: TranscriptSegment) -> [TranscriptSegment] {
        let chars = Array(segment.text)
        guard chars.count >= minSplitLength else { return [segment] }

        let all = candidates(in: chars)
        guard !all.isEmpty else { return [segment] }

        let cuts = chooseCuts(from: all, length: chars.count)
        guard !cuts.isEmpty else { return [segment] }

        let pieces = makePieces(chars: chars, cuts: cuts)
        guard pieces.count > 1 else { return [segment] }

        // 时间按字符数比例分摊原段时间范围:Apple 不给段内时间信息,
        // 这是唯一可行的办法。终点按「已消费字符」累计;最后一段钉死在
        // 原段终点,免得舍入误差让整场转录的总时长看起来变了
        let total = pieces.reduce(0) { $0 + $1.count }
        var result: [TranscriptSegment] = []
        var consumed = 0
        for (idx, piece) in pieces.enumerated() {
            consumed += piece.count
            var sub = segment
            sub.text = piece
            sub.endTimeMillis = idx == pieces.count - 1
                ? segment.endTimeMillis
                : segment.startTimeMillis
                    + Int((Double(consumed) / Double(total))
                        * Double(segment.durationMillis))
            sub.startTimeMillis = idx == 0
                ? segment.startTimeMillis
                : result[idx - 1].endTimeMillis
            result.append(sub)
        }
        return result
    }

    // MARK: - 边界检测

    /// 边界的强度。强边界必须切,次级和弱边界要看前段够不够长,
    /// 长度兜底时强 > 次级 > 弱
    private enum Strength: Int, Comparable {
        case weak = 0, medium = 1, strong = 2
        static func < (lhs: Strength, rhs: Strength) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 一个候选切点。index 是「在这个字符位置之前断」
    private struct Candidate {
        let index: Int
        let strength: Strength
    }

    /// 句末标点:强边界
    private static let strongFullWidth: Set<Character> = ["。", "！", "？", "…"]
    /// 句内标点:次级边界
    private static let mediumFullWidth: Set<Character> = ["，", "、", "；", "："]
    /// 句末语气词:落在一个小句末尾时是小句结束的天然标记
    private static let particles: Set<Character> = ["啊", "吧", "呢", "嘛", "呀", "哪"]
    /// 确认式短语:后面天然换气
    private static let confirmations = ["是不是", "对不对", "明白吧", "对吧", "是吧"]
    /// 出现在句中时可以在它**前面**断的话语标记。
    /// 「那」不在里面单独处理——它太常用作普通代词(那里/那些),要额外看守卫
    private static let discourseMarkers = ["然后", "所以", "但是", "就是", "那么"]

    /// 下一个字符是这些时,语气词才像「句末」——「他呢,就是懒」里逗号
    /// 会接住,真正危险的是「毛呢大衣」这种词中间的「呢」。要求后面是
    /// 标点、另一个语气词、文末、或一个明显的下一句开头(我/你/他/这/那),
    /// 可以把词中间的语气字挡掉大半(「毛呢大衣」的「大」就不在名单里)
    private static let clauseStarters: Set<Character> = ["我", "你", "他", "她", "咱", "这", "那"]

    /// 「那」作话语标记(「那我们看一下」)还是代词(「那里」「那些」),
    /// 单看本身分不出来,看后面跟什么:跟的是人称/指示/停顿就是话语标记,
    /// 跟「里」「些」就是代词
    private static let naMarkerFollowers: Set<Character> = ["我", "你", "他", "她", "咱", "大", "这", "现", "就", "么", "那"]

    private static func isPunctuation(_ c: Character) -> Bool {
        strongFullWidth.contains(c) || mediumFullWidth.contains(c)
            || c == "," || c == ";" || c == ":" || c == "." || c == "!" || c == "?"
    }

    /// **标点优先：带标点的文本只按标点切。**
    ///
    /// 语气词/确认式短语/话语标记那套启发式，是为「整段完全无标点」的
    /// 原始识别输出兜底的（SpeechTranscriber 原生不出标点）。一旦文本
    /// 带了标点——LLM 补过的（PunctuationService），或识别器偶尔给的——
    /// 标点本身就是语义边界，而且是比启发式可靠得多的边界；这时候再叠
    /// 一层语气词规则只会把完整的句子切碎（「这个公式对吧是怎么推导
    /// 出来的」会被确认式短语从句子中间砍开）。
    ///
    /// 判定用「有没有真标点」而不是「有没有标点切点」：末尾的句号
    /// 不产生切点（后面没字符了），但它依然说明这段文本带标点——
    /// 若按切点有无来判，只有末尾一个句号的句子会被错交给启发式。
    /// 半角标点要求后面跟空白或文末才算数（「3.14」「10:30」不算），
    /// 所以一段只含「3.14」的无标点文本照样走启发式，不会被堵死兜底路。
    private static func candidates(in chars: [Character]) -> [Candidate] {
        guard hasPunctuation(chars) else { return heuristicCandidates(in: chars) }
        return punctuationCandidates(in: chars)
    }

    /// 文本是否带「真标点」。全角直接算；半角的判定规则和切点一致
    private static func hasPunctuation(_ chars: [Character]) -> Bool {
        for i in 0..<chars.count {
            let c = chars[i]
            if strongFullWidth.contains(c) || mediumFullWidth.contains(c) { return true }
            if c == "." || c == "!" || c == "?" || c == "," || c == ";" || c == ":" {
                let isLast = i + 1 >= chars.count
                if isLast || chars[i + 1] == " " { return true }
            }
        }
        return false
    }

    /// 标点切点。全角直接算；半角要求后面是空白或文末，否则「3.14」
    /// 「10:30」这种会被当成句末
    private static func punctuationCandidates(in chars: [Character]) -> [Candidate] {
        var result: [Candidate] = []
        let n = chars.count

        for i in 0..<n {
            let c = chars[i]
            let isLast = i + 1 >= n
            let next = isLast ? nil : chars[i + 1]

            if strongFullWidth.contains(c) {
                if i + 1 < n { result.append(Candidate(index: i + 1, strength: .strong)) }
            } else if mediumFullWidth.contains(c) {
                if i + 1 < n { result.append(Candidate(index: i + 1, strength: .medium)) }
            } else if c == "." || c == "!" || c == "?" {
                if (isLast || next == " "), i + 1 < n { result.append(Candidate(index: i + 1, strength: .strong)) }
            } else if c == "," || c == ";" || c == ":" {
                if (isLast || next == " "), i + 1 < n { result.append(Candidate(index: i + 1, strength: .medium)) }
            }
        }
        return result
    }

    /// 启发式切点。只在整段完全无标点时才会被调用（见 candidates 的注释）。
    private static func heuristicCandidates(in chars: [Character]) -> [Candidate] {
        var result: [Candidate] = []
        let n = chars.count

        func add(_ index: Int, _ strength: Strength) {
            guard index > 0, index < n else { return }
            result.append(Candidate(index: index, strength: strength))
        }

        var i = 0
        while i < n {
            let c = chars[i]
            let isLast = i + 1 >= n
            let next = isLast ? nil : chars[i + 1]

            // 句末语气词:位置要在小句末尾(见 clauseStarters 的注释);
            // 「哪怕」的「哪」是词首, explicitly 排除
            if particles.contains(c), i > 0 {
                let wordInitial = (c == "哪" && next == "怕")
                let clauseFinal = isLast
                    || next.map { isPunctuation($0) || particles.contains($0) || clauseStarters.contains($0) } ?? true
                if !wordInitial && clauseFinal {
                    add(i + 1, .weak)
                }
            }

            // 确认式短语:在短语结束处断。短语里的「吧」也会被上面的
            // 语气词规则命中,切点是同一个,去重阶段合并
            for phrase in confirmations {
                let pc = phrase.count
                if i + pc <= n, String(chars[i..<i + pc]) == phrase {
                    add(i + pc, .weak)
                }
            }

            // 话语标记:在它前面断(「那」开头的老习惯)。
            // 前导位置(i == 0)由 add 挡掉
            for marker in discourseMarkers {
                let mc = marker.count
                if i + mc <= n, String(chars[i..<i + mc]) == marker {
                    add(i, .weak)
                }
            }
            if c == "那", let next, naMarkerFollowers.contains(next) {
                add(i, .weak)
            }
            if c == "那", isLast == false, next.map(isPunctuation) == true {
                add(i, .weak)
            }

            i += 1
        }

        // 同一位置可能被多条规则命中(「对吧」的「吧」+ 确认式短语),
        // 合并成一条,保留最强的
        var merged: [Int: Strength] = [:]
        for c in result {
            merged[c.index] = max(merged[c.index] ?? .weak, c.strength)
        }
        return merged.map { Candidate(index: $0.key, strength: $0.value) }
            .sorted { $0.index < $1.index }
    }

    // MARK: - 切点选择

    /// 先按规则切,再做长度兜底,最后把过碎的并回去
    private static func chooseCuts(from candidates: [Candidate], length: Int) -> [Int] {
        var cuts: [Candidate] = []
        var chunkStart = 0

        // 规则切:强边界必切;次级/弱边界要求前段够长,否则断出来全是碎渣
        for c in candidates {
            let pieceLength = c.index - chunkStart
            switch c.strength {
            case .strong:
                if pieceLength > 0 { cuts.append(c); chunkStart = c.index }
            case .medium, .weak:
                if pieceLength >= minClauseLength { cuts.append(c); chunkStart = c.index }
            }
        }

        // 长度兜底:仍有超过上限的长段,在里面挑离上限最近的语义边界
        // 收一刀。找不到候选就留着不切——切不动不硬切
        var boundaries = [0] + cuts.map(\.index) + [length]
        var extra: [Candidate] = []
        for w in 0..<boundaries.count - 1 {
            let start = boundaries[w], end = boundaries[w + 1]
            guard end - start > maxClauseLength else { continue }
            let inside = candidates.filter { $0.index > start && $0.index < end }
            guard !inside.isEmpty else { continue }
            let target = start + maxClauseLength
            // 优先选上限之内的,实在没有才用上限之后最近的;
            // 同距离时强的赢
            let best = inside.min { a, b in
                let da = a.index <= target ? target - a.index : (a.index - target) + 10_000
                let db = b.index <= target ? target - b.index : (b.index - target) + 10_000
                if da != db { return da < db }
                return a.strength > b.strength
            }!
            extra.append(best)
        }
        let allCuts = (cuts + extra).sorted { $0.index < $1.index }

        // 合并过碎:短于 minSubLength 的子段并入相邻。尾部的并回前一段
        // (「……就是这样对吧」比单挂一行「对吧」好读),中间的并进后一段。
        // 但合并不许跨过强边界——「大家听懂了吗?」虽然只有 7 个字,
        // 也是完整的一句,「。」是必须切的边界,不能因为它短就并回去
        let strengthAt = Dictionary(allCuts.map { ($0.index, $0.strength) }) { a, b in max(a, b) }
        boundaries = [0] + allCuts.map(\.index) + [length]
        var spans = zip(boundaries, boundaries.dropFirst()).map { ($0, $1) }
        var i = 0
        while i < spans.count {
            let (s, e) = spans[i]
            guard e - s < minSubLength, spans.count > 1 else { i += 1; continue }
            let strongBefore = strengthAt[s] == .strong
            let strongAfter = i + 1 < spans.count ? strengthAt[spans[i + 1].0] == .strong : true
            if i + 1 < spans.count, !strongAfter {
                spans[i + 1] = (s, spans[i + 1].1)
                spans.remove(at: i)
            } else if i > 0, !strongBefore {
                spans[i - 1] = (spans[i - 1].0, e)
                spans.remove(at: i)
            } else {
                // 两边都是强边界:留着,短句也是完整的句子
                i += 1
                continue
            }
            i = max(0, i - 1)
        }

        return spans.dropFirst().map(\.0)
    }

    // MARK: - 子段生成

    /// 按切点把字符数组切成子串。首尾空白不收进子段——半角标点后
    /// 跟的空格是上一句的尾巴,不该顶在下一句开头
    private static func makePieces(chars: [Character], cuts: [Int]) -> [String] {
        let boundaries = [0] + cuts + [chars.count]
        var pieces: [String] = []
        for w in 0..<boundaries.count - 1 {
            let piece = String(chars[boundaries[w]..<boundaries[w + 1]])
                .trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces
    }

    // MARK: - 自检

    /// `--split-selftest`。打印每条用例的切分结果和切点位置,
    /// 让人一眼看出切得对不对;判定失败会标 ❌ 并以非零汇总收尾。
    static func selfTest() -> [String] {
        var lines: [String] = ["语义切分自检(纯函数,不依赖设备)"]
        var allPassed = true

        /// 受保护的多字词:任何切点都不许落在词中间
        let protectedWords = ["机器学习", "人工智能", "神经网络", "深度学习", "自然语言处理", "计算机视觉", "反向传播"]

        @discardableResult
        func run(
            _ name: String,
            _ text: String,
            durationMillis: Int = 10_000,
            expectPieces: Int? = nil,
            expectMinPieces: Int? = nil,
            protect: [String] = []
        ) -> [TranscriptSegment] {
            let segment = TranscriptSegment(
                text: text, isFinal: true,
                startTimeMillis: 0, endTimeMillis: durationMillis,
                languages: ["zh-CN"]
            )
            let pieces = split(segment)
            lines.append("用例 · \(name)(\(text.count) 字 → \(pieces.count) 段)")

            // 切点 = 各子段在原文里的累计边界;先验证拼接无损
            var rejoined = ""
            var cutPositions: [Int] = []
            for piece in pieces.dropLast() {
                rejoined += piece.text
                cutPositions.append(rejoined.count)
            }
            rejoined += pieces.last!.text

            for (idx, piece) in pieces.enumerated() {
                let t0 = String(format: "%5.1fs", Double(piece.startTimeMillis) / 1000)
                let t1 = String(format: "%5.1fs", Double(piece.endTimeMillis) / 1000)
                let indent = idx == 0 ? "  " : "    "
                lines.append("\(indent)[\(t0)–\(t1)] \(piece.text)")
            }
            if cutPositions.isEmpty {
                lines.append("  切点: 无(整段保留)")
            } else {
                let desc = cutPositions.map { pos -> String in
                    let chars = Array(text)
                    let before = chars[pos - 1]
                    let after = pos < chars.count ? String(chars[pos]) : "末"
                    return "\(pos)(「\(before)」后/「\(after)」前)"
                }
                lines.append("  切点: \(desc.joined(separator: "  "))")
            }

            // 判定
            var failures: [String] = []
            if rejoined != text { failures.append("拼接后有字符丢失或改动") }
            if let expectPieces, pieces.count != expectPieces {
                failures.append("期望 \(expectPieces) 段,实际 \(pieces.count) 段")
            }
            if let expectMinPieces, pieces.count < expectMinPieces {
                failures.append("期望至少 \(expectMinPieces) 段,实际 \(pieces.count) 段")
            }
            for word in protectedWords + protect {
                var searchFrom = text.startIndex
                while let range = text.range(of: word, range: searchFrom..<text.endIndex) {
                    let lo = text.distance(from: text.startIndex, to: range.lowerBound)
                    let hi = text.distance(from: text.startIndex, to: range.upperBound)
                    for cut in cutPositions where cut > lo && cut < hi {
                        failures.append("切点 \(cut) 落在「\(word)」中间")
                    }
                    searchFrom = range.upperBound
                }
            }

            let ok = failures.isEmpty
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") 判定: \(ok ? "通过" : failures.joined(separator: ";"))")
            return pieces
        }

        // 1. 真实录音转出的 13.7 秒长段(无任何标点),应切成多段且切点都在语义边界
        run(
            "13.7 秒真实长段(无标点)",
            "比如生活可能一点参加据我们是不为例了我们到年底的时候啊我觉得我会进行这个就生活就是就是一度拖费",
            durationMillis: 13_700,
            expectMinPieces: 2
        )

        // 2. 带标点:句末标点必切;「它是一种优化算法」只有 8 字,
        //    不够 minClauseLength,逗号处不该断
        run(
            "带标点的文本",
            "今天我们讲梯度下降。它是一种优化算法，用来最小化损失函数。大家听懂了吗？",
            expectPieces: 3
        )

        // 3. 很短:直接不切
        run("短文本", "好的我们开始", expectPieces: 1)

        // 4. 超过上限但没有任何语义边界:宁可整段保留,不许硬切
        run(
            "找不到语义边界的长文本",
            "机器学习深度学习神经网络人工智能自然语言处理计算机视觉强化学习迁移学习都是当前最热门的研究方向",
            expectPieces: 1
        )

        // 5. 含多字词 + 长度兜底:只能在「就是」前断,不许断词
        run(
            "多字词保护 + 兜底",
            "机器学习人工智能深度学习神经网络自然语言处理计算机视觉这些概念大家一定要搞清楚就是它们之间的关系和区别到底是什么",
            expectPieces: 2,
            protect: ["就是"]
        )

        lines.append(allPassed ? "全部通过 ✅" : "存在失败用例 ❌")
        return lines
    }
}
