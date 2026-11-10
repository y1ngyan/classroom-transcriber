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

    /// 页面背景 #F1F1F4 / #000000。
    ///
    /// P14-1 起浅色页面**不再是纯白**：白卡叠白底没有厚度。P14-2 又压深一档
    /// （#F5F5F7 → #F1F1F4）：第一版快照里白卡仍像贴纸，底色差不够。
    /// 深色仍是纯黑（阴影画不出来，靠 12% 白描边 + 卡片底分界）
    static let background = adaptive(light: 0xF1F1F4, dark: 0x000000)
    /// 次级背景（分组块、输入框底）#F5F5F7
    static let backgroundSecondary = adaptive(light: 0xF5F5F7, dark: 0x1C1C1E)
    /// 正文 #1D1D1F
    static let textPrimary = adaptive(light: 0x1D1D1F, dark: 0xFFFFFF)
    /// 次要文字 #86868B
    static let textSecondary = adaptive(light: 0x86868B, dark: 0x98989D)
    /// 三级文字 #D2D2D7。只留给极次要信息（占位说明、装饰刻度）——
    /// 白底上只有 1.4:1，任何需要读的字都不该用它
    static let textTertiary = adaptive(light: 0xD2D2D7, dark: 0x48484A)
    /// 正文补充文字 #6D6D72 / #A1A1A6。
    ///
    /// **为什么单独一档**：`textSecondary`（#86868B）在白底上只有 3.4:1，
    /// 放在卡片里当正文的补充说明（接口说明、释义、空状态引导）时肉眼发虚；
    /// `textTertiary` 更浅，只够当「看一眼定位」的刻度。
    /// 这一档按 AA 正文标准取值：白底 5.1:1、黑底 8.2:1，卡片底上也在
    /// 4.9:1 以上（`--ui-snapshot` 里有对比度自检）。
    /// P14-2 由 #6E6E73 压深 1/255：#F1F1F4 页面底上原值算出来 4.499:1，
    /// 差 0.001 卡在 AA 线下面（自检按未取整的比值判）
    static let textSupporting = adaptive(light: 0x6D6D72, dark: 0xA1A1A6)
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
    /// 「无法核实」（P15-3 时间轴节点）。
    ///
    /// 它和 `warning` 同为橙，但**不能共用一个值**：时间轴上 8pt 的节点
    /// 并排出现时，「存疑」和「无法核实」如果同色，两个不同的语义就
    /// 只剩一个圆点。
    ///
    /// 两种外观都取深一档的赭橙 #C77D00：黑底上 6.4:1，看得清；
    /// 而和 `warning`（#FF9F0A）比，亮度差 0.14——深色下如果也提亮到
    /// #FFB340，两颗橙点只差一点色相，8pt 上看就是「一样的橙」。
    /// 用**明度**而不是色相分（派单把两者都定成橙，色相没得挪）。
    /// 这是全站第一处用到它，目前只属于时间轴节点
    static let unknown = Color(hex: 0xC77D00)

    /// 状态**角标文字**用的状态色（P14-2）。
    ///
    /// 角标底是同色 12% 透明，深色下普通状态色压在这层底上偏暗
    /// （成功绿尤其明显），所以深色单独提亮一档；success / error 直接取
    /// 派单给的可读值 #4ADE80 / #FF6B5E。浅色仍是原状态色——浅色底上的
    /// 问题不是「太暗」而是绿色本身对比不足，那属于角标配色的另一件事
    static let successBadge = adaptive(light: 0x30D158, dark: 0x4ADE80)
    static let warningBadge = adaptive(light: 0xFF9F0A, dark: 0xFFB340)
    static let errorBadge = adaptive(light: 0xFF453A, dark: 0xFF6B5E)

    // MARK: - 表面（卡片）

    /// 卡片用的表面色。
    ///
    /// **为什么浅色卡片是纯白、页面也是纯白**：浅色下的层级靠**阴影 + 6% 边框**
    /// 表达，而不是靠把卡片涂深。把卡片涂成灰的会让整页变成「灰底白卡」，
    /// 那是 Material 的读法，不是这个 App 的（规格是留白和层次）。
    ///
    /// **深色下没有阴影可用**（见 `Shadow.layers`），层级只能靠描边和底色差。
    /// `card`(#1C1C1E) 是所有卡片的底（P14-2 起不再随层级换色），
    /// `cardElevated`(#2C2C2E) 只给显式声明 `.elevated` 的分组底板（设置页）
    enum Surface {
        /// 卡片底
        static let card = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)
        /// 抬高一级的卡片底（深色下靠它表达层级，见上）
        static let cardElevated = adaptive(light: 0xFBFBFD, dark: 0x2C2C2E)
        /// 卡片描边：浅色白底上是 6% 黑，深色是 12% 白。
        /// 0.5pt 宽（`cardStyle` 里写死）——再粗一圈就成「边框设计」了。
        /// 深色 P14-2 由 8% 提到 12%：8% 压在 #1C1C1E 上几乎看不出来
        static let cardBorder = alphaAdaptive(light: (0x000000, 0.06),
                                              dark: (0xFFFFFF, 0.12))
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

        /// 一级（列表行这种「浮起来一点」的）：两层叠加（P14-2 定死）。
        /// 大半径那层给大范围的环境光，小半径那层给「贴着桌面」的接触感。
        /// 数值是派单钉死的，不要凭手感改
        static let card: [Layer] = [
            Layer(opacity: 0.06, radius: 2, y: 1),
            Layer(opacity: 0.10, radius: 20, y: 6),
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
        /// 层级改由 0.5pt 描边（深色 12% 白）表达。
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

    /// 卡片底色该用哪一档表面。
    enum CardSurface {
        /// 按层级自动：一律 `card`。**深色下也不再随层级换 `cardElevated`**——
        /// P14-2 评审点名「深色卡片底必须是 #1C1C1E」，而原来 elevation > 0
        /// 会静默换成 #2C2C2E，卡片和黑底分不开的观感有一半来自这里
        case automatic
        /// 强制用 `cardElevated`。设置页那种「分组底板」用它——
        /// 分组是铺在页面上的盆地，不是浮起来的卡片
        case elevated
    }

    static func cardTokens(elevation: Int,
                           scheme: ColorScheme,
                           surface: CardSurface = .automatic) -> CardTokens {
        let level = min(max(elevation, 0), 2)
        let fill: Color
        switch surface {
        case .elevated:
            fill = Surface.cardElevated
        case .automatic:
            fill = Surface.card
        }
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
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        /// P14-1 的节奏档：录音页只用这些值（自检会钉住）
        static let s6: CGFloat = 6
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let md: CGFloat = 16
        static let s20: CGFloat = 20
        static let lg: CGFloat = 24
        static let s28: CGFloat = 28
        static let s32: CGFloat = 32
        static let xl: CGFloat = 40
        /// 区块之间的留白。`docs/design.md` 设计规范里「`Theme.Spacing.xxl`(80)」就是它——
        /// 取代卡片：靠留白分组，而不是靠框
        static let xxl: CGFloat = 80

        /// 卡片内边距（P14-1）：水平 20 / 垂直 16。**全站卡片共用**
        static let cardPaddingH: CGFloat = 20
        static let cardPaddingV: CGFloat = 16

        /// 录音页允许出现的间距值。自检拿它去卡 `RecordingLayout`
        static let rhythm: Set<CGFloat> = [2, 4, 6, 10, 12, 16, 20, 24, 28, 32]
    }

    /// 圆角。`button` 的 980 是「永远等于半高」的惯用写法，
    /// SwiftUI 里对应的东西叫 `Capsule()`，见 `PillButton`
    enum Radius {
        /// P14-1 由 18 收到 16：圆角越大越像「卡片组件」，16 更接近系统列表
        static let card: CGFloat = 16
        static let button: CGFloat = 980
        static let input: CGFloat = 12
    }

    // MARK: - 旧名字（尺寸）

    static let pagePadding: CGFloat = Spacing.xl
    static let segmentSpacing: CGFloat = Spacing.md
    static let titleSize: CGFloat = Text.largeTitle.size
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
        /// 页面标题（P14-1）：48 → 32 / 700。48 在 1100pt 宽的窗口里像一张
        /// 海报标题，把工具栏和内容全压到第二屏；32 是「App 标题」的高度
        static let largeTitle = TextStyle(
            name: "largeTitle", size: 32, weight: .bold, tracking: -0.4, lineHeight: 38
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
        /// 设置页脚注 11pt。五档里最小的是 caption 14，但设置页的配置文件
        /// 路径、权限说明、缓存状态是**辅助信息**，不是正文：用 14 会把一屏
        /// 说明撑成两屏、压过真正要读的字段；11 与系统设置页的脚注同高。
        /// 这是目前唯一需要 11pt 的场景，别在视图里再就地写数字
        static let footnote = TextStyle(
            name: "footnote", size: 11, weight: .regular, tracking: 0, lineHeight: 16
        )
        /// `body` 的粗体变体。字号不动（17 那档），只把字重提到 semibold——
        /// 术语表卡片里「词条名」要压过「误转写 / 释义」两行，
        /// 而 `rowTitle` 的 medium 在同一张卡里分不出「条目名」和「条目说明」。
        /// P14-1 起它也是录音页的卡片标题 / 分组标题
        static let bodyEmphasized = TextStyle(
            name: "bodyEmphasized", size: 17, weight: .semibold, tracking: -0.2, lineHeight: 25
        )
        /// 卡片摘要 15（P14-1）：比标题轻一档，但仍要能读
        static let summary = TextStyle(
            name: "summary", size: 15, weight: .regular, tracking: 0, lineHeight: 20
        )
        /// 元数据 13（P14-1）：时长 / 段数 / 提问这一行
        static let meta = TextStyle(
            name: "meta", size: 13, weight: .regular, tracking: 0, lineHeight: 18
        )
        /// 读数 28/700（P15-2）：录音页顶部「本周概览」的三个数字。
        ///
        /// 为什么新开一档而不是复用 32 的 `largeTitle`：那档是页面标题，
        /// 同屏出现会把「本周 4h 46m」读成第二个标题。28 比标题低一级、
        /// 又比 17 的正文重得多，正好是「一眼看到读数」的层级。
        /// 行高按 28pt 字号留 34，留给中文数字混排的下沉
        static let metric = TextStyle(
            name: "metric", size: 28, weight: .bold, tracking: -0.3, lineHeight: 34
        )
    }

    // MARK: - 控件尺寸

    enum Control {
        /// 胶囊按钮固定高度。**必须固定**：按钮高度要是随字号/加载态漂，
        /// 同一行里并排的两个按钮就会错位
        static let pillHeight: CGFloat = 38
        /// 工具栏里主操作的胶囊高度（P14-4）。工具条本身 44pt，
        /// 主操作不能跟页面标题一样高，28 是「工具条里的一颗按钮」
        static let toolbarActionHeight: CGFloat = 28
    }

    // MARK: - 录音页尺寸

    /// 录音列表（P14-1）的尺寸规格。**数值是派单定死的**，页面里不许
    /// 再就地写数字；自检会把所有间距类数值拿去对 `Spacing.rhythm`
    enum RecordingLayout {
        static let pagePadding: CGFloat = 24
        static let titleToToolbar: CGFloat = 16
        static let toolbarToGroup: CGFloat = 28
        static let groupSpacing: CGFloat = 24
        static let groupTitleToCard: CGFloat = 10
        static let cardSpacing: CGFloat = 12
        static let cardContentSpacing: CGFloat = 12
        static let cardTextSpacing: CGFloat = 6
        static let metadataSpacing: CGFloat = 10
        static let badgePaddingH: CGFloat = 6
        static let badgePaddingV: CGFloat = 2
        static let listBottom: CGFloat = 32

        /// 控件尺寸（不是间距，不参与节奏表校验）
        static let toolbarHeight: CGFloat = 44
        static let iconButton: CGFloat = 44
        static let newButton: CGFloat = 28
        static let playButton: CGFloat = 44
        /// P14-2：15 → 13。播放是次要入口，不能比「点进详情」更抢眼
        static let playIcon: CGFloat = 13
        /// P14-2：13 → 14，并换成 `textSecondary`（三级色在黑底上看不见）
        static let chevronSize: CGFloat = 14

        /// 自检用：上面所有间距类数值，必须全部落在 `Spacing.rhythm` 里
        static let spacingValues: [CGFloat] = [
            pagePadding, titleToToolbar, toolbarToGroup, groupSpacing,
            groupTitleToCard, cardSpacing, cardContentSpacing, cardTextSpacing,
            metadataSpacing, badgePaddingH, badgePaddingV, listBottom,
        ]
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
    func cardStyle(elevation: Int = 1,
                   surface: Theme.CardSurface = .automatic,
                   isHighlighted: Bool = false) -> some View {
        modifier(CardStyleModifier(elevation: elevation,
                                   surface: surface,
                                   isHighlighted: isHighlighted))
    }
}

/// `.cardStyle(elevation:surface:isHighlighted:)` 的实现。
///
/// 取值全部来自 `Theme.cardTokens(elevation:scheme:surface:)`，这里只负责画——
/// 阴影在深色下由那边返回空数组，所以深色**连一层 shadow 都不会加上**
/// （不是「加一层透明的」：那在像素上一样，但会让下一个人以为深色也有阴影）
private struct CardStyleModifier: ViewModifier {
    let elevation: Int
    let surface: Theme.CardSurface
    let isHighlighted: Bool

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let token = Theme.cardTokens(elevation: elevation, scheme: scheme, surface: surface)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)

        content
            .padding(.horizontal, Theme.Spacing.cardPaddingH)
            .padding(.vertical, Theme.Spacing.cardPaddingV)
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
