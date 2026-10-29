import SwiftUI

struct NotesView: View {
    @Environment(AppState.self) private var appState

    private var store: NotesStore { appState.notes }
    private var segments: [TranscriptSegment] { appState.transcription.segments }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }

            exportButton
                .padding(.bottom, Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("课堂笔记")
                .textStyle(Theme.Text.largeTitle)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                Text("\(segments.count) 段转录")
                if let generatedAt = store.generatedAt {
                    Text("·")
                    Text("生成于 \(timeString(generatedAt))")
                }
            }
            .textStyle(Theme.Text.caption)
            .foregroundStyle(Theme.textSecondary)

            if let error = store.errorMessage {
                StatusMark(kind: .error, text: error)
            }

            PillButton(
                title: store.hasNotes ? "重新生成" : "生成笔记",
                systemImage: "sparkles",
                // 已经有笔记时它就是个「再来一次」的次级操作，不该继续
                // 跟主操作抢眼
                style: store.hasNotes ? .quiet : .filled,
                isLoading: store.isGenerating,
                isEnabled: !segments.isEmpty
            ) {
                Task { await store.generate(from: segments) }
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 正文

    private var content: some View {
        Group {
            if store.hasNotes {
                // 笔记正文是一整块产出，用一张卡片圈住它（elevation 1）——
                // 卡片在这里表达「这一坨是一个东西」，不是给它加装饰。
                // 注意：正文是 `WKWebView`，快照（离屏渲染）拍不到它加载后
                // 的内容，见 `UISnapshot` 的说明
                MarkdownWebView(markdown: store.markdown)
                    .background(Color.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .cardStyle(elevation: 1)
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "text.page")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textTertiary)

                    Text(segments.isEmpty
                         ? "先转录一些内容，再回来生成笔记。"
                         : "点击「生成笔记」，把转录整理成带时间戳的结构化笔记。")
                        .textStyle(Theme.Text.body)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)

                    Text("将包含：核心知识点大纲 · 关键术语解释 · 行动项")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: 520)
                .cardStyle(elevation: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.bottom, 110)
    }

    // MARK: - 悬浮胶囊按钮

    private var exportButton: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.sm) {
            // 结果就近显示：用户点完导出，眼睛在按钮上，不在页面顶部
            if let message = store.exportMessage {
                StatusMark(kind: store.exportFailed ? .error : .ok, text: message)
            }
            // 禁用了就必须说清为什么（见 NotesStore.exportDisabledReason 的注释：
            // 不说话的禁用态，用户读到的就是「按钮坏了」）
            if let reason = store.exportDisabledReason {
                StatusMark(kind: .neutral, text: reason)
            }
            // 设计规范要求不使用阴影。原来靠阴影从内容上「浮」起来，现在靠
            // 实心填充 + 下方留白拉开层次
            PillButton(
                title: "导出 Markdown",
                systemImage: "square.and.arrow.up",
                isEnabled: store.hasNotes
            ) {
                store.export()
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }
}
