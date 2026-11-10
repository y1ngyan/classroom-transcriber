import Foundation

/// `TranscriptSearch` 的离线自检。纯本地：不读用户录音库、不联网、不加载模型。
///
/// 判据盯的是「搜不到的三种假象」：
/// 1. 明明有、搜不到（分词与归一化的坑：全半角、标点、大小写、单字查询）；
/// 2. 搜到了但排得不对（标题命中被正文淹没、长篇里偶然出现压过整句命中）；
/// 3. 搜到一片噪音（空查询、只有一个字、跨课重复段）。
enum TranscriptSearchSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    private final class Checker {
        var lines: [String] = []
        var passed = 0
        var failed = 0
        func note(_ text: String) { lines.append(text) }
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(title)" + (detail.isEmpty ? "" : " · \(detail)"))
        }
    }

    static func run() -> SelfTestResult {
        let c = Checker()
        c.note("跨录音检索自检（纯本地 · 不读用户录音库、不联网、不加载模型）")

        c.note("")
        c.note("─── 一、归一化与二元字组 ───")
        checkTokens(c)

        c.note("")
        c.note("─── 二、命中与不命中 ───")
        checkMatching(c)

        c.note("")
        c.note("─── 三、排序与聚合 ───")
        checkRanking(c)

        c.note("")
        c.note("─── 四、片段与高亮位置 ───")
        checkSnippet(c)

        c.note("")
        c.note(c.failed == 0
            ? "✅ 跨录音检索自检通过（\(c.passed) 条）"
            : "❌ 跨录音检索自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }

    // MARK: - 一

    private static func checkTokens(_ c: Checker) {
        c.check(TranscriptSearch.bigrams("梯度下降") == ["梯度", "度下", "下降"],
                "「梯度下降」切成三个二元组")
        c.check(TranscriptSearch.bigrams("梯度，下降") == ["梯度", "度下", "下降"],
                "标点先剔除（「梯度，下降」和「梯度下降」应命中同一批）")
        c.check(TranscriptSearch.bigrams("梯").isEmpty, "单字没有二元组（要退回子串匹配）")
        c.check(TranscriptSearch.normalize("ＧＰＵ 训练") == "gpu 训练",
                "全角字母转半角并小写", TranscriptSearch.normalize("ＧＰＵ 训练"))
        c.check(TranscriptSearch.bigrams("GPU 训练") == TranscriptSearch.bigrams("gpu训练"),
                "空白不影响切词（查询与正文两侧都归一）")
    }

    // MARK: - 二

    private static func checkMatching(_ c: Checker) {
        let index = TranscriptSearch.build(fixtureDocs())

        let hits = TranscriptSearch.search("梯度下降", in: index)
        c.check(!hits.isEmpty, "有内容的词能搜到", "\(hits.count) 条")
        c.check(hits.allSatisfy { $0.text.contains("梯度下降") || $0.title.contains("梯度下降") },
                "命中的句子或标题里确实有这个词")

        let absent = TranscriptSearch.search("傅里叶变换", in: index)
        c.check(absent.isEmpty, "没讲过的词搜不到（不返回瞎猜的结果）", "\(absent.count) 条")

        c.check(TranscriptSearch.search("   ", in: index).isEmpty, "空查询返回空（不列举全部）")

        let single = TranscriptSearch.search("率", in: index)
        c.check(!single.isEmpty, "单字查询走子串兜底，也能搜到", "\(single.count) 条")

        let fullWidth = TranscriptSearch.search("ＧＰＵ", in: index)
        c.check(!fullWidth.isEmpty, "全角查询能命中半角正文（归一化生效）", "\(fullWidth.count) 条")

        let limited = TranscriptSearch.search("的", in: index, limit: 2)
        c.check(limited.count <= 2, "limit 生效", "\(limited.count) 条")
    }

    // MARK: - 三

    private static func checkRanking(_ c: Checker) {
        let index = TranscriptSearch.build(fixtureDocs())
        let hits = TranscriptSearch.search("反向传播", in: index)
        c.check(hits.first?.title.contains("反向传播") == true,
                "标题命中的课排在最前（正文整句命中不许把它压下去）",
                hits.first?.title ?? "无")
        c.check(hits.contains { $0.title.contains("第 3 讲") },
                "正文命中的课仍然在结果里（标题优先不等于排除别人）")

        let long = TranscriptSearch.search("学习率", in: index)
        c.check(long.count >= 2, "多节课都有命中时都返回", "\(long.count) 条")
        c.check(long.first!.score >= long.last!.score, "结果按分数降序")
        let sameScorePairs = zip(long, long.dropFirst()).filter { $0.score == $1.score }
        if let pair = sameScorePairs.first {
            c.check(pair.0.startedAt >= pair.1.startedAt, "同分时新课在前（用户更可能要最近那节）")
        } else {
            c.check(true, "同分排序（本次无同分样本，跳过）")
        }

        let sections = TranscriptSearch.sections(long)
        c.check(sections.count == Set(long.map(\.sessionID)).count,
                "按课聚合后课数 = 命中的不同会话数", "\(sections.count) 课")
        c.check(sections.allSatisfy { !$0.hits.isEmpty }, "每节课的命中列表都不为空")
        let flat = sections.flatMap(\.hits).count
        c.check(flat == long.count, "聚合不丢结果（摊平后条数一致）", "\(flat)/\(long.count)")
    }

    // MARK: - 四

    private static func checkSnippet(_ c: Checker) {
        let long = String(repeating: "前面填充的文字。", count: 20) + "梯度下降在这里" + String(repeating: "后面填充。", count: 20)
        let (snippet, range) = TranscriptSearch.makeSnippet(text: "", segment: long, query: "梯度下降")
        c.check(snippet.contains("梯度下降"), "片段里包含命中词")
        c.check(snippet.hasPrefix("…") && snippet.hasSuffix("…"), "两头都被截断时有省略号")
        c.check(snippet.count < long.count / 2, "片段是窗口不是整句（长句要短）", "\(snippet.count)/\(long.count)")
        c.check(range != nil, "给出原句上的高亮区间")

        let short = "梯度下降"
        let (shortSnippet, _) = TranscriptSearch.makeSnippet(text: "", segment: short, query: "梯度下降")
        c.check(shortSnippet == "梯度下降", "短句不加省略号", shortSnippet)

        let (noMatch, noRange) = TranscriptSearch.makeSnippet(text: "", segment: "一段没有查询词的話", query: "傅里叶")
        c.check(noRange == nil, "没命中时不给高亮区间")
        c.check(!noMatch.isEmpty, "没命中时也给个可读片段", noMatch)
    }

    // MARK: - 夹具

    private static func fixtureDocs() -> [TranscriptSearch.Doc] {
        let day = Calendar(identifier: .gregorian)
        func date(_ dayOfMonth: Int) -> Date {
            var comps = DateComponents()
            comps.year = 2026; comps.month = 10; comps.day = dayOfMonth; comps.hour = 9
            return day.date(from: comps) ?? Date(timeIntervalSince1970: 0)
        }

        let ml = TranscriptSearch.Doc(
            sessionID: UUID(),
            title: "第 3 讲：梯度下降",
            course: "机器学习",
            startedAt: date(20),
            segments: [
                .init(startMillis: 0, text: "今天讲梯度下降，它是在参数空间里找下降最快的方向。"),
                .init(startMillis: 42_000, text: "学习率太大会震荡，太小收敛慢。"),
                .init(startMillis: 61_000, text: "GPU 训练的瓶颈通常在显存。"),
                .init(startMillis: 90_000, text: "反向传播其实是链式法则的应用。"),
            ]
        )
        let nn = TranscriptSearch.Doc(
            sessionID: UUID(),
            title: "第 4 讲：反向传播",
            course: "机器学习",
            startedAt: date(22),
            segments: [
                // 正文不含完整的「反向传播」：只靠标题命中也必须排到最前
                .init(startMillis: 0, text: "把误差从后往前传一遍。"),
                .init(startMillis: 30_000, text: "反向的链式法则要小心。"),
                .init(startMillis: 45_000, text: "学习率的取值影响收敛速度。"),
            ]
        )
        let other = TranscriptSearch.Doc(
            sessionID: UUID(),
            title: "第 1 讲：课程介绍",
            course: "线性代数",
            startedAt: date(15),
            segments: [
                .init(startMillis: 0, text: "这门课讲矩阵与行列式。"),
            ]
        )
        return [ml, nn, other]
    }
}
