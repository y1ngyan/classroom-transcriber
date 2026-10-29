import SwiftUI

struct NotesView: View {
    @Environment(AppState.self) private var appState

    private var store: NotesStore { appState.notes }
    private var segments: [TranscriptSegment] { appState.transcription.segments }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        // 导出是这一屏的次级操作，放在底部安全区：不再用 ZStack 叠在
        // 内容上，滚到底时最后一行不会被按钮压住
        .safeAreaInset(edge: .bottom, spacing: 0) {
            exportBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // 44pt 工具栏：主操作在右上角（P14-4）
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Text("课堂笔记")
                    .textStyle(Theme.Text.largeTitle)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: Theme.Spacing.md)

                ToolbarActionButton(
                    title: store.hasNotes ? "重新生成" : "生成笔记",
                    systemImage: "sparkles",
                    isLoading: store.isGenerating,
                    isEnabled: !segments.isEmpty
                ) {
                    generate()
                }
            }
            .frame(height: Theme.RecordingLayout.toolbarHeight)

            HStack(spacing: Theme.Spacing.s6) {
                Text("\(segments.count) 段转录")
                if let generatedAt = store.generatedAt {
                    Text("·")
                    Text("生成于 \(timeString(generatedAt))")
                }
            }
            .textStyle(Theme.Text.meta)
            .foregroundStyle(Theme.textSupporting)

            if let error = store.errorMessage {
                StatusMark(kind: .error, text: error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.top, Theme.RecordingLayout.pagePadding)
        .padding(.bottom, Theme.Spacing.md)
    }

    private func generate() {
        Task { await store.generate(from: segments) }
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
                // 空状态 = 一句标题 + 一行说明 + 一个主按钮（P14-4）
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "text.page")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textSupporting)

                    // 不写「点击上面的按钮」：顶部那个胶囊就在眼前，指的是同一件事。
                    // 空状态该回答的是「这里将来会有什么」
                    Text(segments.isEmpty ? "还没有转录内容" : "还没有生成笔记")
                        .textStyle(Theme.Text.bodyEmphasized)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(segments.isEmpty
                         ? "转录结束后，这里会整理出带时间戳的结构化笔记。"
                         : "将包含：核心知识点大纲 · 关键术语解释 · 行动项")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.textSupporting)
                        .multilineTextAlignment(.center)

                    PillButton(
                        title: store.hasNotes ? "重新生成" : "生成笔记",
                        systemImage: "sparkles",
                        isLoading: store.isGenerating,
                        isEnabled: !segments.isEmpty
                    ) {
                        generate()
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
                .padding(.vertical, Theme.Spacing.s32)
                .frame(maxWidth: 520)
                .cardStyle(elevation: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: - 底部导出栏

    private var exportBar: some View {
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
            PillButton(
                title: "导出 Markdown",
                systemImage: "square.and.arrow.up",
                isEnabled: store.hasNotes
            ) {
                store.export()
            }
        }
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }
}
