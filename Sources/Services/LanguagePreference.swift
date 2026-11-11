import Foundation

/// 转录语言的选择与映射。
///
/// 两个后端吃的东西不一样：whisper 要的是 ISO-639-1 两字母码（`zh`/`en`/…，
/// 或 `auto` 让它自己判），Apple Speech 要的是 BCP-47 locale（`zh-CN`/`en-US`）。
/// 界面只能给用户一个下拉框，所以映射必须**只此一处**——两边各写一份，
/// 迟早出现「界面选英语、whisper 还在按中文解」这种查不出来的错。
enum LanguagePreference {

    struct Option: Equatable {
        var code: String
        var label: String
    }

    /// 下拉框的内容。顺序即显示顺序；`auto` 放第一个（默认它最省心）
    static let options: [Option] = [
        Option(code: "auto", label: "自动检测"),
        Option(code: "zh", label: "中文"),
        Option(code: "en", label: "英语"),
        Option(code: "ja", label: "日语"),
        Option(code: "ko", label: "韩语"),
        Option(code: "de", label: "德语"),
        Option(code: "fr", label: "法语"),
        Option(code: "es", label: "西班牙语"),
        Option(code: "ru", label: "俄语"),
    ]

    static let defaultCode = "zh"

    /// 归一：去空白、小写、`zh-CN` 这种带地区的截到两字母。
    /// 不在白名单里 → 回落到 `zh`（缺省行为，和改造前一致）
    static func normalize(_ raw: String?) -> String {
        guard let raw else { return defaultCode }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return defaultCode }
        let base = String(clean.split(separator: "-").first ?? Substring(clean))
        return options.contains { $0.code == base } ? base : defaultCode
    }

    /// 给 whisper 的 language 参数。`auto` 原样传（whisper 认这个值）
    static func whisperCode(_ raw: String?) -> String {
        normalize(raw)
    }

    /// 给 Apple Speech 的 locale 列表。
    ///
    /// `auto` 给中英两条：课堂里中英混讲是常态，给一条「自动»不存在这个能力
    /// （`SpeechTranscriber` 的 locale 是显式指定的），两条能覆盖绝大多数情况。
    /// 其余语言给「语言 + 常用地区」一条
    static func appleLocales(_ raw: String?) -> [String] {
        switch normalize(raw) {
        case "auto": return ["zh-CN", "en-US"]
        case "zh": return ["zh-CN"]
        case "en": return ["en-US"]
        case "ja": return ["ja-JP"]
        case "ko": return ["ko-KR"]
        case "de": return ["de-DE"]
        case "fr": return ["fr-FR"]
        case "es": return ["es-ES"]
        case "ru": return ["ru-RU"]
        default: return ["zh-CN"]
        }
    }

    /// 界面显示名（找不到就用码本身，不要显示空白）
    static func label(for raw: String?) -> String {
        let code = normalize(raw)
        return options.first { $0.code == code }?.label ?? code
    }
}
