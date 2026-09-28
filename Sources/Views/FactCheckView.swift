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
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("事实核查")
                .textStyle(Theme.Text.largeTitle)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                Text("\(store.results.count) 条")
                if store.pendingCount > 0 {
                    Text("·")
                    Text("\(store.pendingCount) 条核查中").foregroundStyle(Theme.accent)
                }
            }
            .textStyle(Theme.Text.caption)
            .foregroundStyle(Theme.textSecondary)

            if !store.isConfigured {
                configWarning
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    /// 缺配置是「这个功能现在不能用」的状态，用警告图标 + 颜色说，
    /// 而不是拿一块底色框起来——设计规范里的状态表达方式
    private var configWarning: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            StatusMark(kind: .warning, text: "未配置搜索密钥，核查不可用")
            ForEach(AppConfig.statusLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
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
                        .textStyle(Theme.Text.body)
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
            .padding(.horizontal, Theme.pagePadding)
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
                // 原句
                Text(result.claim)
                    .textStyle(Theme.Text.body)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

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
                            .textStyle(Theme.Text.caption)
                            .foregroundStyle(Theme.accent)
                    }
                case .done:
                    doneBody
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.leading, Theme.Spacing.md)
        .contentShape(Rectangle())
        // 悬停反馈用左侧一条竖线，不是整块底色——底色就是「卡片」的另
        // 一种形态。画在 overlay 里不占布局，指针进出时列表不会抖
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isHovering ? Theme.textPrimary.opacity(0.22) : Color.clear)
                .frame(width: 2)
        }
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
        // 和原句首行对齐（body 是 17pt）
        .frame(width: 18, height: 22)
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

    private var doneBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(result.status.label)
                    .font(.system(size: Theme.Text.caption.size, weight: .medium))
                    .foregroundStyle(statusColor)
                if result.showsConfidence {
                    Text("把握 \(Int(result.confidence * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Text(result.explanation)
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !result.sources.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(result.sources) { source in
                        SourceLink(source: source)
                    }
                }
            }
        }
    }

    private func progressLabel(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text(text)
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
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
                    .font(.system(size: Theme.Text.caption.size, weight: .medium))
                    .foregroundStyle(statusColor)
                if result.showsConfidence {
                    Text("把握 \(Int(result.confidence * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if result.phase == .done {
                Text(result.explanation)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !context.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("原文上下文")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)

                    ForEach(context) { segment in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Text(segment.formattedTimestamp)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                            Text(segment.text)
                                .textStyle(Theme.Text.caption)
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    ForEach(result.sources) { source in
                        SourceLink(source: source)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if context.isEmpty && result.sources.isEmpty && result.phase != .done {
                Text("核查尚未完成")
                    .textStyle(Theme.Text.caption)
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
                            .font(.system(size: 9))
                        Text(source.title)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                Text(source.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
