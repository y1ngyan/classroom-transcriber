import SwiftUI
import AppKit

/// 设计 token，对应原规格里的 `theme` 对象。
///
/// **深色模式为什么不用 `useColorScheme()` 手动切**：原规格是 React Native
/// 的写法，那边没有系统级的语义色，只能自己读 scheme 再挑一套值。macOS 上
/// 手动切会漏——系统在 App 运行时切换外观（或某些控件在别的外观上下文里
/// 渲染）时，读到的值不会更新，而 `NSColor` 的动态 provider 是每次解析时
/// 现问一次系统，不存在过期。用户可见的结果一样（跟随系统），只是不会漏。
///
/// **这个项目没有 Xcode，所以没有 Asset Catalog**：动态颜色只能写在代码里。
enum Theme {

    // MARK: - 颜色

    /// 页面背景 #FFFFFF / #000000
    static let background = adaptive(light: 0xFFFFFF, dark: 0x000000)
    /// 次级背景（分组块、输入框底）#F5F5F7
    static let backgroundSecondary = adaptive(light: 0xF5F5F7, dark: 0x1C1C1E)
    /// 正文 #1D1D1F
    static let textPrimary = adaptive(light: 0x1D1D1F, dark: 0xFFFFFF)
    /// 次要文字 #86868B
    static let textSecondary = adaptive(light: 0x86868B, dark: 0x98989D)
    /// 三级文字 / 时间戳 #D2D2D7
    static let textTertiary = adaptive(light: 0xD2D2D7, dark: 0x48484A)
    /// 分隔线 #D2D2D7
    static let separator = adaptive(light: 0xD2D2D7, dark: 0x38383A)

    /// 强调色 / 英文文字色 #0071E3。
    ///
    /// 两种外观用同一个值：规格只给了一个。实测它在黑底上对比度 4.45:1，
    /// 紧贴 AA 的 4.5 线但没到——够用，不值得为此偏离规格去换 #0A84FF。
    static let accent = Color(hex: 0x0071E3)

    /// 状态色。规格给的这三个值本身就是苹果深色外观那一套，
    /// 在白底黑底上都立得住，所以两种外观共用。
    static let success = Color(hex: 0x30D158)
    static let warning = Color(hex: 0xFF9F0A)
    static let error = Color(hex: 0xFF453A)

    // MARK: - 旧名字（颜色）

    /// 正文色。保留旧名，调用点太多，一次改干净反而容易漏
    static let body = textPrimary
    static let subtle = textTertiary
    static let pageBackground = background

    // MARK: - 间距

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 40
        /// 区块之间的留白。规格里「section 间距 80」就是它——
        /// 取代卡片：靠留白分组，而不是靠框
        static let xxl: CGFloat = 80
    }

    /// 圆角。`button` 的 980 是「永远等于半高」的惯用写法，
    /// SwiftUI 里对应的东西叫 `Capsule()`，见 `PillButton`
    enum Radius {
        static let card: CGFloat = 18
        static let button: CGFloat = 980
        static let input: CGFloat = 12
    }

    // MARK: - 旧名字（尺寸）

    static let pagePadding: CGFloat = Spacing.xl
    static let segmentSpacing: CGFloat = Spacing.md
    static let titleSize: CGFloat = 48
    static let subtitleSize: CGFloat = Text.caption.size
    static let bodySize: CGFloat = Text.body.size
    static let captionSize: CGFloat = Text.caption.size

    // MARK: - 字号

    /// 字体 token。规格给的是 fontSize / letterSpacing / lineHeight，
    /// SwiftUI 那边对应 `size` / `tracking` / **`lineSpacing`**——
    /// 注意最后这个不是同一个东西，见 `lineSpacing` 的说明。
    struct TextStyle {
        let name: String
        let size: CGFloat
        let weight: Font.Weight
        let tracking: CGFloat
        /// 规格里的行高（一行占的总高度）
        let lineHeight: CGFloat
        var monospaced = false

        var font: Font {
            if monospaced {
                return .system(size: size, weight: weight, design: .monospaced)
            }
            return .system(size: size, weight: weight)
        }

        /// 规格的 `lineHeight` 是「整行高度」，SwiftUI 的 `lineSpacing` 是
        /// 「行与行之间额外加多少空隙」——两者差一个字体自身的行高。
        /// 直接写 `.lineSpacing(25)` 会得到 25 的空隙，行距翻倍。
        ///
        /// 负数（规格要求比字体自然行高更紧）SwiftUI 表达不了，只能夹到 0。
        /// 受影响的只有 largeTitle：48pt 的自然行高约 57，规格要 52。
        /// 它只用在单行的页面大标题上，行距本来就不显现。
        var lineSpacing: CGFloat {
            guard !monospaced else { return 0 }
            let natural = Self.naturalLineHeight(size: size, weight: weight)
            return max(0, lineHeight - natural)
        }

        private static func naturalLineHeight(size: CGFloat, weight: Font.Weight) -> CGFloat {
            let nsWeight: NSFont.Weight
            switch weight {
            case .semibold: nsWeight = .semibold
            case .medium: nsWeight = .medium
            case .bold: nsWeight = .bold
            case .light: nsWeight = .light
            default: nsWeight = .regular
            }
            let font = NSFont.systemFont(ofSize: size, weight: nsWeight)
            return font.ascender - font.descender + font.leading
        }
    }

    enum Text {
        static let largeTitle = TextStyle(
            name: "largeTitle", size: 48, weight: .semibold, tracking: -0.5, lineHeight: 52
        )
        static let title = TextStyle(
            name: "title", size: 28, weight: .semibold, tracking: -0.3, lineHeight: 34
        )
        static let body = TextStyle(
            name: "body", size: 17, weight: .regular, tracking: -0.2, lineHeight: 25
        )
        static let caption = TextStyle(
            name: "caption", size: 14, weight: .regular, tracking: 0, lineHeight: 20
        )
        static let mono = TextStyle(
            name: "mono", size: 15, weight: .regular, tracking: 0, lineHeight: 20, monospaced: true
        )
    }

    // MARK: - 动态色

    /// 一套值管两种外观。`NSColor` 的 provider 在每次解析颜色时被调用，
    /// 所以系统外观变了它会自己跟上，不需要任何刷新代码。
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

// MARK: - 便捷修饰符

extension View {
    /// 一次套上字体、字距、行距
    func textStyle(_ style: Theme.TextStyle) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

// MARK: - 颜色构造

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 中英混排着色

enum TextHighlight {

    /// 把文本中的英文/拉丁字母片段染成强调色，中文保持正文色。
    ///
    /// 之所以可行：实测发现 zh-CN 模型会把英文术语按读音转写成拉丁字母
    /// （machine learning → "Machin learning"），所以「哪部分是英文」
    /// 可以直接靠字符集判断，不需要额外的语言检测。
    static func styled(_ text: String) -> AttributedString {
        var output = AttributedString()
        var buffer = ""
        var bufferIsLatin = false

        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            piece.foregroundColor = bufferIsLatin ? Theme.accent : Theme.textPrimary
            output.append(piece)
            buffer = ""
        }

        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let isLatin = isLatinRun(
                character,
                previous: index > 0 ? characters[index - 1] : nil,
                next: index + 1 < characters.count ? characters[index + 1] : nil
            )
            if isLatin != bufferIsLatin {
                flush()
                bufferIsLatin = isLatin
            }
            buffer.append(character)
        }
        flush()

        return output
    }

    /// 拉丁字母/数字算英文。夹在英文之间的空格也算英文，
    /// 这样 "machine learning" 会作为一整段着色，而不是被空格切断。
    private static func isLatinRun(_ character: Character, previous: Character?, next: Character?) -> Bool {
        if character.isASCII && (character.isLetter || character.isNumber) { return true }
        if character == " " {
            let leftIsLatin = previous.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
            let rightIsLatin = next.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
            return leftIsLatin && rightIsLatin
        }
        // 英文里常见的标点跟着英文走
        if ".,;:!?'\"-()/%".contains(character) {
            let leftIsLatin = previous.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
            return leftIsLatin
        }
        return false
    }
}
