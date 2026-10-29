import SwiftUI

/// 历史录音与转录的浏览页。
///
/// 存在的理由：这个 App 原先只能「录完当场看」，转录结果还只在内存里，
/// 关掉就没了；recordings/ 下的 wav 和转录文本之间也没有任何关联。
/// 一学期下来录音攒了几十条，却没有任何入口能回去看某一天讲了什么。
///
/// 布局（P13-1 起）：列表行是**卡片**（`.cardStyle(elevation: 1)`）——
/// 这一屏是卡片设计的试点，其余屏还是旧的「靠留白分组」。分组的课程/日期
/// 标题仍靠留白分层，卡片只负责「一条录音」这个最小单位。
struct RecordingsView: View {
    @Environment(AppState.self) private var appState

    /// 当前打开的会话。nil = 还停在列表
    @State private var openSessionID: UUID?
    /// 删除确认。非 nil 时弹确认框
    @State private var pendingDelete: SessionSummary?
    /// 丢弃未完成录音的确认。**删文件一律显式**——非 nil 时弹确认框
    @State private var pendingDiscard: RecoveryScan.Item?

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
        // 丢弃未完成的录音。**只删那一份草稿，绝不碰音频**——
        // 音频是不可恢复的原始素材，要删它得另走「删除录音」那条路，
        // 那条路上的确认文案写明了「音频不可恢复」
        .confirmationDialog(
            "丢弃这份未完成的转录？",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            presenting: pendingDiscard
        ) { item in
            Button("丢弃转录（保留音频文件）", role: .destructive) {
                store.discard(item)
                pendingDiscard = nil
            }
            Button("取消", role: .cancel) { pendingDiscard = nil }
        } message: { item in
            Text("只会删掉这份没写完的转录。音频 \(item.fileName ?? "") 留在原处，"
                 + "之后会显示成「无会话的录音」。")
        }
    }

    // MARK: - 列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.summaries.isEmpty && store.recoveryItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                        // 「未完成」排在最前：它是**要用户做决定**的一组，
                        // 压在一屏历史录音底下等于没提。做完决定这一组就消失
                        if !store.recoveryItems.isEmpty {
                            recoverySection
                        }
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
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "waveform")
                .font(.system(size: 22))
                .foregroundStyle(Theme.textTertiary)

            // 页头副标题已经写了「还没有录音」，这里不再重复一遍标题
            Text("在转录页点「开始录制」，录完的内容会自动出现在这里。")
                .textStyle(Theme.Text.body)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)

            // 空状态只说明「该去哪」不够：用户还得自己去找标签页。
            // 这里直接把他送到那一页，不新开窗口
            PillButton(title: "去转录页录制", systemImage: "mic") {
                appState.selectedTab = .transcription
            }
        }
        .frame(maxWidth: 520)
        .cardStyle(elevation: 1)
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

    /// 「未完成」那一组（P9-1）。
    ///
    /// 存在的理由：崩溃/强杀/断电之后，音频还在盘上（`WAVRecorder` 流式落盘），
    /// 但会话从来没被写下来过——**列表的数据源是 sessions/index.json，
    /// 所以那些录音原本一条都不会出现**，用户看不到、也找不回来。
    /// 这一组就是那个「看得见」的入口
    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                StatusMark(kind: .warning, text: "未完成")
                Text("\(store.recoveryItems.count)")
                    .textStyle(Theme.Text.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }

            Text("这些录音没有正常结束（崩溃、被强杀或断电），转录只写到一半。"
                 + "恢复会把它们变成正式录音；丢弃只删这份没写完的转录，音频留着。")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                ForEach(store.recoveryItems) { item in
                    RecoveryRow(
                        item: item,
                        onRecover: { store.recover(item) },
                        onDiscard: { pendingDiscard = item }
                    )
                }
            }
            // 和课程组同一个缩进档：这一组也是「标题 + 条目」的两级结构
            .padding(.leading, Theme.Spacing.md)

            // 恢复是唯一一处会改用户音频的动作，改了什么要看得见。
            // 空的时候不占位——一句话都没有才是常态
            if !store.recoveryNotes.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("上次恢复改动了音频头：")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(store.recoveryNotes, id: \.self) { line in
                        Text(line)
                            .textStyle(Theme.Text.mono)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
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
                        .textStyle(Theme.Text.rowTitle)
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

                    // 右侧只放一件事：悬停时是删除，平时是质量状态。
                    // 删除常驻的话每行都挂一个按钮，一屏几十条全是控件，
                    // 扫列表反而被挤没了
                    if isHovering {
                        Button(action: onDelete) {
                            Text("删除")
                                .textStyle(Theme.Text.caption)
                                .foregroundStyle(Theme.error)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    } else {
                        qualityMark
                    }
                }

                if !summary.firstText.isEmpty {
                    Text(summary.firstText)
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                // 读数行，只在实际有内容的项上出现——「0 个提问 0 段存疑」
                // 这种占位读数没有任何信息量，只会把列表撑高。
                // 质量相关的两条已经移到右上角（`qualityMark`），这里不再重复
                HStack(spacing: Theme.Spacing.md) {
                    if summary.partCount > 1 {
                        Label("\(summary.partCount) 段录音", systemImage: "square.stack")
                    }
                    Text("\(summary.segmentCount) 段转录")
                    if summary.questionCount > 0 {
                        Label("\(summary.questionCount) 个提问", systemImage: "questionmark.bubble")
                    }
                }
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 卡片外观必须套在**按钮的 label 里**，不能套在按钮外面：
            // `cardStyle` 自带 16pt 内边距，套在外面时那圈内边距落在按钮
            // 的命中区之外——悬停会亮（`onHover` 在外层），点到卡片边缘
            // 却不打开。`contentShape` 放在 `cardStyle` 之后，把包括内边距
            // 在内的整张卡片都算成命中区
            .cardStyle(elevation: 1, isHighlighted: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    /// 右上角的质量状态：有坏段优先报坏段，其次是存疑，都没有就是一个绿勾。
    /// 绿勾不带文字——每行都写一遍「全部可信」会把列表读成一排公告
    private var qualityMark: StatusMark {
        // 两种段可以并存（是两个独立计数），所以不能写成「有坏段就只说坏段」——
        // 那样有 1 段不可信 + 20 段存疑时，用户只看得到那个 1
        let poor = summary.poorCount
        let fair = summary.fairCount
        if poor > 0 && fair > 0 {
            return StatusMark(kind: .error, text: "\(poor) 段不可信 · \(fair) 段存疑")
        }
        if poor > 0 {
            return StatusMark(kind: .error, text: "\(poor) 段不可信")
        }
        if fair > 0 {
            return StatusMark(kind: .warning, text: "\(fair) 段存疑")
        }
        return StatusMark(kind: .ok, text: nil)
    }
}

/// 一条「未完成」的录音（P9-1）。和 `RecordingRow` 的差别是**它要用户做决定**：
/// 所以右侧那个位置留给唯一的主动作（`PillButton`「恢复」），
/// 次要动作（丢弃）退化成文字链接——一行只放一个按钮是设计规范。
private struct RecoveryRow: View {
    let item: RecoveryScan.Item
    let onRecover: () -> Void
    let onDiscard: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(item.kindLabel)
                    .textStyle(Theme.Text.body)
                    .foregroundStyle(Theme.textPrimary)

                if let startedAt = item.startedAt {
                    Text(Self.time.string(from: startedAt))
                        .textStyle(Theme.Text.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                // 只有「有草稿可扶正」的那一类才给恢复。孤儿音频没有草稿，
                // 按了也无事可做——给一个按下去没反应的按钮比不给更糟
                if item.isRecoverable {
                    PillButton(title: "恢复", action: onRecover)
                }
            }

            if !item.summary.isEmpty {
                Text(item.summary)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            // 「恢复会顺手修音频头」这件事在**点之前**就说。放在最下面一行
            // 是因为它只在部分条目上出现，摆中间会把其他行的对齐撑乱
            if let note = item.headerRepairNote {
                HStack(spacing: Theme.Spacing.xs) {
                    StatusMark(kind: .warning, text: "音频头")
                    Text(note)
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 丢弃只在悬停时浮出，理由同 `RecordingRow` 的删除入口：
            // 常驻会把「未完成」这一组变成一屏控件。丢弃**永不自动发生**，
            // 一律走确认框（见 `pendingDiscard`）
            if isHovering {
                Button(action: onDiscard) {
                    Text("丢弃这份转录")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.error)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 「未完成」也是列表里的一行，和正式录音同一个卡片语言。
        // **层级是 2**（P13-2 附 3）：整页正式录音都是 elevation 1，同屏
        // 再开一档才分得出主次——这一组要用户做决定，是唯一该被「抬起来」
        // 的那类条目；两档是上限，别再往下加
        .cardStyle(elevation: 2, isHighlighted: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
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
