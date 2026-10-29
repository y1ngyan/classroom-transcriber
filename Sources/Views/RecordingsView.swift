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
                    LazyVStack(alignment: .leading,
                               spacing: Theme.RecordingLayout.groupSpacing) {
                        // 「未完成」排在最前：它是**要用户做决定**的一组，
                        // 压在一屏历史录音底下等于没提。做完决定这一组就消失
                        if !store.recoveryItems.isEmpty {
                            recoverySection
                        }
                        ForEach(courseGroups, id: \.0) { group in
                            courseGroup(name: group.0, sessions: group.1)
                        }
                    }
                    .padding(.horizontal, Theme.RecordingLayout.pagePadding)
                    .padding(.top, Theme.RecordingLayout.toolbarToGroup)
                    .padding(.bottom, Theme.RecordingLayout.listBottom)
                }
            }
        }
    }

    /// 页头：标题 + 右侧工具栏（P14-1）。
    ///
    /// 标题下那条分割线删掉了：工具栏已经给出「这一屏有操作」的分界，
    /// 再加一条线就是两层分界叠在一起。数量副标题也一并收走——
    /// 每个分组标题都带着计数，页头再报一遍总数是重复信息
    private var header: some View {
        HStack(alignment: .center, spacing: Theme.RecordingLayout.titleToToolbar) {
            Text("录音")
                .textStyle(Theme.Text.largeTitle)
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            toolbar
        }
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.top, Theme.Spacing.lg)
    }

    /// 顶部工具栏：搜索 / 筛选 / 新建。
    ///
    /// **搜索和筛选这一包只做了视觉**，没接任何逻辑（派单要求不改功能逻辑）。
    /// 它们在 `help` 里照实说「尚未接入」，不做成点了没反应的假按钮观感
    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ToolbarIconButton(symbol: "magnifyingglass", help: "搜索（尚未接入）") {}
            ToolbarIconButton(symbol: "line.3.horizontal.decrease", help: "筛选（尚未接入）") {}

            Button {
                // 新建录音 = 去转录页录制。沿用空状态那个入口，不新造逻辑
                appState.selectedTab = .transcription
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: Theme.RecordingLayout.playIcon, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.RecordingLayout.newButton,
                           height: Theme.RecordingLayout.newButton)
                    .background(Circle().fill(Theme.accent))
                    // 44 的热区套在 28 的圆外面，视觉小、可点范围大
                    .frame(width: Theme.RecordingLayout.iconButton,
                           height: Theme.RecordingLayout.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressOpacityButtonStyle())
            .help("新建录音（去转录页）")
        }
        .frame(height: Theme.RecordingLayout.toolbarHeight)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "waveform")
                .font(.system(size: 22))
                .foregroundStyle(Theme.textSupporting)

            // 页头不再有副标题，这里就是空状态唯一的那句话
            Text("在转录页点「开始录制」，录完的内容会自动出现在这里。")
                .textStyle(Theme.Text.summary)
                .foregroundStyle(Theme.textSupporting)
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
        VStack(alignment: .leading, spacing: Theme.RecordingLayout.groupTitleToCard) {
            // 课程名是这一屏的第二级标题（页面标题是 32）：17/600 + 主色。
            // 计数靠右且低一档（13 + supporting）——挨在名字后面会被读成上标
            HStack(spacing: Theme.Spacing.s6) {
                Text(name)
                    .textStyle(Theme.Text.bodyEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(sessions.count) 条")
                    .textStyle(Theme.Text.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSupporting)
            }

            // 日期和卡片**不再缩进**（P14-2）：分组标题、日期、卡片共用
            // 页面边距那一条左基线；两级归属只靠字号和颜色区分
            VStack(alignment: .leading, spacing: Theme.RecordingLayout.groupSpacing) {
                ForEach(daysWithin(sessions), id: \.0) { day in
                    dayGroup(title: day.0, items: day.1)
                }
            }
        }
    }

    private func dayGroup(title: String, items: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: Theme.RecordingLayout.groupTitleToCard) {
            // 日期是定位刻度，不是内容：13/500 + supporting，比课程名低一级
            Text(title)
                .textStyle(Theme.Text.meta)
                .fontWeight(.medium)
                .foregroundStyle(Theme.textSupporting)

            VStack(alignment: .leading, spacing: Theme.RecordingLayout.cardSpacing) {
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
            HStack(spacing: Theme.RecordingLayout.cardContentSpacing) {
                // 播放键是**装饰**，不是第二个按钮：整张卡已经是按钮，
                // 里面再套一个按钮会变成嵌套命中区，点中间那圈行为不确定。
                // 点它走的是同一个 `onOpen`，和点卡片其它地方没有区别。
                // P14-2：图标 15→13、底 8%→6%，让「能点进去」比「能播放」显眼
                Image(systemName: "play.fill")
                    .font(.system(size: Theme.RecordingLayout.playIcon))
                    .foregroundStyle(Theme.accent)
                    .frame(width: Theme.RecordingLayout.playButton,
                           height: Theme.RecordingLayout.playButton)
                    .background(Circle().fill(Theme.accent.opacity(0.06)))

                VStack(alignment: .leading, spacing: Theme.RecordingLayout.cardTextSpacing) {
                    // 标题行。角标钉在右上角（第一行基线），不跟元数据挤一行
                    HStack(alignment: .top, spacing: Theme.RecordingLayout.cardTextSpacing) {
                        // 显示名：用户起过就用它，没起过回落成时间。
                        // 标题**永远**是课程/讲次，日期时间在元信息行里
                        Text(summary.displayTitle)
                            .textStyle(Theme.Text.bodyEmphasized)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: Theme.RecordingLayout.cardTextSpacing)

                        // 右侧只放一件事：悬停时是删除，平时是质量角标。
                        // 删除常驻的话每行都挂一个按钮，一屏几十条全是控件
                        if isHovering {
                            Button(action: onDelete) {
                                Text("删除")
                                    .textStyle(Theme.Text.meta)
                                    .foregroundStyle(Theme.error)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        } else {
                            qualityBadge
                        }
                    }

                    if !summary.firstText.isEmpty {
                        Text(summary.firstText)
                            .textStyle(Theme.Text.summary)
                            .foregroundStyle(Theme.textSupporting)
                            .lineLimit(1)
                    }

                    // 读数行，只在实际有内容的项上出现——「0 个提问」这种
                    // 占位读数没有任何信息量，只会把列表撑高。
                    // P14-2：各项用 ` · ` 连起来，否则四个读数会糊成一串
                    HStack(spacing: 0) {
                        Text(metadataText)
                            .textStyle(Theme.Text.meta)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSupporting)
                            .lineLimit(1)
                    }
                }

                // 「这行能点」的暗示。P14-2：13→14pt 且提到 textSecondary，
                // 三级色压在黑底上几乎看不见，而它正是这一行最重要的提示
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.RecordingLayout.chevronSize, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 卡片外观必须套在**按钮的 label 里**，不能套在按钮外面：
            // `cardStyle` 自带内边距，套在外面时那圈内边距落在按钮
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

    /// 元信息一行：`09:00 · 1:36:00 · 4 段转录 · 1 个提问`（P14-2）。
    /// 时间固定第一项（标题不再兼任日期）；没有标题的旧数据里标题本身
    /// 就是日期时间，这里不再重复一遍。空项不占位——「0 个提问」没有信息量
    private var metadataText: String {
        var items: [String] = []
        if !summary.title.isEmpty { items.append(summary.formattedTime) }
        items.append(summary.formattedDuration)
        if summary.partCount > 1 { items.append("\(summary.partCount) 段录音") }
        items.append("\(summary.segmentCount) 段转录")
        if summary.questionCount > 0 { items.append("\(summary.questionCount) 个提问") }
        return items.joined(separator: " · ")
    }

    /// 右上角状态角标（P14-2）：胶囊 + 状态色 12% 底 + 11/600 角标色文字。
    /// 文案由 `RecordingBadge` 统一生成（形状、顺序、超长处理都在那边），
    /// 这里只按最严重的状态选颜色——有不可信就不该用存疑的橙色报
    private var qualityBadge: QualityBadge {
        let poor = summary.poorCount
        let fair = summary.fairCount
        let verified = max(0, summary.segmentCount - poor - fair)
        let color = poor > 0 ? Theme.errorBadge
            : (fair > 0 ? Theme.warningBadge : Theme.successBadge)
        return QualityBadge(
            text: RecordingBadge.text(verified: verified, fair: fair, poor: poor),
            color: color
        )
    }
}

/// 状态角标。底色用状态色 12% 透明——不是不透明色块：
/// 它是注释，不是警告牌，面积大了会盖过标题。
/// 文案本身由 `RecordingBadge.text` 收口；这里只保证**不换行**
private struct QualityBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.Text.footnote.font.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Theme.RecordingLayout.badgePaddingH)
            .padding(.vertical, Theme.RecordingLayout.badgePaddingV)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// 工具栏图标按钮：44×44 热区、次级色、按下 0.9（P14-1）。
private struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Text.summary.font)
                .frame(width: Theme.RecordingLayout.iconButton,
                       height: Theme.RecordingLayout.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressOpacityButtonStyle())
        .help(help)
    }
}

/// 图标按钮的按下态。只改透明度，不缩放——列表头部的图标缩一下
/// 会比旁边的文字先动，看起来像点歪了
private struct PressOpacityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.textSecondary)
            .opacity(configuration.isPressed ? 0.9 : 1)
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
