import Foundation

/// 学习笔记生成特有的失败。请求本身失败的情形由 `ModelTextError` 直接抛出。
enum StudyNotesError: LocalizedError {
    case noSegments
    /// 内容太少，**根本没送模型**（见 `minTotalCharacters`）
    case tooShort(characters: Int, floor: Int)
    /// 每一片都没解析出 JSON。**这时必须抛**：写一份空笔记出去，
    /// 用户看到的是「这堂课没有要点」，而事实是「模型全崩了」——
    /// 两件事长得一样，但一件要重跑、另一件要改提示词
    case allSlicesMalformed(slices: Int)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "这条会话没有转录内容，无法生成学习笔记"
        case .tooShort(let characters, let floor):
            return "转录内容太少（\(characters) 字，不足 \(floor) 字），生成不出有意义的笔记"
        case .allSlicesMalformed(let slices):
            return "模型返回的 \(slices) 片全都不是合法 JSON，没有产出任何要点"
        }
    }
}

/// 一条候选要点被丢弃的原因。**枚举而不是一句「校验失败」**——沿用
/// `PunctuationValidation` 立的范式：自检要断言「是因为什么被拒的」，
/// 报告里的原因分布也要按它分组，糊成一句话这两件事都做不了
enum StudyItemRejection: Error, Equatable {
    /// `kind` 不是五个已知值之一（模型爱写「重点」「Key Point」这类自由文本）
    case unknownKind(String)
    case emptyText
    /// 一条锚点都没给
    case noAnchor
    /// 锚点在会话里找不到对应段落——**编造时间戳的指纹**
    case anchorNotFound(String)
    /// 要点里的数字原文里没有
    case unknownNumber(String)
    /// 要点里的英文词原文里没有、术语表里也没有
    case unknownTerm(String)

    /// 报告里分组用的短标签
    var label: String {
        switch self {
        case .unknownKind: return "kind 不是已知值"
        case .emptyText: return "正文为空"
        case .noAnchor: return "没有锚点"
        case .anchorNotFound: return "锚点在原文里不存在"
        case .unknownNumber: return "数字原文里没有"
        case .unknownTerm: return "术语原文里没有"
        }
    }

    /// 附带的具体值（哪个时间戳 / 哪个数字）——原因分布之外还要能看见「是哪一个」，
    /// 否则「拒了 12 条数字」这句话对定位问题没有帮助
    var detail: String {
        switch self {
        case .unknownKind(let v), .anchorNotFound(let v), .unknownNumber(let v), .unknownTerm(let v):
            return v
        case .emptyText, .noAnchor:
            return ""
        }
    }
}

/// 被丢弃的一条要点（原因 + 正文摘要）。
struct RejectedStudyItem: Equatable {
    var reason: StudyItemRejection
    var excerpt: String
}

/// 单价与费用估算。
///
/// **单价是假设值，不是从接口读来的**——DeepSeek 的响应里只有 token 数，
/// 没有价格，而验收判据「一堂课 ≤ 0.1 元」得有一个能算的基数。所以：
///   · token 数是**实测的**（来自响应的 `usage`）；
///   · 单价在输出里**跟着费用一起打出来**，读的人随时能自己重算、
///     也能看出这个结论建立在什么假设上；
///   · 换价不用改代码，设环境变量即可（价格调整是常态）。
///
/// 默认值取 deepseek-chat 人民币档：输入未命中 2 元 / 百万、输入命中 0.2 元 /
/// 百万、输出 8 元 / 百万。**这个数字有不确定性**（各家渠道、峰谷计价给出的
/// 价格不一致），所以它必须显示出来，不能被当成事实引用
enum StudyNotesCost {

    static func price(_ env: String, fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[env],
              let value = Double(raw.trimmingCharacters(in: .whitespaces)),
              value >= 0
        else { return fallback }
        return value
    }

    /// 元 / 百万 token
    static var inputMissPerMillion: Double { price("DEEPSEEK_PRICE_INPUT", fallback: 2.0) }
    static var inputHitPerMillion: Double { price("DEEPSEEK_PRICE_CACHE_HIT", fallback: 0.2) }
    static var outputPerMillion: Double { price("DEEPSEEK_PRICE_OUTPUT", fallback: 8.0) }

    /// 估算费用（元）。缓存命中的部分**单独按命中价算**：DeepSeek 对它是
    /// 另一个单价，全按未命中价算会把重复生成同一片的那次报贵一个数量级
    static func yuan(
        promptTokens: Int,
        completionTokens: Int,
        cacheHitTokens: Int
    ) -> Double {
        let hit = max(0, min(cacheHitTokens, promptTokens))
        let miss = max(0, promptTokens - hit)
        return (Double(miss) * inputMissPerMillion
            + Double(hit) * inputHitPerMillion
            + Double(completionTokens) * outputPerMillion) / 1_000_000
    }

    /// 打给用户看的一行，用来把费用钉在它依赖的假设上
    static var priceLine: String {
        String(
            format: "单价假设：输入 %.2f 元/百万（命中 %.2f）· 输出 %.2f 元/百万",
            inputMissPerMillion, inputHitPerMillion, outputPerMillion
        )
    }
}

/// 一次生成的统计。**每一条候选的去向都在这里有数**——被拒不是耻辱，
/// 是防线在工作，但得能看见它拦了什么
struct StudyNotesStats {
    var sliceCount: Int
    var malformedSlices: Int
    var countsByKind: [StudyItemKind: Int]
    var rejected: [RejectedStudyItem]
    var usage: StudyNotesUsage

    var acceptedCount: Int { countsByKind.values.reduce(0, +) }

    /// 原因分布：标签 → 条数，按条数从多到少
    var rejectionDistribution: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in rejected { counts[item.reason.label, default: 0] += 1 }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (label: $0.key, count: $0.value) }
    }
}

/// 一次生成的完整产出：落盘的笔记 + 报告用的统计
struct StudyNotesOutcome {
    var notes: StudyNotes
    var stats: StudyNotesStats

    /// 报告文本。放在这里而不是各个无头入口里各写一份：`--study-notes-selftest`
    /// 和 `--study-notes` 要能对着同一份数字讨论，两边各打一套字段早晚对不上
    func report() -> [String] {
        var lines: [String] = []
        lines.append("分片 \(stats.sliceCount) 片（其中解析失败 \(stats.malformedSlices) 片）")
        lines.append("耗时 \(String(format: "%.1f", stats.usage.elapsedSeconds)) 秒")
        lines.append("token：输入 \(stats.usage.promptTokens)（缓存命中 \(stats.usage.cacheHitTokens)）"
            + " · 输出 \(stats.usage.completionTokens)")
        lines.append(StudyNotesCost.priceLine)
        lines.append(String(format: "估算费用：%.4f 元", stats.usage.estimatedYuan))
        lines.append("")
        lines.append("产出要点 \(stats.acceptedCount) 条：")
        for kind in StudyItemKind.allCases {
            lines.append("  \(kind.label) \(stats.countsByKind[kind] ?? 0) 条")
        }
        // 有效率是**数出来的**，不是印上去的。验收判据要求它等于 100%，
        // 而把「100%」写死在报告里，那条判据就永远为真——它得能变红
        let anchored = notes.items.filter { !$0.anchors.isEmpty }.count
        let total = notes.items.count
        lines.append("锚点有效率：\(total == 0 ? "—（没有要点）" : "\(anchored * 100 / total)%（\(anchored)/\(total) 条）")")

        lines.append("")
        if stats.rejected.isEmpty {
            lines.append("被拒 0 条")
        } else {
            lines.append("被拒 \(stats.rejected.count) 条：")
            for (label, count) in stats.rejectionDistribution {
                lines.append("  \(label) · \(count) 条")
            }
            lines.append("  明细：")
            for item in stats.rejected {
                let detail = item.reason.detail.isEmpty ? "" : "（\(item.reason.detail)）"
                lines.append("    · \(item.reason.label)\(detail) — \(item.excerpt)")
            }
        }
        return lines
    }
}

/// 把一堂课的转录加工成可复习的学习笔记。
///
/// **与转录的关系**：只读。这个类型不写任何 `RecordingSession`、不改
/// `segments`（拍板 3b / 设计稿 §1.1）。产出是另一份东西，存在另一个文件里。
///
/// **为什么要校验**：模型会编。仓库里已有实证——补标点那一轮实测到它擅自纠正
/// 英文大小写、给数字加分隔（`PunctuationService` 的注释里记着）。学习笔记比
/// 补标点危险得多：补标点的错误是「改了字」，而笔记的错误是**「这堂课讲过 X」**，
/// 用户会照着它复习。所以每条要点都要过机械校验，锚点必须真实存在，
/// 数字和术语必须在原文里检索得到，不合格**整条丢弃**（拍板 4a）
enum StudyNotesService {

    /// 分片的时间窗。设计稿 §3.2 给的是 8–12 分钟，取中值 10 分钟。
    ///
    /// 为什么按时间切而不是按字数切：这一片要**独立成立**——它得是一段能
    /// 单独读懂的课，而「第 2000 到第 4000 个字」可能从半句话开始。
    /// 时间窗贴着课的自然分段走
    static let windowMillis = 10 * 60 * 1000

    /// 低于这么多字**根本不送模型**。
    ///
    /// 沿用 `PunctuationService.minInputLength` 那条教训：极短输入会触发模型的
    /// 对话本能——你给它一句话，它回「请提供需要整理的课堂内容」。校验挡得住
    /// 那种返回，但白花一次请求；而且一两句话本来就没有摘要可写。
    /// 100 字约等于四五句课堂口语，是「还称得上一段内容」的下限
    static let minTotalCharacters = 100

    /// 要点里的英文词短于这个长度不查原文。
    ///
    /// 2 个字母的串（「AI」「ok」「vs」）几乎总能在原文里撞上，查它们不加分辨力；
    /// 而真正会出问题的编造是「模型写了一个没讲过的术语」——那多半是个长词。
    /// 这条门限的效果是**放宽**：漏掉两字母的编造，换更少的误拒
    static let minLatinWordLength = 3

    /// 模型调用。**抽成参数是为了自检能打桩**（`--study-notes-selftest` 离线跑，
    /// 不联网、不花钱）。默认值就是真实那条路，所以生产代码和自检走的是同一段逻辑
    typealias ModelCall = @Sendable (_ systemPrompt: String, _ userPrompt: String) async throws -> ModelTextReply

    /// 每片开跑前的回调节点：`(第几片, 共几片)`，都是 1 起的。
    ///
    /// **只有这里知道分片结构**，所以进度从这里往外报——界面自己按时间猜
    /// 「大约还有多久」既不准，也没法离线自检。设计成 `async` 是因为调用方
    /// 要把它送回主 actor 才能改界面状态；进度回调晚几十毫秒无所谓，
    /// 而让 `generate` 去感知主 actor 才是把两个不相干的层焊在一起
    typealias ProgressHook = @Sendable (_ sliceIndex: Int, _ sliceCount: Int) async -> Void

    static let defaultCall: ModelCall = { system, user in
        try await ModelText.deepSeekChatWithUsage(
            systemPrompt: system, userPrompt: user, temperature: 0.3, timeout: 180
        )
    }

    // MARK: - 分片

    /// 一片要送出去的内容
    struct SliceLine: Equatable {
        /// `HH:MM:SS`，**会话轴**（片段 offset + 段内起点）
        var timestamp: String
        var text: String
        var isPoor: Bool
    }

    struct Slice: Equatable {
        /// 1 起。给模型看「这是第几片」，也用于报告
        var index: Int
        var total: Int
        var lines: [SliceLine]
    }

    /// 按时间窗切。空文本段落直接不进来（送过去只会占 token，
    /// 而且它没法当锚点——`AnchorIndex` 也跳过它们，两边口径必须一致）
    static func sliceByWindow(parts: [RecordingPart]) -> [Slice] {
        var buckets: [Int: [SliceLine]] = [:]
        for part in parts {
            for segment in part.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = RecordingSession.absoluteRange(of: segment, in: part).lowerBound
                buckets[start / windowMillis, default: []].append(SliceLine(
                    timestamp: NotesService.formatTimestamp(start),
                    text: segment.text,
                    isPoor: segment.qualityGrade == .poor
                ))
            }
        }
        let keys = buckets.keys.sorted()
        return keys.enumerated().map { position, key in
            Slice(index: position + 1, total: keys.count, lines: buckets[key] ?? [])
        }
    }

    // MARK: - 锚点索引

    /// `HH:MM:SS` → 一个真实段落。
    ///
    /// **为什么按秒而不是按毫秒**：给模型看的时间戳就是秒精度的
    /// （`[00:12:03]`），它抄回来也只能到秒。要求毫秒级相等是要求它
    /// 凭空造出我们没告诉它的精度
    ///
    /// **同一秒可能有好几段**——实测 67 分钟那条真实会话（922 段）里有 144 段
    /// 落在别人同一秒上（15.6%，`--study-notes-selftest` 之外可用
    /// `python3` 数一遍 `start//1000` 的重复）。这时取**起点最小**的那一段，
    /// 是确定性的选择：同一个输入永远得到同一个锚点，自检才断得住。
    /// 挑错了也只是差几百毫秒，锚点仍然指向真实存在的一段
    struct AnchorIndex {
        private var bySecond: [String: Anchor] = [:]

        init(parts: [RecordingPart]) {
            for part in parts {
                for segment in part.segments {
                    guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    let start = RecordingSession.absoluteRange(of: segment, in: part).lowerBound
                    let key = NotesService.formatTimestamp(start)
                    if let existing = bySecond[key], existing.startMillis <= start { continue }
                    bySecond[key] = Anchor(partID: part.id, segmentID: segment.id, startMillis: start)
                }
            }
        }

        /// 模型可能连着方括号一起抄回来，也可能写成中文/全角括号，全部剥掉再查。
        /// 认不出来返回 nil = 这条要点的锚点不存在 = 整条丢弃
        func anchor(for raw: String) -> Anchor? {
            bySecond[Self.normalizeTimestamp(raw)]
        }

        static func normalizeTimestamp(_ raw: String) -> String {
            raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n[]【】（）()"))
        }
    }

    // MARK: - 校验（纯函数）

    /// 文本里出现的数字串（连续数字字符）。用于「原文里没有的数字」这条判据
    static func digitRuns(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { !$0.isNumber })
            .map(String.init)
    }

    /// 文本里出现的拉丁字母词。中文词不查——「这个术语原文里没有」在中文上
    /// 没法用子串判定（同一个意思有十种说法），而数字和拉丁术语是**拼写级的
    /// 事实**，可以硬查
    static func latinRuns(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { !$0.isLetter || !$0.isASCII })
            .map(String.init)
            .filter { $0.count >= minLatinWordLength }
    }

    /// 去空白 + 小写。术语比对用——原文写「Machine learning」而要点写
    /// 「machine learning」是同一个词，不该因为空格和大小写判它编造；
    /// 反过来「原文一个字都没有这个词」才是要抓的
    static func compact(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// 逐条机械校验。返回第一条不通过的**原因**（不是一句 Bool）——
    /// 报告的原因分布靠它，自检断言「因为什么被拒」也靠它
    static func validate(
        kind: StudyItemKind,
        text: String,
        rawAnchors: [String],
        index: AnchorIndex,
        sessionText: String,
        sessionTextCompact: String,
        allowedTerms: Set<String>
    ) -> Result<StudyItem, StudyItemRejection> {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure(.emptyText) }

        // ① 锚点：一条都不能少、一条都不能假
        guard !rawAnchors.isEmpty else { return .failure(.noAnchor) }
        var anchors: [Anchor] = []
        var seenSegments = Set<UUID>()
        for raw in rawAnchors {
            guard let anchor = index.anchor(for: raw) else {
                // 改口径必须是「整条丢弃」而不是「丢掉这个锚点再用剩下的」——
                // 剩下的锚点可能只覆盖这条要点的一小半，留着就是让用户以为
                // 整条都有出处。宁可少一条，不许编一条（拍板 4a）
                return .failure(.anchorNotFound(raw))
            }
            if seenSegments.insert(anchor.segmentID).inserted { anchors.append(anchor) }
        }
        guard !anchors.isEmpty else { return .failure(.noAnchor) }

        // ② 数字：原文里检索不到就是编的
        for run in digitRuns(body) where !sessionText.contains(run) {
            return .failure(.unknownNumber(run))
        }

        // ③ 英文术语：原文（去空白、不分大小写）里没有，且术语表里也没有
        for word in latinRuns(body) {
            let needle = word.lowercased()
            if sessionTextCompact.contains(needle) { continue }
            if allowedTerms.contains(needle) { continue }
            return .failure(.unknownTerm(word))
        }

        return .success(StudyItem(kind: kind, text: body, anchors: anchors))
    }

    /// 去重用的键：类型 + 去空白去标点后的小写正文。
    /// 同一片内和跨片都靠它——模型很爱在相邻两片里把同一句话写两遍
    static func dedupeKey(_ item: StudyItem) -> String {
        item.kind.rawValue + "|"
            + item.text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    // MARK: - 提示词

    static func systemPrompt(glossary: [GlossaryEntry]) -> String {
        var prompt = """
        你是课堂学习笔记整理器。你会收到一堂课的**一片**转录（全课的一部分，
        片头标了这是第几片）。每一行形如 `[HH:MM:SS] 正文`，方括号里是这段
        在**整堂课**时间轴上的起点。标了〔低置信〕的行来自识别质量差的音频，
        里面的术语和数字可能是错的——不要仅凭这些行下结论。

        只输出一个 JSON 对象，不要解释、不要用代码块包裹：
        {"items":[{"kind":"keyPoint","text":"…","anchors":["00:12:03"]}]}

        kind 只能取这五个值之一：summary（本节摘要）· keyPoint（知识点）·
        todo（课后要做的事）· examFocus（复习提纲/考点）· term（术语解释）。

        硬约束（违反的条目会被程序直接丢弃，没有第二次机会）：
        - **每条必须有 anchors，至少 1 个。** anchors 里只能出现输入里真实
          出现过的 `HH:MM:SS`，原样抄，不要换算、不要写没出现过的时间。
        - 不许出现输入里没有的数字、术语、公式、结论。宁可少写一条。
        - text 用中文，一句话说清，不要照抄原文。
        - 输入里没提到就不要写，不要为了凑数把同一件事写成两条。
        """

        let glossaryText = GlossaryService.makeGlossaryText(glossary)
        if !glossaryText.isEmpty {
            // 注入术语表的理由和术语校正那一轮一样：中文课堂只挂单个 zh-CN
            // 模型，英文术语会被按读音转写成拉丁字母。不把正确写法告诉它，
            // 它写出来的术语就会是原文里那种错拼，然后被「术语原文里没有」
            // 这条判据全部拒掉——那是判据在罚一个我们本可以避免的问题
            prompt += "\n\n本课术语表（这些是正确写法，用到时按这个写）：\n\(glossaryText)"
        }
        return prompt
    }

    static func userPrompt(slice: Slice) -> String {
        var lines = ["【第 \(slice.index)/\(slice.total) 片】"]
        for line in slice.lines {
            // 〔低置信〕标签和 AnchorIndex / 判据共用同一个来源（qualityGrade），
            // 不另设一套「哪些段不可信」的规则
            lines.append("[\(line.timestamp)] \(line.isPoor ? "〔低置信〕" : "")\(line.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 模型返回的解析

    /// 模型返回的一条候选。**逐字段可选**：少一个字段只该丢这一条，
    /// 不该让整个 JSON 解析失败——一条写坏的要点不该带走它周围 20 条好的
    struct RawItem: Decodable {
        var kind: String?
        var text: String?
        var anchors: [String]?
    }

    struct RawReply: Decodable {
        var items: [RawItem]?
    }

    /// 解析一片的返回。返回 nil = **整个返回不是合法 JSON / 没有 items 键**，
    /// 也就是「垃圾」。`items: []` 是合法的空结果，不是垃圾
    static func parse(_ content: String) -> [RawItem]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let reply = try? JSONDecoder().decode(RawReply.self, from: data) else { return nil }
        return reply.items
    }

    // MARK: - 生成

    /// 跑一遍：分片 → 每片问模型 → 逐条校验 → 去重排序。
    ///
    /// **不写盘**。落盘是调用方的事（`StudyNotesStorage`），这样
    /// 「模型返回垃圾时不许写盘」这条判据在结构上就成立——生成失败时
    /// 根本没有返回值可以写
    static func generate(
        session: RecordingSession,
        glossary: [GlossaryEntry] = [],
        call: ModelCall = StudyNotesService.defaultCall,
        onSlice: ProgressHook? = nil,
        now: Date = Date()
    ) async throws -> StudyNotesOutcome {
        let slices = sliceByWindow(parts: session.parts)
        guard !slices.isEmpty else { throw StudyNotesError.noSegments }

        let characters = slices.reduce(0) { total, slice in
            total + slice.lines.reduce(0) { $0 + $1.text.count }
        }
        guard characters >= minTotalCharacters else {
            throw StudyNotesError.tooShort(characters: characters, floor: minTotalCharacters)
        }

        let index = AnchorIndex(parts: session.parts)
        let sessionText = session.parts
            .flatMap(\.segments)
            .map(\.text)
            .joined(separator: "\n")
        let sessionTextCompact = compact(sessionText)
        let allowedTerms = Set(
            glossary
                .flatMap { [$0.term] + $0.aliases }
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        let system = systemPrompt(glossary: glossary)
        let started = Date()

        var accepted: [StudyItem] = []
        var rejected: [RejectedStudyItem] = []
        var malformedSlices = 0
        var promptTokens = 0
        var completionTokens = 0
        var cacheHitTokens = 0

        for (offset, slice) in slices.enumerated() {
            // 进度**在请求之前**报：报在之后的话，用户看到的片号是「刚跑完的那片」，
            // 一片要跑好几秒，那几秒里界面显示的是已经过期的数字
            await onSlice?(offset + 1, slices.count)

            // 请求本身失败（无 key / HTTP / 超时）**直接抛**：费用已经花了一部分，
            // 而「有一片悄悄没跑」在结果里看不出来——用户会以为笔记就是这么多。
            // 设计稿 §1.4 要的是「失败不写半截结果」，抛出去调用方就不会写
            let reply = try await call(system, userPrompt(slice: slice))
            promptTokens += reply.usage?.promptTokens ?? 0
            completionTokens += reply.usage?.completionTokens ?? 0
            cacheHitTokens += reply.usage?.cacheHitTokens ?? 0

            guard let rawItems = parse(reply.content) else {
                malformedSlices += 1
                continue
            }

            for raw in rawItems {
                guard let rawKind = raw.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let kind = StudyItemKind(rawValue: rawKind)
                else {
                    rejected.append(RejectedStudyItem(
                        reason: .unknownKind(raw.kind ?? "（缺 kind）"),
                        excerpt: excerpt(raw.text)
                    ))
                    continue
                }
                switch validate(
                    kind: kind,
                    text: raw.text ?? "",
                    rawAnchors: raw.anchors ?? [],
                    index: index,
                    sessionText: sessionText,
                    sessionTextCompact: sessionTextCompact,
                    allowedTerms: allowedTerms
                ) {
                case .success(let item):
                    accepted.append(item)
                case .failure(let reason):
                    rejected.append(RejectedStudyItem(reason: reason, excerpt: excerpt(raw.text)))
                }
            }
        }

        // 每一片都崩 = 什么都没产出。写一份空笔记出去等于告诉用户
        // 「这堂课没内容」，那是另一个意思
        guard malformedSlices < slices.count else {
            throw StudyNotesError.allSlicesMalformed(slices: slices.count)
        }

        // 归并：去重（保留先出现的，也就是更早那片）、按类型与时间排序。
        // **不做第二次 LLM 归并**：派单书 §3 把 reduce 定义为「归并、去重、排序」，
        // 而一次 LLM 归并的输入是摘要而不是转录——它没法再给出可校验的锚点，
        // 那正好绕过了这一包最要紧的那道闸
        var seen = Set<String>()
        var merged: [StudyItem] = []
        for item in accepted where seen.insert(dedupeKey(item)).inserted {
            merged.append(item)
        }

        let order = Dictionary(
            uniqueKeysWithValues: StudyItemKind.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        merged.sort { lhs, rhs in
            let left = order[lhs.kind] ?? 0
            let right = order[rhs.kind] ?? 0
            if left != right { return left < right }
            return (lhs.anchors.map(\.startMillis).min() ?? 0)
                < (rhs.anchors.map(\.startMillis).min() ?? 0)
        }

        let elapsed = Date().timeIntervalSince(started)
        var counts: [StudyItemKind: Int] = [:]
        for item in merged { counts[item.kind, default: 0] += 1 }

        return StudyNotesOutcome(
            notes: StudyNotes(
                sessionID: session.id,
                generatedAt: now,
                model: ModelText.defaultModel,
                items: merged,
                usage: StudyNotesUsage(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    cacheHitTokens: cacheHitTokens,
                    sliceCount: slices.count,
                    elapsedSeconds: elapsed,
                    estimatedYuan: StudyNotesCost.yuan(
                        promptTokens: promptTokens,
                        completionTokens: completionTokens,
                        cacheHitTokens: cacheHitTokens
                    )
                )
            ),
            stats: StudyNotesStats(
                sliceCount: slices.count,
                malformedSlices: malformedSlices,
                countsByKind: counts,
                rejected: rejected,
                usage: StudyNotesUsage(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    cacheHitTokens: cacheHitTokens,
                    sliceCount: slices.count,
                    elapsedSeconds: elapsed,
                    estimatedYuan: StudyNotesCost.yuan(
                        promptTokens: promptTokens,
                        completionTokens: completionTokens,
                        cacheHitTokens: cacheHitTokens
                    )
                )
            )
        )
    }

    /// 报告里的正文摘要。太长的截断——报告是用来定位问题的，
    /// 整篇贴出来会把原因分布淹掉
    static func excerpt(_ text: String?, limit: Int = 40) -> String {
        guard let text else { return "（无 text）" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }
}

// MARK: - 离线自检

extension StudyNotesService {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// `--study-notes-selftest`。
    ///
    /// **全程离线**：模型那一步打桩（`ModelCall` 是参数，见那里的注释），
    /// 不联网、不花钱、不加载模型、不碰音频、**不发声**。写盘那几条在临时
    /// 目录里跑，不碰真实的 `study-notes/`
    static func selfTest() async -> SelfTestResult {
        var lines: [String] = ["学习笔记自检（离线 · 打桩模型 · 不联网、不花钱、不发音）"]
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        // ── 打桩：把「模型调用」换成一个记下提示词、按序吐预置返回的盒子 ──
        //
        // 用锁保护是照 `RecordingsStore.Collector` 的写法：`ModelCall` 是
        // `@Sendable`，闭包要跨并发域改状态，裸的可变捕获在 Swift 6 下编译不过
        let recorder = StubModel()
        let call: ModelCall = recorder.call

        // ── 夹具 ──
        let stamp = Date(timeIntervalSince1970: 1_858_464_000)

        func makeSession(
            parts: [(offset: Int, duration: Int, segments: [TranscriptSegment])]
        ) -> RecordingSession {
            RecordingSession(
                id: UUID(), startedAt: stamp, updatedAt: stamp,
                parts: parts.map { spec in
                    RecordingPart(
                        id: UUID(), fileName: nil, startedAt: stamp,
                        durationMillis: spec.duration, offsetMillis: spec.offset,
                        segments: spec.segments
                    )
                }
            )
        }

        func seg(_ text: String, _ start: Int, _ end: Int, poor: Bool = false) -> TranscriptSegment {
            var segment = TranscriptSegment(
                text: text, isFinal: true,
                startTimeMillis: start, endTimeMillis: end,
                timestamp: stamp, languages: ["zh-CN"]
            )
            if poor { segment.qualityGrade = .poor }
            return segment
        }

        // 三段的短课：总字数过 100 的下限，落在同一个 10 分钟窗里（= 1 片）
        let s1 = seg("今天我们讲梯度下降，它是一种一阶优化算法，核心是沿着损失函数的负梯度方向迭代更新参数。", 0, 8_000)
        let s2 = seg("大家注意学习率这个超参数，如果设得太大，模型就会震荡不收敛；设得太小，收敛速度又会非常慢。", 8_000, 22_000)
        let s3 = seg("课后请在 MNIST 数据集上实现一遍，另外预习 backpropagation，下节课我们会用到它。", 22_000, 32_000)
        let shortSession = makeSession(parts: [(0, 32_000, [s1, s2, s3])])

        // ── 1. 正常路径：锚点全部有效，且要顺带验掉去重与排序 ──
        //
        // 桩故意把顺序打乱（term 打头）、并塞一条和 keyPoint 正文完全相同的
        // 重复条目（锚点不同）——归并那一层就是干这个的
        recorder.push("""
        {"items":[
          {"kind":"term","text":"backpropagation 是反向传播","anchors":["00:00:22"]},
          {"kind":"todo","text":"在 MNIST 数据集上实现一遍","anchors":["00:00:22"]},
          {"kind":"keyPoint","text":"学习率过大会导致震荡不收敛","anchors":["00:00:08"]},
          {"kind":"keyPoint","text":"学习率过大会导致震荡不收敛","anchors":["00:00:00"]},
          {"kind":"summary","text":"本片讲梯度下降的原理和学习率的影响","anchors":["00:00:00","00:00:08"]}
        ]}
        """)

        do {
            let outcome = await awaitResult { try await generate(session: shortSession, call: call) }
            switch outcome {
            case .failure(let error):
                check(false, "正常路径：能生成", "抛了 \(error.localizedDescription)")
            case .success(let value):
                let notes = value.notes
                check(notes.items.count == 4, "正常路径：产出 4 条（重复的那条被去掉）",
                      "实际 \(notes.items.count) 条：\(notes.items.map(\.kind.label).joined(separator: "/"))")
                check(notes.items.map(\.kind) == [.summary, .keyPoint, .todo, .term],
                      "正常路径：按类型排序（摘要→重点→待办→术语）",
                      notes.items.map(\.kind.label).joined(separator: "→"))
                check(value.stats.countsByKind[.keyPoint] == 1, "正常路径：同类里正文相同的只留一条")
                check(notes.items.allSatisfy { !$0.anchors.isEmpty },
                      "正常路径：每条都有锚点")
                // 锚点必须指回真实段落：拿生成的锚点去会话里核对，
                // 而不是相信服务自己说「都有效」
                let real = Set([s1.id, s2.id, s3.id])
                let badAnchors = notes.items.flatMap(\.anchors).filter { !real.contains($0.segmentID) }
                check(badAnchors.isEmpty, "正常路径：锚点指向真实存在的段落",
                      badAnchors.isEmpty ? "全部命中夹具里的 3 段" : "\(badAnchors.count) 个指向不存在的段")
                let summary = notes.items.first { $0.kind == .summary }
                check(summary?.anchors.map(\.startMillis) == [0, 8_000],
                      "正常路径：一个要点可以带多个锚点，顺序原样保留")
                check(notes.usage?.sliceCount == 1 && value.stats.sliceCount == 1,
                      "正常路径：32 秒的课 = 1 片")
                check(notes.model == ModelText.defaultModel, "正常路径：记下模型标识", notes.model)
                check(notes.sessionID == shortSession.id, "正常路径：笔记挂在被整理的那条会话上")
            }
        }

        // 送出去的到底是些什么。断言的是**提示词本身**，不是「代码里应该有」——
        // 注入这一步写错（拼错字段、加在错误的分支里）不会报错，只会让模型
        // 看不到术语表，然后我们反过来怪模型写错术语
        let sent = recorder.prompts.first ?? ""
        check(sent.contains("[00:00:22]") && sent.contains("第 1/1 片"),
              "提示词：带上了会话轴时间戳与片号")
        check(sent.contains("MNIST") && !sent.contains("00:00:22]〔低置信〕"),
              "提示词：接得上转录原文，且没有把不可信的段误标成低置信")

        // ── 2. 编造锚点 → 整条丢弃，原因正确 ──
        recorder.reset()
        recorder.push("""
        {"items":[
          {"kind":"keyPoint","text":"这条锚点是编的","anchors":["00:99:99"]},
          {"kind":"keyPoint","text":"这条一半真一半假","anchors":["00:00:00","00:42:42"]},
          {"kind":"keyPoint","text":"这条是真的","anchors":["00:00:00"]}
        ]}
        """)
        if case .success(let value) = await awaitResult({ try await generate(session: shortSession, call: call) }) {
            check(value.notes.items.count == 1 && value.notes.items[0].text == "这条是真的",
                  "编造锚点：不存在的锚点整条丢弃",
                  "留下 \(value.notes.items.count) 条")
            let reasons = value.stats.rejected.map(\.reason)
            check(reasons.contains(.anchorNotFound("00:99:99")),
                  "编造锚点：原因指向那个不存在的时间戳",
                  reasons.map(\.label).joined(separator: "、"))
            // 一条真 + 一条假 = 整条丢。这条最容易写错成「丢掉假锚点、留下真的」
            check(value.stats.rejected.contains { $0.reason == .anchorNotFound("00:42:42") },
                  "编造锚点：真假混在一处时也整条丢（不许只丢假的那个锚点）")
            check(value.notes.items.count != 3, "编造锚点：被拒的条目没有混进产出")
        } else {
            check(false, "编造锚点：用例本身抛了异常", "夹具或实现有问题")
        }

        // ── 3. 改了内容：原文没有的数字 / 原文没有的术语 ──
        recorder.reset()
        recorder.push("""
        {"items":[
          {"kind":"keyPoint","text":"本课提到准确率提升了 87%","anchors":["00:00:00"]},
          {"kind":"term","text":"这里用了 Transformer 架构","anchors":["00:00:08"]},
          {"kind":"keyPoint","text":"损失函数的负梯度方向","anchors":["00:00:00"]}
        ]}
        """)
        if case .success(let value) = await awaitResult({ try await generate(session: shortSession, call: call) }) {
            let reasons = value.stats.rejected.map(\.reason)
            check(reasons.contains(.unknownNumber("87")),
                  "改了内容：原文没有的数字被拒", reasons.map(\.label).joined(separator: "、"))
            check(reasons.contains(.unknownTerm("Transformer")),
                  "改了内容：原文没有的术语被拒")
            check(value.notes.items.count == 1 && value.notes.items[0].text == "损失函数的负梯度方向",
                  "改了内容：没改的那条正常留下", "\(value.notes.items.count) 条")
        } else {
            check(false, "改了内容：用例本身抛了异常")
        }

        // 边界（反向）：同一个词，**词表里有**时不该被拒——
        // 否则这条判据会罚一个注入术语表本就想解决的问题
        recorder.reset()
        recorder.push("""
        {"items":[{"kind":"term","text":"这里用了 Transformer 架构","anchors":["00:00:08"]}]}
        """)
        if case .success(let value) = await awaitResult({
            try await generate(
                session: shortSession,
                glossary: [GlossaryEntry(term: "Transformer", aliases: ["transfomer"], note: "一种序列模型")],
                call: call
            )
        }) {
            check(value.notes.items.count == 1 && value.stats.rejected.isEmpty,
                  "改了内容（反向）：词表里的术语不被判成编造",
                  "留下 \(value.notes.items.count) 条")
        } else {
            check(false, "改了内容（反向）：用例本身抛了异常")
        }

        // 术语表注入：断言**送出去的提示词里**有它，而不是「代码里应该有这么一段」。
        // 注入写错（拼错、加进错的分支）不会报错，只会让模型看不到正确写法，
        // 然后我们反过来怪它把术语写错
        let glossaryPrompt = recorder.prompts.last ?? ""
        check(glossaryPrompt.contains("本课术语表") && glossaryPrompt.contains("Transformer"),
              "提示词：术语表真的注进去了（含正确写法与误转写）",
              glossaryPrompt.contains("本课术语表") ? "命中" : "没找到术语表那一段")

        // 低置信标注：`qualityGrade == .poor` 的段必须在提示词里被标出来。
        // 这条也是「标注」这个动作的唯一判据——不标不会报错，只会让模型
        // 把识别崩坏的内容当真事写进笔记
        recorder.reset()
        recorder.push("{\"items\":[]}")
        let poor = seg("这一段是识别崩坏的产物。", 0, 5_000, poor: true)
        let poorSession = makeSession(parts: [(0, 32_000, [s1, s2, s3, poor])])
        _ = await awaitResult { try await generate(session: poorSession, call: call) }
        let poorPrompt = recorder.prompts.last ?? ""
        check(poorPrompt.contains("〔低置信〕这一段是识别崩坏的产物。"),
              "提示词：低置信标记贴在那一段那一行上，不是飘在别处")

        // ── 4. 没有锚点 / kind 认不出来，各自的原因要对 ──
        recorder.reset()
        recorder.push("""
        {"items":[
          {"kind":"keyPoint","text":"这条没给锚点","anchors":[]},
          {"kind":"核心要点","text":"这条 kind 是自由文本","anchors":["00:00:00"]},
          {"kind":"todo","text":"   ","anchors":["00:00:00"]}
        ]}
        """)
        if case .success(let value) = await awaitResult({ try await generate(session: shortSession, call: call) }) {
            let reasons = value.stats.rejected.map(\.reason)
            check(reasons.contains(.noAnchor), "没有锚点：被拒且原因正确")
            check(reasons.contains(.unknownKind("核心要点")),
                  "kind 自由文本：被拒且把那个值报出来")
            check(reasons.contains(.emptyText), "正文为空：被拒且原因正确")
            check(value.notes.items.isEmpty, "三种坏条目一条都没混进产出")
        } else {
            check(false, "坏条目用例本身抛了异常")
        }

        // ── 5. 空白 / 单段 / 极短：不崩，给明确结果，**且不送模型** ──
        let emptySession = makeSession(parts: [(0, 5_000, [seg("", 0, 5_000)])])
        recorder.reset()
        if case .failure(let error) = await awaitResult({ try await generate(session: emptySession, call: call) }) {
            check(error is StudyNotesError, "空转录：抛的是 StudyNotesError", "\(type(of: error))")
            check(recorder.callCount == 0, "空转录：一次模型都没调", "调了 \(recorder.callCount) 次")
        } else {
            check(false, "空转录：应当抛错")
        }

        let tinySession = makeSession(parts: [(0, 3_000, [seg("好，下课。", 0, 3_000)])])
        recorder.reset()
        if case .failure(let error) = await awaitResult({ try await generate(session: tinySession, call: call) }) {
            let message = error.localizedDescription
            check(message.contains("太少"), "极短转录：给出「内容太少」的明确结果", message)
            check(recorder.callCount == 0,
                  "极短转录：一次模型都没调（沿用 PunctuationService 那条教训）",
                  "调了 \(recorder.callCount) 次")
        } else {
            check(false, "极短转录：应当抛错")
        }

        // 单段但够长：应当正常送模型（别把「单段」当成「太短」）
        let oneLong = seg(String(repeating: "梯度下降是优化算法。", count: 12), 0, 30_000)
        recorder.reset()
        recorder.push("""
        {"items":[{"kind":"summary","text":"本片讲梯度下降","anchors":["00:00:00"]}]}
        """)
        if case .success(let value) = await awaitResult({
            try await generate(session: makeSession(parts: [(0, 30_000, [oneLong])]), call: call)
        }) {
            check(value.notes.items.count == 1 && recorder.callCount == 1,
                  "单段但够长：正常送模型产出 1 条", "调了 \(recorder.callCount) 次")
        } else {
            check(false, "单段用例本身抛了异常")
        }

        // ── 6. 模型返回垃圾 / 非 JSON：拒，且**不写盘** ──
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("study-notes-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 先证明这个目录写进去看得见。**这一步不能省**：不先证明「写这个目录
        // 确实能读回来」，下面那句「没有落盘」光看 `load == nil` 是分不清
        // 「没写」和「路径压根不对」的——那就是一条永远为真的假判据
        let probe = StudyNotes(sessionID: shortSession.id, generatedAt: stamp, model: "stub", items: [], usage: nil)
        try? StudyNotesStorage.save(probe, in: scratch)
        let scratchUsable = StudyNotesStorage.load(sessionID: shortSession.id, in: scratch) != nil
        StudyNotesStorage.delete(sessionID: shortSession.id, in: scratch)
        check(scratchUsable, "（前提）临时目录写得进也读得回——下面的「没有落盘」才有意义")

        // 走调用方的顺序：生成成功才落盘。垃圾返回时 generate 抛错，
        // 落盘那一步根本走不到
        recorder.reset()
        recorder.push("好的，请把需要整理的课堂内容发给我。")
        var garbageThrew: (any Error)?
        do {
            let outcome = try await generate(session: shortSession, call: call)
            try StudyNotesStorage.save(outcome.notes, in: scratch)
        } catch {
            garbageThrew = error
        }
        check(garbageThrew is StudyNotesError, "模型返回垃圾：抛 StudyNotesError 而不是产出空笔记",
              garbageThrew?.localizedDescription ?? "居然成功产出了一份笔记")
        check(StudyNotesStorage.load(sessionID: shortSession.id, in: scratch) == nil,
              "模型返回垃圾：磁盘上什么都没留下",
              scratchUsable ? "查的就是上面那个能读能写的目录" : "（前提没成立，这条不作数）")

        // 合法 JSON 但没有 items 键 = 垃圾；items 是空数组 = 合法的空结果
        recorder.reset()
        recorder.push("{\"note\":\"我换个格式\"}")
        if case .failure(let error) = await awaitResult({ try await generate(session: shortSession, call: call) }) {
            check(error.localizedDescription.contains("JSON"),
                  "模型返回合法 JSON 但没有 items：按「不是合法返回」处理")
        } else {
            check(false, "缺 items 键：应当抛错")
        }
        recorder.reset()
        recorder.push("{\"items\":[]}")
        if case .success(let value) = await awaitResult({ try await generate(session: shortSession, call: call) }) {
            check(value.notes.items.isEmpty && value.stats.rejected.isEmpty,
                  "模型返回空的 items：是合法的空结果，不是垃圾")
        } else {
            check(false, "空的 items：不该抛错")
        }

        // ── 7. 分片：跨 10 分钟窗 → 两片，两片的产出都归并进来 ──
        let late = seg("第二段录音的内容，讲的是反向传播的链式法则推导过程，这里要写够字数才不会被当成太短。", 700_000, 720_000)
        let twoSliceSession = makeSession(parts: [(0, 32_000, [s1, s2, s3]), (32_000, 720_000, [late])])
        recorder.reset()
        recorder.push("""
        {"items":[{"kind":"keyPoint","text":"学习率过大会导致震荡不收敛","anchors":["00:00:08"]}]}
        """)
        recorder.push("""
        {"items":[
          {"kind":"keyPoint","text":"反向传播用的是链式法则","anchors":["00:12:12"]},
          {"kind":"keyPoint","text":"学习率过大会导致震荡不收敛","anchors":["00:00:08"]}
        ]}
        """)
        if case .success(let value) = await awaitResult({ try await generate(session: twoSliceSession, call: call) }) {
            check(value.stats.sliceCount == 2 && recorder.callCount == 2,
                  "分片：跨 10 分钟窗切成 2 片，每片一次调用",
                  "\(value.stats.sliceCount) 片 / \(recorder.callCount) 次调用")
            check(value.notes.items.count == 2, "分片：两片的产出都归并进来，跨片重复的去掉",
                  "\(value.notes.items.count) 条")
            // 第二段录音的 offset 是 32000，段内起点 700000 →
            // 会话轴 732000ms。锚点必须是这个数：写成 700000 就说明
            // 有人把「段内相对时间」当成了会话时间
            check(value.notes.items.contains { item in
                item.anchors.contains { $0.startMillis == 732_000 }
            }, "分片：第二片的锚点落在会话轴上（32 秒的片段偏移加进去了）",
               value.notes.items.flatMap(\.anchors).map { "\($0.startMillis)" }.joined(separator: ","))
        } else {
            check(false, "分片用例本身抛了异常")
        }

        // ── 8. 同一秒有多段时，锚点是确定性的（起点最小者） ──
        let dup1 = seg("同一秒里的第一段，写长一点凑够字数下限。", 8_000, 8_400)
        let dup2 = seg("同一秒里的第二段，起点比第一段晚六百毫秒。", 8_600, 9_000)
        let dupSession = makeSession(parts: [(0, 30_000, [s1, dup1, dup2, s3])])
        recorder.reset()
        recorder.push("""
        {"items":[{"kind":"keyPoint","text":"学习率过大会导致震荡不收敛","anchors":["00:00:08"]}]}
        """)
        if case .success(let value) = await awaitResult({ try await generate(session: dupSession, call: call) }),
           let anchor = value.notes.items.first?.anchors.first {
            check(anchor.segmentID == dup1.id && anchor.startMillis == 8_000,
                  "同一秒多段：锚点确定性地取起点最小的那段",
                  "段 \(anchor.segmentID == dup1.id ? "dup1" : "dup2") @ \(anchor.startMillis)ms")
        } else {
            check(false, "同一秒多段用例本身抛了异常")
        }

        // ── 9. 落盘：独立文件、往返一致、删得掉 ──
        recorder.reset()
        recorder.push("""
        {"items":[{"kind":"summary","text":"本片讲梯度下降的原理和学习率的影响","anchors":["00:00:00"]}]}
        """)
        if case .success(let value) = await awaitResult({ try await generate(session: shortSession, call: call) }) {
            do {
                try StudyNotesStorage.save(value.notes, in: scratch)
                let url = StudyNotesStorage.fileURL(sessionID: shortSession.id, in: scratch)
                check(FileManager.default.fileExists(atPath: url.path)
                        && url.lastPathComponent == "\(shortSession.id.uuidString).notes.json",
                      "落盘：文件名是 <uuid>.notes.json（与转录文件分得开）",
                      url.lastPathComponent)
                let back = StudyNotesStorage.load(sessionID: shortSession.id, in: scratch)
                check(back == value.notes, "落盘：读回来和写出去的一致",
                      back == nil ? "读不回来" : "\(back?.items.count ?? 0) 条")
                check(back?.usage?.sliceCount == 1, "落盘：用量（片数/费用）也存下来了")
                StudyNotesStorage.delete(sessionID: shortSession.id, in: scratch)
                check(StudyNotesStorage.load(sessionID: shortSession.id, in: scratch) == nil,
                      "落盘：删得掉")
            } catch {
                check(false, "落盘：写失败", error.localizedDescription)
            }
        } else {
            check(false, "落盘用例本身抛了异常")
        }

        // ── 10. 会话文件里没有这条笔记时读出来是 nil（空手不崩） ──
        check(StudyNotesStorage.load(sessionID: UUID(), in: scratch) == nil,
              "落盘：没有笔记的会话读出来是 nil，不是抛异常")

        // 收尾：把提示词带出去看一眼（不给断言，只为「它到底发了什么」留证据）
        lines.append("")
        lines.append("  最后一次送模型的提示词（截断 300 字）：")
        lines.append("    " + String((recorder.prompts.last ?? "（无）").prefix(300)))

        lines.append(failed == 0
            ? "✅ 学习笔记自检通过（\(passed) 条）"
            : "❌ 学习笔记自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }

    /// 把 `async throws` 收成一个值，好让自检里能用 `if case .success` 分支。
    /// 自检里到处写 `do/catch` 会把每条用例的断言埋进缩进里
    private static func awaitResult<T>(
        _ body: () async throws -> T
    ) async -> Result<T, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

/// 自检用的打桩模型：按序吐预置返回，同时把送出去的提示词记下来。
///
/// `@unchecked Sendable` + 内部加锁，理由同 `RecordingsStore.Collector`：
/// `ModelCall` 是 `@Sendable` 的，闭包要跨并发域改状态，裸的可变捕获
/// 在 Swift 6 下编译不过
private final class StubModel: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String] = []
    private var index = 0
    private var captured: [String] = []

    func push(_ reply: String) {
        lock.lock(); defer { lock.unlock() }
        replies.append(reply)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        replies = []
        index = 0
        captured = []
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return index
    }

    var prompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    /// 加锁必须在**同步**函数里做：`NSLock.lock()` 被标注为「异步上下文不可用」
    /// （Swift 6 会直接报错），所以在闭包里现锁现解是编译不过的。
    /// 把临界区挪进这个普通方法，闭包只负责转调
    func respond(_ system: String, _ user: String) -> ModelTextReply {
        lock.lock(); defer { lock.unlock() }
        captured.append(system + "\n─ 用户 ─\n" + user)
        let reply = replies.isEmpty
            ? "{\"items\":[]}"
            : replies[min(index, replies.count - 1)]
        index += 1
        return ModelTextReply(
            content: reply,
            usage: ModelTextUsage(promptTokens: 1_000, completionTokens: 200, cacheHitTokens: 0)
        )
    }

    var call: StudyNotesService.ModelCall {
        { system, user in self.respond(system, user) }
    }
}
