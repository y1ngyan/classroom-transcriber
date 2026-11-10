import SwiftUI
import AppKit

// MARK: - PillButton

/// 胶囊按钮。主色 #0071E3、文字白色、圆角 980。
///
/// 980 是「永远等于半高」的惯用写法（大到任何高度都取不到真正的圆角），
/// SwiftUI 里对应的东西就是 `Capsule()`，所以不写那个数字。
struct PillButton: View {

    enum Style {
        /// 主按钮
        case filled
        /// 次级操作。`CLAUDE.md` 设计规范只定义了主按钮，但界面上确实有「添加图片」这类
        /// 不该跟主操作抢眼的地方——都涂成蓝的等于没有主次
        case quiet
    }

    /// 禁用时的样子（P14-5）
    enum DisabledStyle {
        /// 老做法：整颗按钮降到 35%。适合「暂时不能点」的次要按钮
        case faded
        /// 灰底 + 三级灰字。**主操作禁用时必须用它**：蓝色按钮降透明度
        /// 在浅色页面上仍然读作「一颗浅蓝色的按钮」，而不是「它现在不能点」
        /// （P14-5 用户原话：右下「保存」看着像被禁用了一样）
        case neutral
    }

    let title: String
    var systemImage: String?
    /// 标题前的小圆点。录制按钮用它表示「正在录/未在录」，
    /// 做成参数而不是让调用方拿 overlay 去叠——那样等于把按钮内部
    /// 的间距假设抄一份到外面，改一处就错位
    var dotColor: Color?
    var style: Style = .filled
    /// 进行中。有它就不该再让用户点第二下——「生成笔记」跑到一半再点一次
    /// 会并发起两个请求，而且两个都会写进同一个 store
    var isLoading = false
    var isEnabled = true
    var disabledStyle: DisabledStyle = .faded
    let action: () -> Void

    @State private var isHovering = false

    private var isInteractive: Bool { isEnabled && !isLoading }

    var body: some View {
        Button(action: action) {
            PillLabel(
                title: title,
                systemImage: systemImage,
                dotColor: dotColor,
                isLoading: isLoading,
                style: style,
                // 灰底灰字只换颜色、不换尺寸：禁用前后按钮不会跳一下宽度
                isDisabled: !isInteractive && disabledStyle == .neutral
            )
        }
        .buttonStyle(.plain)
        .opacity(isInteractive || disabledStyle == .neutral ? 1 : 0.35)
        .disabled(!isInteractive)
        // 悬停反馈取代阴影：设计规范不要阴影，但按钮总得能看出是可点的
        .brightness(isHovering && isInteractive ? 0.06 : 0)
        .onHover { isHovering = $0 }
    }
}

// MARK: - PillLabel

/// 胶囊按钮的样子。`PillButton` 和 `PillMenu` 共用一份——
/// 各画一份的话，改一次内边距就得记得改两处，早晚会漂移。
struct PillLabel: View {

    let title: String
    var systemImage: String?
    var dotColor: Color?
    var trailingSystemImage: String?
    var isLoading = false
    var style: PillButton.Style = .filled
    /// 禁用态换成灰底灰字（见 `PillButton.DisabledStyle.neutral`）
    var isDisabled = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
            }
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(foreground)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
            }
            Text(title)
                .font(.system(size: 15, weight: .medium))
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(foreground.opacity(0.7))
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: Theme.Control.pillHeight)
        .background(Capsule().fill(background))
        .foregroundStyle(foreground)
    }

    private var background: Color {
        // 用 `separator` 而不是 `backgroundSecondary`：后者在浅色下是
        // #F5F5F7，比页面底 #F1F1F4 还亮，灰胶囊直接消失在底上
        if isDisabled { return Theme.separator }
        switch style {
        case .filled: return Theme.accent
        case .quiet: return Theme.backgroundSecondary
        }
    }

    private var foreground: Color {
        if isDisabled { return Theme.textSecondary }
        switch style {
        case .filled: return .white
        case .quiet: return Theme.textPrimary
        }
    }
}

// MARK: - PillMenu

/// 胶囊外观的下拉菜单。
///
/// 用在「从一组预设里挑一个」这类动作上：做成 Button 就得自己弹 sheet
/// 再把列表画一遍，而系统 Menu 已经把键盘导航、暗色模式、点外关闭都做完了。
struct PillMenu<Content: View>: View {

    let title: String
    var systemImage: String?
    var style: PillButton.Style = .quiet
    var isEnabled = true
    @ViewBuilder let content: Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            content
        } label: {
            PillLabel(
                title: title,
                systemImage: systemImage,
                trailingSystemImage: "chevron.down",
                style: style
            )
        }
        // .borderlessButton 是让自定义 label 完全接管外观的那档；
        // .menuIndicator(.hidden) 去掉系统另画的那个箭头，用 label 里自己的
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .brightness(isHovering && isEnabled ? 0.06 : 0)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 工具栏主操作

/// 每屏顶部工具栏右侧的主操作（P14-4）：accent 胶囊、固定 28pt 高。
///
/// 和 `PillButton` 分开而不是加个高度参数：工具条里的按钮和页面里的
/// 胶囊不是同一种东西——`PillButton` 的水平内边距、字号、高度都是按
/// 「页面里的主按钮」定的，把尺寸做成参数会让每个调用点都要记住一组数
struct ToolbarActionButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    private var isInteractive: Bool { isEnabled && !isLoading }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: Theme.Text.meta.size))
                }
                Text(title)
                    .font(Theme.Text.meta.font.weight(.semibold))
            }
            .padding(.horizontal, Theme.Spacing.s12)
            .frame(height: Theme.Control.toolbarActionHeight)
            .background(Capsule().fill(Theme.accent))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .opacity(isInteractive ? 1 : 0.35)
        .disabled(!isInteractive)
        .brightness(isHovering && isInteractive ? 0.06 : 0)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 状态胶囊

/// 11pt 状态胶囊：文字 + 12% 同色底（P14-4）。
///
/// 录音列表那版角标是「N 段 + 状态」，这里的单段状态 / 提问标记没有段数，
/// 只放状态词——两者形状一致（胶囊 + 12% 底），扫读时是同一族的标记
struct StatusCapsule: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: Theme.Text.footnote.size))
            }
            Text(text)
                .font(Theme.Text.footnote.font.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.RecordingLayout.badgePaddingH)
        .padding(.vertical, Theme.RecordingLayout.badgePaddingV)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(color)
    }
}

// MARK: - 说明气泡

/// 压缩后的说明文字旁边挂一个问号，完整文案进系统帮助气泡。
///
/// 用 `.help` 而不是自绘 popover：系统气泡已经把键盘、焦点、点外关闭做完，
/// 而这里要的只是「放不下的话去哪儿看」
struct InfoBubble: View {
    let text: String

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: Theme.Text.footnote.size))
            .foregroundStyle(Theme.textTertiary)
            .help(text)
            .accessibilityLabel("更多说明")
    }
}

// MARK: - Separator

/// 发丝级分隔线，对应 RN 的 `StyleSheet.hairlineWidth` + #D2D2D7。
///
/// 直接写 `.frame(height: 1)` 在 Retina 上是 2 个物理像素，比系统画的线粗
/// 一倍，一屏里排几条就很显眼。发丝线要按屏幕缩放比算，所以读 `displayScale`。
struct Separator: View {
    @Environment(\.displayScale) private var displayScale
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1 / max(1, displayScale))
            .padding(.leading, inset)
    }
}

// MARK: - TranscriptLine

/// 一段转录外面的容器（P15-5）。
///
/// **时间轴上不许有卡片**：白底 + 圆角 + 描边挨着一条半透明竖线，是两块
/// 并列的图形，读不成一根轴。所以转录页用 `.plain`（透明，只留内边距），
/// 段与段之间靠间距 + 发丝线分开。卡片（`.card`）仍给录音列表这类
/// 「一个个独立条目」的屏；`.bare` 是录音详情里连内边距都不要的只读预览
enum TranscriptSurface {
    case card(elevation: Int)
    case plain
    case bare
}

/// 一行转录：中英混排（英文走 accent 色），时间戳右对齐灰色小字。
struct TranscriptLine: View {
    let segment: TranscriptSegment
    var attachments: [ImageAttachment] = []
    var onRemoveAttachment: ((ImageAttachment) -> Void)?
    /// 这一段的核查状态。传 `.none` 表示还没查过。
    ///
    /// 由调用方从 FactCheckStore 查好传进来，而不是在这里读 store：
    /// 这个组件是纯展示的，让它去依赖某个 Store 就没法在别处复用了
    var checkState: SegmentCheckState = .none
    /// 点「核查」时回调。为 nil 表示调用方不支持手动核查（比如文件转录预览）
    var onCheck: (() -> Void)?
    /// 这一段的说话人课内编号（`S1`/`S2`…）。为 nil = **这一行不显示说话人**。
    ///
    /// 判据**不在这里**，由调用方从 `SpeakerLabel.text(for:)` 取了传进来：
    /// 组件是纯展示的（同 `checkState` 那一条），而且「什么样的段不显示」
    /// 是要能离线自检的规则，散进 View 就测不到了
    var speakerLabel: String?

    /// 段落外面的容器。见 `TranscriptSurface`
    var surface: TranscriptSurface = .bare
    /// 正在转写的那一行。给一个轻的 `isHighlighted` 态：
    /// 最后一段还没定稿时，用户要能一眼找到「现在写到哪了」
    var isActive = false
    /// 音频正播放到这一句（P17）。铺一层 accent 淡底。
    ///
    /// **和 `isActive` 分开**：那个是「识别器正在写这一行」，这个是
    /// 「耳朵正听到这一句」。两者可能同时存在（边播边转），但语义不同，
    /// 合成一个布尔值之后就没法只高亮其中一个了
    var isPlaying = false
    /// 正文能不能拖选。录音详情页要关掉（P17）：`textSelection` 打开时
    /// 拖选会和「点句子播放 / 双击改错」抢鼠标，第一下点击会被系统当成
    /// 设置选区起点，行上的 tap 手势收不到。转录页不关——那里没有行级点击
    var allowsTextSelection = true
    /// 是否在卡片里画时间戳。时间轴（P15-3）把它搬到了节点那一行，
    /// 这里传 false——同一段时间戳画两次，卡内那一个会和节点行的错位
    var showsTimestamp = true

    @State private var isHovering = false

    /// 该段是否已完成过核查（决定按钮措辞）
    private var hasResolvedCheck: Bool {
        if case .done = checkState { return true }
        return false
    }

    @ViewBuilder
    var body: some View {
        switch surface {
        case .card(let elevation):
            playbackHighlightedContent
                .cardStyle(elevation: elevation,
                           isHighlighted: isActive || isHovering)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
                }
        case .plain:
            // 透明底，只留内边距（P15-5 时间轴）。
            //
            // **为什么连悬停底色都不给**：白色圆角卡挨着半透明竖线时，
            // 两者是两块并列的图形，时间轴读不成一条轴；悬停时再铺一层
            // 4% 的底，等于在指针经过时把盒子又画回来一次。悬停仍有反馈——
            // 「核查」按钮只在这时出现（见 `content` 里的 isHovering）
            playbackHighlightedContent
                .padding(Theme.Spacing.md)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
                }
        case .bare:
            playbackHighlightedContent
                // 悬停反馈是一条 2pt 左侧竖条（设计规范），不是背景填充。
                // 画在 overlay 里不占布局，指针进出时列表不会抖
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isHovering ? Theme.textPrimary.opacity(0.22) : Color.clear)
                        .frame(width: 2)
                        .offset(x: -Theme.Spacing.sm)
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
                }
        }
    }

    /// 播放高亮的底铺在正文之下。用负 padding 扩出去一圈，**不加正
    /// padding**：正 padding 会让「开始播放」那一刻整行文字往里一跳，
    /// 而播放位置是每几秒变一次的，跳一次用户就丢一次读到的位置
    private var playbackHighlightedContent: some View {
        content
            .background {
                if isPlaying {
                    RoundedRectangle(cornerRadius: Theme.Spacing.sm)
                        .fill(Theme.accent.opacity(0.10))
                        .padding(.horizontal, -Theme.Spacing.sm)
                        .padding(.vertical, -Theme.Spacing.xs)
                }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s6) {
            // 顶部一行：时间是定位刻度，说话人是内容，提问是状态，核查结论
            // 收在右端。P14-4 把原来「正文下面那一行长文本」整段搬上来：
            // 核查结论是个状态，不是正文的第二行
            HStack(alignment: .center, spacing: Theme.Spacing.s6) {
                if showsTimestamp {
                    Text(segment.formattedTimestamp)
                        .font(Theme.Text.meta.font.monospacedDigit())
                        .foregroundStyle(Theme.textSupporting)
                }

                // 说话人是内容（用户要知道谁说的），时间戳是定位用的刻度：
                // 时间戳用 textSupporting 之后，说话人必须提到正文色，
                // 否则两档深浅会反
                if let speakerLabel {
                    Text(speakerLabel)
                        .font(Theme.Text.meta.font.weight(.medium).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }

                // 提问标记：L2 是确认的提问，L1 只是点名/祈使预警——
                // 颜色和措辞都分开，混在一起用户会以为每条「谁来回答一下」
                // 都是一道完整的问题
                if segment.isQuestion {
                    StatusCapsule(
                        text: segment.questionLevel >= 2 ? "提问" : "点名",
                        color: segment.questionLevel >= 2 ? Theme.accent : Theme.warning,
                        systemImage: segment.questionLevel >= 2
                            ? "questionmark.bubble.fill"
                            : "hand.raised.fill"
                    )
                }

                // 人工改过的段要能认出来（P17）。不标的话，用户下次重转
                // 看到「这一句怎么还是我改的样子」得靠记忆判断原因
                if segment.edited {
                    StatusCapsule(
                        text: "人工修改",
                        color: Theme.textSecondary,
                        systemImage: "pencil"
                    )
                }

                Spacer(minLength: Theme.Spacing.sm)

                // 手动核查入口：悬停才出现。常驻的话每段都挂个按钮，
                // 一屏几十段全是控件，读转录本身反而被挤没了
                if isHovering, onCheck != nil, segment.isFinal {
                    Button(action: { onCheck?() }) {
                        Text(hasResolvedCheck ? "重新核查" : "核查")
                            .font(Theme.Text.meta.font.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(checkState == .checking)
                    .opacity(checkState == .checking ? 0.4 : 1)
                    .transition(.opacity)
                }

                // 核查状态：右上角标。只在「查过」或「正在查」时出现——
                // 没查过的段是绝大多数，给每段都挂一个「未核查」
                // 等于把列表塞满噪声
                if let badge = checkBadge {
                    StatusCapsule(text: badge.text, color: badge.color)
                }
            }

            // 质量自评：good 不标——满屏都是「可信」标记，等于没有标记；
            // 只有需要用户警惕的段落才占一行
            if let grade = segment.qualityGrade, grade != .good {
                StatusMark(
                    kind: grade == .poor ? .error : .warning,
                    text: grade == .poor
                        ? "此段转录不可信，可能是识别失败"
                        : "此段转录存疑，可能有错字"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 语义切分：识别器只在长静音处切段，课堂上十几秒一整段是常态。
            // 切分是派生数据（segments 数据层不动，见 TranscriptSplitter），
            // 这里只负责把子段分行画出来。**不再给续行缩进**（P14-4）：
            // 左基线全站统一，卡内缩进一档会被读成「二级层级」
            let pieces = TranscriptSplitter.split(segment)
            if pieces.count == 1 {
                bodyText(segment.text)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                        bodyText(piece.text)
                    }
                }
                .opacity(segment.isFinal ? 1 : 0.55)
            }

            if !attachments.isEmpty {
                HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                    ForEach(attachments) { attachment in
                        if let onRemoveAttachment {
                            Thumbnail(attachment: attachment) { onRemoveAttachment(attachment) }
                        } else {
                            Thumbnail(attachment: attachment) {}
                        }
                    }
                }
            }
        }
    }

    /// 正文 15pt（P14-4）。未定稿的段落压暗一档：识别结果还会变，视觉上先分开
    private func bodyText(_ text: String) -> some View {
        Group {
            // 两种 selectability 是不同类型，三元表达式拼不到一起，
            // 只能分支构造（`TextSelection` 的两个静态成员不在同一类型上）
            if allowsTextSelection && segment.isFinal {
                bodyLabel(text).textSelection(.enabled)
            } else {
                bodyLabel(text).textSelection(.disabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bodyLabel(_ text: String) -> some View {
        Text(TextHighlight.styled(text))
            .textStyle(Theme.Text.summary)
            .opacity(segment.isFinal ? 1 : 0.55)
    }

    /// 核查状态角标。没查过返回 nil
    private var checkBadge: (text: String, color: Color)? {
        switch checkState {
        case .none:
            return nil
        case .checking:
            return ("核查中", Theme.accent)
        case .failed:
            return ("核查失败", Theme.warning)
        case .done(.verified):
            return ("已证实", Theme.success)
        case .done(.disputed):
            return ("存疑", Theme.error)
        case .done(.unverifiable):
            return ("无法核实", Theme.warning)
        }
    }
}

// MARK: - 图片缩略图

/// 缩略图用圆角裁切是**内容裁切**，不是卡片外壳——设计规范里「不使用卡片」
/// 说的是不要给内容加容器装饰，不是不能把图片切成圆角。
struct Thumbnail: View {
    let attachment: ImageAttachment
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: attachment.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Spacing.sm))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
        .onHover { isHovering = $0 }
        .help("\(attachment.originalName) · \(attachment.formattedTimestamp)")
    }
}

// MARK: - 录音状态角标

/// 录音列表右上角状态角标（P14-3）。
///
/// **按状态分开口子，不混在一个胶囊里**：P14-2 把「2 段已核实 · 1 段不可信」
/// 整句装进一个红底角标，语义上等于说「已核实也算异常」。现在一种状态
/// 一个胶囊、各用自己的颜色，红角标里只放不可信的段数。
///
/// 文案形状钉死成「数字 + 段 + 状态」：`4 段已核实` / `1 段存疑` /
/// `1 段不可信`。顺序固定（已核实 → 存疑 → 不可信）：同一份数据每次
/// 都按同一个方向读。
///
/// **最多两个彩色胶囊**；再多的状态合并成一个灰底「N 段异常」
/// （N = 被合并掉的段数），右上角不会无限横长。胶囊本身不换行。
///
/// 放在这里而不是 View 私有：快照自检要拿真实逻辑跑正则
/// （「不许出现 `1 不可信` 这种」），私有函数测不到
enum RecordingBadge {
    struct Item: Equatable {
        let text: String
        let kind: Kind

        enum Kind: Equatable {
            case verified, fair, poor
            /// 合并掉的次要状态。灰底，不和彩色状态抢注意力
            case overflow
        }
    }

    /// 按状态拆成若干胶囊。`verified` 由段总数减去两类异常算好传进来。
    static func items(verified: Int, fair: Int, poor: Int) -> [Item] {
        var statuses: [(Int, Item.Kind, String)] = []
        if verified > 0 { statuses.append((verified, .verified, "\(verified) 段已核实")) }
        if fair > 0 { statuses.append((fair, .fair, "\(fair) 段存疑")) }
        if poor > 0 { statuses.append((poor, .poor, "\(poor) 段不可信")) }
        guard !statuses.isEmpty else {
            return [Item(text: "0 段已核实", kind: .verified)]
        }
        if statuses.count <= 2 {
            return statuses.map { Item(text: $0.2, kind: $0.1) }
        }
        // 三个状态并存：前两个按顺序保留，第三个的段数并进灰底。
        // 这里「异常」只数被并掉的那一类——已经单独显示的不可信不在里面，
        // 否则同一段会被数两遍
        let head = statuses.prefix(2).map { Item(text: $0.2, kind: $0.1) }
        let merged = statuses.dropFirst(2).map(\.0).reduce(0, +)
        return head + [Item(text: "\(merged) 段异常", kind: .overflow)]
    }
}

// MARK: - 状态标记

/// 状态用小图标 + 颜色表达（`CLAUDE.md` 设计规范要求），而不是靠背景色块。
struct StatusMark: View {
    enum Kind {
        case ok, warning, error, neutral
        /// 「查不到依据」。不是错误：问号 + warning 橙，和事实核查屏的
        /// 「无法核实」用同一套符号语言（P13-3 只改了核查屏，转录行还是
        /// 空心圆；同一状态两屏两个符号，读起来像两回事）
        case unknown
        /// 进行中（正在录制）。不是「出错」：用实心点，和红点录制指示
        /// 灯是同一个符号语言
        case live

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .neutral: return "circle"
            case .unknown: return "questionmark.circle"
            case .live: return "circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .ok: return Theme.success
            case .warning: return Theme.warning
            case .error: return Theme.error
            // 中性状态旁边常跟着一行说明文字（「下次录制：…」「已核查：…」），
            // 它们和正文同处一张卡里；用 textTertiary 会跟文字一起淡到看不清
            case .neutral: return Theme.textSupporting
            case .unknown: return Theme.warning
            case .live: return Theme.error
            }
        }
    }

    let kind: Kind
    var text: String?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: kind.symbol)
                .font(.system(size: Theme.Text.footnote.size))
            if let text {
                Text(text)
                    .textStyle(Theme.Text.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(kind.color)
    }
}
