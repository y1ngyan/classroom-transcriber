import Foundation

/// 元问题排除表（设计稿 §7）：**这个提问是不是知识问题？**
///
/// 和 `QuestionDetector` 的分工（§7.1）：检测器回答「这句话是不是提问」
/// （看语法形式），这张表回答「这个提问值不值得查」（看内容）。所以它排在
/// 检测器**之后**，不是重写检测器。
///
/// 纯本地、纯规则：不联网、不调模型（B2a）。命中后**不删条目**，只把
/// `LessonQuestion.filtered` 标成 true——主列表不显示、进折叠区，
/// 折叠区里只有原句、没有查询入口（拍板第 7 条）。
enum MetaQuestionFilter {

    /// 模式（归一化**之后**的文本上匹配，§7.3）。三类按 exact → regex →
    /// contains 的顺序判定；contains 命中后还要过 §7.5 的知识锚点降级
    enum Kind: String, CaseIterable {
        case exact, regex, contains
    }

    struct Rule: Equatable {
        var kind: Kind
        var pattern: String
    }

    /// 24 条初始规则集。分组只是给人读的；判定顺序由 `kind` 决定，
    /// 不按组顺序——`exact` 最硬，必须最先短路
    static let rules: [Rule] = {
        let list: [Rule] = [
            // A. 听觉/设备
            Rule(kind: .exact, pattern: "听得到吗"),
            Rule(kind: .contains, pattern: "听得到"),
            Rule(kind: .exact, pattern: "听得到我说话吗"),
            Rule(kind: .contains, pattern: "听得见吗"),
            Rule(kind: .contains, pattern: "听不清"),
            Rule(kind: .contains, pattern: "听不到"),
            Rule(kind: .exact, pattern: "有声音吗"),
            Rule(kind: .contains, pattern: "麦克风"),
            Rule(kind: .contains, pattern: "声音"),
            Rule(kind: .contains, pattern: "能看到屏幕吗"),
            Rule(kind: .contains, pattern: "看得到吗"),
            Rule(kind: .contains, pattern: "屏幕"),
            // B. 进度/行政
            Rule(kind: .contains, pattern: "第几页"),
            Rule(kind: .contains, pattern: "翻到第"),
            Rule(kind: .contains, pattern: "看到第"),
            Rule(kind: .regex, pattern: "第\\s*(几|[0-9一二三四五六七八九十]+)\\s*(页|章|节|题|部分)"),
            Rule(kind: .contains, pattern: "休息"),
            Rule(kind: .contains, pattern: "下课"),
            Rule(kind: .exact, pattern: "讲完了吗"),
            // C. 理解检查
            Rule(kind: .contains, pattern: "听懂了吗"),
            Rule(kind: .contains, pattern: "听懂了"),
            Rule(kind: .contains, pattern: "明白了吗"),
            Rule(kind: .contains, pattern: "明白吗"),
            Rule(kind: .contains, pattern: "清楚吗"),
            Rule(kind: .contains, pattern: "清楚了吗"),
            Rule(kind: .contains, pattern: "有没有问题"),
            Rule(kind: .contains, pattern: "有问题吗"),
            Rule(kind: .contains, pattern: "还有问题吗"),
            Rule(kind: .contains, pattern: "会不会"),
            Rule(kind: .contains, pattern: "对不对"),
            Rule(kind: .contains, pattern: "是不是"),
            Rule(kind: .contains, pattern: "好不好"),
            Rule(kind: .contains, pattern: "行不行"),
        ]
        return list
    }()

    /// 知识锚点（§7.5）。命中 `contains` 规则后，句子里只要有任何一个锚点，
    /// **不判为元问题**——方向必须是「漏放 > 误杀」：元问题漏进主列表的代价
    /// 是学生多看一眼，知识问题被过滤掉的代价是学生根本没看见。
    ///
    /// 基础是 `QuestionDetector` 的强疑问结构（`zhStrong` / `zhStrongSoft`，
    /// 那边是 private，由 `QuestionDetector.metaAnchorTerms` 暴露一份），
    /// 另加学科痕迹词。「多少」「怎么」也显式列进来：它们在检测器里属于
    /// 弱疑问词（单独不足以判提问），但在这里是**知识问题的确凿痕迹**
    /// （「声音的传播速度是多少」「屏幕上的这个字怎么念」），两处用途不同
    private static let anchors: [String] = QuestionDetector.metaAnchorTerms + [
        "定义", "公式", "定理", "证明", "区别", "原理", "推导", "参数", "函数", "概念",
        "多少", "怎么",
    ]

    /// 是不是元问题。**归一化用 `LessonQuestion.normalizeForDedup`**：
    /// 和去重键同一把尺子，否则「听得到吗？」和「听得到吗」会在两个地方
    /// 得到不同结论
    static func isMetaQuestion(_ text: String) -> Bool {
        let normalized = LessonQuestion.normalizeForDedup(text)
        guard !normalized.isEmpty else { return false }

        if rules.contains(where: { $0.kind == .exact && $0.pattern == normalized }) {
            return true
        }
        if rules.contains(where: { rule in
            rule.kind == .regex
                && normalized.range(of: rule.pattern, options: .regularExpression) != nil
        }) {
            return true
        }
        let containsHit = rules.contains { rule in
            rule.kind == .contains && normalized.contains(rule.pattern)
        }
        guard containsHit else { return false }
        // 有知识锚点 → 放行（§7.5）。只对 contains 降级：exact 是整句就是
        // 元问题，「听得到吗」里出现锚点也无从谈起
        return !anchors.contains { normalized.contains($0) }
    }
}
