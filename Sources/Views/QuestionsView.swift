import SwiftUI
import AppKit

/// 「提问查答案」页（B 包 §3）。
///
/// 这是一个**独立页面**（拍板第 2 条 A）：标签栏里有它，录音详情和转录页的
/// 入口也跳到它，但三处到的是同一个视图、同一个 `QuestionAnswerStore`。
///
/// 布局按 §3.2 自上而下：标题 + 汇总 → 唯一的 PillButton「查询全部待查」→
/// 过滤分布说明 → 问题列表（`LazyVStack` + `Separator`，**不用卡片**）→
/// 折叠区 → 空状态。这一屏刻意和录音列表那套卡片设计分家：一行问题是一条
/// 读数，不是一张「条目」，套卡片会把列表读成一堆盒子。
struct QuestionsView: View {
    @Environment(AppState.self) private var appState

    /// 元问题折叠区是否展开（拍板第 7 条：默认收起，收起的只是原句，没有查询入口）
    @State private var isShowingFiltered = false
    /// 重查的二次确认对象（拍板第 4 条）。非 nil 时弹确认框
    @State private var pendingOverwrite: LessonQuestion?

    private var store: QuestionAnswerStore { appState.questions }
    private var sensitivity: QuestionSensitivity { appState.settings.questionSensitivity }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear {
            // 第一次进这一页（从标签栏点进来）自己挑一个范围：录制中就跟着
            // 这一次录制，否则挑最近一条有提问的录音。从转录页 / 详情页
            // 进来的走的是 `openQuestions`，已经打开过，不能顶掉用户的选择
            if !store.hasOpened {
                autoOpen()
            } else if store.isLive {
                // 切走再回来：实时段落在别处还在增长，先把新段并进来
                store.refreshLive(scope: .live, sensitivity: sensitivity)
            }
        }
        // 实时转录期间新定稿的段落可能带新提问。只刷新列表，不写盘、不联网
        .onChange(of: appState.transcription.segments.count) {
            guard store.isLive else { return }
            store.refreshLive(scope: .live, sensitivity: sensitivity)
        }
        // 录完 / 开始录：`.live` 的落点会变（内存候选 ↔ 占位会话），整体重开
        .onChange(of: appState.transcription.isRunning) {
            guard store.isLive else { return }
            store.open(scope: .live, sensitivity: sensitivity)
        }
        .confirmationDialog(
            "重新查询这条？",
            isPresented: Binding(
                get: { pendingOverwrite != nil },
                set: { if !$0 { pendingOverwrite = nil } }
            ),
            presenting: pendingOverwrite
        ) { question in
            Button("替换旧答案", role: .destructive) {
                let id = question.id
                pendingOverwrite = nil
                Task { await store.query(questionID: id, confirmedOverwrite: true) }
            }
            Button("取消", role: .cancel) { pendingOverwrite = nil }
        } message: { _ in
            // 文案里必须原样出现「旧的答案和来源会被替换」（拍板第 4 条）
            Text(QuestionFlow.overwriteConfirmation)
        }
    }

    // MARK: - 打开范围

    private func autoOpen() {
        if appState.transcription.isRunning {
            appState.openQuestions(scope: .live)
            return
        }
        let summaries = appState.recordings.summaries
        let withQuestions = summaries.filter { $0.questionCount > 0 }
        if let latest = withQuestions.max(by: { $0.startedAt < $1.startedAt })
            ?? summaries.max(by: { $0.startedAt < $1.startedAt }) {
            appState.openQuestions(scope: .session(latest.id))
        } else {
            // 库里一条录音都没有：停在 `.live` 的空状态，不硬造会话
            store.open(scope: .live, sensitivity: sensitivity)
        }
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Text("提问查答案")
                    .textStyle(Theme.Text.largeTitle)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: Theme.Spacing.md)

                sessionMenu
            }

            Text(summaryLine)
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)

            if let session = store.currentSession {
                Text("\(session.displayTitle) · \(Self.dateText(session.startedAt))")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
            } else if store.isLive {
                Text("本次录制（实时）")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
            }

            // 缺密钥时列表照常显示（拍板第 9 条）：问题识别是纯本地的，
            // 不该被联网配置绑住。只把查询入口禁用
            if !store.isConfigured {
                configWarning
            }

            actionRow
                .padding(.top, Theme.Spacing.xs)

            if !store.filteredQuestions.isEmpty {
                distributionRow
            }
        }
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .overlay(alignment: .bottom) { Separator() }
    }

    private var summaryLine: String {
        "\(store.mainQuestions.count) 个问题 · \(store.queriedCount) 个已查 · \(store.pendingCount) 个待查"
    }

    /// 配置警告：形态复用 `FactCheckView.configWarning`（图标 + 颜色 + 2pt 竖条），
    /// 不用底色块——设计规范里状态就是「小图标 + 颜色」
    private var configWarning: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            StatusMark(kind: .warning, text: "未配置搜索或 DeepSeek 密钥，查询不可用（问题列表照常显示）")
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

    /// 页首唯一的 `PillButton`（一行只放一个）。其余操作都是文字链接
    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            PillButton(
                title: batchTitle,
                isLoading: store.batchProgress != nil,
                isEnabled: store.pendingCount > 0 && store.isConfigured,
                disabledStyle: .neutral
            ) {
                Task { await store.queryAllPending() }
            }

            if let message = store.message {
                Text(message)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var batchTitle: String {
        if let progress = store.batchProgress {
            return "已完成 \(progress.done) / \(progress.total)"
        }
        return "查询全部待查"
    }

    /// 过滤分布说明行（§3.2 第 3 条）。只在有元问题时出现；
    /// 「查看」是文字链接——它不能跟页首那个 PillButton 抢位
    private var distributionRow: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("另有 \(store.filteredQuestions.count) 条课堂管理用语已过滤，不参与查询")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isShowingFiltered.toggle()
                }
            } label: {
                Text(isShowingFiltered ? "收起" : "查看")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    /// 多节有提问的录音时给一个切换入口。只有一条时是纯噪声，不画
    private var sessionMenu: some View {
        let withQuestions = appState.recordings.summaries.filter { $0.questionCount > 0 }
        return Group {
            if appState.transcription.isRunning || withQuestions.count > 1 {
                Menu {
                    if appState.transcription.isRunning {
                        Button("本次录制（实时）") {
                            appState.openQuestions(scope: .live)
                        }
                    }
                    ForEach(withQuestions.prefix(20)) { summary in
                        Button("\(summary.displayTitle) · \(Self.dateText(summary.startedAt))") {
                            appState.openQuestions(scope: .session(summary.id))
                        }
                    }
                } label: {
                    Text("切换录音")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.accent)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - 列表

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.mainQuestions.isEmpty && store.filteredQuestions.isEmpty {
                    emptyState
                }

                ForEach(Array(store.mainQuestions.enumerated()), id: \.element.id) { index, question in
                    QuestionRow(
                        question: question,
                        phase: store.phases[question.id],
                        isConfigured: store.isConfigured,
                        onAction: { requestQuery(question) }
                    )
                    if index < store.mainQuestions.count - 1 {
                        Separator()
                    }
                }

                if isShowingFiltered, !store.filteredQuestions.isEmpty {
                    if !store.mainQuestions.isEmpty { Separator() }
                    filteredSection
                }
            }
            .padding(.horizontal, Theme.RecordingLayout.pagePadding)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(store.isLive
                ? "这节课还没有识别到提问。识别在每段定稿时完成。"
                : "这节课还没有识别到提问。识别在本节课定稿时完成。")
                .textStyle(Theme.Text.body)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    /// 折叠区：只有原句和「不参与查询」说明，**没有查答案入口**（拍板第 7 条）
    private var filteredSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已过滤的课堂管理用语")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, Theme.Spacing.md)

            ForEach(Array(store.filteredQuestions.enumerated()), id: \.element.id) { index, question in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text(Self.timestamp(question.startTimeMillis))
                            .textStyle(Theme.Text.mono)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textTertiary)
                        Text(question.rawSentence)
                            .textStyle(Theme.Text.summary)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                    Text("自动识别为课堂管理用语，未参与查询")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.vertical, Theme.Spacing.md)

                if index < store.filteredQuestions.count - 1 {
                    Separator()
                }
            }
        }
    }

    // MARK: - 动作

    /// 有答案的条目先弹确认（不可逆的覆盖），其余直接查
    private func requestQuery(_ question: LessonQuestion) {
        if store.requiresConfirmation(questionID: question.id) {
            pendingOverwrite = question
        } else {
            Task { await store.query(questionID: question.id) }
        }
    }

    // MARK: - 格式化

    static func timestamp(_ millis: Int) -> String {
        let total = max(0, millis) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 单个问题行

/// 一行问题（§3.3）。五种状态共用这一套骨架，差异只在状态标记、
/// 行内动作和展开出来的区块：
/// 未查 → 查答案；查询中 → 转圈 + 阶段文案；有答案 → 就地展开；
/// 查不到 / 失败 → 说明 + 重试。
private struct QuestionRow: View {
    let question: LessonQuestion
    let phase: String?
    let isConfigured: Bool
    let onAction: () -> Void

    @State private var isHovering = false
    /// 答案区块是否展开。**默认收起**（§2.1 第 5 步：学生扫的是「老师问过
    /// 什么」，一进页面就把旧答案全摊开会把列表撑成几屏）；刚查完的那一行
    /// 由 `onChange(of: status)` 自动展开（§2.1 第 9 步：成功时就地展开）
    @State private var showsAnswer = false
    /// 展开后正文是否再放开到全文（拍板第 8 条：默认前若干行，不硬截断）
    @State private var isAnswerExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(QuestionsView.timestamp(question.startTimeMillis))
                    .textStyle(Theme.Text.mono)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)

                if question.level == 1 {
                    // 点名 / 祈使预警：检测器拿不准，交给学生判断，
                    // **不**直接送进元问题表（§3.3）
                    Text("点名")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.warning)
                }

                if question.askedCount > 1 {
                    Text("本课重复 \(question.askedCount) 次")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: Theme.Spacing.md)

                statusBadge
            }

            Text(question.text)
                .textStyle(Theme.Text.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // 原句与本体不同时才有对照价值（检测器剥口头禅可能剥错）
            if question.rawSentence != question.text {
                Text(question.rawSentence)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            actionRow
                .padding(.top, Theme.Spacing.xxs)

            if question.status == .answered, showsAnswer, let answer = question.answer {
                answerBlock(answer)
            }
            if question.status == .noResults {
                noResultsBlock
            }
            if question.status == .failed {
                failedBlock
            }
        }
        .padding(.vertical, Theme.Spacing.md)
        // 悬停反馈是左侧 2pt 竖条，放 overlay，不占布局（§3.3）
        .overlay(alignment: .leading) {
            if isHovering {
                Rectangle()
                    .fill(Theme.accent.opacity(0.45))
                    .frame(width: 2)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        // 刚查成功的这一行就地展开；从盘里读到的旧答案保持收起
        .onChange(of: question.status) { _, newStatus in
            if newStatus == .answered { showsAnswer = true }
        }
    }

    // MARK: 状态

    @ViewBuilder
    private var statusBadge: some View {
        switch question.status {
        case .unasked:
            StatusMark(kind: .neutral, text: "未查")
        case .searching:
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(phase ?? QuestionAnswerPhase.searching.text)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .answered:
            StatusMark(kind: .ok, text: "有答案")
        case .noResults:
            StatusMark(kind: .neutral, text: "查不到")
        case .failed:
            StatusMark(kind: .error, text: "失败")
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch question.status {
        case .unasked:
            actionLink("查答案")
        case .failed, .noResults:
            actionLink("重试")
        case .answered:
            // 展开/收起答案不是查询动作，密钥缺失时也该能点——它只读本地
            HStack(spacing: Theme.Spacing.lg) {
                actionLink("重新查询")
                Button {
                    showsAnswer.toggle()
                } label: {
                    Text(showsAnswer ? "收起答案" : "展开答案")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        case .searching:
            EmptyView()
        }
    }

    private func actionLink(_ title: String) -> some View {
        Button(action: onAction) {
            Text(title)
                .textStyle(Theme.Text.caption)
                .foregroundStyle(isConfigured ? Theme.accent : Theme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isConfigured)
        .help(isConfigured ? "" : "未配置搜索或 DeepSeek 密钥")
    }

    // MARK: 答案区块

    /// 答案区块。第一行是**不可关闭的 AI 标注**（§8.3）：它永远排在正文之上，
    /// 不能折叠、不能被后续内容顶掉
    private func answerBlock(_ answer: QuestionAnswer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            StatusMark(
                kind: .neutral,
                text: answer.notice.isEmpty ? QuestionAnswer.aiNotice : answer.notice
            )

            if !answer.markdown.isEmpty {
                MarkdownWebView(markdown: isAnswerExpanded
                    ? answer.markdown
                    : Self.preview(of: answer.markdown))
                    .frame(height: isAnswerExpanded ? 320 : 110)
                    .clipped()

                if Self.isTruncated(answer.markdown) {
                    Button {
                        isAnswerExpanded.toggle()
                    } label: {
                        Text(isAnswerExpanded ? "收起" : "展开全部")
                            .textStyle(Theme.Text.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !answer.sources.isEmpty {
                sourcesBlock(answer.sources)
            }

            Text("由 \(answer.model.isEmpty ? "未知模型" : answer.model) 于 \(Self.generatedAt(answer.createdAt)) 联网生成")
                .textStyle(Theme.Text.meta)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, Theme.Spacing.sm)
    }

    /// 有资料、没答案：只列来源，**不显示模型编的正文**（§2.3）
    private var noResultsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            StatusMark(
                kind: .neutral,
                text: QuestionFlow.noResultsMessage(
                    hasSources: !(question.answer?.sources.isEmpty ?? true)
                )
            )
            if let sources = question.answer?.sources, !sources.isEmpty {
                sourcesBlock(sources)
            }
        }
        .padding(.top, Theme.Spacing.xxs)
    }

    /// 失败：通道不通用红，模型这一步失败用橙——两种失败学生该做的事不同
    private var failedBlock: some View {
        StatusMark(
            kind: question.failure == .channel ? .error : .warning,
            text: QuestionFlow.failureMessage(question.failure, note: question.failureNote)
        )
        .padding(.top, Theme.Spacing.xxs)
    }

    /// 来源列表。标题与 URL 都是代码从真实 `SearchHit` 拷来的（拍板第 5 条），
    /// 这里只负责显示和打开
    private func sourcesBlock(_ sources: [AnswerSource]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("依据的来源")
                .textStyle(Theme.Text.meta)
                .foregroundStyle(Theme.textSecondary)

            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                Button {
                    if let url = URL(string: source.url) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("\(index + 1). \(source.title) · \(Self.domain(of: source.url))")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(source.url)
            }
        }
    }

    // MARK: 文本处理

    /// 默认显示前若干行（拍板第 8 条：不硬截断，完整内容留在数据里）
    static func preview(of markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(6).joined(separator: "\n")
    }

    static func isTruncated(_ markdown: String) -> Bool {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).count > 6
    }

    static func domain(of url: String) -> String {
        URL(string: url)?.host ?? url
    }

    static func generatedAt(_ date: Date) -> String {
        // 1970 = 老存档缺生成时间。**不把它显示成「刚刚」**（同
        // `QuestionAnswer.init(from:)` 的取舍），就说不知道
        guard date.timeIntervalSince1970 > 0 else { return "时间未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
