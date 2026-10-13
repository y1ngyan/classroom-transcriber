import Foundation

/// 把「本次录音的术语表」构造成 whisper 的 `initial_prompt`（P12-1）。
///
/// **它解决的是哪一类错**：中英混合课堂只挂单个 `zh-CN` 模型（同时挂
/// zh-CN + en-US 两路结果不会融合，各说各话），于是英文术语被按读音转写成
/// 拉丁字母——实测 "machine learning" → "Machin learning"、
/// "gradient descent" → "gredion destent"。今天这些词靠**事后**一轮 LLM
/// 校正拉回来（`GlossaryService.correct`，词表是它的锚点）。
///
/// 前移是**事前偏置**：把这些词当作「上一段已有文本」喂给解码器，让它一开始
/// 就倾向于拼出这些词。事前与事后**两道工序共存**、互相兜底——事后校正能改
/// 回的错，事前能少犯一些；事前没兜住的，事后照旧改。
///
/// **为什么用 `initial_prompt`、而不去动 `no_context`**
/// （这一段原先写错过，2026-10-13 按实测改正）：原文说「`no_context = false`
/// 是 whisper 的出厂默认，它把上一窗的输出接回来当上下文」——**两句都不对**。
/// 实测 `whisper_full_default_params` 打出来就是 `no_context = true`
/// （v1.9.4 源码 `whisper.cpp:6044`），而 `whisper_full` **每次调用开头**都会
/// 因为它是 true 而清空累积的上下文（`whisper.cpp:7040`）。我们一窗一次
/// `whisper_full`、又从不改这个字段，所以**窗口之间根本没有前文条件化**，
/// 「复读自己」那个机制在这里不成立（要它成立得同时把 `no_context` 改成 false）。
///
/// 两件事因此分开说：
/// - `no_context = true` 管的是「要不要把**上一次解码的文本**接回来」，
///   我们的答案是不要——保持不动；
/// - `initial_prompt` 管的是「解码前先塞一段**固定的引子文本**」。它和
///   `no_context` 不冲突：清空发生在塞词表**之前**（`whisper.cpp:7040` 在
///   `7062` 那段的上面），所以即使 `no_context = true`，词表照样进上下文。
///
/// 我们要的正是后者：一张**不随窗口变化**的词表，只提供「这些词长什么样」，
/// 不提供「上一句是什么」。所以这一包只动 `initial_prompt`。
///
/// **为什么构造是纯函数、但要把分词器从外面传进来**：
/// 这一包的主判据是「构造对不对」（空词表 / 超限截断），而那两个边界在真实
/// 词表上都不出现（105 条既不空、也不会正好卡在上限上）。做成纯函数，
/// 自检才能不加载模型、不联网、直接喂边界值把它跑红。
/// 但**上限是 token 数的**，而 token 数只有模型的分词器算得出来——所以
/// 计数函数是注入的：自检注入一个确定的假计数器（1 token/字），
/// 生产注入 `whisper_token_count`。算法只有一份，两边的差别只是那把尺子。
enum GlossaryPrompt {

    /// 引导语。whisper 把 `initial_prompt` 当「上一段已有文本」用，
    /// 所以措辞要**像正文**（像一个说出这些词的句子），而不是像一张标签栏——
    /// 一串裸词没有句法，模型更容易把它当成噪声
    static let lead = "本课术语："

    /// 词与词之间的分隔。中文顿号，同样是「像正文」的一部分
    static let separator = "、"

    /// **上限**：整条 prompt 的 token 数上限。
    ///
    /// whisper 侧的限制在 `whisper.h:526`：
    /// "maximum of whisper_n_text_ctx()/2 tokens are used (typically 224)"。
    /// 取 **200** 留一截余量：224 是「typically」，不同模型的 `n_text_ctx`
    /// 不一样，卡满没有好处（超了 whisper 自己会截，截在哪我们不知道——
    /// 与其让它替我截，不如我自己在词边界上截）。
    ///
    /// **为什么这个上限是 token 而不是字符**（第一版写成字符，实测后改掉）：
    /// 字符→token 的换算率随文本而变，中文常用词约 1 token/字，生僻组合
    /// 能到 2-3；按最坏情形 2 折算出来的字符上限只有 110 字，而真实词表
    /// 105 条里有 99 条装不下——**为了防一个测都没测过的最坏情况，把功能
    /// 本身废掉了**。计数函数是注入的，量一次真值比推一个界更省事也更准。
    ///
    /// 实测（`--whisper-window-file --glossary-prompt`，medium 模型，2026-10-10）：
    /// 这台机器的真实词表（105 条）构造出来是 **597 字 / 198 token**，
    /// 上限 200 只压掉 2 个 token 的余量 → 装进 48 条、丢掉 57 条。
    /// 所以 200 这个数**不是随手取的**：再小一点就会有更多术语被挡在外面，
    /// 再大一点就贴着 whisper 自己会动手截的那条线（224）。
    static let tokenBudget = 200

    /// 构造结果。**四个字段都要报出来**：只报一句「已启用术语前移」的话，
    /// 「词表是空的」和「词表太长全被截掉了」两种完全不同的情形在输出上
    /// 长得一模一样
    struct Built: Equatable, Sendable {
        /// 要送给 whisper 的 prompt。nil = **不送**（空词表 / 一条都装不下）
        var text: String?
        /// 真的装进去了的术语（按词表原顺序）
        var kept: [String]
        /// 因为超限被丢掉的术语
        var dropped: [String]
        /// `text` 的**实测** token 数（不是折算）。nil 时是 0
        var tokens: Int

        var truncated: Bool { !dropped.isEmpty }
        /// 字符数。nil 时是 0
        var characterCount: Int { text?.count ?? 0 }
    }

    /// 一次「要不要送、送什么」的完整裁决。
    ///
    /// **为什么不能只返回一个 `String?`**：`nil` 有三条完全不同的来路
    /// ——开关关着、词表是空的、词表太长一条都装不下。前一条是「按你的
    /// 要求没送」，后两条是「该送但没送成」。三级产物长得一样的话，
    /// 用户看到「已启用术语前移」而实际一个词都没送进去，谁也发现不了
    struct Resolution: Equatable, Sendable {
        var enabled: Bool
        var built: Built
        /// 术语是从哪儿来的（报告里要用）。开关关着时也要说清来源，
        /// 否则「关了」和「读了 0 条」分不开
        var sourceNote: String

        /// 实际要送进 whisper 的那串。关闭 = nil（**与今天的参数逐字节一致**）
        var text: String? { enabled ? built.text : nil }

        /// 给日志/报告的一行
        var reportLine: String {
            guard enabled else { return "术语前移：关（\(sourceNote)）→ 不送 initial_prompt" }
            guard let text = built.text else {
                return "术语前移：开（\(sourceNote)）→ **没送**（构造不出可用的 prompt）"
            }
            return "术语前移：开（\(sourceNote)）→ 装进 \(built.kept.count) 条"
                + "\(built.truncated ? "、超限丢了 \(built.dropped.count) 条" : "")"
                + "、\(text.count) 字 / \(built.tokens) token"
        }
    }

    /// 裁决。`enabled` 由 `AppConfig.glossaryPromptEnabled` 来；
    /// `tokenCount` 由调用方注入（生产 = `whisper_token_count`）
    static func resolve(
        terms: [String],
        enabled: Bool,
        sourceNote: String,
        tokenCount: (String) -> Int
    ) -> Resolution {
        Resolution(
            enabled: enabled,
            built: build(terms: terms, tokenCount: tokenCount),
            sourceNote: sourceNote
        )
    }

    /// 构造。**顺序敏感、截断点是确定的**：从头开始装，装不下就停，
    /// 不在后面补小的词——补了的话「装进哪几条」会随后面词的长度而变，
    /// 判据就没法钉死一个期望值了。
    ///
    /// - Parameters:
    ///   - budget: token 数上限。默认 `tokenBudget`
    ///   - tokenCount: 「这串文本多少 token」。**注入**，见类型注释
    static func build(
        terms rawTerms: [String],
        budget: Int = tokenBudget,
        tokenCount: (String) -> Int
    ) -> Built {
        // 去重 + 去空白：词表里同一个词出现两次（不同 id）时，
        // 送两遍只会白占 budget，而 budget 是要按 token 换算的稀缺资源
        var seen = Set<String>()
        var terms: [String] = []
        for raw in rawTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            if seen.insert(term).inserted { terms.append(term) }
        }
        guard !terms.isEmpty else { return Built(text: nil, kept: [], dropped: [], tokens: 0) }

        // 预算连引导语都放不下 → 一条都不送。**不截断引导语**：
        // 「本课术语：梯」这种半截引导语既不像正文，又把一个残缺的词喂给了模型
        guard budget > 0, tokenCount(lead) <= budget else {
            return Built(text: nil, kept: [], dropped: terms, tokens: 0)
        }

        var kept: [String] = []
        var dropped: [String] = []
        for (index, term) in terms.enumerated() {
            // 分隔符由 joined 在词之间补上——第一个词前面没有顿号
            let probe = lead + (kept + [term]).joined(separator: separator)
            // 每条候选都现量一次：**不估**。估的时候要用「每字几 token」，
            // 而那个比率正是这里最不确定的东西（见 `tokenBudget` 的注释）
            if tokenCount(probe) > budget {
                dropped = Array(terms[index...])
                break
            }
            kept.append(term)
        }

        guard !kept.isEmpty else {
            return Built(text: nil, kept: [], dropped: dropped, tokens: 0)
        }
        let text = lead + kept.joined(separator: separator)
        return Built(text: text, kept: kept, dropped: dropped, tokens: tokenCount(text))
    }

    /// **主判据**：一段转录文本里「正确出现」的词表术语个数。
    ///
    /// 只匹配 `term`（正确写法），**不看 `aliases`**：aliases 记的是已知的
    /// *错误*转写形式，拿它去数「命中」等于把错也算成对。这一包要回答的是
    /// 「前移有没有让词表里的词**更多地以正确形式出现**」，所以只认正确形式。
    ///
    /// 英文术语不区分大小写（Whisper 的英文大小写本来就不稳，实测会
    /// 擅自改大小写——见 `GlossaryService` 的注释）；中文没有大小写问题。
    static func hits(terms: [String], in text: String) -> [String] {
        let haystack = text.lowercased()
        return terms.filter { term in
            let needle = term.lowercased()
            return !needle.isEmpty && haystack.contains(needle)
        }
    }

    /// 命中的**次数**（同一个词出现 3 次算 3）。报告里两个数都给：
    /// 个数回答「覆盖了多少词」，次数回答「这些词出现了多少次」
    static func occurrenceCount(terms: [String], in text: String) -> Int {
        let haystack = text.lowercased()
        return terms.reduce(0) { total, term in
            let needle = term.lowercased()
            guard !needle.isEmpty else { return total }
            var count = 0
            var search = haystack.startIndex
            while let found = haystack.range(of: needle, range: search..<haystack.endIndex) {
                count += 1
                search = found.upperBound
            }
            return total + count
        }
    }
}
