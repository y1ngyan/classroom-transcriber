import SwiftUI

/// 详情页的「说话人识别」区块（C-3-2）。
///
/// **这里不做任何状态判断**：显示哪一档由 `DiarizationPanelState` 那个纯函数
/// 算好，本视图只负责把算出来的那一档画出来（同 `StudyNotesPanelView`）。
/// 原因是 View 是唯一没法离线自检的东西——「跑不了的时候该说什么」一旦落在这里，
/// 就只能靠肉眼在真机上确认，而 `--diarize-ui-selftest` 碰不到它
struct DiarizationPanelView: View {
    @Environment(AppState.self) private var appState
    let session: RecordingSession

    private var store: DiarizationStore { appState.diarization }
    private var state: DiarizationPanelState { store.state(session: session) }
    private var progress: DiarizationProgress? { store.progress[session.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("说话人识别")
                .textStyle(Theme.Text.title)
                .foregroundStyle(Theme.textPrimary)

            statusRow
            actionRow
        }
        .overlay(alignment: .bottom) { Separator() }
    }

    // MARK: - 状态行

    /// 四档都有可见文案（派单书：「不许静默灰」）。分组靠留白和发丝线，
    /// 不靠容器——区块的头是 `Theme.Text.title`，底部一条 `Separator()`
    /// （设计规范：不要卡片、不要阴影、不要边框）
    @ViewBuilder
    private var statusRow: some View {
        switch state.phase {
        case .unavailable:
            // 原因统一由下面那行 `runDisabledReason` 显示，这里不重复同样的话
            EmptyView()

        case .empty:
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("还没有这条录音的说话人标签。")
                    .textStyle(Theme.Text.body)
                    .foregroundStyle(Theme.textTertiary)
                // 说清产出是什么样，用户才知道值不值得等这十几秒
                Text("识别后每段转录旁边会标出 S1 / S2…，编号按开口先后排（S1 是第一个说话的人）；"
                     + "把握不足的段不标。全程十几秒到一分多钟，可以离开这个页面。")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

        case .running:
            // 秒表要走起来。`TimelineView` 而不是 `Timer`：视图离开页面就自动停，
            // 不需要谁记得去 invalidate 一个 Timer（同 `StudyNotesPanelView`）
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(progress?.label(now: context.date) ?? "正在识别说话人…")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

        case .ready:
            if let labels = state.labels {
                StatusMark(
                    kind: .ok,
                    text: "已识别 \(labels.speakerCount) 个说话人 · "
                        + "标注 \(labels.labeled)/\(labels.total) 段（\(labels.rateText)）"
                )
            }

        case .failed(let message):
            // 失败要看得见：不然用户以为重跑成功了，看的还是旧标签
            StatusMark(kind: .error, text: message)
        }

        // 「禁用了就必须说清为什么」——纯函数那边保证这里不是空串
        // （见 `DiarizationPanelState`，自检里有一条不变量穷举所有输入组合钉这件事）。
        // 正在跑那一档不重复说：上面那行进度里已经写着「正在识别」了
        if state.phase != .running, let reason = state.runDisabledReason {
            StatusMark(kind: .neutral, text: reason)
        }

        // 重跑提示。**和禁用原因分开两行**：禁用那条说的是「现在动不了」，
        // 这条说的是「动起来会改什么」——两件事，用户要的是后者
        if let notice = state.rerunNotice {
            StatusMark(kind: .neutral, text: notice)
        }
    }

    // MARK: - 操作行

    /// 一行一个 `PillButton`（设计规范）。次要操作才退化成文字链接——
    /// 这里没有次要操作：重跑和首次跑是同一个动作
    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            PillButton(
                title: state.phase == .ready ? "重新识别"
                    : (state.hasFailed ? "重试" : "识别说话人"),
                systemImage: "person.wave.2",
                // 已经标过时它是「再来一次」的次级操作，不该继续跟主操作抢眼（同 6a）
                style: state.phase == .ready ? .quiet : .filled,
                isLoading: state.phase == .running,
                isEnabled: state.canRun
            ) {
                // **只在这一处触发**（拍板第 2 条：手动触发，不自动跑）
                Task { await store.run(session: session) }
            }

            Spacer()
        }
    }
}
