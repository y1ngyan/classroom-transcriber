import Foundation

/// Whisper 对着**非语音**会稳定吐出的一套模板 —— 判定与处置。
///
/// **为什么必须治**：这不是偶发噪声，是训练数据（YouTube 字幕）留下的固定套路，
/// 已在四处独立复现：2026-09-22 一次 120 秒麦克风静音（用户没说话）、9/20 那条
/// 被毁的录音、以及 9/18、9/20 两条真实课堂录音。课堂里每个安静段落都满足触发
/// 条件，而**置信度判不出来**——实测这些段的平均置信度 0.79–1.00，
/// `TranscriptQualityAssessor` 全部判「可信」（`(音乐)` 那条甚至 0.997）。
/// 所以它必须在**文本**这一层治，不能指望置信度。
///
/// **两条独立的判据，因为两类的可信度不同**（见 `Verdict`）：
/// ① 固定话术是**类别上**不可能出现的词，无条件丢；
/// ② 括号标注要看**内容是不是落在两个封闭语义类里**，而不是「短括号就丢」——
/// 否则会误杀「(我给你们美人四十了…)」这种「整段被括号包住、但确实是人在说话」的段。
///
/// ## 已知盲区（实测，别以为治干净了）
///
/// **自由文本幻觉这一层治不了**。核验者 2026-09-24 用 30 秒**数字静音**
///（全 0 样本）喂探针，whisper 吐的是 `你还在那边等我?`——**置信度 0.735，
/// 没有任何模板特征、也不在括号里**，文本判据判留。这条录音里它会被当成
/// 一句真话进转录。所以「静音上会稳定长出像真话的句子」这件事**还在**，
/// 只是换了个形状；要治它得靠音频侧的证据（比如整窗电平），不是词表。
///
/// 另一侧的边界是 `annotationWords` 的**子串任意位置匹配 + 8 字门**：整段被套进
/// 括号、又含标注词的**真话**会被误丢。2026-09-24 裁决 3 判的 `(我喜欢听音乐)`
/// 和 `(掌声响起来)` 就是这两条，**已各修掉**（前者走人称代词出路，后者让
/// 「掌声」只认光杆形态），改法各自记在 `personalPronouns` 和 `standaloneOnlyWords` 上。
/// 同一天裁决 A/B 又各收紧了窄缝一处：光杆标注一律判丢、署名要看剩余正文。
///
/// **剩下的边界仍然在**，别以为治干净了：`(小白)` 这类**既不是响动也不是身份、
/// 但确实是幻觉**的段，判据没有依据说它是假的，按「宁可漏一条噪声、不赌一个
/// 可能真的人名」留着；`(老师说话)` 同理（「老师」不收——收了会误杀
/// 「(老师说的)」这类真人短句）。这两条是**已知漏网**，裁决 2 判维持现状。
///
/// **繁简都要写全，这不是冗余**：`WhisperEngine.transcribe` 会调 `toSimplified`，
/// 所以走生产链路的文本到这里已经是简体；但
/// - 逐字符置信度试验台、`--confidence-probe` 这些**绕开引擎**的通道不转换，
/// - 而且转换本身依赖 ICU 表，换一次表就可能漏字（`--whisper-selftest` 里
///   「原表漏字 門/請/謝」那条用例就是为这个存在的），
/// - `suppress_regex` 若哪天启用，它作用在**解码期**，那时确实还是繁体。
/// 只写一边，三条里任何一条都会漏。
enum WhisperHallucination {

    /// 判定结果
    enum Verdict: Equatable {
        case keep
        /// 固定话术。**无条件丢**——这些词在课堂里不会出现
        case dropSubtitleTemplate(String)
        /// 非语音标注。**内容落在标注语义类里才丢**
        case dropNonSpeechAnnotation(String)
    }

    // MARK: - ① 固定话术

    /// 「致谢 + 收看/观看」这类收尾话术，**按两半配对匹配，不是枚举整串**。
    ///
    /// ⚠️ **这条设计是被数据打回来的，记在这**：第一版把整串枚举成词表
    /// （「谢谢收看」「谢谢大家收看」…），2026-09-23 跑真实录音立刻漏了一条
    /// ——9/20 那条 200.0 秒处 whisper 吐的是「**谢谢大家的收看**」，中间夹了个
    /// 「的」，**两个都没命中**。当时补了「谢谢大家收看」，可是「谢谢各位同学的
    /// 收看」照样漏。**枚举整串这条路本身就是错的**：致谢词和收看词之间能塞进
    /// 任意多的定语，写多少变体都是打地鼠。
    ///
    /// 所以改成配对：只要「致谢词」出现后 `maxGap` 个字内出现「收看词」就算命中。
    /// 这个形状对误杀也更安全——见下面的 `maxGap` 取值理由。
    struct TemplateFamily: Equatable {
        let head: String
        let tail: String
        /// 中间最多允许夹几个字
        let maxGap: Int
    }

    /// 取 6 是因为实测到的两种形态是「谢谢大家收看」（夹 2）、「谢谢大家的收看」
    /// （夹 3）；留到 6 能盖住「谢谢各位同学的收看」（夹 5）。
    ///
    /// **为什么不能取更大**：老师真会说「谢谢大家，我们今天讲电视收看率」——
    /// 那句里「谢」到「收看」隔着 11 个字。6 和 11 之间留了足够余量，
    /// 这个门就是在「盖住所有定语」和「不跨句误杀」之间取的一个点。
    static let templateFamilies: [TemplateFamily] = [
        .init(head: "谢谢", tail: "收看", maxGap: 6), .init(head: "謝謝", tail: "收看", maxGap: 6),
        .init(head: "谢谢", tail: "观看", maxGap: 6), .init(head: "謝謝", tail: "观看", maxGap: 6),
        .init(head: "谢谢", tail: "觀看", maxGap: 6), .init(head: "謝謝", tail: "觀看", maxGap: 6),
        .init(head: "感谢", tail: "收看", maxGap: 6), .init(head: "感謝", tail: "收看", maxGap: 6),
        .init(head: "感谢", tail: "观看", maxGap: 6), .init(head: "感謝", tail: "观看", maxGap: 6),
        .init(head: "感谢", tail: "觀看", maxGap: 6), .init(head: "感謝", tail: "觀看", maxGap: 6),
    ]

    /// 固定话术里**不成对**的那部分，按子串收。
    ///
    /// 收词的标准只有一条，而且是**可反驳的**：
    /// 「这个字符串出现在真实课堂录音里，是不是**必然为假**」。
    /// 不是「看起来像幻觉」——那是主观的，也没法跟人交代。
    ///
    /// 按这条标准，下面这些**看着很该收、实际必须拒绝**：
    /// - 「分享」——老师会说「大家分享一下自己的答案」
    /// - 「下次见」/「再见」——老师会说「同学们下次见」，这**太常见了**
    /// - 「影片」——老师会说「我们来看一段影片」，所以只收「影片见/影片見」
    /// - 「观看」/「收看」——老师会说「请同学们观看这段视频」。只作为固定话术
    ///   的一部分收（见 `templateFamilies`），不单独收
    /// - 「频道」——媒介/传播类课程真会讲「这个频道的内容」
    /// - **「订阅」「点赞」**——学术语境真会说「我们要订阅这个期刊」；「同学们给
    ///   点个赞」也是老师会开的玩笑。**2026-09-23 之前它们是被单独收进来的**，
    ///   自检里还留着那条「已知误杀」的记录。现在降级成固定搭配（订阅+频道、
    ///   按赞+分享…），代价是光杆的「請訂閱!」会漏网——按「不许误杀」的要求，
    ///   这个方向的取舍是明确的
    static let exactMarkers: [String] = [
        // 订阅 / 点赞：**不再单收**，见 `platformTokens`
        // 「下一个影片见」
        "影片见", "影片見", "下个影片", "下個影片",
        // 小铃铛（提醒订阅的图标，只在平台话术里出现）
        "小铃铛", "小鈴鐺",
    ]

    // MARK: - ①a 署名模板（「字幕组」留下的那一行）

    /// 字幕组留下的署名（「字幕」三字只在署名语境里出现，课堂不会）。
    ///
    /// **它和 `exactMarkers` 分开，是因为判法不同**（2026-09-24 裁决 B）：
    /// 这里命中的是**前缀**，后面还接着正文，所以要看着剩下的是什么才能判。
    ///
    /// `(字幕君:我还没说完)`（9/21，电平 0.01610 vs 门 0.00516，**是响段**）
    /// 就是这条规则存在的理由：署名「字幕君」是幻觉、可剩下的「我还没说完」
    /// 是老师原话，整段丢会把真话一起删掉。
    static let signatureMarkers: [String] = [
        "字幕君", "字幕组", "字幕組", "字幕制作", "字幕製作", "字幕提供", "字幕志愿", "字幕志願",
    ]

    /// 署名的**载荷**——签名标记后面跟的、本身就属于模板的串。只有它才让整段判丢。
    ///
    /// 「我愛你」是 whisper 最有名的收尾幻觉（`whisper` 在静音上最常吐的一句），
    /// 裁决 B 点名要收。「貝爾」是 /tmp/phase4_whisper_push.md 里实测到的译制署名。
    ///
    /// ⚠️ **名单只收观测到的**，不铺——铺专名是打地鼠，而且每一个都可能撞上
    /// 老师真会说到的人名（「贝尔定理」）。剩下那些没命中的载荷，靠的是
    /// 「剩余正文是空的、或者本身就是模板」这条判据，不是我猜
    static let signaturePayloadMarkers: [String] = [
        "我愛你", "我爱你", "貝爾", "贝尔",
    ]

    // MARK: - ①b 平台话术（词元共现）

    /// 平台话术的**词元**。单个词元在课堂上都真会出现——老师会说「大家分享一下」
    /// 「来看一段影片」「这个频道的内容」「请同学们观看」——所以**一个都不判**。
    ///
    /// 但**一段话里同时出现两个、且其中至少一个是平台专有词**，就是平台话术。
    ///
    /// **为什么要共现而不是枚举整串**：2026-09-21 那条录音（383 秒）里，
    /// 同一类收尾话术**一条录音里就有三种写法**——
    ///   `谢谢大家收看! 请订阅、按赞、分享! 下次见!`
    ///   `谢谢大家的收看! 请按赞、订阅、分享唷!`
    ///   `谢谢大家的收看,我们下一次见!`
    /// 枚举整串是打地鼠：`请订阅和分享`（不带顿号）就能从「按赞分享」这种
    /// 固定搭配底下漏过去。共现判据对它天然免疫——它判的是**一段话的用词构成**，
    /// 不是某个具体句子的字面。
    ///
    /// `关注` 刻意**不在**词元里：老师真会说「大家关注一下这个现象」，
    /// 而它对共现门槛没有贡献（真实话术里已经有订阅/按赞了）
    static let platformTokens: [String] = [
        "订阅", "訂閱", "按赞", "按讚", "点赞", "點讚", "小铃铛", "小鈴鐺",
        "分享", "频道", "頻道", "收看", "观看", "觀看", "影片",
    ]

    /// **平台专有**词元：课堂语境里基本不会出现的那些。共现判据要求至少命中一个，
    /// 这一条是**防止误杀**的：没有它，「我们来看一段影片，看完大家分享一下」
    ///（影片 + 分享 = 2 个词元）会被判成平台话术
    static let platformOnlyTokens: [String] = [
        "订阅", "訂閱", "按赞", "按讚", "点赞", "點讚", "小铃铛", "小鈴鐺",
    ]

    /// 共现门槛。取 2 是因为实测到的三种写法命中数分别是 4 / 4 / —（第三种走
    /// `templateFamilies`），2 已经有余量；调高会开始漏「请订阅和分享」
    static let platformTokenThreshold = 2

    // MARK: - ② 括号标注

    /// 非语音标注的**语义类**。判断的是「内容属不属于这两类」，
    /// 而不是「是不是短的括号」。
    ///
    /// 两类都是封闭的，这是它比「长度门」更可靠的地方：
    /// 1. **非说话内容**——whisper 听见的响动（音乐、掌声、音效、静音…）
    /// 2. **说话人身份**——whisper 标注「谁在说」（观众、听众、主席、旁白…）
    ///
    /// 真实数据里观测到的（9/18 + 9/20 两条录音的全部标注段）：
    /// `音效` `音乐` `观众在听音乐` `观众留言` `观众说` `观众问` `观众问好`
    /// `主席说话` `听不清` —— 全部落在这两类里。
    ///
    /// **长度门仍在，但降到辅助位置**：实测标注最长 6 字（`观众在听音乐`），
    /// 留到 8（余量 2）。它挡的是「一条真话恰好含上面某个词」这种罕见情况
    /// （比如老师念「这段音乐……」被整段包进括号——但那种段远长于 8 字）。
    ///
    /// ## 「掌声」在表里、却又不许按子串判（2026-09-24 裁决 A 定的，别改回去）
    ///
    /// 一句话：**这个词表同时担着两个角色，而「掌声」只在第一个角色里成立。**
    /// - 角色一「整段**就是**这个词」（光杆标注）→ 该丢。`(掌声)` 是 whisper
    ///   对中文掌声最常见的标注形状，留着它就是把标注当正文；
    /// - 角色二「整段**含**这个词」（标注类名词 + 轻谓语）→ **不许**用它判。
    ///   因为 `(掌声响起来)` 是老师真会说的整句话（5 字，落在长度门以内），
    ///   而它和实测真标注 `(观众在听音乐)` **在文本上同形**——任何能救前者的
    ///   通则都会同时放过后者。所以只能让「掌声」退出角色二，见
    ///   `standaloneOnlyWords`。
    ///
    /// **这不是放宽**：相对裁决 3 那一版（把「掌声」整个删掉、`(掌声)` 漏网），
    /// 它把 `(掌声)` 从「留」改回「丢」，方向是**收紧**。
    static let annotationWords: [String] = [
        // 类 1：非说话内容
        "音乐", "音樂", "音效", "背景音", "伴奏", "掌声", "掌聲", "鼓掌", "笑声", "笑聲",
        "欢呼", "歡呼", "尖叫", "静音", "靜音", "沉默", "杂音", "雜音", "噪音", "白噪音",
        "听不清", "聽不清", "听不到", "聽不到", "无法辨认", "無法辨認",
        // 类 2：说话人身份 / 场记
        //
        // ⚠️ **只收「指人」的名词，不收「说话/发言」这类动词**：2026-09-23 自检里
        // 「(老师说话)」那条红了，追下去发现命中的不是「老师」而是我顺手收进来的
        // 「说话」——可这是个口语常用动词，`(他不说话)` 这种真人短句会被它误杀，
        // 而观测到的 `(主席说话)` 里「主席」本来就能单独命中，**「说话」一个用例都
        // 不多盖**。所以删掉。这条记在这，是因为「顺手多收一个词」正是误杀的来源
        "观众", "觀眾", "听众", "聽眾", "主席", "旁白",
        // whisper 的英文标注：**本仓库数据里没出现过**（我们固定传 language="zh"），
        // 但它是 whisper 在静音上输出的原始形式，属于同一个成因，所以一起收
        "blank_audio", "music", "applause", "laughter", "silence", "inaudible", "no speech",
    ]

    /// **只认「光杆」**的标注词：整段就是它本人 → 丢；后面只要还跟着别的实词，
    /// 就不许拿它判丢（2026-09-24 裁决 A）。
    ///
    /// 收词标准同 `annotationWords`：这个词**本身**是老师会说的整句话。
    /// 「掌声」是唯一一个这样的词——「掌声响起来」「大家给点掌声」都是课堂原话，
    /// 而 `(掌声响起来)` 和真标注 `(观众在听音乐)` 文本同形，通则分不开。
    ///
    /// ⚠️ 这里**没有实测数据**：三条录音里 `掌声` 一次都没出现过（我 grep 过），
    /// 所以这一条是**理论漏网**的补丁，不是量出来的。裁决 A 明说了这一点
    /// 「鼓掌」和「掌声」**必须同进同出**：裁决 A 从头到尾把它俩当一对
    /// （「退成『都留』（`(掌声)` `(鼓掌)` 一起留）」）。只收「掌声」的话，
    /// 那笔脏账并没有消掉、只是从「掌声 vs 鼓掌」挪到了「`(掌声响起来)` 留
    /// vs `(鼓掌欢迎)` 丢」——核验者 2026-09-24 就是这么指出来的
    static let standaloneOnlyWords: [String] = ["掌声", "掌聲", "鼓掌"]

    /// `annotationWords` / `standaloneOnlyWords` 的**归一化副本** —— 判据里比对的是
    /// 这两份，**不是原表**。
    ///
    /// 为什么必须有它们（2026-09-24，核验者抓到的回归）：比对左边是
    /// `annotationKey(inner)`，它会把空格删掉，可原表里的 `"no speech"` 是**带空格**的
    /// ——`"nospeech"` 既不等于它、也不被它包含，于是这一条**永远不可达**：表里写了、
    /// 代码永远不认。这正是本项目最怕的「看着对、其实没接上」那类缺陷，只不过这次
    /// 发生在判据自己的词表里。
    ///
    /// 修法不是给 `"no speech"` 补一条特例，而是**让表项和 key 走同一个函数**：
    /// 归一化一次、两边共用，这类错就再也犯不出来——将来往表里加任何带空格/标点的词，
    /// 都会自动跟着一起归一化。守这一点的是**两层**，缺一层就有盲区（核验者用变异实测
    /// 出来的，详见 selfTest 里那段注释）：`(no speech)` / `[NO SPEECH]` 两条用例 +
    /// 末尾的词表可达性循环——**两处比对点同时回归**时循环才红，**只坏一处**时它绿、
    /// 靠用例兜住
    static let normalizedAnnotationWords: [String] = annotationWords.map(annotationKey)
    static let normalizedStandaloneOnlyWords: [String] = standaloneOnlyWords.map(annotationKey)

    /// 整段只有音符符号。whisper 用 ♪ 表示「这里是音乐」，真人不可能说出音符字形
    static let musicGlyphs: Set<Character> = ["♪", "♫", "♩", "♬", "♭", "♮", "🎵", "🎶"]

    /// 人称代词 —— 括号标注的**保底出路**用的那唯一一条窄缝（2026-09-24 裁决 3）。
    ///
    /// 观察依据：whisper 的标注要么描述**响动**（音乐/掌声/音效），要么标注
    /// **身份**（观众/主席/旁白），**两类都不带人称代词**。所以括号里出现代词，
    /// 就说明这一句是有人在说话，而不是在标注。
    ///
    /// 「大家」收进来是因为老师真会说「(大家听一下)」这类短句；它是称呼语不是
    /// 身份名词，和 `annotationWords` 里那些「老师会用来指第三方的词」不同
    static let personalPronouns: [String] = [
        "我", "你", "您", "咱", "俺", "他", "她", "它", "祂", "大家",
    ]

    static func containsPersonalPronoun(_ key: String) -> Bool {
        personalPronouns.contains { key.contains($0) }
    }

    /// 判断一个段落是不是幻觉。
    ///
    /// - Parameters:
    ///   - text: 段落正文（引擎已转简体，但这里两种字形都匹配）
    ///   - noSpeechProbability: whisper 给的 `no_speech_prob`（0–1）。
    ///     **⚠️ 当前未参与判定**，理由见 `noSpeechProbabilityIsInert`。
    ///     参数留着是因为链条（引擎 → 段落 → 探针 TSV）已经接通、报告要用它；
    ///     哪天这个字段被证明有信息量，判据在这里加一条就行
    ///   - audioLevel: 这一段对应音频的 RMS。`nil` = 没测到
    ///   - silenceFloor: 底噪门。同样**当前未参与判定**，只用于报告误杀上界
    ///     （见 `WhisperWindowFileRun`）和自检里的边界记录
    static func verdict(
        text: String,
        noSpeechProbability: Double,
        audioLevel: Double?,
        silenceFloor: Double
    ) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ⓪ 整段音符
        if !trimmed.isEmpty && trimmed.allSatisfy({ musicGlyphs.contains($0) || $0.isWhitespace }) {
            return .dropNonSpeechAnnotation(trimmed)
        }

        let normalized = normalize(trimmed)
        guard !normalized.isEmpty else { return .keep }

        // ①a 署名模板 —— **只有剩余正文也命中模板、或者是空的，才丢**。
        // 剩下的正文若不在模板里（如「我还没说完」），说明署名是幻觉、正文是
        // 老师的话，那就**不能整段丢**，落到下面接着判（2026-09-24 裁决 B）
        if let marker = signatureMarkers.first(where: { normalized.contains(normalize($0)) }) {
            // 判等不是判包含：署名载荷要求**整段剩余就是它**。
            // 用 `contains` 会把 `字幕组翻译了贝尔定理`（老师真在讲贝尔定理，
            // 只是同段里出现了署名标记）也一起丢掉——核验者 2026-09-24 构造出来的。
            // 判等对裁决 B 点名的两条用例（`(字幕君:我愛你)` / `(字幕製作:貝爾)`）
            // 结果完全一样，所以是纯收紧
            let remainder = normalized.replacingOccurrences(of: normalize(marker), with: "")
            if remainder.isEmpty
                || signaturePayloadMarkers.contains(where: { remainder == normalize($0) }) {
                return .dropSubtitleTemplate(marker)
            }
        }

        // ①b 其余固定话术
        for marker in exactMarkers where normalized.contains(normalize(marker)) {
            return .dropSubtitleTemplate(marker)
        }
        for family in templateFamilies where templateHit(normalized, family) {
            return .dropSubtitleTemplate("\(family.head)…\(family.tail)")
        }
        // 词元共现。**用一个 Set 数不同词元**，不是数出现次数——
        // 「分享分享分享」只算一个，「订阅+分享」才算两个
        let hits = platformTokens.filter { normalized.contains(normalize($0)) }
        if hits.count >= platformTokenThreshold,
           platformOnlyTokens.contains(where: { normalized.contains(normalize($0)) }) {
            return .dropSubtitleTemplate(hits.joined(separator: "+"))
        }

        // ② 括号标注
        if let inner = parenthesizedContent(trimmed) {
            // ⚠️ 这里的 key **不能用 `normalize`**：那会去掉下划线，而
            // `annotationWords` 里的 `blank_audio` 正是靠下划线认出来的
            //（`_` 属于 `punctuationCharacters`）。2026-09-24 我改这条时踩过，
            // `[BLANK_AUDIO]` 当场变红。见 `annotationKey`
            let key = annotationKey(inner)
            // ②′ **保底出路：括号里出现了人称代词 → 留下**。
            //
            // 理由（2026-09-24 裁决 3 要求的那条出路）：「(我喜欢听音乐)」是**完整的
            // 真话**，被整段套进括号、又含标注词「音乐」，原来会被丢——那是 spec 1.c
            // 「不许误杀」的正面违反。
            //
            // **为什么是代词这一刀**：whisper 的标注描述的是「响动」或「谁在说」，
            // 它**从不用人称代词指人**——代词的存在本身就说明这是有人在讲话，
            // 而不是在标注。这一刀很窄：它**不放松「标注词 + 轻谓语」这条通则**
            // （`(观众在听音乐)` 没有代词，照丢不误），只救那些明确有说话人的括号段。
            //
            // ⚠️ **这一刀刻意偏向「留」**：单字代词按子串匹配，「其他」里的「他」
            // 也会命中。松的方向是漏网、紧的方向是误杀，spec 1.c 要求在这两者之间
            // 选漏网，所以这个偏向是故意的，不是没考虑到
            if containsPersonalPronoun(key) {
                return .keep
            }
            // 整段**就是**某个标注词本身 → 无条件丢，**不受长度门限制**。
            // 长度门是为中文标注定的（实测最长 6 字），可英文标注是下划线连写的：
            // `blank_audio` 有 11 个字符、`sound effect` 有 12 个，会被它整个挡掉。
            // 2026-09-23 自检里 `[BLANK_AUDIO]` 那条就是这么红的
            // ⚠️ 用 `normalizedAnnotationWords`（归一化过的表），不是 `annotationWords`
            // ——原表里的 `"no speech"` 带空格，拿它比 `key` 永远不中。见那张表的注释
            if normalizedAnnotationWords.contains(key) {
                return .dropNonSpeechAnnotation(inner)
            }
            // ⚠️ `!standaloneOnlyWords.contains($0)` 这一半就是裁决 A 的形态约束：
            // 「掌声」能判**光杆**（上一段的精确匹配），但**不许**判子串，
            // 否则 `(掌声响起来)` 会跟着 `(观众在听音乐)` 一起被这条通则带走
            if inner.count <= annotationMaxLength,
               normalizedAnnotationWords.contains(where: {
                   key.contains($0) && !normalizedStandaloneOnlyWords.contains($0)
               }) {
                return .dropNonSpeechAnnotation(inner)
            }
        }

        return .keep
    }

    /// 「致谢词」出现后 `maxGap` 个字内出现「收看词」才算命中。
    ///
    /// 逐个头词出现位置扫过去（而不是只找第一个）：一句里可能出现两次「谢谢」，
    /// 第一次离得远、第二次正好贴着「收看」——只看第一次会漏。
    static func templateHit(_ normalized: String, _ family: TemplateFamily) -> Bool {
        let head = normalize(family.head)
        let tail = normalize(family.tail)
        guard !head.isEmpty, !tail.isEmpty else { return false }
        var search = normalized.startIndex
        while let found = normalized.range(of: head, range: search..<normalized.endIndex) {
            let after = found.upperBound
            // 尾巴整体必须落在 after 之后的窗口里，所以窗口要连 tail 的长度一起放开
            let limit = normalized.index(
                after, offsetBy: family.maxGap + tail.count, limitedBy: normalized.endIndex
            ) ?? normalized.endIndex
            if normalized.range(of: tail, range: after..<limit) != nil { return true }
            search = normalized.index(after: found.lowerBound)
        }
        return false
    }

    /// 非语音标注的最大长度。实测标注最长 6 字（`观众在听音乐`），留两个字余量。
    /// **调大只会更保守**（更少误杀、更多漏网）
    static let annotationMaxLength = 8

    /// 括号内容的比对键：**去掉标点和空格，但保留下划线**。
    ///
    /// 下划线必须留：`annotationWords` 里的 `blank_audio` 靠它认，而 `_` 属于
    /// `punctuationCharacters`——用 `normalize` 会把它一起删掉，`[BLANK_AUDIO]`
    /// 当场漏网（2026-09-24 我踩过）。
    ///
    /// 其余标点要去掉：`(掌声。)`、`(掌 声)` 里的标点是 whisper 加的，
    /// 内容仍然是光杆标注。核验者 2026-09-24 指出：只比原样的话，这些形状
    /// 既不满足精确匹配、又被 `standaloneOnlyWords` 挡在子串匹配外，会漏网
    static func annotationKey(_ inner: String) -> String {
        var strip = CharacterSet.punctuationCharacters
        strip.remove(charactersIn: "_")
        strip.formUnion(.symbols)
        strip.formUnion(.whitespacesAndNewlines)
        return inner.lowercased().unicodeScalars
            .filter { !strip.contains($0) }
            .map(String.init)
            .joined()
    }

    /// 整段就是一对括号/方括号时返回里面的内容，否则 nil。
    ///
    /// 方括号不是补的：whisper 在静音上的原始输出就是 `[BLANK_AUDIO]`
    /// 这种形式，只认圆括号会让它整条漏网
    static func parenthesizedContent(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else { return nil }
        for (open, close) in [
            (Character("("), Character(")")),
            (Character("（"), Character("）")),
            (Character("["), Character("]")),
            (Character("【"), Character("】")),
        ] where first == open && last == close {
            return String(trimmed.dropFirst().dropLast())
        }
        return nil
    }

    // MARK: - `no_speech_prob` 为什么没参与判定

    /// 2026-09-23/24 实测，三条独立证据：
    ///
    /// 1. **`%.6f` 下仍然是 0**。9/18 那条录音**整条 43 段**：39 条 `0.000000`、
    ///    4 条 `0.000019`。所以不是「被 4 位小数显示成 0」。
    ///    （我第一版注释把 `--head 60` 那趟的 17 段写成了「那条录音」——是把子集
    ///    当全集，核验者 2026-09-24 指出。整条的数才是上面这个。）
    /// 2. **那 4 条 0.000019 只出现在第 1 窗（起点 0.0 秒）**，第 2 窗起每条
    ///    恰好 `0.000000`，三条臂（基线跑两次 + 带 suppress_regex）一致。
    ///    **一个跟着内容变的量不会长这个形状**——这是「死字段」而非「值很小」
    ///    最直接的证据。核验者独立复现了这个形状。
    /// 3. **数字静音（全 0 样本）上也是 `0.000000`**。核验者合成 30 秒纯 0
    ///    WAV 喂探针，whisper 照样吐 `你还在那边等我?`（置信度 0.735），而
    ///    `no_speech_prob` 是 0。**能用的 no-speech 检测器在这里应该接近 1.0**。
    ///    这一条比前两条都硬——它不依赖任何统计推断。
    ///
    /// **成因还没完全钉死，但取数路径已排除**：核验者 2026-09-24 逐行核过
    /// `/tmp/wcpp.cpp`（v1.9.4），赋值（:7299，在第一次 decode 之后、
    /// `whisper_process_logits` 之前）、两处入 `result_all`（7782/7830）、
    /// getter（8293）**都是对的**——返回的确实是 `probs[<|nospeech|>]`。
    /// 所以「getter/接线坏了」基本可以排除，零值更像**这个中文模型第一步
    /// 就不给 `<|nospeech|>` 概率质量**。
    ///
    /// **仍未解释的**：那 4 条恰好 `1/vocab` 且**只出现在第 1 窗**——源码里
    /// 没看到只对首窗生效的分支。它不改变结论，但别假装已经解释干净。
    ///
    /// 顺带：`1/51864 ≈ 0.0000193` 看着像均匀分布，但 `1/51865`（multilingual
    /// 常见的另一个 vocab 尺寸）在 `%.6f` 下**同样是 0.000019**——分母没能确证，
    /// 所以别把 51864 当结论写。
    ///
    /// ⚠️ **一个不能拿来当判据的推理**（我犯过，核验者纠正）：拿
    /// `--suppress-regex '的'` 有效来证明「接线是好的，所以零值是模型的事」是
    /// **无效**的——那只证明 `whisper_full_params` 传对了，而 `no_speech_prob`
    /// 走的是另一个函数（`whisper_full_get_segment_no_speech_prob`），两者不相干。
    ///
    /// 结论：**判据不能建在这个字段上**。spec 里规定的那条臂
    ///（「no_speech_prob 门限 + 模板黑名单」）在本项目里是空的，
    /// 这是要报上去裁决的事，不是可以糊过去的事。
    static let noSpeechProbabilityIsInert = true

    // MARK: - 音频佐证（独立于 whisper 的第二个视角）

    /// 一段（时间相对窗口起点）在窗口样本里的 RMS。
    ///
    /// 现在**不参与判定**（判据只看文本），但探针和生产管线都要用它算
    /// 「这一段到底有没有声音」，人判误杀时唯一的客观依据就是它。
    ///
    /// **为什么电平一定要本进程自己算**：whisper 是**被检验对象**。拿它的
    /// 输出当唯一依据，就等于让被告给自己作证——它要是判错了，
    /// 没有任何东西能发现。电平是从原始样本算的，和 whisper 的判断互相独立，
    /// 才有资格当「不许误杀」的对照基准。
    static func level(of segment: WhisperSegment, in samples: [Float], sampleRate: Double) -> Double {
        let start = max(0, Int(Double(segment.startMillis) / 1000 * sampleRate))
        let end = min(samples.count, Int(Double(segment.endMillis) / 1000 * sampleRate))
        guard end > start else { return 0 }
        var sum = 0.0
        for i in start..<end { sum += Double(samples[i]) * Double(samples[i]) }
        return (sum / Double(end - start)).squareRoot()
    }

    /// 一窗的「有语音」电平参考 → 静音门。
    ///
    /// **为什么是相对基准而不是绝对阈值**：麦克风增益每台机器、每次都不一样，
    /// 绝对阈值必然在某台机器上错。这里比的是**同一窗内**——和 CLAUDE.md 里
    /// 「判断基准是和自身比」同一条原则。
    ///
    /// 取 100ms 帧 RMS 的 90 分位当参考：中位数会被静音占满（课堂上静音常过半），
    /// 90 分位才落在「真的在说话」那一档。门取参考的 20%（-14 dB）。
    ///
    /// **已知局限（要如实报，不能假装门总是有效）**：整窗全静音时参考本身也很低，
    /// 这个门就失去分辨力。而且它分不开「响的音乐」和「响的说话」——
    /// 所以它给出来的误杀率只能是**上界**，不是精确值。
    static func speechFloor(samples: [Float], sampleRate: Double) -> Double {
        let frame = Int(sampleRate * 0.1)
        guard frame > 0, samples.count >= frame else { return 0 }
        var rms: [Double] = []
        rms.reserveCapacity(samples.count / frame)
        var index = 0
        while index + frame <= samples.count {
            var sum = 0.0
            for i in index..<(index + frame) { sum += Double(samples[i]) * Double(samples[i]) }
            rms.append((sum / Double(frame)).squareRoot())
            index += frame
        }
        guard !rms.isEmpty else { return 0 }
        rms.sort()
        return rms[min(rms.count - 1, Int(Double(rms.count) * 0.9))] * 0.2
    }

    // MARK: - 归一化

    /// 归一化：去空白、去标点、统一大小写。**不做繁简转换**——
    /// 转换要依赖引擎那条链路，而这一层必须是纯函数（自检要能脱离引擎跑）
    static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }.map(String.init).joined()
    }

    // MARK: - 自检

    /// `--hallucination-selftest`。纯函数，不加载模型、不碰麦克风、不联网。
    ///
    /// **每一条用例都来自真实数据**，不是编的——这是这个自检唯一有价值的地方：
    /// - 「必须丢」组：whisper 在那条 120 秒麦克风静音和 9/20 那条录音里
    ///   实际吐出来的东西（`/tmp/phase4_whisper_push.md` 第 21–23 行原文），
    ///   加上 9/18 / 9/20 两条真实录音上实测到的每一段标注
    /// - 「必须留」组：课堂上真会说的话，**尤其是那几个「看着最像幻觉、
    ///   其实老师天天说」的**（「下次见」「分享一下」「一段影片」「观看」
    ///   「频道」「订阅」）。它们不是凑数的用例，是词表逐条筛过之后留下的边界记录
    ///
    /// 自检**不测 `no_speech_prob` 那条臂**，因为它实测恒 0
    /// （见 `noSpeechProbabilityIsInert`）——用例里那些非零值是为了保留
    /// 「将来这条臂启用后判定不会翻转」的记录，不是它今天在起作用
    static func selfTest() -> [String] {
        var lines = ["─── 幻觉治理自检（纯函数；用例全部来自真实录音）───"]
        var failures = 0

        // (文本, no_speech_prob, 电平, 静音门, 期望)
        // 电平/门现在不参与判定，留着是为了记录「这条用例的电平是多少」
        struct Case {
            let text: String
            let noSpeech: Double
            let level: Double
            let floor: Double
            let shouldDrop: Bool
            let note: String
        }

        let quiet = 0.00040   // 静音段的典型电平
        let floor = 0.00200   // 静音门
        let loud = 0.05000    // 真有人说话的典型电平

        let cases: [Case] = [
            // ── 必须丢：固定话术 ──
            .init(text: "(字幕君:我愛你)", noSpeech: 0.90, level: quiet, floor: floor,
                  shouldDrop: true, note: "麦克风静音 120 秒时实测"),
            .init(text: "(字幕製作:貝爾)", noSpeech: 0.90, level: quiet, floor: floor,
                  shouldDrop: true, note: "同上"),
            .init(text: "謝謝收看!", noSpeech: 0.85, level: quiet, floor: floor,
                  shouldDrop: true, note: "同上"),
            .init(text: "謝謝收看! 請訂閱支持! 按讚支持! 分享支持!", noSpeech: 0.88, level: quiet, floor: floor,
                  shouldDrop: true, note: "同上（整句模板）"),
            .init(text: "谢谢大家收看,我们下一次节目再见!", noSpeech: 0.85, level: 0.00060, floor: floor,
                  shouldDrop: true, note: "9/18 录音 150.0 秒，置信度 1.00"),
            .init(text: "谢谢大家,我们下一个影片见!", noSpeech: 0.70, level: 0.01918, floor: 0.00668,
                  shouldDrop: true, note: "9/18 录音 160.0 秒。「影片见」单收"),
            // 配对匹配的三个边界——**第一版枚举整串时这条是红的**
            .init(text: "谢谢大家的收看!", noSpeech: 0.00, level: 0.00314, floor: 0.00092,
                  shouldDrop: true, note: "9/20 录音 200.0 秒。夹「的」——枚举「谢谢收看」「谢谢大家收看」都漏"),
            .init(text: "谢谢各位同学的收看", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: true, note: "夹 5 字，配对门 maxGap=6 的边界（数据里没有，是推出来的形状）"),
            .init(text: "感谢您的观看", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: true, note: "夹 3 字"),
            // ── 必须丢：平台词元共现（三条都来自 9/21 那条 383 秒录音）──
            .init(text: "谢谢大家收看! 请订阅、按赞、分享! 下次见!", noSpeech: 0.00,
                  level: 0.01862, floor: 0.00637,
                  shouldDrop: true, note: "9/21 录音实测。4 个词元。**注意它含「下次见」**，"
                                         + "而「下次见」是刻意不收的——它靠共现进来，不是靠「下次见」"),
            .init(text: "谢谢大家的收看! 请按赞、订阅、分享唷!", noSpeech: 0.00,
                  level: 0.01472, floor: 0.00562,
                  shouldDrop: true, note: "9/21 录音实测。同一类话术的第二种写法"),
            .init(text: "请订阅和分享", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: true, note: "**这条是共现判据存在的理由**：不带顿号，「按赞分享」"
                                         + "那种固定搭配接不住它，枚举整串必然漏"),
            .init(text: "请订阅一下我们的期刊", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: false, note: "只有「订阅」一个词元——单个词元不判，这是共现门槛的作用"),

            // ── 必须丢：括号标注 ──
            .init(text: "(音樂)", noSpeech: 0.95, level: quiet, floor: floor,
                  shouldDrop: true, note: "麦克风静音时实测"),
            .init(text: "(音效)", noSpeech: 0.00, level: 0.04660, floor: 0.01487,
                  shouldDrop: true, note: "9/18 录音 40.0 秒。**电平比门高 3 倍**，靠内容类丢"),
            .init(text: "(观众在听音乐)", noSpeech: 0.00, level: 0.01385, floor: 0.00535,
                  shouldDrop: true, note: "9/18 录音 80.0 秒（标注里最长的，6 字）"),
            .init(text: "(音乐)", noSpeech: 0.00, level: 0.01000, floor: 0.00628,
                  shouldDrop: true, note: "9/18 录音 90.0 秒。no_speech 为 0 也照样丢——内容类不依赖它"),
            .init(text: "(观众问)", noSpeech: 0.00, level: 0.00759, floor: 0.00196,
                  shouldDrop: true, note: "9/20 录音 20.0 秒（这条录音里出现 8 次）"),
            .init(text: "(观众问好)", noSpeech: 0.00, level: 0.00471, floor: 0.00138,
                  shouldDrop: true, note: "9/20 录音 190.0 秒"),
            .init(text: "(主席说话)", noSpeech: 0.00, level: 0.00466, floor: 0.00128,
                  shouldDrop: true, note: "9/20 录音 220.0 秒"),
            .init(text: "(听不清)", noSpeech: 0.00, level: 0.00437, floor: 0.00128,
                  shouldDrop: true, note: "9/20 录音 240.0 秒"),
            .init(text: "[BLANK_AUDIO]", noSpeech: 0.99, level: quiet, floor: floor,
                  shouldDrop: true, note: "whisper 英文静音标注的原始形式——**方括号**，只认圆括号会漏"),
            .init(text: "♪♪♪", noSpeech: 0.99, level: quiet, floor: floor,
                  shouldDrop: true, note: "音符字形"),

            // ── 必须留：老师真会说的话 ──
            .init(text: "同学们下次见", noSpeech: 0.10, level: loud, floor: floor,
                  shouldDrop: false, note: "「下次见」刻意不收进词表"),
            .init(text: "大家分享一下自己的答案", noSpeech: 0.10, level: loud, floor: floor,
                  shouldDrop: false, note: "「分享」刻意不收"),
            .init(text: "我们来看一段影片", noSpeech: 0.10, level: loud, floor: floor,
                  shouldDrop: false, note: "「影片」单独不收，只收「影片见」"),
            .init(text: "请同学们观看这段视频", noSpeech: 0.10, level: loud, floor: floor,
                  shouldDrop: false, note: "「观看」单独不收——老师真会说"),
            .init(text: "这个频道的内容很有意思", noSpeech: 0.10, level: loud, floor: floor,
                  shouldDrop: false, note: "「频道」单独不收——媒介课真会讲"),
            .init(text: "我们要订阅这个期刊", noSpeech: 0.10, level: loud, floor: floor,
                  shouldDrop: false, note: "**上一版的已知误杀，这一版修好了**：光杆「订阅」不再收"),
            .init(text: "我们来看一段影片,看完大家分享一下", noSpeech: 0.10, level: loud, floor: floor,
                  shouldDrop: false, note: "**共现判据的误杀边界**：「影片」+「分享」= 2 个词元，"
                                         + "但一个平台专有词都没有，所以留。没有这条限制它就被误杀了"),
            .init(text: "谢谢大家!", noSpeech: 0.10, level: 0.04121, floor: 0.00714,
                  shouldDrop: false, note: "9/18 录音 140.0 秒。**「谢谢」后没有收看词，一个字都不能丢**——"
                                             + "配对门的误杀边界就在这里"),
            .init(text: "谢谢大家,我们今天讲电视收看率", noSpeech: 0.10, level: loud, floor: floor,
                  shouldDrop: false, note: "「谢」到「收看」隔 11 字，超出 maxGap=6。**这是 maxGap 取值的依据**"),

            // ── 必须留：真人说话被套进括号（「不许误杀」的核心用例）──
            .init(text: "(我给你们美人四十了,但是你要帮我找一些漂亮点的,像你这么漂亮的)",
                  noSpeech: 0.10, level: 0.03116, floor: 0.01079,
                  shouldDrop: false, note: "9/18 录音 70.0 秒。括号包住但确实是人在说话——长度门挡住它"),
            .init(text: "(好)", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: false, note: "**上一版的已知误杀，这一版修好了**：内容不在标注语义类里就不丢"),

            // ── 代价，明着记下来 ──
            .init(text: "(小白)", noSpeech: 0.00, level: 0.02141, floor: 0.00654,
                  shouldDrop: false, note: "**已知漏网**：9/18 录音 130.0 秒连续 4 次。"
                                          + "「小白」既不是响动也不是身份，判据没有依据说它是假的——"
                                          + "宁可留一条噪声，不赌一个可能真的人名"),
            .init(text: "(老师说话)", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: false, note: "**已知漏网**：「老师」不在身份词表里（收了会误杀「(老师说的)」这类真人短句）。"
                                          + "要收就得把身份词表铺满，那正是误杀的来源，所以停在观测到的那几个"),
            .init(text: "(他不说话)", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: false, note: "**边界用例**：「说话」曾被顺手收进身份词表，这条就会被误杀。"
                                          + "删掉它是为了守住这里——观测到的 `(主席说话)` 里「主席」本来就能单独命中"),
            // ── 裁决 3 的两条保底出路（2026-09-24）──
            // 这两条原来是「已知误杀」被记下来的；裁决 3 判「记用例 ≠ 处理」，
            // 那是 spec 1.c 的正面违反，所以各修了一条窄缝，现在都留下
            .init(text: "(我喜欢听音乐)", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: false, note: "**裁决 3 修好的误杀**：6 字 ≤ 8、子串含「音乐」，"
                                         + "原来必丢。现在走 `personalPronouns`——括号里有「我」，说明是有人在说话"),
            .init(text: "(掌声响起来)", noSpeech: 0.00, level: loud, floor: floor,
                  shouldDrop: false, note: "**裁决 3 修好的误杀**：「掌声」退出了**子串**判定"
                                         + "（`standaloneOnlyWords`）——它和真标注同形，"
                                         + "用通则救不了，只能让它只认光杆那一种形态"),
            // 这一条**钉住那条窄缝有多窄**：它和上面 `(掌声响起来)` 同形
            //（标注类名词 + 轻谓语），只差没有代词。**只要有谁把通则放松了，
            // 它立刻红**——这就是「放宽的只能是这一条窄缝」的可执行形式。
            // 「标注词 + 轻谓语」那条通则本身没有被碰过，见 `annotationWords`
            .init(text: "(他在听音乐)", noSpeech: 0.00, level: 0.01000, floor: 0.00628,
                  shouldDrop: false, note: "**窄缝的边界**：同样的标注词，只多了一个「他」→ 留下。"
                                          + "它和 `(观众在听音乐)`（在上面「括号标注」组里、照丢）"
                                          + "摆在一起，才是那条窄缝的定义"),

            // ── 裁决 A 钉死的形态约束（2026-09-24）──
            // 「掌声」这个词只在「光杆」这一种形态下判丢。这两条 + 上面那条
            // `(掌声响起来)` 留，三条摆在一起才是那条约束的定义。
            // ⚠️ 这一组**没有实测数据**（三条录音里「掌声」一次都没出现），
            // 裁决 A 明说了，我也在 `standaloneOnlyWords` 上记了
            .init(text: "(掌声)", noSpeech: 0.00, level: 0.01000, floor: 0.00600,
                  shouldDrop: true, note: "**裁决 A 的形态约束**：整段就是标注词本人（光杆）→ 丢。"
                                         + "whisper 对中文掌声最常见的就是这个形状"),
            .init(text: "(鼓掌)", noSpeech: 0.00, level: 0.01000, floor: 0.00600,
                  shouldDrop: true, note: "**裁决 A 要的一致性**：它一直判丢，`(掌声)` 现在也判丢，"
                                         + "同一个语义不再两类处理"),

            // ── 裁决 B 钉死的署名规则（2026-09-24）──
            // 署名命中时，只有「剩余正文也命中模板（或为空）」才丢
            .init(text: "(字幕君:我还没说完)", noSpeech: 0.00, level: 0.01610, floor: 0.00516,
                  shouldDrop: false, note: "**裁决 B 的实测用例**：9/21 录音的响段（0.01610 vs 门 0.00516）。"
                                          + "「字幕君」是幻觉、「我还没说完」是老师原话——"
                                          + "整段丢会把真话一起删掉，所以规则改成看剩余正文"),

            // ── 核验者 2026-09-24 构造出来的三条边界，收成用例 ──
            .init(text: "(掌声。)", noSpeech: 0.00, level: 0.01000, floor: 0.00600,
                  shouldDrop: true, note: "标点是 whisper 加的，内容仍是光杆标注。"
                                         + "**原来会漏**——精确匹配比的是原样、子串匹配又被 "
                                         + "`standaloneOnlyWords` 挡着。见 `annotationKey`"),
            .init(text: "(鼓掌欢迎)", noSpeech: 0.00, level: 0.01000, floor: 0.00600,
                  shouldDrop: false, note: "**和 `(掌声响起来)` 对称**：「鼓掌」也进了 "
                                          + "`standaloneOnlyWords`。不收它的话脏账没消掉、只是挪了位置"),
            .init(text: "(字幕组翻译了贝尔定理)", noSpeech: 0.00, level: 0.01000, floor: 0.00600,
                  shouldDrop: false, note: "**署名载荷判等、不是判包含**：老师真在讲贝尔定理，"
                                          + "只是同段里出现了署名标记。用 `contains` 会把这条真话整段丢掉"),

            // ── 核验者 2026-09-24 抓到的回归：词表里的死条目 ──
            // 我改用 `annotationKey` 之后，比对左边删了空格、右边（原表）没删，
            // 于是带空格的 `"no speech"` 永远匹配不上。这两条钉住它
            .init(text: "(no speech)", noSpeech: 0.00, level: 0.01000, floor: 0.00600,
                  shouldDrop: true, note: "**带空格的表项曾经永远不可达**：`annotationKey` 删空格、"
                                         + "原表没删，两边永不相等。改用 `normalizedAnnotationWords`"),
            .init(text: "[NO SPEECH]", noSpeech: 0.00, level: 0.01000, floor: 0.00600,
                  shouldDrop: true, note: "同左，顺带钉住大小写和方括号形态"),
        ]

        for item in cases {
            let verdict = verdict(
                text: item.text, noSpeechProbability: item.noSpeech,
                audioLevel: item.level, silenceFloor: item.floor
            )
            let dropped = verdict != .keep
            let ok = dropped == item.shouldDrop
            if !ok { failures += 1 }
            let kind = switch verdict {
            case .keep: "留"
            case .dropSubtitleTemplate(let marker): "丢·话术(\(marker))"
            case .dropNonSpeechAnnotation: "丢·标注"
            }
            lines.append("  \(ok ? "✅" : "❌") 期望\(item.shouldDrop ? "丢" : "留") 实得\(kind) — \(item.note)")
            lines.append("       「\(item.text)」 无语音\(String(format: "%.2f", item.noSpeech)) 电平\(String(format: "%.5f", item.level)) 门\(String(format: "%.5f", item.floor))")
        }

        // ── 词表可达性不变量（2026-09-24）──
        // 「表里写了、代码永远不认」是这次真出过的缺陷（`no speech` 带空格，归一化后
        // 永不匹配）。逐条把**表项本身**喂回判据，要求它必须被判丢——一条标注词如果
        // 连「整段就是它」都丢不掉，它就是个死条目。
        //
        // ⚠️ **它和上面那 2 条 `(no speech)` 用例是互补的两层，不是谁替代谁**
        // （核验者 2026-09-24 用变异实测出来的，我原来的注释把这点说错了）：
        // - **两处比对点同时回归**（:360 精确臂 + :367 子串臂都不用归一化表）→ 这个
        //   循环变红，用例也变红。这是当初那个 bug 的完整形态。
        // - **只有一处回归**（比如只有精确臂退回原表）→ 子串臂会把 `nospeech` 接住
        //   （8 字 ≤ 长度门），**循环仍绿**，只有用例变红。
        // 所以「循环能覆盖哪些」取决于坏在哪一处，**单点回归它兜不住**。两层的盲区
        // 不重合，删掉任何一层都会漏掉一类
        //
        // 非空转性我做过变异测试：塞一个含人称代词的词（`大家`，会被 ②′ 分支先接走）
        // → 变红并点名；删掉精确臂单独回归 → 由上面那 2 条用例变红
        var dead: [String] = []
        for word in normalizedAnnotationWords
        where verdict(text: "(\(word))", noSpeechProbability: 0.0,
                      audioLevel: 0.01000, silenceFloor: 0.00600) == .keep {
            dead.append(word)
        }
        if dead.isEmpty {
            lines.append("  ✅ 词表可达性：\(normalizedAnnotationWords.count) 个标注词逐条判「光杆即丢」，无死条目")
        } else {
            failures += dead.count
            lines.append("  ❌ 词表可达性：\(dead.count) 个标注词**永远判不丢**（死条目）— \(dead.joined(separator: " / "))")
        }

        let expectDrop = cases.filter(\.shouldDrop).count
        lines.append("")
        lines.append("  汇总：\(cases.count) 条用例（必丢 \(expectDrop) / 必留 \(cases.count - expectDrop)）· 不符 \(failures) 条")
        lines.append(failures == 0 ? "✅ 幻觉治理自检通过" : "❌ 幻觉治理自检未通过")
        return lines
    }
}
