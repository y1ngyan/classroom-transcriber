import SwiftUI

struct FactCheckView: View {
    @Environment(AppState.self) private var appState

    private var store: FactCheckStore { appState.factCheck }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.pageBackground)
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // 44pt 工具栏：主操作在右上角（P14-4）
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Text("事实核查")
                    .textStyle(Theme.Text.largeTitle)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: Theme.Spacing.md)

                ToolbarActionButton(
                    title: "重新核查",
                    systemImage: "arrow.clockwise",
                    isEnabled: canRecheck
                ) {
                    recheckAll()
                }
            }
            .frame(height: Theme.RecordingLayout.toolbarHeight)

            HStack(spacing: Theme.Spacing.s6) {
                Text("\(store.results.count) 条")
                if store.pendingCount > 0 {
                    Text("·")
                    Text("\(store.pendingCount) 条核查中").foregroundStyle(Theme.accent)
                }
            }
            .textStyle(Theme.Text.meta)
            .foregroundStyle(Theme.textSupporting)

            if !store.isConfigured {
                configWarning
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.top, Theme.RecordingLayout.pagePadding)
        .padding(.bottom, Theme.Spacing.md)
    }

    /// 有结论、有凭证、且没有正在跑的核查时才允许「重新核查」。
    /// 跑着的时候再点一次会给同一条 claim 起两个请求
    private var canRecheck: Bool {
        store.isConfigured && !store.results.isEmpty && store.pendingCount == 0
    }

    /// 重新核查 = 对当前每一条结果再走一次既有的 `retry`。
    /// 这是 UI 层的批量动作，不改 store 的语义：`retry` 本来就是
    /// 「删掉这条、拿同一句 claim 重新提交」，逐条调用和用户逐条点
    /// 右上角的「重试」完全同一条路径
    private func recheckAll() {
        guard canRecheck else { return }
        for result in store.results {
            store.retry(result)
        }
    }

    /// 缺配置是「这个功能现在不能用」的状态，用警告图标 + 颜色说，
    /// 而不是拿一块底色框起来——设计规范里的状态表达方式
    private var configWarning: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            StatusMark(kind: .warning, text: "未配置搜索密钥，核查不可用")
            ForEach(AppConfig.statusLines, id: \.self) { line in
                Text(line)
                    .font(Theme.Text.footnote.font.monospaced())
                    .foregroundStyle(Theme.textSupporting)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.warning).frame(width: 2)
        }
        .padding(.top, Theme.Spacing.xs)
    }

    // MARK: - 列表

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if store.results.isEmpty {
                    Text("转录出完整句子后，核查结果会自动出现在这里。")
                        .textStyle(Theme.Text.summary)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 100)
                }

                ForEach(store.results) { result in
                    FactCheckRow(
                        result: result,
                        context: appState.context(around: result.segmentID),
                        onRetry: { store.retry(result) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.RecordingLayout.pagePadding)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }
}

// MARK: - 单条结果

private struct FactCheckRow: View {
    let result: FactCheckResult
    /// 原句前后各一段转录，浮窗里显示
    let context: [TranscriptSegment]
    let onRetry: () -> Void

    @State private var isHovering = false
    @State private var isPreviewVisible = false
    @State private var showTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            statusIcon

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // 原句 + 右上角结论角标。置信度从正文行里拿出来贴在角标旁
                // （P14-4）：它是结论的注脚，不是正文的第二行
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(result.claim)
                        .textStyle(Theme.Text.summary)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: Theme.Spacing.s12)

                    if result.phase == .done {
                        StatusCapsule(text: result.status.label, color: statusColor)
                        if result.showsConfidence {
                            Text("把握 \(Int(result.confidence * 100))%")
                                .font(Theme.Text.footnote.font.monospacedDigit())
                                .foregroundStyle(Theme.textSupporting)
                                .lineLimit(1)
                        }
                    }
                }

                switch result.phase {
                case .searching:
                    progressLabel("正在检索来源…")
                case .analyzing:
                    progressLabel("正在分析…")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        StatusMark(kind: .error, text: message)
                        Button("重试", action: onRetry)
                            .buttonStyle(.plain)
                            .textStyle(Theme.Text.meta)
                            .foregroundStyle(Theme.accent)
                    }
                case .done:
                    doneBody
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(elevation: 1, isHighlighted: isHovering)
        // 结论色做成左缘 3pt 竖条：扫一屏时颜色比读文字快。
        // 圆头而不是方头——方头会被卡片的圆角切掉一半，看着像画坏了
        .overlay(alignment: .leading) {
            Capsule()
                .fill(barColor)
                .frame(width: 3)
                .padding(.vertical, Theme.Spacing.md)
                .padding(.leading, 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            hovering ? pointerEntered() : pointerExited()
        }
        .popover(isPresented: $isPreviewVisible, arrowEdge: .trailing) {
            FactCheckPreview(result: result, context: context)
                // 浮窗自己也要参与 hover 状态机：否则指针移到浮窗上时
                // 卡片先收到 hover=false → 收起浮窗 → 指针又落回卡片 →
                // 再次弹出，就会来回闪
                .onHover { $0 ? pointerEntered() : pointerExited() }
        }
    }

    // MARK: - 悬停状态机

    /// 悬停 450ms 才弹窗：指针只是路过时不该弹
    private func pointerEntered() {
        hideTask?.cancel()
        guard !isPreviewVisible else { return }
        showTask?.cancel()
        showTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            isPreviewVisible = true
        }
    }

    /// 离开后留 250ms 宽限：给指针从卡片移到浮窗的时间
    private func pointerExited() {
        showTask?.cancel()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isPreviewVisible = false
        }
    }

    /// 状态用小图标 + 颜色表达。
    ///
    /// 这里用文字符号（✓ / ? / ✗）而不是 SF Symbol：`FactCheckResult.Status.symbol`
    /// 就是这几个字符，浮窗里也在用，改成一个字段两种含义只会让两边不一致。
    /// 核查没出结果之前没有状态可标，给个旋转的指示器，而不是一个含义不明的省略号。
    private var statusIcon: some View {
        Group {
            if result.phase == .done {
                Text(result.status.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        // 和原句首行对齐（原句是 15pt）
        .frame(width: 18, height: 20)
    }

    /// verified #30D158，unverifiable #FF9F0A，disputed 用系统红
    private var statusColor: Color {
        switch result.phase {
        case .failed: return Theme.error
        case .searching, .analyzing: return .secondary
        case .done:
            switch result.status {
            case .verified: return Theme.success
            case .unverifiable: return Theme.warning
            case .disputed: return Theme.error
            }
        }
    }

    /// 左缘那条 3pt 竖条的颜色。还没结论时用分隔线的灰——
    /// 用绿/黄/红会让人以为已经有结论了
    private var barColor: Color {
        switch result.phase {
        case .failed: return Theme.error
        case .searching, .analyzing: return Theme.separator
        case .done:
            switch result.status {
            case .verified: return Theme.success
            case .unverifiable: return Theme.warning
            case .disputed: return Theme.error
            }
        }
    }

    private var doneBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(result.explanation)
                .textStyle(Theme.Text.meta)
                .foregroundStyle(Theme.textSupporting)
                .fixedSize(horizontal: false, vertical: true)

            if !result.sources.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    // 每条来源一行；整个来源块最多两行（P14-4），
                    // 多出来的用一行计数收口，不把卡片撑成一段链接列表
                    ForEach(result.sources.prefix(2)) { source in
                        SourceLink(source: source)
                    }
                    if result.sources.count > 2 {
                        Text("+\(result.sources.count - 2) 个来源")
                            .textStyle(Theme.Text.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private func progressLabel(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text(text)
                .textStyle(Theme.Text.meta)
                .foregroundStyle(Theme.textSupporting)
        }
    }
}

// MARK: - 悬停浮窗

/// 核查卡片的悬停预览。
///
/// 对应原 TS 版里 Expo Router 的 `<Link.Preview>`（长按窥视详情）。
/// macOS 没有长按，改成悬停；语义保留「不离开当前页就能多看一眼」。
/// 内容刻意**不是**卡片的复读——多出来的是原句前后的上下文，
/// 判断一句结论可不可信，靠的正是它前后说了什么。
private struct FactCheckPreview: View {
    let result: FactCheckResult
    let context: [TranscriptSegment]

    private var statusColor: Color {
        switch result.status {
        case .verified: return Theme.success
        case .unverifiable: return Theme.warning
        case .disputed: return Theme.error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(result.status.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(result.status.label)
                    .font(Theme.Text.meta.font.weight(.semibold))
                    .foregroundStyle(statusColor)
                if result.showsConfidence {
                    Text("把握 \(Int(result.confidence * 100))%")
                        .font(Theme.Text.footnote.font.monospacedDigit())
                        .foregroundStyle(Theme.textSupporting)
                }
            }

            if result.phase == .done {
                Text(result.explanation)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !context.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("原文上下文")
                        .font(Theme.Text.footnote.font.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)

                    ForEach(context) { segment in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Text(segment.formattedTimestamp)
                                .font(Theme.Text.footnote.font.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                            Text(segment.text)
                                .textStyle(Theme.Text.meta)
                                .foregroundStyle(segment.id == result.segmentID
                                    ? Theme.textPrimary : Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, Theme.Spacing.sm)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(segment.id == result.segmentID
                                    ? statusColor.opacity(0.7) : Theme.separator)
                                .frame(width: 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !result.sources.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("来源")
                        .font(Theme.Text.footnote.font.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                    ForEach(result.sources) { source in
                        SourceLink(source: source)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if context.isEmpty && result.sources.isEmpty && result.phase != .done {
                Text("核查尚未完成")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: 380, alignment: .leading)
    }
}

private struct SourceLink: View {
    let source: FactCheckSource

    private var url: URL? { URL(string: source.url) }

    var body: some View {
        Group {
            if let url {
                Link(destination: url) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "link")
                            .font(.system(size: Theme.Text.footnote.size))
                        Text(source.title)
                            // 来源每条一行：长标题截断，不换行挤成两段
                            .lineLimit(1)
                    }
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
                }
                .buttonStyle(.plain)
            } else {
                Text(source.title)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}
