import Foundation

/// `--glossary-prompt-selftest`：术语表前移这条路的**离线**判据（P12-1）。
///
/// 为什么单独一条自检：这一包真正会出错的地方**在真实数据上都不出现**。
/// 真实词表有 100 多条，既不空、也不会正好卡在上限上——而「空词表」
/// 「超限截断」「开关关掉」这三件事只在特定输入下现形，一旦错了
/// （比如超限时送了半截词、或者开关关掉了其实还在送），
/// **转录照样出结果，什么都不报**。
///
/// 所以构造做成纯函数（`GlossaryPrompt.build`），这里直接喂边界值：
/// 空词表 / 只差一个字装不下 / 正好装下 / 引导语都放不下 / 重复词 /
/// 开关关掉但词表又短又非空 / **缺省值本身（关）**。
/// 全部离线：不加载模型、不联网、不碰音频、不发声。
enum GlossaryPromptSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    static func run() -> SelfTestResult {
        var lines: [String] = ["术语表前移自检（离线 · 纯函数 · 不加载模型、不联网、不碰麦克风）"]
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        let lead = GlossaryPrompt.lead
        let sep = GlossaryPrompt.separator

        // **注入的假分词器**：1 token/字。真实的 `whisper_token_count` 要加载
        // 模型才算得出来，而这条自检必须离线——所以尺子换成一把确定的假尺子，
        // 算法一个字都不改（同一个 `build`）。两把尺子的差别只影响「装得下几条」，
        // 不影响「超限时截在哪」这套逻辑
        let onePerChar: (String) -> Int = { $0.count }
        // 另一把：2 token/字，用来证明「上限是 token 数」不是嘴上说说——
        // 同一串文本在这把尺子下装得少一半
        let twoPerChar: (String) -> Int = { $0.count * 2 }

        // ── 一、上限本身站得住 ──

        lines.append("")
        lines.append("── 一、上限 ──")
        // whisper.h:526：'maximum of whisper_n_text_ctx()/2 tokens are used
        // (typically 224)'. 上限按 token 卡，取 200 留余量。钉住它：
        // 谁把 budget 调到 224 以上，这里必须红
        check(GlossaryPrompt.tokenBudget <= 224,
              "上限 \(GlossaryPrompt.tokenBudget) token ≤ whisper 说的 224",
              "得 \(GlossaryPrompt.tokenBudget) ≤ 224")
        check(GlossaryPrompt.tokenBudget > onePerChar(lead),
              "上限本身装得下引导语（否则任何词表都送不出去）",
              "上限 \(GlossaryPrompt.tokenBudget) vs 引导语 \(onePerChar(lead)) token")
        // 同一串文本、两把尺子 → 装进的数量必须不同。相同就说明「上限是 token 数」
        // 这句话是假的（上限其实在按字符卡，尺子换不换都一样）
        let rulerProbe = ["梯度下降", "反向传播", "卷积神经网络", "随机梯度下降法", "过拟合"]
        let byChar = GlossaryPrompt.build(terms: rulerProbe, budget: 20, tokenCount: onePerChar)
        let byDouble = GlossaryPrompt.build(terms: rulerProbe, budget: 20, tokenCount: twoPerChar)
        check(byChar.kept.count > byDouble.kept.count,
              "尺子换了、装进的数量就变（上限确实按 token 卡，不是按字符）",
              "1 token/字 \(byChar.kept.count) 条 vs 2 token/字 \(byDouble.kept.count) 条")

        // ── 二、空词表 ──

        lines.append("")
        lines.append("── 二、空词表 ──")
        let empty = GlossaryPrompt.build(terms: [], tokenCount: onePerChar)
        check(empty.text == nil, "空词表 → 不送（text == nil）")
        check(empty.kept.isEmpty && empty.dropped.isEmpty,
              "空词表 → 装进 0、丢掉 0（**不是**「丢掉了全部」）")
        check(!empty.truncated, "空词表 → 不算截断（truncated == false）")

        let blanks = GlossaryPrompt.build(terms: ["", "   ", "\n"], tokenCount: onePerChar)
        check(blanks.text == nil, "只有空串/空白的词表 → 不送")

        // ── 三、截断边界（精确到一字）──

        lines.append("")
        lines.append("── 三、截断边界 ──")
        // 引导语 5 字 + 一个 2 字词 = 7 字。上限给 7 正好装下，给 6 一个字都装不下
        let oneTerm = ["梯度"]
        let exact = GlossaryPrompt.build(terms: oneTerm, budget: lead.count + 2, tokenCount: onePerChar)
        check(exact.text == lead + "梯度", "正好装下：预算 = 引导语 + 词长 → 送出去且内容正确",
              "实得 \(exact.text.map { "「\($0)」" } ?? "nil")")
        check(exact.kept == ["梯度"] && exact.dropped.isEmpty, "正好装下：装进 1、丢掉 0")

        let tooTight = GlossaryPrompt.build(terms: oneTerm, budget: lead.count + 1, tokenCount: onePerChar)
        check(tooTight.text == nil && tooTight.kept.isEmpty,
              "差一个字：预算 = 引导语 + 词长 − 1 → 一条都不送（**不截断引导语**）")
        check(tooTight.dropped == oneTerm, "差一个字：那一条算「丢掉」（不是「装进空串」）")

        let budgetTooSmall = GlossaryPrompt.build(
            terms: ["梯度", "反向传播"], budget: lead.count - 1, tokenCount: onePerChar)
        check(budgetTooSmall.text == nil && budgetTooSmall.dropped.count == 2,
              "预算连引导语都放不下 → 全部算丢掉，且不送")

        // 分隔符只在第 2 条起算：3 条 2 字词 = 5 + 2 + 1 + 2 + 1 + 2 = 13
        let three = ["梯度", "学习", "下降"]
        let threeExact = GlossaryPrompt.build(terms: three, budget: 13, tokenCount: onePerChar)
        check(threeExact.text == lead + three.joined(separator: sep) && threeExact.dropped.isEmpty,
              "3 条正好装下（分隔符只在词之间加，末尾不加）",
              "实得 \(threeExact.text.map { "\($0.count) 字" } ?? "nil")")
        let threeTight = GlossaryPrompt.build(terms: three, budget: 12, tokenCount: onePerChar)
        check(threeTight.kept == ["梯度", "学习"] && threeTight.dropped == ["下降"],
              "少一个字 → 只丢最后那条，前面的照留",
              "装进 \(threeTight.kept.count)、丢掉 \(threeTight.dropped.count)")

        // ── 四、去重 ──

        lines.append("")
        lines.append("── 四、去重与空白 ──")
        let dup = GlossaryPrompt.build(
            terms: ["梯度下降", "梯度下降", " 梯度下降 "], budget: 200, tokenCount: onePerChar)
        check(dup.kept == ["梯度下降"], "同一个词出现 3 次（含带空格）→ 只装一条",
              "装进 \(dup.kept.count) 条")

        // ── 五、开关关掉时的行为（本包最要紧的一条）──

        lines.append("")
        lines.append("── 五、开关关掉 ──")
        // 用一个**又短又非空**的词表：这样「不送」只可能是开关挡的，
        // 不可能是「词表是空的」或者「超限了」——否则这条判据是空转
        let shortGlossary = ["梯度下降", "反向传播"]
        let offEnabled = GlossaryPrompt.resolve(
            terms: shortGlossary, enabled: true, sourceNote: "测试", tokenCount: onePerChar)
        let offDisabled = GlossaryPrompt.resolve(
            terms: shortGlossary, enabled: false, sourceNote: "测试", tokenCount: onePerChar)
        check(offDisabled.text == nil, "开关关掉 → text == nil（这一串不会进 whisper 的 params）")
        check(offEnabled.text != nil, "同一个词表、开关打开 → 送得出去（证明上一条是开关挡的，不是词表空）")
        check(offDisabled.built.kept == shortGlossary,
              "开关关掉时**仍把词表算了一遍**（kept 非空）——所以「关了」和「词表读不出来」在报告里分得开")
        check(offDisabled.reportLine.contains("关"), "关掉时的那行报告说的是「关」",
              "实得：\(offDisabled.reportLine)")

        // ── 六、命中数只认正确写法 ──

        lines.append("")
        lines.append("── 六、命中数 ──")
        let terms = ["梯度下降", "反向传播", "Machine Learning"]
        let text = "今天我们讲梯度下降。梯度下降是最优化方法。反向传播算法……"
        let hits = GlossaryPrompt.hits(terms: terms, in: text)
        check(hits == ["梯度下降", "反向传播"],
              "命中 2/3：没出现的那个不算命中", "实得 \(hits.joined(separator: "、"))")
        check(GlossaryPrompt.hits(terms: terms, in: "mACHINE learning 是机器学习的英文")
              == ["Machine Learning"], "英文不区分大小写（Whisper 的英文大小写本来就不稳）")
        check(GlossaryPrompt.occurrenceCount(terms: ["梯度下降"], in: text) == 2,
              "出现次数按实际出现数（「梯度下降」在样本里出现 2 次）",
              "实得 \(GlossaryPrompt.occurrenceCount(terms: ["梯度下降"], in: text))")
        // aliases 不参与命中：这一包问的是「词表里的词有没有以**正确形式**出现」
        let aliasEntry = GlossaryEntry(term: "Machine Learning", aliases: ["Machin learning"], note: "")
        let aliasHits = GlossaryPrompt.hits(terms: [aliasEntry.term], in: "今天讲了 Machin learning")
        check(aliasHits.isEmpty, "只出现别名（错拼）时**不算命中**——把错也算对等于没在量这件事")

        // ── 七、真实词表上的实况（读磁盘，只读）──

        lines.append("")
        lines.append("── 七、真实词表的实况（只读磁盘，不写）──")
        // ⚠️ 这一节用的是**假尺子**（1 token/字），所以「装进几条」不是真值
        // ——真实 tokenizer 对英文术语便宜得多（约 3 字/token），真值见
        // `tools/probes/glossary_prompt.sh` 打出来的那一行。这里只用它验
        // 「上限逻辑在真实规模的词表上不会一条都装不下 / 不会装爆」
        let diskTerms = GlossaryStore.termsFromDisk()
        let diskBuilt = GlossaryPrompt.build(terms: diskTerms, tokenCount: onePerChar)
        check(diskBuilt.tokens <= GlossaryPrompt.tokenBudget,
              "真实词表构造结果不超过上限", "\(diskBuilt.tokens) ≤ \(GlossaryPrompt.tokenBudget) token")
        if diskTerms.isEmpty {
            lines.append("  ⚠️ 磁盘术语表读不出内容（文件不在或为空）——这一节只报告，不算红")
            lines.append("     路径：\(GlossaryStore.storeFilePath)")
        } else {
            lines.append("  磁盘术语表 \(diskTerms.count) 条 → 装进 \(diskBuilt.kept.count) 条"
                         + "、丢掉 \(diskBuilt.dropped.count) 条、共 \(diskBuilt.characterCount) 字")
            lines.append("  「一条都没装下」与「装了一部分」是两回事：这里必须装进 ≥ 1 条")
            check(!diskBuilt.kept.isEmpty, "真实词表至少装进 1 条（上限不是小到什么都装不下）")
        }

        // 报告行本身也要能打出来——它是「这一场送了什么」的唯一凭证
        let diskReport = GlossaryPrompt.resolve(
            terms: diskTerms, enabled: true, sourceNote: "磁盘", tokenCount: onePerChar
        ).reportLine
        lines.append("")
        lines.append("  报告行示例：\(diskBuilt.truncated ? "（当前真实词表会截断）" : "（当前真实词表全装得下）")")
        lines.append("  \(diskReport)")

        // ── 八、缺省值本身（关）──

        lines.append("")
        lines.append("── 八、缺省值 ──")
        // 缺省值是一条**会变的决定**，所以它得被一条判据钉住，不能只活在注释里：
        // 2026-10-13 的 A/B 把它从「开」翻成「关」（数字见 `AppConfig` 的注释）。
        // 断言的是**纯函数**：真 accessor 读的是本进程的配置和环境变量，
        // 在这个自检进程里两样都不是缺省状态，拿它断言缺省值等于撞运气。
        // 「文件里没写」（nil）和「用户明确关掉」（false）在这里结果相同、
        // 但含义不同——所以两条都断，防止有人把 nil 走成 true 又把它当成「用户关的」
        check(AppConfig.glossaryPromptEnabled(fileValue: nil, envValue: nil) == false,
              "文件里没写这一项 → 缺省关（A/B 实测：开臂段数 13→4、置信度全面下降、命中 0/105）")
        check(AppConfig.glossaryPromptEnabled(fileValue: false, envValue: nil) == false,
              "用户明确配成 false → 关")
        check(AppConfig.glossaryPromptEnabled(fileValue: true, envValue: nil) == true,
              "用户明确配成 true → 开（开关没被这一改堵死，还能手动打开）")
        check(AppConfig.glossaryPromptEnabled(fileValue: nil, envValue: "1") == true,
              "环境变量 GLOSSARY_PROMPT=1 仍然能覆盖成开（无头 A/B 靠它）")
        check(AppConfig.glossaryPromptEnabled(fileValue: true, envValue: "0") == false,
              "环境变量优先于文件（无头 A/B 要在「用户开着」时也能跑关的那一臂）")

        lines.append("")
        lines.append("  ── 结果：\(passed) 过 / \(failed) 红 ──")
        // 这一行是给 `exit_codes.sh` 的 `run_assert` 断言的：那条扫描只看一行
        // 输出、不看退出码的含义（退出码只分红绿，说不出「过了几条」）
        lines.append("  \(failed == 0 ? "✅" : "❌") 术语表前移自检通过（\(passed) 条）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }
}
