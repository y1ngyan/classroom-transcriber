import SwiftUI

/// 历史录音与转录的浏览页。
///
/// 存在的理由：这个 App 原先只能「录完当场看」，转录结果还只在内存里，
/// 关掉就没了；recordings/ 下的 wav 和转录文本之间也没有任何关联。
/// 一学期下来录音攒了几十条，却没有任何入口能回去看某一天讲了什么。
///
/// 布局按设计规范：不用卡片、不用底色块，分组靠留白和 `Separator()`；
/// 悬停反馈是一条 2pt 左侧竖条（画在 overlay 里不占布局）。
struct RecordingsView: View {
    @Environment(AppState.self) private var appState

    /// 当前打开的会话。nil = 还停在列表
    @State private var openSessionID: UUID?
    /// 删除确认。非 nil 时弹确认框
    @State private var pendingDelete: SessionSummary?

    private var store: RecordingsStore { appState.recordings }

    var body: some View {
        ZStack {
            if let id = openSessionID, let session = store.session(id: id) {
                RecordingDetailView(session: session) {
                    openSessionID = nil
                }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .confirmationDialog(
            "删除这条录音？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { summary in
            // 两个选项刻意分开命名：默认那条只删转录、保留 wav。
            // wav 是不可恢复的原始素材，转录是派生的、重转可得——
            // 可恢复的那个先走，不可恢复的要用户明确点第二次
            Button("只删除转录记录（保留音频）", role: .destructive) {
                store.delete(id: summary.id)
                pendingDelete = nil
            }
            Button("删除录音和转录（音频不可恢复）", role: .destructive) {
                store.deleteWithAudio(id: summary.id)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { summary in
            Text("\(summary.formattedDate) · \(summary.segmentCount) 段转录")
        }
    }

    // MARK: - 列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.summaries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                        ForEach(courseGroups, id: \.0) { group in
                            courseGroup(name: group.0, sessions: group.1)
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.xxl)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("录音")
                .textStyle(Theme.Text.largeTitle)
                .foregroundStyle(Theme.textPrimary)

            let total = store.summaries.count
            Text(total == 0 ? "还没有录音" : "共 \(total) 条录音")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.md)
        .overlay(alignment: .bottom) { Separator() }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text("还没有录音")
                .textStyle(Theme.Text.body)
                .foregroundStyle(Theme.textSecondary)
            Text("在转录页点「开始录制」，录完的内容会自动出现在这里。")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 两级分组：先按课程，课程内再按天。
    ///
    /// 为什么是「课程 → 天」而不是「天 → 课程」：用户找一条录音时想的是
    /// 「那节机器学习课」，课程是第一位的检索维度；日期是课程内部的次级
    /// 定位。反过来（天在上）会把同一门课打散在几十个日期组里，等于没有
    /// 分类。未分类排在最后——它是兜底组，不该压在有归属的内容前面
    private var courseGroups: [(String, [SessionSummary])] {
        let byCourse = Dictionary(grouping: store.summaries) { $0.displayCourse }
        return byCourse
            .map { (name: $0.key, sessions: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { lhs, rhs in
                // 未分类永远最后
                let lIsOther = lhs.name == "未分类"
                let rIsOther = rhs.name == "未分类"
                if lIsOther != rIsOther { return rIsOther }
                // 其余按组内最新时间倒序——最近在用的课排前面
                let l = lhs.sessions.first?.startedAt ?? .distantPast
                let r = rhs.sessions.first?.startedAt ?? .distantPast
                return l > r
            }
    }

    /// 课程内按天分组
    private func daysWithin(_ sessions: [SessionSummary]) -> [(String, [SessionSummary])] {
        let byDay = Dictionary(grouping: sessions) { $0.dayKey }
        return byDay
            .map { (title: $0.value.first?.groupTitle ?? $0.key,
                     sessions: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { lhs, rhs in
                let l = lhs.sessions.first?.startedAt ?? .distantPast
                let r = rhs.sessions.first?.startedAt ?? .distantPast
                return l > r
            }
    }

    private func courseGroup(name: String, sessions: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // 课程名用 body 字号 + 主色，比日期组标题（caption + 次级色）
            // 高一级：两级标题必须能一眼分出层级，同一档字号会读成平级
            HStack(spacing: Theme.Spacing.sm) {
                Text(name)
                    .textStyle(Theme.Text.body)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(sessions.count)")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                ForEach(daysWithin(sessions), id: \.0) { day in
                    dayGroup(title: day.0, items: day.1)
                }
            }
            // 课程内部缩进一档，让两级归属在视觉上成立
            .padding(.leading, Theme.Spacing.md)
        }
    }

    private func dayGroup(title: String, items: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // 分组标题小一号、次级色：它管的是分组，不该和条目本身抢注意力
            Text(title)
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(items) { item in
                    RecordingRow(
                        summary: item,
                        onOpen: { openSessionID = item.id },
                        onDelete: { pendingDelete = item }
                    )
                }
            }
        }
    }
}

// MARK: - 列表行

/// 一条录音。整行可点进详情，悬停时右侧浮出删除入口。
private struct RecordingRow: View {
    let summary: SessionSummary
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    // 显示名：用户起过就用它，没起过回落成时间。
                    // title 为空时才另外补一个时间——否则「9月21日 11:12」
                    // 会被显示两次
                    Text(summary.displayTitle)
                        .textStyle(Theme.Text.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if !summary.title.isEmpty {
                        Text(summary.formattedTime)
                            .textStyle(Theme.Text.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Text(summary.formattedDuration)
                        .textStyle(Theme.Text.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)

                    Spacer()

                    // 删除入口：悬停才出现。常驻的话每行都挂一个按钮，
                    // 一屏几十条全是控件，扫列表反而被挤没了
                    if isHovering {
                        Button(action: onDelete) {
                            Text("删除")
                                .textStyle(Theme.Text.caption)
                                .foregroundStyle(Theme.error)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }

                if !summary.firstText.isEmpty {
                    Text(summary.firstText)
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                // 读数行，只在实际有内容的项上出现——「0 个提问 0 段存疑」
                // 这种占位读数没有任何信息量，只会把列表撑高
                HStack(spacing: Theme.Spacing.md) {
                    if summary.partCount > 1 {
                        Label("\(summary.partCount) 段录音", systemImage: "square.stack")
                    }
                    Text("\(summary.segmentCount) 段转录")
                    if summary.poorCount > 0 {
                        StatusMark(kind: .error, text: "\(summary.poorCount) 段不可信")
                    }
                    if summary.fairCount > 0 {
                        StatusMark(kind: .warning, text: "\(summary.fairCount) 段存疑")
                    }
                    if summary.questionCount > 0 {
                        Label("\(summary.questionCount) 个提问", systemImage: "questionmark.bubble")
                    }
                }
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 悬停反馈是 2pt 左侧竖条，不是背景填充
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isHovering ? Theme.textPrimary.opacity(0.22) : Color.clear)
                .frame(width: 2)
                .offset(x: -Theme.Spacing.md)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// MARK: - 摘要的显示格式

extension SessionSummary {
    /// 按天分组的键。用 yyyy-MM-dd 而不是本地化字符串：
    /// 它是拿来分组和排序的，不是给人读的，格式必须稳定
    var dayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: startedAt)
    }

    /// 分组标题。今天/昨天用相对说法，更早给日期——
    /// 「2026-09-21」这种绝对值读起来要转一下脑子，最近两天不该付这个成本
    var groupTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(startedAt) { return "今天" }
        if calendar.isDateInYesterday(startedAt) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: startedAt)
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: startedAt)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: startedAt)
    }

    /// `12:03` 形式。超过一小时才带小时位
    var formattedDuration: String {
        let total = max(0, durationMillis) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
