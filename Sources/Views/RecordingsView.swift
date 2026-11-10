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
    /// 清理「只有提问、没有录音」的占位会话（B 包拍板第 1 条）
    @State private var isConfirmingQuestionCleanup = false

    /// 跨录音检索：查询词与结果。
    ///
    /// 索引**懒建**：没人搜就不扫全库。55 节课第一次建约几十毫秒（实测见自检），
    /// 之后每次按键只查倒排表。录音增删后按 `indexedCount` 重建
    @State private var query = ""
    @State private var searchIndex: TranscriptSearch.Index?
    @State private var indexedCount = -1
    @State private var hits: [TranscriptSearch.Hit] = []
    @State private var indexBuildMillis: Double = 0

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
        // 删除占位会话。这些会话只有问题与答案、没有音频；删除后答案不可恢复，
        // 所以走和删录音同一套「先确认再删」的规矩
        .confirmationDialog(
            "删除 \(store.questionOnlySummaries.count) 条无录音的提问记录？",
            isPresented: $isConfirmingQuestionCleanup,
            titleVisibility: .visible
        ) {
            Button("删除提问记录", role: .destructive) {
                store.deleteQuestionOnlySessions()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些记录只有问题和查到的答案，没有音频。删除后不可恢复；"
                 + "真录到的课不受影响。")
        }
    }

    // MARK: - 跨录音检索

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchBar: some View {
        HStack(spacing: Theme.Spacing.s10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            // 占位文字自己画：SwiftUI 的 TextField 占位符用系统灰，压在 #1C1C1E 上
            // 几乎看不见（截图里被判为「像一条静态标签」）。自己画能指定对比度
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("在所有课里找一句话（例如：梯度下降）")
                        .textStyle(Theme.Text.body)
                        .foregroundStyle(Theme.textTertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .textStyle(Theme.Text.body)
                    .onSubmit { runSearch() }
                    .onChange(of: query) { _, _ in runSearch() }
            }
            if isSearching {
                Button {
                    query = ""
                    hits = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, Theme.Spacing.s10)
        .padding(.vertical, Theme.Spacing.s6)
        .background(Theme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous)
                .strokeBorder(Theme.Surface.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.top, Theme.Spacing.s20)
        .padding(.bottom, Theme.Spacing.s6)
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.s6) {
                    Text("\(hits.count) 处命中 · \(TranscriptSearch.sections(hits).count) 节课")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.textSecondary)
                    if indexBuildMillis > 0 {
                        Text(String(format: "· 建索引 %.0f ms", indexBuildMillis))
                            .textStyle(Theme.Text.meta)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }

                if hits.isEmpty {
                    Text("没有找到。换个说法试试——检索按两字一组匹配，长句比单词更容易命中。")
                        .textStyle(Theme.Text.body)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, Theme.Spacing.s20)
                } else {
                    ForEach(TranscriptSearch.sections(hits), id: \.sessionID) { section in
                        VStack(alignment: .leading, spacing: Theme.Spacing.s6) {
                            Button {
                                openSessionID = section.sessionID
                            } label: {
                                HStack(spacing: Theme.Spacing.s6) {
                                    Text(section.course.isEmpty ? "未分类" : section.course)
                                        .textStyle(Theme.Text.meta)
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(section.title)
                                        .textStyle(Theme.Text.bodyEmphasized)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(dateText(section.startedAt))
                                        .textStyle(Theme.Text.meta)
                                        .foregroundStyle(Theme.textTertiary)
                                    Spacer()
                                    Text("\(section.hits.count) 处")
                                        .textStyle(Theme.Text.meta)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("打开这节课")

                            ForEach(Array(section.hits.prefix(6).enumerated()), id: \.offset) { _, hit in
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s10) {
                                    Text(stamp(hit.startMillis))
                                        .textStyle(Theme.Text.meta)
                                        .foregroundStyle(Theme.textTertiary)
                                        .monospacedDigit()
                                    Text(highlighted(hit))
                                        .textStyle(Theme.Text.body)
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(2)
                                    Spacer()
                                }
                            }
                            if section.hits.count > 6 {
                                Text("另有 \(section.hits.count - 6) 处，打开这节课看全部")
                                    .textStyle(Theme.Text.meta)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(Theme.Spacing.md)
                        .cardStyle(elevation: 1)
                    }
                }
            }
            .padding(.horizontal, Theme.RecordingLayout.pagePadding)
            .padding(.top, Theme.Spacing.s20)
            .padding(.bottom, Theme.RecordingLayout.listBottom)
        }
    }

    /// 命中词加粗。用原句的 String 找位置再换算到 AttributedString 的下标——
    /// AttributedString 自己的 range(of:) 在深色主题里会被系统默认样式盖住颜色
    private func highlighted(_ hit: TranscriptSearch.Hit) -> AttributedString {
        var result = AttributedString(hit.snippet)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let range = hit.snippet.range(of: needle, options: [.caseInsensitive, .widthInsensitive])
        else { return result }
        let lower = hit.snippet.distance(from: hit.snippet.startIndex, to: range.lowerBound)
        let length = hit.snippet.distance(from: range.lowerBound, to: range.upperBound)
        guard let start = result.characters.index(result.startIndex, offsetBy: lower, limitedBy: result.endIndex),
              let end = result.characters.index(start, offsetBy: length, limitedBy: result.endIndex)
        else { return result }
        result[start..<end].inlinePresentationIntent = .stronglyEmphasized
        return result
    }

    private func stamp(_ millis: Int) -> String {
        let total = max(0, millis) / 1000
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    /// 检索：索引懒建；录音条数变了就重建（增删录音后不用重启也能搜到）
    private func runSearch() {
        guard isSearching else { hits = []; return }
        if searchIndex == nil || indexedCount != store.summaries.count {
            let started = Date()
            let docs: [TranscriptSearch.Doc] = store.summaries.compactMap { summary in
                guard let session = store.session(id: summary.id) else { return nil }
                var segments: [TranscriptSearch.Segment] = []
                for part in session.parts {
                    for segment in part.segments where segment.isFinal {
                        segments.append(.init(startMillis: part.offsetMillis + segment.startTimeMillis,
                                              text: segment.text))
                    }
                }
                return TranscriptSearch.Doc(sessionID: session.id,
                                            title: session.title.isEmpty ? "未命名" : session.title,
                                            course: session.course,
                                            startedAt: session.startedAt,
                                            segments: segments)
            }
            searchIndex = TranscriptSearch.build(docs)
            indexedCount = store.summaries.count
            indexBuildMillis = Date().timeIntervalSince(started) * 1000
        }
        guard let index = searchIndex else { return }
        hits = TranscriptSearch.search(query, in: index, limit: 60)
    }

    // MARK: - 列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar

            if isSearching {
                searchResults
            } else if !store.questionOnlySummaries.isEmpty {
                questionOnlyCleanup
            }

            if !isSearching && store.summaries.isEmpty && store.recoveryItems.isEmpty {
                emptyState
            } else if !isSearching {
                // 本周概览（P15-2）。放在标题与第一个分组之间，用留白 +
                // 分隔线和列表分开。它是**读数**，不是一条录音，所以不套卡片。
                // 没有数据时整条不渲染（见 `overviewStats`）
                if let stats = overviewStats {
                    RecordingsOverview(stats: stats)
                        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
                        .padding(.top, Theme.Spacing.s20)

                    Separator()
                        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
                        .padding(.top, Theme.Spacing.s20)
                }

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

    /// 概览读数。生产路径只对内存里的 summaries 求和（不扫盘）；
    /// 快照路径用固定值，理由见 `RecordingStats.snapshotFixture`。
    /// 复用 `WaveformEnvelope.isSnapshotMode` 是因为两者判的都是同一个
    /// `--ui-snapshot` 进程标志，不该再各写一份参数解析
    private var overviewStats: RecordingStats? {
        WaveformEnvelope.isSnapshotMode
            ? .snapshotFixture
            : RecordingStats.make(from: store.summaries)
    }

    /// 清理入口（B 包拍板第 1 条）：实时期间查过答案、但最后没录成音频的
    /// 占位会话会留在库里。它是可回收的垃圾数据，但**不能自动删**——
    /// 里面可能有学生查过的答案，删不删由他决定
    private var questionOnlyCleanup: some View {
        HStack(spacing: Theme.Spacing.sm) {
            StatusMark(
                kind: .neutral,
                text: "有 \(store.questionOnlySummaries.count) 条只有提问、没有录音的记录"
            )
            Spacer(minLength: Theme.Spacing.md)
            Button {
                isConfirmingQuestionCleanup = true
            } label: {
                Text("删除")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.top, Theme.Spacing.s12)
    }

    private var emptyState: some View {        VStack(spacing: Theme.Spacing.md) {
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
                        resolveAudioURL: { store.audioURL(for: item) },
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
    /// 只在 `.task` 里调用，不在 body 里调用：body 每次重绘（悬停、角标变化）
    /// 都会跑，在那里解析音频路径等于给每帧加一次磁盘/解码开销。
    /// 旧 index 的摘要没有文件名，解析会回落成解码正文——更不该在 body 里做
    let resolveAudioURL: () -> URL?
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    /// 包络算完之前是空数组，缩略图渲成一条 40% 灰直条（派的规格）。
    /// 空数组也覆盖「这条录音没有 wav」：占位直条不该假装有波形
    @State private var envelope: [Float] = []

    /// 快照模式下直接用固定数组（理由见 `WaveformEnvelope.snapshotFixture`）。
    /// 判断放在渲染路径上而不是 `.task` 里：离屏 `NSHostingView` 不会跑
    /// 异步任务，等 `.task` 的话快照永远只拍到占位直条
    private var displayedEnvelope: [Float] {
        WaveformEnvelope.isSnapshotMode
            ? WaveformEnvelope.snapshotFixture(seed: summary.id)
            : envelope
    }

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

                // 真实波形缩略图（P15-1）。读包络要打开 wav、扫全段，
                // 放在主线程会让列表滚动卡顿——`.task` 里丢给 detached 任务，
                // 回来时若这一行已被复用/移除就丢弃结果
                WaveformThumbnail(values: displayedEnvelope)
                    .task(id: summary.id) {
                        guard !WaveformEnvelope.isSnapshotMode else { return }
                        guard let url = resolveAudioURL() else { return }
                        let values = await Task.detached(priority: .utility) {
                            WaveformEnvelope.compute(url: url)
                        }.value
                        guard !Task.isCancelled else { return }
                        envelope = values
                    }

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
                            qualityBadges
                        }
                    }

                    if !summary.firstText.isEmpty {
                        Text(summary.firstText)
                            .textStyle(Theme.Text.summary)
                            .foregroundStyle(Theme.textSupporting)
                            .lineLimit(1)
                    }

                    // 读数行（P15-1）：时长**排第一且更重**，其余读数低一档。
                    // 以前所有读数同一个字号，一眼扫过去分不出「这条多长」和
                    // 「转了多少段」哪个是主信息。两段文字共用 firstTextBaseline
                    // 对齐——17pt 和 13pt 按顶/底对齐都会让数字看着悬空
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(summary.formattedDuration)
                            .textStyle(Theme.Text.bodyEmphasized)
                            .monospacedDigit()
                            // 主色，不是 supporting：17pt 配三级灰在同一行里
                            // 压不住 13pt 的读数，反而像一行褪色的备注
                            .foregroundStyle(Theme.textPrimary)

                        if !metadataTrailingText.isEmpty {
                            Text(" · " + metadataTrailingText)
                                .textStyle(Theme.Text.meta)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSupporting)
                        }
                    }
                    .lineLimit(1)
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

    /// 时长之后那段读数：`4 段转录 · 1 个提问`。
    ///
    /// 时长不再放在这里——它要单独的字号和字重，单独渲染。
    /// 起始时刻也去掉了（P15-1）：分组标题和日期已经给出「哪天」，
    /// 而派单定的这一行是**时长在前**的读数行；两处都报时刻会把这个
    /// 最重要的数字挤到第三位。空项不占位——「0 个提问」没有信息量
    private var metadataTrailingText: String {
        var items: [String] = []
        if summary.partCount > 1 { items.append("\(summary.partCount) 段录音") }
        items.append("\(summary.segmentCount) 段转录")
        if summary.questionCount > 0 { items.append("\(summary.questionCount) 个提问") }
        return items.joined(separator: " · ")
    }

    /// 右上角状态角标（P14-3）：一种状态一个胶囊，各用各的颜色。
    /// 顺序、个数、超长合并都在 `RecordingBadge` 里定；这里只负责上色。
    /// **红胶囊里只放异常**——把「已核实」和「不可信」装进同一个红底，
    /// 等于告诉用户已核实也算异常（P14-2 的原文如此，评审点掉了）
    private var qualityBadges: some View {
        let poor = summary.poorCount
        let fair = summary.fairCount
        let verified = max(0, summary.segmentCount - poor - fair)
        return HStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(RecordingBadge.items(verified: verified, fair: fair, poor: poor)
                .enumerated()), id: \.offset) { _, item in
                switch item.kind {
                case .verified:
                    QualityBadge(text: item.text,
                                 textColor: Theme.successBadge,
                                 fillColor: Theme.successBadge.opacity(0.12))
                case .fair:
                    QualityBadge(text: item.text,
                                 textColor: Theme.warningBadge,
                                 fillColor: Theme.warningBadge.opacity(0.12))
                case .poor:
                    QualityBadge(text: item.text,
                                 textColor: Theme.errorBadge,
                                 fillColor: Theme.errorBadge.opacity(0.12))
                case .overflow:
                    // 灰底：被合并掉的状态不在主叙述里，颜色让位给彩色胶囊
                    QualityBadge(text: item.text,
                                 textColor: Theme.textSupporting,
                                 fillColor: Theme.textSecondary.opacity(0.12))
                }
            }
        }
    }
}

/// 60×24 的波形缩略图（P15-1）。
///
/// 64 桶固定不变，不跟宽度走：它是缩略图，不是可缩放的图表；桶数一旦
/// 跟着布局变，「同一段录音在不同宽度下形状不同」就会变成很难解释的 bug。
/// 每桶一根 1pt 圆角竖线，高度 = 归一化峰值（最小 1pt，否则静音处
/// 会连成一条看不见的缝）。
///
/// 已播放/未播放：列表上没有播放进度（播放器在详情页），派单允许固定
/// 0，于是全部走未播放色。`playedFraction` 留着，等列表接上播放状态
/// 再传真实比例——不要让这个视图自己去猜
private struct WaveformThumbnail: View {
    let values: [Float]
    var playedFraction: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            // 没数据 = 占位：一条 40% 灰直条。不画随机波形——那会让
            // 「还在算」和「算出来是平的」看起来一样，也会让没有 wav 的
            // 旧会话假装有音频
            guard !values.isEmpty else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(Theme.textTertiary.opacity(0.4)),
                               lineWidth: 1)
                return
            }

            let step = size.width / CGFloat(values.count)
            let playedX = size.width * min(1, max(0, playedFraction))
            for (index, value) in values.enumerated() {
                let height = max(1, CGFloat(value) * size.height)
                let x = step * (CGFloat(index) + 0.5)
                let rect = CGRect(x: x - 0.5, y: (size.height - height) / 2,
                                  width: 1, height: height)
                let color = x <= playedX
                    ? Theme.accent.opacity(0.8)
                    : Theme.textTertiary.opacity(0.4)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.5),
                             with: .color(color))
            }
        }
        .frame(width: 60, height: 24)
        // 波形是装饰：读屏念不出任何有用信息，别让它抢走卡片标题的朗读
        .accessibilityHidden(true)
    }
}

/// 单个状态角标。底色用文字色 12% 透明——不是不透明色块：
/// 它是注释，不是警告牌，面积大了会盖过标题。文案由 `RecordingBadge`
/// 拆好；这里只保证**不换行**
private struct QualityBadge: View {
    let text: String
    let textColor: Color
    let fillColor: Color

    var body: some View {
        Text(text)
            .font(Theme.Text.footnote.font.weight(.semibold))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .padding(.horizontal, Theme.RecordingLayout.badgePaddingH)
            .padding(.vertical, Theme.RecordingLayout.badgePaddingV)
            .background(Capsule().fill(fillColor))
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
