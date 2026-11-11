import Foundation

/// `SubtitleOverlayLogic` 的离线自检（纯函数）。
enum SubtitleOverlaySelfTest {
    struct SelfTestResult { var lines: [String]; var passed: Int; var failed: Int }

    private final class Checker {
        var lines: [String] = []; var passed = 0; var failed = 0
        func note(_ t: String) { lines.append(t) }
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(title)" + (detail.isEmpty ? "" : " · \(detail)"))
        }
    }

    static func run() -> SelfTestResult {
        let c = Checker()
        c.note("悬浮字幕自检（纯逻辑 · 不建窗、不抢焦点）")

        let two = SubtitleOverlayLogic.snapshot(recent: ["第一句", "第二句"], secondsSinceUpdate: 0)
        c.check(two.lines == ["第一句", "第二句"], "两句都在，顺序不变")
        c.check(!two.collapsed, "刚说完话 → 展开")

        let three = SubtitleOverlayLogic.snapshot(recent: ["一", "二", "三"], secondsSinceUpdate: 0)
        c.check(three.lines.count == SubtitleOverlayLogic.maxLines, "最多两行（新的在后）", three.lines.joined(separator: "/"))
        c.check(three.lines.last == "三", "保留最新那句")

        let idle = SubtitleOverlayLogic.snapshot(recent: ["一", "二"], secondsSinceUpdate: 7)
        c.check(idle.collapsed, "停顿 7 秒 → 收起")

        let edge = SubtitleOverlayLogic.snapshot(recent: ["一"], secondsSinceUpdate: SubtitleOverlayLogic.idleSeconds)
        c.check(edge.collapsed, "正好到静止阈值 → 收起（边界算收起）")

        let none = SubtitleOverlayLogic.snapshot(recent: [], secondsSinceUpdate: 0)
        c.check(none.collapsed, "没有内容 → 收起（不显示空气泡）")
        c.check(none.lines.isEmpty, "没有内容时行数为 0")

        let blanks = SubtitleOverlayLogic.snapshot(recent: ["  ", "\n", "有内容"], secondsSinceUpdate: 0)
        c.check(blanks.lines == ["有内容"], "空白句被剔除", blanks.lines.joined(separator: "/"))

        let long = String(repeating: "字", count: 100)
        let trimmed = SubtitleOverlayLogic.trim(long)
        c.check(trimmed.count == SubtitleOverlayLogic.maxCharactersPerLine + 1,
                "超长句截到 46 字 + 省略号", "\(trimmed.count)")
        c.check(trimmed.hasPrefix("…"), "从头部截（句尾结论优先保留）")

        let narrow = SubtitleOverlayLogic.widthUnits(for: ["好"])
        c.check(narrow == SubtitleOverlayLogic.minWidthUnits, "短句用最小宽度（岛不会缩成一个点）")
        let wide = SubtitleOverlayLogic.widthUnits(for: [String(repeating: "字", count: 200)])
        c.check(wide == SubtitleOverlayLogic.maxWidthUnits, "长句用最大宽度（不撑成横幅）")

        c.note("")
        c.note(c.failed == 0 ? "✅ 悬浮字幕自检通过（\(c.passed) 条）"
                              : "❌ 悬浮字幕自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }
}
