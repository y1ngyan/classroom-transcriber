import Foundation
import Observation

/// 提问页的数据与查询编排（B 包设计稿 §2 / §5 / §6.5）。
///
/// 页面在两种范围里打开，**同一个 store、同一套转移规则**：
/// - `.live`：实时转录期间，问题来自内存里的 `transcription.segments`；
///   第一次查询时才建占位会话（拍板第 1 条），之后一切落盘；
/// - `.session(id)`：课后从录音详情 / 标签页进入某一条存档。
///
/// 状态机本身在 `QuestionFlow`（纯函数，可离线自检）；这里只负责把它接到
/// 磁盘、网络和正在转写的引擎上。所有判断都走 `QuestionFlow.gate` /
/// `QuestionFlow.decide`，**不在这里另写一份 if**——两份判断迟早漂移，
/// 而漂移的那天表现为「自检全绿、界面上那行却不转」。
@MainActor
@Observable
final class QuestionAnswerStore {

    enum Scope: Equatable {
        case live
        case session(UUID)
    }

    struct BatchProgress: Equatable {
        var done: Int
        var total: Int
    }

    private(set) var scope: Scope = .live
    /// 问题实际落在哪条会话上。`.live` 且还没建占位会话时为 nil——
    /// 那时列表里是内存候选（`ephemeral`），点第一次查询才落盘
    private(set) var sessionID: UUID?
    /// `open` 至少被调用过一次没有。页面用它决定「第一次进来要不要自己挑
    /// 一个范围」：从转录页 / 录音详情点进来时 `openQuestions` 已经先调了
    /// `open`，此时再自动挑一次会把用户刚指定的会话顶掉
    private(set) var hasOpened = false
    /// 当前展示的条目（主列表与折叠区都从这里分）。按时间排序
    private(set) var questions: [LessonQuestion] = []
    /// 每一行「查询中」的阶段文案
    private(set) var phases: [UUID: String] = [:]
    private(set) var batchProgress: BatchProgress?
    /// 页面上的一行反馈（配置缺失、批量完成）。**不是**行的失败文案——
    /// 那是条目自己的 `status` / `failure`，跟着会话落盘
    private(set) var message: String?

    /// 还没建占位会话时，实时页显示的候选。id 稳定（同一段只造一次），
    /// 否则 SwiftUI 的 `ForEach` 会在每次刷新时重建整行
    private var ephemeral: [LessonQuestion] = []

    private var recordings: RecordingsStore
    private var transcription: TranscriptionEngine
    private var service: QuestionAnswerService
    private var isBatchRunning = false

    init(recordings: RecordingsStore,
         transcription: TranscriptionEngine,
         service: QuestionAnswerService = .live) {
        self.recordings = recordings
        self.transcription = transcription
        self.service = service
    }

    // MARK: - 派生

    /// 讨论页的主列表：被元问题表命中的不进主列表（拍板第 7 条）
    var mainQuestions: [LessonQuestion] { questions.filter { !$0.filtered } }
    /// 折叠区：默认收起，只显示原句、没有查询入口
    var filteredQuestions: [LessonQuestion] { questions.filter(\.filtered) }

    /// 有答案的条数（「已答」口径，只看 `.answered`）
    var answeredCount: Int { mainQuestions.filter { $0.status == .answered }.count }

    /// 查过的条数（「已查」口径）。**这是页头那行用的数**。
    ///
    /// 「查不到」和「查失败」都算查过：用户点了查询、系统也真的去问了，只是没得到可靠答案。
    /// 早先这里直接拿 `answeredCount`（只数 `.answered`）当「已查」，
    /// 于是「3 个问题：有答案 1 / 查不到 1 / 未查 1」的页面写着「1 个已查」，
    /// 少报了真实的查询次数。判据在 `QuestionTally`（纯函数，离线自检）。
    var queriedCount: Int { QuestionTally.queried(mainQuestions) }

    /// 还等着查的条数（未查 + 查询中）。与 `queriedCount` 互斥，两者相加 = 主列表条数
    var pendingCount: Int { QuestionTally.pending(mainQuestions) }

    /// 搜索和 DeepSeek 两个密钥都得有（拍板第 9 条：缺任意一个就禁用入口，
    /// 但列表照常显示）
    var isConfigured: Bool {
        AppConfig.searchAPIKey != nil && AppConfig.deepSeekAPIKey != nil
    }

    var isLive: Bool { scope == .live }
    var currentSession: RecordingSession? {
        sessionID.flatMap { recordings.session(id: $0) }
    }

    /// 重查会不会覆盖已有答案。**UI 拿它决定弹不弹确认**，
    /// 判断本身在 `QuestionFlow.owesConfirmation`
    func requiresConfirmation(questionID: UUID) -> Bool {
        guard let question = questions.first(where: { $0.id == questionID }) else { return false }
        return QuestionFlow.owesConfirmation(question.status)
    }

    // MARK: - 打开 / 刷新

    /// 打开某个范围。**只读**：读盘、按需回填、把实时片段里的新提问并进来，
    /// 不发任何网络请求（§5.3「页面加载不产生转移」）
    func open(scope: Scope, sensitivity: QuestionSensitivity) {
        self.scope = scope
        self.hasOpened = true
        self.message = nil
        self.phases.removeAll()
        self.batchProgress = nil

        switch scope {
        case .live:
            let bound = transcription.sessionID
            if let bound, recordings.session(id: bound) != nil {
                sessionID = bound
                ephemeral = []
                loadSession(id: bound)
                mergeLiveSegments(intoSession: bound)
            } else {
                sessionID = nil
                loadSession(id: nil)
                refreshEphemeral()
            }

        case .session(let id):
            if sessionID != id {
                ephemeral.removeAll()
            }
            sessionID = id
            // 旧存档按需回填（§4.6.4）：打开提问页这一刻才跑，不在启动路径上
            _ = recordings.backfillQuestions(id: id, sensitivity: sensitivity)
            loadSession(id: id)
        }
    }

    /// 实时页在片段增加时刷新（视图那边 `onChange(of: segments.count)` 调它）。
    /// 不写盘、不联网——只是把新段落的提问并进内存/占位会话
    func refreshLive(scope: Scope, sensitivity: QuestionSensitivity) {
        // 范围变了（用户切了页）就整体重开，别把别人的列表续上
        guard scope == self.scope else {
            open(scope: scope, sensitivity: sensitivity)
            return
        }
        guard case .live = scope else { return }
        if let id = sessionID, recordings.session(id: id) != nil {
            mergeLiveSegments(intoSession: id)
        } else {
            refreshEphemeral()
        }
    }

    private func loadSession(id: UUID?) {
        guard let id, var session = recordings.session(id: id) else {
            questions = LessonQuestion.sortedByTime(ephemeral)
            return
        }
        // 元问题标记按当前规则表重算。表会演进（§7.6），旧存档里的
        // `filtered` 是当时的结论；不重算的话，规则改了以后这份存档
        // 永远按老结论分组
        var changed = false
        for index in session.questions.indices {
            let expected = MetaQuestionFilter.isMetaQuestion(session.questions[index].text)
            if session.questions[index].filtered != expected {
                session.questions[index].filtered = expected
                changed = true
            }
        }
        if changed { recordings.save(session) }
        questions = LessonQuestion.sortedByTime(session.questions)
    }

    /// 实时候选（还没有占位会话时）：直接从引擎片段造条目，不落盘。
    /// 第一次查询时整体搬进占位会话，id 原样保留
    private func refreshEphemeral() {
        let known = Set(ephemeral.compactMap(\.sourceSegmentID))
        for segment in transcription.segments where segment.isQuestion {
            guard !known.contains(segment.id) else { continue }
            ephemeral.append(Self.candidate(from: segment, offsetMillis: 0))
        }
        questions = LessonQuestion.sortedByTime(ephemeral)
    }

    /// 把引擎里还没入列的提问并进已有会话并落盘（实时期间）。
    ///
    /// 偏移取**会话当前时长**：`transcription.segments` 里每一段的时间都是
    /// 自己那一段（part）的局部时间，而问题条目要的是会话时间轴（§4.2）。
    /// 已经入列过的段按 `sourceSegmentID` 跳过，所以旧段不会被重复加偏移
    private func mergeLiveSegments(intoSession id: UUID) {
        guard var session = recordings.session(id: id) else { return }
        let known = Set(session.questions.compactMap(\.sourceSegmentID))
        let offset = session.durationMillis
        var appended = false
        for segment in transcription.segments where segment.isQuestion {
            guard !known.contains(segment.id) else { continue }
            let candidate = Self.candidate(from: segment, offsetMillis: offset)
            LessonQuestion.enqueue(candidate, into: &session.questions)
            appended = true
        }
        if appended {
            recordings.save(session)
        }
        questions = LessonQuestion.sortedByTime(session.questions)
    }

    private static func candidate(from segment: TranscriptSegment, offsetMillis: Int) -> LessonQuestion {
        let text = segment.coreQuestion ?? segment.text
        return LessonQuestion(
            text: text,
            rawSentence: segment.text,
            startTimeMillis: offsetMillis + min(segment.startTimeMillis, segment.endTimeMillis),
            sourceSegmentID: segment.id,
            level: segment.questionLevel,
            filtered: MetaQuestionFilter.isMetaQuestion(text)
        )
    }

    // MARK: - 查询

    /// 点一行的「查答案 / 重试 / 重新查询」。
    ///
    /// `confirmedOverwrite` 由 UI 在二次确认之后传 true（拍板第 4 条）；
    /// 没确认就调用一个有答案的条目，**这里会拒绝**——把确认留在 UI 的
    /// 自觉上是不可接受的，覆盖是不可逆的
    func query(questionID: UUID, confirmedOverwrite: Bool = false) async {
        guard let question = questions.first(where: { $0.id == questionID }) else { return }

        let duplicateAnswer = questions.first {
            $0.id != questionID
                && $0.normalizedText == question.normalizedText
                && $0.status == .answered
                && $0.answer != nil
        }
        let duplicateSearching = questions.contains {
            $0.id != questionID
                && $0.normalizedText == question.normalizedText
                && $0.status == .searching
        }

        let gate = QuestionFlow.gate(
            status: question.status,
            filtered: question.filtered,
            isConfigured: isConfigured,
            hasAnswer: question.status == .answered,
            duplicateAnswerID: duplicateAnswer?.id,
            duplicateSearching: duplicateSearching
        )

        switch gate {
        case .blocked(.alreadySearching), .blocked(.duplicateSearching):
            return
        case .blocked(.filtered):
            // 防御性：折叠区的条目本来就没有入口（拍板第 7 条）
            return
        case .blocked(.notConfigured):
            message = "未配置搜索或 DeepSeek 密钥，先到「设置」里填上再查"
            return
        case .copyAnswer(let sourceID):
            copyAnswer(from: sourceID, into: questionID)
            return
        case .proceed:
            break
        }

        let event: QuestionFlow.Event = question.status == .answered
            ? .requery
            : (question.status == .unasked ? .ask : .retry)
        let transition = QuestionFlow.decide(current: question.status, event: event)
        guard transition.allowed else { return }
        if transition.requiresConfirmation && !confirmedOverwrite {
            // UI 应该先弹确认；走到这里说明调用方漏了那一步，宁可什么都不做，
            // 也不能悄悄覆盖学生看过的答案
            message = QuestionFlow.overwriteConfirmation
            return
        }

        // 实时第一次查询：先把归属钉下来（占位会话），再改状态。
        // 顺序不能反——状态先改的话，建会话失败时内存里会留下一个
        // 「查询中」却没有落点的条目
        ensurePlaceholderIfNeeded()
        guard sessionID != nil else { return }

        mutateQuestion(id: questionID) { q in
            q.status = .searching
            q.failure = nil
            q.failureNote = nil
            // 进入查询中即清掉旧答案：覆盖是学生的明确选择，旧的答案与来源
            // 会被替换（拍板第 4 条）。留着旧答案再显示「查询中」会让那行
            // 同时挂着两份互相矛盾的内容
            q.answer = nil
        }
        await runQuery(questionID: questionID)
    }

    /// 「查询全部待查」：把 N 次点击合成一次（§5.3）。**只选主列表里
    /// `unasked` 的**——有答案的、失败的、被过滤的都不动
    func queryAllPending() async {
        guard !isBatchRunning, isConfigured else { return }
        let ids = questions
            .filter { !$0.filtered && $0.status == .unasked }
            .map(\.id)
        guard !ids.isEmpty else { return }
        isBatchRunning = true
        batchProgress = BatchProgress(done: 0, total: ids.count)
        defer {
            isBatchRunning = false
            batchProgress = nil
        }
        for (index, id) in ids.enumerated() {
            await query(questionID: id, confirmedOverwrite: true)
            batchProgress = BatchProgress(done: index + 1, total: ids.count)
        }
        message = "已完成 \(ids.count) 条查询"
    }

    private func copyAnswer(from sourceID: UUID, into targetID: UUID) {
        guard let source = questions.first(where: { $0.id == sourceID }),
              let answer = source.answer else { return }
        mutateQuestion(id: targetID) { q in
            q.status = .answered
            q.failure = nil
            q.failureNote = nil
            // `QuestionAnswer` 是值类型，赋值就是一份副本，不与来源共用
            q.answer = answer
        }
    }

    private func runQuery(questionID: UUID) async {
        guard let question = questions.first(where: { $0.id == questionID }) else { return }
        phases[questionID] = QuestionAnswerPhase.searching.text

        let outcome = await service.answer(question: question.text) { [weak self] phase in
            Task { @MainActor in
                self?.phases[questionID] = phase.text
            }
        }

        phases.removeValue(forKey: questionID)
        switch outcome {
        case .answered(let answer):
            mutateQuestion(id: questionID) { q in
                q.status = .answered
                q.failure = nil
                q.failureNote = nil
                q.answer = answer
            }
        case .noResults(let sources):
            // 有资料没答案时也要把来源留住（§2.3）：`answer.markdown` 为空，
            // 界面只列来源、不显示正文。`status == .noResults` 而不是
            // `.answered`，所以重试它不需要确认
            mutateQuestion(id: questionID) { q in
                q.status = .noResults
                q.failure = nil
                q.failureNote = nil
                q.answer = sources.isEmpty ? nil : QuestionAnswer(
                    markdown: "",
                    sources: sources,
                    model: service.model,
                    searchProvider: service.searchProvider
                )
            }
        case .failed(let failure):
            mutateQuestion(id: questionID) { q in
                q.status = .failed
                q.failure = failure
                q.failureNote = nil
                q.answer = nil
            }
        }
    }

    // MARK: - 落盘

    /// 实时第一次查询：建占位会话并把当前候选搬进去（拍板第 1 条）。
    /// 已有会话（「接着录」的 sessionID）就复用
    private func ensurePlaceholderIfNeeded() {
        if let id = sessionID, recordings.session(id: id) != nil {
            return
        }
        if let bound = transcription.sessionID, recordings.session(id: bound) != nil {
            sessionID = bound
            mergeLiveSegments(intoSession: bound)
            return
        }

        let startedAt = transcription.currentPartStartedAt ?? Date()
        let id = recordings.createQuestionPlaceholder(startedAt: startedAt)
        // 引擎记住它：stop() 落盘时 ingest 会带着同一个 id 追加片段，
        // 而不是再建一条会话
        transcription.sessionID = id
        sessionID = id

        if !ephemeral.isEmpty {
            _ = mutatePersistedQuestions(id: id) { list in
                let known = Set(list.compactMap(\.sourceSegmentID))
                for question in ephemeral
                where !(question.sourceSegmentID.map { known.contains($0) } ?? false) {
                    LessonQuestion.enqueue(question, into: &list)
                }
            }
            ephemeral.removeAll()
        }
        loadSession(id: id)
    }

    /// 只改一条已落盘的问题。`questions` 跟着重读，保证界面与盘一致
    private func mutateQuestion(id questionID: UUID, _ body: (inout LessonQuestion) -> Void) {
        guard let id = sessionID else { return }
        _ = mutatePersistedQuestions(id: id) { list in
            guard let index = list.firstIndex(where: { $0.id == questionID }) else { return }
            body(&list[index])
        }
    }

    @discardableResult
    private func mutatePersistedQuestions(
        id: UUID,
        _ body: (inout [LessonQuestion]) -> Void
    ) -> Bool {
        guard var session = recordings.session(id: id) else { return false }
        body(&session.questions)
        recordings.save(session)
        questions = LessonQuestion.sortedByTime(session.questions)
        return true
    }
}
