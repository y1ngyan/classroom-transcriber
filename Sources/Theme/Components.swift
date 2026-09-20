import SwiftUI

// MARK: - PillButton

/// 胶囊按钮。规格：主色 #0071E3、文字白色、圆角 980。
///
/// 980 是「永远等于半高」的惯用写法（大到任何高度都取不到真正的圆角），
/// SwiftUI 里对应的东西就是 `Capsule()`，所以不写那个数字。
struct PillButton: View {

    enum Style {
        /// 规格给的主按钮
        case filled
        /// 次级操作。规格只定义了主按钮，但界面上确实有「添加图片」这类
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
        // 悬停反馈取代阴影：规格不要阴影，但按钮总得能看出是可点的
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
        .padding(.vertical, 10)
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

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
            // 提问标记：小图标 + 颜色（规格的状态表达方式），不加底色块。
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

            Text(TextHighlight.styled(segment.text))
                .textStyle(Theme.Text.body)
                // 未定稿的段落压暗一档：识别结果还会变，视觉上先区分开
                .opacity(segment.isFinal ? 1 : 0.55)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 缩略图 + 时间戳，一起右对齐
            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                ForEach(attachments) { attachment in
                    if let onRemoveAttachment {
                        Thumbnail(attachment: attachment) { onRemoveAttachment(attachment) }
                    } else {
                        Thumbnail(attachment: attachment) {}
                    }
                }

                Text(segment.formattedTimestamp)
                    .textStyle(Theme.Text.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - 图片缩略图

/// 缩略图用圆角裁切是**内容裁切**，不是卡片外壳——规格里「不使用卡片」
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

// MARK: - 状态标记

/// 状态用小图标 + 颜色表达（规格要求），而不是靠背景色块。
struct StatusMark: View {
    enum Kind {
        case ok, warning, error, neutral
        /// 进行中（正在录制）。不是「出错」：用实心点，和红点录制指示
        /// 灯是同一个符号语言
        case live

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .neutral: return "circle"
            case .live: return "circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .ok: return Theme.success
            case .warning: return Theme.warning
            case .error: return Theme.error
            case .neutral: return Theme.textTertiary
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
