import SwiftUI
import AppKit

/// 设计 token。对应迁移前那版 TS/RN App 里的 `theme` 对象——**那份 spec
/// 不在本仓库里**，本文件就是这些值的唯一出处。
///
/// **深色模式为什么不用 `useColorScheme()` 手动切**：迁移前那版是 React Native
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
    /// 两种外观用同一个值：迁移前那版只给了一个。实测它在黑底上对比度 4.45:1，
    /// 紧贴 AA 的 4.5 线但没到——够用，不值得为此偏离它去换 #0A84FF。
    static let accent = Color(hex: 0x0071E3)

    /// 状态色。迁移前那版给的这三个值本身就是苹果深色外观那一套，
    /// 在白底黑底上都立得住，所以两种外观共用。
    static let success = Color(hex: 0x30D158)
    static let warning = Color(hex: 0xFF9F0A)
    static let error = Color(hex: 0xFF453A)

    // MARK: - 表面（卡片）

    /// 卡片用的表面色。
    ///
    /// **为什么浅色卡片是纯白、页面也是纯白**：浅色下的层级靠**阴影 + 6% 边框**
    /// 表达，而不是靠把卡片涂深。把卡片涂成灰的会让整页变成「灰底白卡」，
    /// 那是 Material 的读法，不是这个 App 的（规格是留白和层次）。
    ///
    /// **深色下没有阴影可用**（见 `Shadow.layers`），层级只能靠底色差：
    /// `card`(#1C1C1E) 比页面黑底亮一档，`cardElevated`(#2C2C2E) 再亮一档，
    /// 于是「抬起来的那张」在深色里是**更亮**的那张。这两个值就是苹果
    /// 深色外观的 systemGray6 / systemGray5，直接沿用，不另调
    enum Surface {
        /// 卡片底
        static let card = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)
        /// 抬高一级的卡片底（深色下靠它表达层级，见上）
        static let cardElevated = adaptive(light: 0xFBFBFD, dark: 0x2C2C2E)
        /// 卡片描边：浅色白底上是 6% 黑，深色是 8% 白。
        /// 0.5pt 宽（`cardStyle` 里写死）——再粗一圈就成「边框设计」了
        static let cardBorder = alphaAdaptive(light: (0x000000, 0.06),
                                              dark: (0xFFFFFF, 0.08))
        /// 悬停 / 选中反馈：浅色 4% 黑、深色 6% 白。**叠在卡片底上**，
        /// 不是替换卡片底——替换的话卡片会在悬停时换一个颜色，看起来像切换选中
        static let cardHighlight = alphaAdaptive(light: (0x000000, 0.04),
                                                 dark: (0xFFFFFF, 0.06))
    }

    // MARK: - 阴影

    /// 卡片阴影。**只在浅色用**——理由见 `layers(elevation:scheme:)`。
    enum Shadow {

        /// 一层阴影。存数值而不是 `Color`，是为了自检能直接读这些数
        /// （“opacity/r 在范围内”“亮色必须有阴影”都得能跑红）
        struct Layer: Equatable {
            let opacity: Double
            let radius: CGFloat
            let y: CGFloat

            var color: Color { Color.black.opacity(opacity) }
        }

        /// 一级（列表行这种「浮起来一点」的）：两层叠加。
        /// 单层要么太重（看得出边界）要么太轻（等于没画）；两层里
        /// 小半径那层给「贴着桌面」的接触感，大半径那层给大范围的环境光
        static let card: [Layer] = [
            Layer(opacity: 0.06, radius: 10, y: 2),
            Layer(opacity: 0.04, radius: 24, y: 8),
        ]

        /// 二级（弹层 / 详情面板这种「更靠近眼睛」的）：同结构、再重一档
        static let cardRaised: [Layer] = [
            Layer(opacity: 0.09, radius: 16, y: 4),
            Layer(opacity: 0.06, radius: 36, y: 12),
        ]

        /// 某个层级在某套外观下该画几层阴影。
        ///
        /// **深色恒为空，这不是省事，是实测结论**：深色页面是纯黑，
        /// 阴影是「比背景更暗」——黑底上没有任何更暗可画，`black 0.06`
        /// 落在 #000 上和没画逐像素一样。所以深色下**不许有阴影**，
        /// 层级改由 `Surface.cardElevated`（更亮一档的底）+ 0.5pt 描边表达。
        /// 谁把阴影加回深色，谁就是在往黑底上刷看不成的东西
        static func layers(elevation: Int, scheme: ColorScheme) -> [Layer] {
            guard scheme != .dark else { return [] }
            switch elevation {
            case 0: return []
            case 1: return card
            default: return cardRaised
            }
        }
    }

    /// 一张卡片在某种外观、某个层级下的全部取值。**取值的唯一出处**——
    /// `cardStyle` 只把它翻译成视图，自检也只读它。两处各算一遍的话，
    /// 「深色没有阴影」迟早会在一处成立、在另一处不成立
    struct CardTokens {
        let fill: Color
        let border: Color
        let shadow: [Shadow.Layer]
    }

    static func cardTokens(elevation: Int, scheme: ColorScheme) -> CardTokens {
        let level = min(max(elevation, 0), 2)
        // 深色下「抬起来」= 更亮的底。elevation 0 是平铺的、不需要抬
        let fill = (scheme == .dark && level > 0) ? Surface.cardElevated : Surface.card
        return CardTokens(
            fill: fill,
            border: Surface.cardBorder,
            shadow: Shadow.layers(elevation: level, scheme: scheme)
        )
    }

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
        /// 区块之间的留白。`CLAUDE.md` 设计规范里「`Theme.Spacing.xxl`(80)」就是它——
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

    /// 字体 token。迁移前那版给的是 fontSize / letterSpacing / lineHeight，
    /// SwiftUI 那边对应 `size` / `tracking` / **`lineSpacing`**——
    /// 注意最后这个不是同一个东西，见 `lineSpacing` 的说明。
    struct TextStyle {
        let name: String
        let size: CGFloat
        let weight: Font.Weight
        let tracking: CGFloat
        /// 迁移前那版的 `lineHeight`（一行占的总高度）
        let lineHeight: CGFloat
        var monospaced = false

        var font: Font {
            if monospaced {
                return .system(size: size, weight: weight, design: .monospaced)
            }
            return .system(size: size, weight: weight)
        }

        /// 那边的 `lineHeight` 是「整行高度」，SwiftUI 的 `lineSpacing` 是
        /// 「行与行之间额外加多少空隙」——两者差一个字体自身的行高。
        /// 直接写 `.lineSpacing(25)` 会得到 25 的空隙，行距翻倍。
        ///
        /// 负数（要求比字体自然行高更紧）SwiftUI 表达不了，只能夹到 0。
        /// 受影响的只有 largeTitle：48pt 的自然行高约 57，那边要 52。
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
        /// 卡片里的行标题。**尺寸仍走 body 那档 17**（字号只有五档，
        /// 不为卡片另开一档），层级靠字重——medium 比正文重半档，
        /// 在卡片里刚好是「这一行叫什么」，再重（semibold）会跟页面大标题抢
        static let rowTitle = TextStyle(
            name: "rowTitle", size: 17, weight: .medium, tracking: -0.2, lineHeight: 25
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

    /// 带透明度的版本。描边和悬停底色必须是**半透明**的：它们叠在卡片底
    /// （白 / #1C1C1E）上，预先混好一个不透明的颜色就等于把「底下是什么」
    /// 写死进 token，将来卡片底一改，这两处就会露出旧底色的影子
    private static func alphaAdaptive(light: (UInt32, Double),
                                      dark: (UInt32, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (rgb, alpha) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255,
                           alpha: alpha)
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

    /// 卡片外观。elevation 只有 0 / 1 / 2 三档（越界按最近的档夹住）。
    ///
    /// 用法上的一条规矩：**卡片是分组的边界，不是布局的容器**。两张卡片
    /// 之间的间距走 `Theme.Spacing.lg` 以上，别拿卡片去拼网格——那会退化成
    /// 「什么都要框一下」，与原规范要反对的东西是同一件事。
    func cardStyle(elevation: Int = 1, isHighlighted: Bool = false) -> some View {
        modifier(CardStyleModifier(elevation: elevation, isHighlighted: isHighlighted))
    }
}

/// `.cardStyle(elevation:isHighlighted:)` 的实现。
///
/// 取值全部来自 `Theme.cardTokens(elevation:scheme:)`，这里只负责画——
/// 阴影在深色下由那边返回空数组，所以深色**连一层 shadow 都不会加上**
/// （不是「加一层透明的」：那在像素上一样，但会让下一个人以为深色也有阴影）
private struct CardStyleModifier: ViewModifier {
    let elevation: Int
    let isHighlighted: Bool

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let token = Theme.cardTokens(elevation: elevation, scheme: scheme)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)

        content
            .padding(Theme.Spacing.md)
            .background {
                shape
                    .fill(token.fill)
                    // 悬停/选中叠在卡片底上，不替换它（见 Surface.cardHighlight）
                    .overlay {
                        shape.fill(isHighlighted ? Theme.Surface.cardHighlight : Color.clear)
                    }
            }
            .overlay {
                // 0.5pt 在 Retina 上是一物理像素。深色里它就是那层「没有阴影时
                // 唯一把卡片从黑底上分出来的线」；浅色里它给白卡一个收口
                shape.strokeBorder(token.border, lineWidth: 0.5)
            }
            .shadowed(token.shadow)
    }
}

private extension View {
    /// 按 token 逐层叠阴影。层数为 0 时**原样返回**（深色的默认路径）
    @ViewBuilder
    func shadowed(_ layers: [Theme.Shadow.Layer]) -> some View {
        switch layers.count {
        case 0:
            self
        case 1:
            shadow(color: layers[0].color, radius: layers[0].radius, y: layers[0].y)
        default:
            // token 最多两层；多出来的忽略而不是报错——这是装饰，
            // 为它让整个界面编不过不成比例
            shadow(color: layers[0].color, radius: layers[0].radius, y: layers[0].y)
                .shadow(color: layers[1].color, radius: layers[1].radius, y: layers[1].y)
        }
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
