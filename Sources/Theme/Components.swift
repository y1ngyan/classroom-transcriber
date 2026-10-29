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
                style: style
            )
        }
        .buttonStyle(.plain)
        .opacity(isInteractive ? 1 : 0.35)
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
        switch style {
        case .filled: return Theme.accent
        case .quiet: return Theme.backgroundSecondary
        }
    }

    private var foreground: Color {
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

    /// 卡片层级。nil = 不加卡片（录音详情页的只读预览沿旧样式）。
    ///
    /// 转录页传 0：这一屏是流式内容，卡片只负责把「一段」圈出来，
    /// 不该像列表项那样浮起来（浮起来等于在说「这些是各自独立的条目」，
    /// 而转录读的是一条连续的流）
    var cardElevation: Int?
    /// 正在转写的那一行。给一个轻的 `isHighlighted` 态：
    /// 最后一段还没定稿时，用户要能一眼找到「现在写到哪了」
    var isActive = false

    @State private var isHovering = false

    /// 该段是否已完成过核查（决定按钮措辞）
    private var hasResolvedCheck: Bool {
        if case .done = checkState { return true }
        return false
    }

    @ViewBuilder
    var body: some View {
        if let cardElevation {
            content
                .cardStyle(elevation: cardElevation,
                           isHighlighted: isActive || isHovering)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
                }
        } else {
            content
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

    private var content: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
            // 提问标记：小图标 + 颜色（设计规范的状态表达方式），不加底色块。
            // L2 是确认的提问，L1 只是点名/祈使预警——颜色和措辞都分开，
            // 混在一起用户会以为每条「谁来回答一下」都是一道完整的问题
            if segment.isQuestion {
                HStack(spacing: 5) {
                    Image(systemName: segment.questionLevel >= 2
                        ? "questionmark.bubble.fill"
                        : "hand.raised.fill")
                        .font(.system(size: 11))
                    Text(segment.questionLevel >= 2 ? "提问" : "点名")
                        .textStyle(Theme.Text.caption)
                }
                .foregroundStyle(segment.questionLevel >= 2 ? Theme.accent : Theme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 质量自评：小图标 + 颜色（和提问标记同一套状态语言），不加底色块。
            // good 不标——满屏都是「可信」标记，等于没有标记；只有需要用户
            // 警惕的段落才占一行
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
            // 这里只负责把子段分行画出来——同一段的子段共享底部那一个
            // 时间戳，后续子行缩进一档表示「我是续行」，不再重复时间戳
            let pieces = TranscriptSplitter.split(segment)
            if pieces.count == 1 {
                Text(TextHighlight.styled(segment.text))
                    .textStyle(Theme.Text.body)
                    // 未定稿的段落压暗一档：识别结果还会变，视觉上先区分开
                    .opacity(segment.isFinal ? 1 : 0.55)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                        Text(TextHighlight.styled(piece.text))
                            .textStyle(Theme.Text.body)
                            .padding(.leading, index == 0 ? 0 : Theme.Spacing.lg)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .opacity(segment.isFinal ? 1 : 0.55)
            }

            // 核查状态：和提问标记、质量自评同一套状态语言（小图标 + 颜色）。
            // 只在「查过」或「正在查」时占一行——没查过的段是绝大多数，
            // 给每段都挂一个「未核查」等于把列表塞满噪声
            if let mark = checkMark {
                StatusMark(kind: mark.kind, text: mark.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 缩略图 + 时间戳，一起右对齐
            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                // 手动核查入口：悬停才出现。
                // 放在时间戳左边而不是常驻——常驻的话每段都挂个按钮，
                // 一屏几十段全是控件，读转录本身反而被挤没了
                if isHovering, onCheck != nil, segment.isFinal {
                    Button(action: { onCheck?() }) {
                        Text(hasResolvedCheck ? "重新核查" : "核查")
                            .textStyle(Theme.Text.caption)
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(checkState == .checking)
                    .opacity(checkState == .checking ? 0.4 : 1)
                    .transition(.opacity)
                }

                ForEach(attachments) { attachment in
                    if let onRemoveAttachment {
                        Thumbnail(attachment: attachment) { onRemoveAttachment(attachment) }
                    } else {
                        Thumbnail(attachment: attachment) {}
                    }
                }

                // 说话人编号。**放在时间戳左边**，不另起一行：另起一行会让
                // 每一段都多出一行（一屏几十段），而它和核查按钮、时间戳
                // 一样都是这行的元数据。
                //
                // 说话人是内容（用户要知道谁说的），时间戳是定位用的刻度：
                // 时间戳提到 textSupporting 之后，说话人必须一起提到正文色，
                // 否则两档深浅会反（supporting 比 textSecondary 深）
                if let speakerLabel {
                    Text(speakerLabel)
                        .textStyle(Theme.Text.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                }

                // 时间戳：dispatch 里「太浅」点名的一处。它是卡片里的辅助信息，
                // 不是装饰刻度，按正文补充标准取色（≥4.5:1）
                Text(segment.formattedTimestamp)
                    .textStyle(Theme.Text.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSupporting)
            }
        }
    }

    /// 核查状态对应的标记。没查过返回 nil（那一行不显示）
    private var checkMark: (kind: StatusMark.Kind, text: String)? {
        switch checkState {
        case .none:
            return nil
        case .checking:
            return (.live, "核查中…")
        case .failed:
            return (.warning, "核查失败，可重新核查")
        case .done(.verified):
            return (.ok, "已核查：已证实")
        case .done(.disputed):
            return (.error, "已核查：存疑")
        case .done(.unverifiable):
            return (.unknown, "已核查：无法核实")
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

/// 录音列表右上角状态角标的文案（P14-2）。
///
/// 文案形状钉死成「数字 + 段 + 状态」：`4 段已核实` / `1 段存疑` /
/// `1 段不可信`。多状态用 ` · ` 连、顺序固定（已核实 → 存疑 → 不可信），
/// 这样「有几段怎么回事」永远按同一个方向读。
///
/// 一格放不下时整句退成「N 段异常」（N = 存疑 + 不可信），**不换行也不截字**：
/// 换行会把旁边的标题挤到第二行，截字则会把「不可信」截成「不可」——
/// 两种都比说实话的粗粒度更糟。
///
/// 放在这里而不是 View 私有：快照自检要拿真实逻辑跑正则
/// （「不许出现 `1 不可信` 这种」），私有函数测不到
enum RecordingBadge {
    static func text(verified: Int, fair: Int, poor: Int) -> String {
        var parts: [String] = []
        if verified > 0 { parts.append("\(verified) 段已核实") }
        if fair > 0 { parts.append("\(fair) 段存疑") }
        if poor > 0 { parts.append("\(poor) 段不可信") }
        guard !parts.isEmpty else { return "0 段已核实" }
        let full = parts.joined(separator: " · ")
        return measuredWidth(full) <= Theme.RecordingLayout.badgeMaxWidth
            ? full
            : "\(fair + poor) 段异常"
    }

    /// 按角标同字号、同字重量宽度，不按字符数估——
    /// 「1」和「段」的宽度差一倍，按字数估会在中英混排上判错
    static func measuredWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Theme.Text.footnote.size, weight: .semibold)
        return (text as NSString).size(withAttributes: [.font: font]).width
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
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11))
            if let text {
                Text(text)
                    .textStyle(Theme.Text.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(kind.color)
    }
}
