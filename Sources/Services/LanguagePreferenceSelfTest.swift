import Foundation

/// `LanguagePreference` 的离线自检（纯函数，不联网、不读配置）。
///
/// 盯的是「界面选的语言和实际解码的语言不一致」这类查不出来的错：
/// whisper 吃两字母码、Apple 吃 BCP-47，两个后端各写一份映射，迟早分家
enum LanguagePreferenceSelfTest {

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
        c.note("转录语言自检（纯函数 · 不读配置、不联网）")

        c.check(LanguagePreference.options.first?.code == "auto", "下拉框第一项是「自动检测」")
        c.check(LanguagePreference.options.count >= 8, "至少覆盖 8 种语言",
                "\(LanguagePreference.options.count) 项")

        c.check(LanguagePreference.normalize(nil) == "zh", "没配置 → 中文（与改造前一致）")
        c.check(LanguagePreference.normalize("") == "zh", "空串 → 中文")
        c.check(LanguagePreference.normalize("  EN ") == "en", "去空白并小写", LanguagePreference.normalize("  EN "))
        c.check(LanguagePreference.normalize("zh-CN") == "zh", "带地区的码截到两字母")
        c.check(LanguagePreference.normalize("auto") == "auto", "自动检测原样保留")
        c.check(LanguagePreference.normalize("xx") == "zh", "不在白名单 → 回落中文（不静默乱传）")

        c.check(LanguagePreference.whisperCode("ja") == "ja", "whisper 拿两字母码")
        c.check(LanguagePreference.whisperCode("auto") == "auto", "whisper 认 auto")

        c.check(LanguagePreference.appleLocales("auto") == ["zh-CN", "en-US"],
                "Apple 的「自动」= 中英两条（它没有逐窗检测）")
        c.check(LanguagePreference.appleLocales("en") == ["en-US"], "英语映射到 en-US")
        c.check(LanguagePreference.appleLocales("xx") == ["zh-CN"], "非法值回落 zh-CN")
        c.check(LanguagePreference.appleLocales("ja") == ["ja-JP"], "日语映射到 ja-JP")

        c.check(LanguagePreference.label(for: "ja") == "日语", "显示中文名")
        c.check(LanguagePreference.label(for: "xx") == "中文",
                "未知码先回落中文、再取它的显示名（不留空白）",
                LanguagePreference.label(for: "xx"))

        c.note("")
        c.note(c.failed == 0
            ? "✅ 转录语言自检通过（\(c.passed) 条）"
            : "❌ 转录语言自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }
}
