import SwiftUI

/// 详情页顶部的「课后笔记」区块（拍板 6a）。
///
/// **这里不做任何状态判断**：显示哪一档由 `StudyNotesPanelState` 那个纯函数
/// 算好，本视图只负责把算出来的那一档画出来。原因是 View 是唯一没法离线自检的
/// 东西——判断一旦落在这里，「生成中该显示什么」就只能靠肉眼在真机上确认
struct StudyNotesPanelView: View {
    @Environment(AppState.self) private var appState
    let session: RecordingSession

    /// 导出结果就近显示：用户点完导出，眼睛在按钮上，不在别处
    /// （同 `NotesStore.exportMessage`，理由见那边的注释）
    @State private var exportMessage: String?
    @State private var exportFailed = false

    private var store: StudyNotesStore { appState.studyNotes }
    private var state: StudyNotesPanelState { store.state(sessionID: session.id) }
    private var progress: StudyNotesProgress? { store.progress[session.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // 详情页里的小节标题走 17/600（P14-4）：28 那一档留给页面标题，
            // 一个区块不能和整页标题一样大
            Text("课后笔记")
                .textStyle(Theme.Text.bodyEmphasized)
                .foregroundStyle(Theme.textPrimary)

            // 面板内容（状态、操作、正文）是一个整体，用一张卡片圈住。
            // 原来底部那条 Separator 由卡片的 0.5pt 描边接替
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                statusRow
                actionRow

                if state.showsExistingNotes,
                   let markdown = store.markdown(sessionID: session.id) {
                    MarkdownWebView(markdown: markdown)
                        .frame(height: StudyNotesPanelState.notesViewportHeight(
                            itemCount: store.notes[session.id]?.items.count ?? 0
                        ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(elevation: 1)
        }
        // 磁盘上那份笔记只在进页面时读一次。放在 `.task` 而不是 `init`：
        // 这是个磁盘读，不该发生在 SwiftUI 求值 body 的过程里
        .task { store.load(sessionID: session.id) }
    }

    // MARK: - 状态行

    /// 每一档都有可见文案（派单书要求「别只灰着」）。
    ///
    /// P13-2 起面板内容整体进了一张卡片（见 `body`），这里只负责状态文案，
    /// 不再自己画分隔线
    @ViewBuilder
    private var statusRow: some View {
        switch state.phase {
        case .needsKey:
            // 原因统一在下面那行显示，这里不重复一遍同样的话
            EmptyView()

        case .empty:
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("还没有这条录音的课后笔记。")
                    .textStyle(Theme.Text.summary)
                    .foregroundStyle(Theme.textTertiary)
                Text("将包含：摘要 · 重点 · 待办 · 考点 · 术语（每条都带转录时间戳）")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textTertiary)
            }

        case .generating:
            // 秒表要走起来。`TimelineView` 而不是 `Timer`：视图离开页面就自动停，
            // 不需要谁记得去 invalidate 一个 Timer（忘了就是一条常驻的后台唤醒）
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(progress?.label(now: context.date) ?? "正在生成…")
                        .textStyle(Theme.Text.meta)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }

        case .ready:
            if let notes = store.notes[session.id] {
                StatusMark(kind: .ok, text: "已生成 \(notes.items.count) 条 · \(timeString(notes.generatedAt))")
            }

        case .failed(let message):
            // 失败要看得见：不然用户会以为重跑成功、看的还是旧内容
            StatusMark(kind: .error, text: message)
        }

        // 「禁用了就必须说清为什么」——纯函数那边保证这里不是空串
        // （见 `StudyNotesPanelState`，自检里有一条不变量专门钉这件事）
        if state.phase != .generating, let reason = state.generateDisabledReason {
            StatusMark(kind: .neutral, text: reason)
        }

        if let exportMessage {
            StatusMark(kind: exportFailed ? .error : .ok, text: exportMessage)
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 操作行

    /// 一行一个 `PillButton`（设计规范），次要操作退化成文字链接
    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            PillButton(
                title: state.phase == .ready ? "重新生成" : "生成课后笔记",
                systemImage: "sparkles",
                // 已经有笔记时它是「再来一次」的次级操作，不该继续跟主操作抢眼
                style: state.phase == .ready ? .quiet : .filled,
                isLoading: state.phase == .generating,
                isEnabled: state.canGenerate
            ) {
                Task {
                    await store.generate(session: session, glossary: appState.glossary.entries)
                }
            }

            if state.showsExistingNotes {
                Button(action: exportNotes) {
                    Text("导出 Markdown").textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.accent).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    /// 面板自己的导出入口。**落盘复用 `NotesExporter`**（见 `StudyNotesStore.export`）：
    /// 2026-09-24 那次「点导出生成不了文件」之后才把写文件那段抽出来配了判据，
    /// 这里另写一份等于绕开那条修好的路
    private func exportNotes() {
        guard let result = store.export(sessionID: session.id) else { return }
        exportMessage = result.message
        exportFailed = result.failed
    }
}
