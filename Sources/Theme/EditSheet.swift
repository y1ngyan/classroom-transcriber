import SwiftUI

/// 单行文本输入的弹窗。改名和设置课程共用一份。
///
/// 为什么不做成就地编辑：改名/改课程都是低频操作，就地编辑要在列表里
/// 引入「哪一行正在编辑」的状态机，还得处理点别处取消、失焦提交这些
/// 分支；而弹窗天然有明确的开始和结束，用户不会误改。
///
/// `suggestions` 给已有值做候选——课程名手打早晚会出现「机器学习」和
/// 「机器学习 」这样的两个组，让用户点选已有的能避免这件事。
struct EditSheet: View {
    let title: String
    var hint: String = ""
    var placeholder: String = ""
    @Binding var text: String
    var suggestions: [String] = []
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(title)
                .textStyle(Theme.Text.title)
                .foregroundStyle(Theme.textPrimary)

            if !hint.isEmpty {
                Text(hint)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .textStyle(Theme.Text.body)
                .foregroundStyle(Theme.textPrimary)
                .focused($isFocused)
                .onSubmit(onConfirm)
                .padding(.vertical, Theme.Spacing.sm)
                .overlay(alignment: .bottom) { Separator() }

            // 候选：点一下填进输入框，不直接提交——先让用户看清要填什么
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("已有课程")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)

                    FlowRow(spacing: Theme.Spacing.sm) {
                        ForEach(suggestions, id: \.self) { name in
                            Button {
                                text = name
                            } label: {
                                Text(name)
                                    .textStyle(Theme.Text.caption)
                                    .foregroundStyle(Theme.accent)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: Theme.Spacing.lg) {
                // 只有主操作用 PillButton，取消退化成文字链接（设计规范）
                PillButton(title: "保存", style: .filled, action: onConfirm)

                Button(action: onCancel) {
                    Text("取消")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(Theme.pagePadding)
        .frame(width: 460)
        .background(Theme.background)
        .onAppear { isFocused = true }
    }
}

/// 自动折行的横向排列。
///
/// 存在的理由：候选课程名个数不定、长度也不定，用 `HStack` 会溢出，
/// 用 `LazyVGrid` 得先算列宽（而列宽取决于文字长度，算不出来）。
/// 这里按可用宽度逐行装填，装不下就换行——这正是标签云要的行为。
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
