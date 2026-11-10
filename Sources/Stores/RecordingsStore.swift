import Foundation
import Observation

/// 历史会话（录音 + 转录）的持久化和列表数据源。
///
/// **存储选型：一会话一文件 + 一个轻量 index.json，不用单 JSON。**
/// 会话只增不减（一学期几百条），而一条会话的 segments 可能有几百段、
/// 几百 KB。单 JSON 意味着每次落盘都全量重写、每次启动都全量解码，
/// 越用越慢且一次写坏全灭。按文件拆开后：保存只写被动过的那一条，
/// 列表只读 index.json 里的摘要，正文按需解码。
///
/// 目录布局（Application Support/ClassroomTranscriber/sessions/）：
///   index.json      —— [SessionSummary]，列表数据源
///   <uuid>.json     —— 一条 RecordingSession 的正文
@MainActor
@Observable
final class RecordingsStore {

    /// 列表数据源，新的在前。视图绑定它，不用碰会话正文
    private(set) var summaries: [SessionSummary] = []
    private(set) var statusMessage = ""

    /// 解码过的会话正文缓存。详情页反复进出不该每次读盘；
    /// 会话条数有限，全缓存也占不了多少内存，不做 LRU
    private var cache: [UUID: RecordingSession] = [:]

    private let directory: URL
    /// wav 所在目录（删除音频时用）。可注入是为了自检不碰真实存档
    private let recordingsDirectory: URL

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    init(
        directory: URL? = nil,
        recordingsDirectory: URL = RecordingStorage.directory
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.recordingsDirectory = recordingsDirectory
        loadIndex()
        refreshRecovery()
    }

    // MARK: - 读取

    /// 按需求取一条会话的完整正文。列表用 summaries，详情才走这里
    func session(id: UUID) -> RecordingSession? {
        if let cached = cache[id] { return cached }
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RecordingSession.self, from: data)
        else { return nil }
        cache[id] = decoded
        return decoded
    }

    /// 列表缩略图要的 wav 路径（P15-1）。
    ///
    /// 正常路径只读摘要里的 `audioFileName`，不解码正文。旧 index.json
    /// 没有这个字段，回落成解码一次会话正文——**只在摘要缺字段时发生**，
    /// 而会话下一次 `save` 就会把摘要补齐，所以这是过渡期的代价，
    /// 不是常态。解码走 `session(id:)` 的缓存，反复取也不会重复读盘
    func audioURL(for summary: SessionSummary) -> URL? {
        let fileName = summary.audioFileName
            ?? self.session(id: summary.id)?.parts.lazy.compactMap(\.fileName).first
        guard let fileName, !fileName.isEmpty else { return nil }
        return recordingsDirectory.appendingPathComponent(fileName)
    }

    // MARK: - 写入

    /// 接收引擎的录音快照：新会话就建，「接着录」就追加片段。
    ///
    /// 返回会话 id ——引擎要拿它记在身上，下一次 stop 才知道自己
    /// 属于哪条会话
    /// - Parameter questionSensitivity: 落盘时顺带把这一段里检测到的问题并进
    ///   会话（只在会话已经回填过条目时做，见下方注释）。默认 `.off` 让
    ///   自检和旧调用点行为不变
    @discardableResult
    func ingest(_ draft: SessionDraft,
                questionSensitivity: QuestionSensitivity = .off) -> RecordingSession {
        var session: RecordingSession
        if let id = draft.sessionID, let existing = self.session(id: id) {
            session = existing
        } else {
            // draft 带了 sessionID 但会话找不到（被删了/拷来的草稿），
            // 按新会话建——数据落盘比「忠于引用」重要，丢了就找不回来
            session = RecordingSession(
                id: UUID(), startedAt: draft.startedAt, updatedAt: draft.startedAt, parts: []
            )
        }

        let offset = session.parts.last.map { $0.offsetMillis + $0.durationMillis } ?? 0
        let part = RecordingPart(
            id: UUID(),
            fileName: draft.recordingFileName,
            startedAt: draft.startedAt,
            durationMillis: draft.durationMillis,
            offsetMillis: offset,
            segments: draft.segments,
            // 「这一段是哪个麦」由引擎在**录制当时**读出来、跟着 draft 交过来。
            // 这里绝不自己去查一次设备：Store 是在 stop 之后才被调用的，
            // 那时用户可能已经把外置麦拔了，查出来的是「现在」的默认设备，
            // 不是「录这一段时」用的那只
            capture: draft.capture
        )
        session.parts.append(part)
        session.updatedAt = Date()

        // 实时期间问题页可能已经先建了占位会话并落过问题（版本已达标）。
        // 那种会话**不会再走按需回填**（版本门槛拦着），所以这一段的提问
        // 必须在这里并进去，否则「查完答案之后老师又问了几个问题」会丢。
        //
        // 版本没达标（0）的旧会话**不在这里盖章**：只并新片段会让「已回填」
        // 变成谎话，旧片段的提问从此再也补不回来。留给按需要回填一次跑全量
        if session.questionSchemaVersion >= LessonQuestionSchema.current {
            mergeDetectedQuestions(in: part, into: &session,
                                   sensitivity: questionSensitivity)
        }

        save(session)
        return session
    }

    /// 把一段里检测到的提问并进会话（§6.3 入列去重，§7 元问题标记）。
    ///
    /// **按 `sourceSegmentID` 跳过已经入列的段**：实时期间问题页已经把它们
    /// 落过一次了，再来一遍会把 `askedCount` 从 1 翻成 2——同一句话只说了
    /// 一次，数字却是两次，学生看到的「本课重复 n 次」就成了假话。
    private func mergeDetectedQuestions(
        in part: RecordingPart,
        into session: inout RecordingSession,
        sensitivity: QuestionSensitivity
    ) {
        guard sensitivity != .off else { return }
        let detector = QuestionDetector(sensitivity: sensitivity)
        let known = Set(session.questions.compactMap(\.sourceSegmentID))
        for segment in part.segments where !known.contains(segment.id) {
            guard let hit = detector.detect(segment.text) else { continue }
            let candidate = LessonQuestion(
                text: hit.coreQuestion,
                rawSentence: segment.text,
                startTimeMillis: RecordingSession.absoluteRange(of: segment, in: part).lowerBound,
                sourceSegmentID: segment.id,
                level: hit.level,
                filtered: MetaQuestionFilter.isMetaQuestion(hit.coreQuestion)
            )
            LessonQuestion.enqueue(candidate, into: &session.questions)
        }
    }

    // MARK: - 占位会话（B 包拍板第 1 条）

    /// 实时期间第一次查询时建一条**空占位会话**，让「答案落盘」在点击的
    /// 瞬间就成立（崩溃不丢）。录制结束 `ingest` 带着同一个 id 追加片段，
    /// 不会变成两条；如果最终没有片段，它留成一条「只有提问」的会话，
    /// 由录音列表的「删除无录音的提问记录」清理
    ///
    /// `questionSchemaVersion` 直接盖当前版本：这条会话的提问由问题页
    /// 实时并进来（见 `ingest` 的分支），不该再被按需回填重跑一遍
    func createQuestionPlaceholder(startedAt: Date) -> UUID {
        let now = Date()
        let session = RecordingSession(
            id: UUID(),
            startedAt: startedAt,
            updatedAt: now,
            parts: [],
            questionSchemaVersion: LessonQuestionSchema.current
        )
        save(session)
        return session.id
    }

    /// 没有录音片段的会话（占位会话；理论上只有在实时期间查过答案、
    /// 后来没录成才会出现）。列表页的清理入口只在这里读摘要，不解码正文
    var questionOnlySummaries: [SessionSummary] {
        summaries.filter { $0.partCount == 0 }
    }

    /// 删除所有「只有提问、没有录音」的会话。返回删掉几条。
    ///
    /// 用 `delete(id:)` 而不是 `deleteWithAudio`：这些会话没有片段，
    /// 不存在 wav，而误删音频不可恢复——两个删除语义的边界不在这里松动
    @discardableResult
    func deleteQuestionOnlySessions() -> Int {
        let ids = questionOnlySummaries.map(\.id)
        for id in ids { delete(id: id) }
        return ids.count
    }

    /// 编码 + 原子落盘的**唯一一处**实现。会话正文和录制草稿都走它——
    /// 第二份「写临时文件再 rename」的实现迟早会和这一份漂移，
    /// 而漂移的那天表现为「草稿能写但会话写不进去」这种只在崩溃时才见到的差别
    private func atomicWrite(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// 保存/更新一条会话：写正文文件 + 同步 index 里的摘要
    func save(_ session: RecordingSession) {
        do {
            try atomicWrite(session, to: fileURL(for: session.id))
        } catch {
            statusMessage = "❌ 会话保存失败: \(error.localizedDescription)"
            // 这条失败原本只变成界面上一句 statusMessage，用户划过去就没了。
            // 而它意味着**这节课的转录没落盘**——最该留下现场的一类失败
            DiagnosticLog.error(.storage, "会话保存失败", fields: [
                .init("sessionId", session.id),
                .init("原因", error.localizedDescription),
            ])
            return
        }

        cache[session.id] = session
        let summary = SessionSummary(session: session)
        if let index = summaries.firstIndex(where: { $0.id == session.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort { $0.startedAt > $1.startedAt }
        persistIndex()

        // 脏数据告警（派单书点名的那类）。**只在不为零时记**：正常会话每存
        // 一次都写一条「0 段反向」，环形那 1 MB 会被这种噪声占满，
        // 真要查的时候现场已经滚掉了。
        //
        // 判据借 C-4 那个纯函数，不在这里另写一遍——两处判定迟早会漂移，
        // 而漂移的那天没人会发现（两边各自都"看着对"）
        let reversed = RecordingSession.reversedSegments(in: session).count
        if reversed > 0 {
            DiagnosticLog.warn(.data, "会话里含反向转录段", fields: [
                .init("sessionId", session.id),
                .init("反向段", reversed),
                .init("总段数", session.segmentCount),
            ])
        }
    }

    // MARK: - 录制草稿（P9-1）

    /// 草稿目录。**放在 `sessions/` 下但自成一个子目录**：
    /// `sessions/` 的语义是「完整的会话」，列表（`index.json`）、体检
    /// （`IntegrityScan` 七类判据）都按这个语义写的。半成品混进去，
    /// 每个读那个目录的地方都得多判一次「这条算不算数」——那种判断迟早
    /// 会在某一条路径上漏掉，表现就是列表里冒出一条永远打不开的录音
    var draftsDirectory: URL { directory.appendingPathComponent("drafts", isDirectory: true) }

    private func draftURL(for id: UUID) -> URL {
        draftsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// 周期性落一份录制草稿。**复用 `save` 的那一次原子写**（`atomicWrite`）
    ///
    /// 失败**只记日志、不改 `statusMessage`**：草稿是保险，不是主路径。
    /// 每 30 秒往界面上顶一句报错，用户会以为录音坏了——而录音好好的，
    /// 真正该报的那个错（会话没落盘）在 `save` 里
    func saveDraft(_ draft: RecordingDraft) {
        do {
            try atomicWrite(draft, to: draftURL(for: draft.id))
        } catch {
            DiagnosticLog.error(.storage, "录制草稿保存失败", fields: [
                .init("草稿", draft.id),
                .init("原因", error.localizedDescription),
            ])
        }
    }

    /// 读草稿目录。**解不出来的草稿照样返回一个占位**，不静默丢掉：
    /// 崩溃现场只出现一次，「这里本来有个草稿但读不出来」本身就是要让
    /// 用户看见的信息（他才知道那段录音为什么恢复不了）
    func loadDrafts() -> [RecordingDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: draftsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(RecordingDraft.self, from: data)
            }
    }

    /// 草稿扶正：**走和正常停止完全相同的落盘路径**（`ingest`），
    /// 然后把草稿文件删掉。
    ///
    /// 为什么删草稿要放在 `ingest` 之后：反过来的话，`ingest` 抛错/被杀
    /// 就变成「草稿没了、会话也没写成」——一次崩溃把保险也一起烧了
    @discardableResult
    func promoteDraft(_ draft: RecordingDraft) -> RecordingSession {
        let session = ingest(draft.asSessionDraft)
        removeDraftFile(draft.id, reason: "已扶正成会话 \(session.id)")
        return session
    }

    /// 「有音频但没有完整会话」的录音（P9-1）。**启动时扫一次**，
    /// 之后每次恢复/丢弃再刷新。
    ///
    /// 启动时扫而不是每次进列表页现扫：这个扫描要读 `recordings/` 里每个
    /// wav 的文件头拿时长，几十条录音就是几十次 open。挂在启动上，
    /// 代价落在用户还在看启动画面的时候
    private(set) var recoveryItems: [RecoveryScan.Item] = []

    /// 上一次恢复时改了什么（逐行，含原值）。**恢复是唯一一处会改用户音频
    /// 的动作**，所以它必须留下可读的账——用户点完「恢复」得能看见
    /// 「长度字段 192000 → 220800」这一行，而不是只有一句「已完成」
    private(set) var recoveryNotes: [String] = []

    func refreshRecovery() {
        recoveryItems = RecoveryScan.scan(
            sessionsDirectory: directory,
            recordingsDirectory: recordingsDirectory,
            draftsDirectory: draftsDirectory
        )
    }

    /// 用户点了「恢复」：草稿扶正成正式会话。
    ///
    /// **顺手修音频头。** 崩溃是留下过期头的那个原因（`WAVRecorder` 每秒
    /// 回填一次），而恢复正是用户明确说「把这段录音要回来」的那一刻；
    /// 不修的话，救回来的录音尾部最多 1 秒对任何读者都不存在——
    /// 用户拿到的是一条「静悄悄短了一截」的录音。
    ///
    /// 这一步**不是偷偷做的**：界面上那一行的按钮文案和说明会写明
    /// 「恢复时会一并修复音频头」（`Item.headerRepairNote`），用户在点之前
    /// 就看到了。修不成（那个文件根本不是音频）也照常恢复，只是记一条日志
    ///
    /// 失败**不做任何破坏性兜底**——草稿原地不动，下次启动还能再试一次
    func recover(_ item: RecoveryScan.Item) {
        guard let draft = item.draft else { return }
        if let defect = item.headerDefect, defect.isRepairable, let name = item.fileName {
            let url = recordingsDirectory.appendingPathComponent(name)
            if let inspection = WAVHeaderRepair.inspect(url), inspection.defect.isRepairable {
                do {
                    let outcome = try WAVHeaderRepair.apply(inspection)
                    recoveryNotes.append(contentsOf: outcome.lines)
                    DiagnosticLog.info(.storage, "恢复时修复了音频头", fields: [
                        .init("文件", name), .init("草稿", draft.id),
                    ])
                } catch {
                    DiagnosticLog.error(.storage, "恢复时修复音频头失败", fields: [
                        .init("文件", name), .init("原因", error.localizedDescription),
                    ])
                }
            }
        }
        promoteDraft(draft)
        refreshRecovery()
    }

    /// 用户点了「丢弃」。**调用方必须先拿到显式确认**——这个函数本身不弹框，
    /// 它也没法知道调用它的那一刻用户看没看见
    func discard(_ item: RecoveryScan.Item) {
        guard let draft = item.draft else { return }
        discardDraft(draft)
        refreshRecovery()
    }

    /// 丢弃草稿。**只有用户显式确认之后才调得到这里**——
    /// 这个类型里没有第二处 `removeItem` 作用于草稿目录
    func discardDraft(_ draft: RecordingDraft) {
        removeDraft(id: draft.id, reason: "用户显式丢弃")
    }

    /// 按 id 移除草稿文件。两个调用方：用户显式丢弃，以及**录制正常收尾
    /// 之后**（那一刻草稿已经被正式会话取代了）
    func removeDraft(id: UUID, reason: String) {
        removeDraftFile(id, reason: reason)
    }

    private func removeDraftFile(_ id: UUID, reason: String) {
        // 只删草稿自己这个 json。**绝不碰 recordings/ 下的音频**——
        // 丢弃的是「这份转录」，不是那段录音；音频删不删是另一件事、
        // 另一个确认框（见 `deleteWithAudio`）
        try? FileManager.default.removeItem(at: draftURL(for: id))
        DiagnosticLog.info(.storage, "移除录制草稿", fields: [
            .init("草稿", id),
            .init("原因", reason),
        ])
    }

    // MARK: - 改名 / 课程

    /// 改名。空串表示恢复成「没起过名」（列表回落到显示时间）——
    /// 用户把名字清空就是在表达「别给我起名」，不是想显示一个空行
    func rename(id: UUID, to title: String) {
        guard var session = session(id: id) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != session.title else { return }
        session.title = clean
        session.updatedAt = Date()
        save(session)
    }

    /// 设置课程。空串 = 未分类
    func setCourse(id: UUID, to course: String) {
        guard var session = session(id: id) else { return }
        let clean = course.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != session.course else { return }
        session.course = clean
        session.updatedAt = Date()
        save(session)
    }

    // MARK: - 提问按需回填（B 包 §4.6.4）

    /// 给一条旧会话补出问题条目。返回是否真的跑了（false = 版本已达标、
    /// 灵敏度关着，或者会话不存在）。
    ///
    /// **按需**，不是启动时全量扫：回填要解码正文并逐段跑检测器，
    /// 一学期几百条会话放在启动路径上就是「打开 App 先卡十秒」。
    /// 由提问页在打开某一条会话时调它。
    ///
    /// **不动 `updatedAt`**：它是「用户最后一次动这条录音」的意思，
    /// 列表和「最近更新」都读它。回填是派生数据的补齐，把它算成一次用户编辑
    /// 会让一堆旧录音在同一天集体变成「刚更新过」
    @discardableResult
    func backfillQuestions(id: UUID, sensitivity: QuestionSensitivity) -> Bool {
        guard var session = session(id: id) else { return false }
        guard session.backfillQuestions(sensitivity: sensitivity) else { return false }
        save(session)
        return true
    }

    /// 已有课程名，按出现次数从多到少。给「设置课程」的下拉候选，
    /// 让用户复用已有课程名而不是每次手打——手打早晚会出现
    /// 「机器学习」和「机器学习 」两个组
    var knownCourses: [String] {
        var counts: [String: Int] = [:]
        for summary in summaries where !summary.course.isEmpty {
            counts[summary.course, default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)
    }

    // MARK: - 重新转录

    /// 重转的进行状态。UI 要显示「正在重转第 N 段」——
    /// 一条几十分钟的录音要跑很久，没有进度用户会以为卡死了
    private(set) var retranscribing: UUID?
    private(set) var retranscribeProgress = ""

    /// 正在进行的那次重转任务。**必须自己拿住句柄**：取消要靠它。
    ///
    /// `Task {}` 从外面 `.cancel()` 才会把取消传到驱动循环里；而重转的活儿
    /// 跑在 `Task.detached` 上（它**不继承**外面的取消），所以取消要经
    /// `withTaskCancellationHandler` 显式转发一层——见 `retranscribeSegment`。
    /// 少了这个句柄，「取消」就只是一个改不动的按钮
    private var retranscribeWork: Task<Void, Never>?

    /// 「正在重转」的判据是**任务句柄**，不是 `retranscribing`。
    /// 两者差着一段实实在在的时间：句柄在 `retranscribe()` 里同步置上，
    /// 而 `retranscribing` 要等走到那一段才填。模型裁决 + 加载引擎那几秒
    /// （large 冷启动更久）界面必须已经在报「在跑」——否则用户看到的是
    /// 「点了一下没反应」，然后再点一次
    var isRetranscribing: Bool { retranscribeWork != nil }

    /// 取消这一轮重转。**只置位，不直接停**——真正的停点在
    /// `WhisperFileTranscription.run` 的每一窗之前（单次 `whisper_full`
    /// 是秒级的阻塞调用，中途插不进去）。所以用户点完最多还要等一窗
    func cancelRetranscribe() {
        guard retranscribeWork != nil else { return }
        retranscribeWork?.cancel()
        retranscribeProgress = "正在取消…（等这一窗转完）"
    }

    /// 本次重转预计要跑多久（派单目标 3 的第一条：代价先摆出来）。
    /// 纯计算，不碰磁盘也不碰模型
    func retranscribeEstimate(
        for session: RecordingSession,
        engine: RetranscribeEngine = .preferred
    ) -> String {
        let audioSeconds = Double(session.parts.reduce(0) { $0 + $1.durationMillis }) / 1000
        return engine.estimatedText(audioSeconds: audioSeconds)
    }

    /// 重新转录一条会话的**所有**有音频的片段，用新的结果替换各片段原有的 segments。
    ///
    /// **默认档是 `RetranscribeEngine.preferred`（large-v3）**：课后重转离线跑，
    /// 慢一点换准确度（实测覆盖率 85.9% → 100%，见 `RetranscribeEngine` 的注释）。
    /// 实时链路不走这里，它固定 medium。
    ///
    /// **旧转录怎么处理**（派单要求交付时说清的一条）：**保留到新的一整段跑完为止**。
    /// 结果先攒在内存里，一个片段转完了才写回存档；取消或失败时那个片段
    /// **一个字都不动**（见 `retranscribeSegment` 的返回值和本轮末尾的落盘）。
    /// 「不许留下半个转录」这条因此落在两处：分段成原子单位 + 只认跑完的结果。
    ///
    /// 覆盖是不可逆的：原 segments 上可能已经有用户看过的内容，所以
    /// UI 层必须先确认再调这里
    func retranscribe(sessionID: UUID, engine: RetranscribeEngine = .preferred) {
        guard retranscribeWork == nil else { return }
        retranscribeProgress = "正在准备（\(engine.fileName)）…"
        retranscribeWork = Task { [weak self] in
            guard let self else { return }
            await self.performRetranscribe(sessionID: sessionID, engine: engine)
            self.retranscribeWork = nil
            self.retranscribing = nil
            self.retranscribeProgress = ""
        }
    }

    private func performRetranscribe(sessionID: UUID, engine: RetranscribeEngine) async {
        guard var session = session(id: sessionID) else {
            statusMessage = "❌ 找不到要重转的会话"
            return
        }

        // 1. 先裁决模型，**在动手之前**。
        //    缺 large 时这一段就是本包的全部答案：说出来 + 怎么补，
        //    然后**什么都不做**——不回落 medium（那会让你以为这份转录是
        //    large 的产物）。文案里带着路径、期望大小、下载入口三件事
        let decision = RetranscribeRequirement.resolve(engine: engine)
        guard case .ready(let modelPath, let bytes, let revision) = decision else {
            if case .blocked(let reason) = decision { statusMessage = reason }
            return
        }
        statusMessage = ""

        // 2. 加载引擎（一次，几秒到十几秒）。`Task.detached`：`WhisperEngine.init`
        //    会编译 Metal 内核、同步阻塞，放主 actor 上界面就僵在那儿
        let whisper: WhisperEngine
        do {
            whisper = try await Task.detached(priority: .userInitiated) {
                try WhisperEngine(modelURL: URL(fileURLWithPath: modelPath))
            }.value
        } catch {
            statusMessage = "❌ 重转引擎加载失败：\(error.localizedDescription)\n   模型位置：\(modelPath)"
            return
        }

        let provenance = TranscriptionProvenance(
            modelFile: engine.fileName, revision: revision, bytes: bytes,
            retranscribedAt: Date()
        )

        // 3. 逐片段跑。**串行、一个 Task 里跑完**：原先 UI 那层是
        //    `for part in parts { Task { … } }`，而 `retranscribe` 的入口
        //    guard 只放行第一个——并发起 N 个任务、N-1 个被静默丢掉
        var done: [(index: Int, segments: [TranscriptSegment])] = []
        var skipped: [String] = []
        var cancelled = false

        for (index, part) in session.parts.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            guard let fileName = part.fileName else {
                // 这一片没开存档（recordsAudio 关着）——没有音频可转，
                // 跳过而不是报错。原有的 segments 一个字不动
                skipped.append("第 \(index + 1) 段没有音频文件")
                continue
            }
            let url = recordingsDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                skipped.append("第 \(index + 1) 段音频不在：\(fileName)")
                continue
            }

            retranscribing = part.id
            let total = session.parts.count
            retranscribeProgress = "正在重转第 \(index + 1)/\(total) 段 \(fileName)…"

            switch await retranscribeSegment(
                url: url, whisper: whisper, engine: engine, partIndex: index, partCount: total
            ) {
            case .success(let segments):
                done.append((index, segments))
            case .cancelled:
                cancelled = true
            case .failed(let message):
                skipped.append(message)
            }
            if cancelled { break }
        }

        // 4. 落盘。**只有跑完的片段**进得来（`done` 里全是完整结果），
        //    取消/失败的那些片段保持原样——这就是「不许留下半个转录」
        for entry in done {
            session.parts[entry.index].segments = entry.segments
            session.parts[entry.index].transcriptionProvenance = provenance
        }
        if !done.isEmpty {
            session.updatedAt = Date()
            save(session)
        }

        var notes = ["模型 \(engine.fileName)"]
        if !done.isEmpty { notes.append("已重转 \(done.count) 段录音") }
        if cancelled { notes.append("⏹ 已取消") }
        notes.append(contentsOf: skipped.map { "⚠️ \($0)" })
        if done.isEmpty {
            statusMessage = notes.joined(separator: "；")
                + (cancelled ? "——原有转录全部保留" : "")
        } else {
            statusMessage = "✅ " + notes.joined(separator: "；")
        }
    }

    private enum SegmentOutcome: Sendable {
        case success([TranscriptSegment])
        case cancelled
        case failed(String)
    }

    /// 转一个片段。**返回成功才代表这一片可以覆盖旧转录**。
    ///
    /// 取消要显式往下传：`Task.detached` 不继承外面的取消状态，所以这里用
    /// `withTaskCancellationHandler` 把 `cancel()` 转发进那个 detached 任务，
    /// 驱动循环里的 `Task.isCancelled` 才看得见（见 `WhisperFileTranscription.run`）
    private func retranscribeSegment(
        url: URL,
        whisper: WhisperEngine,
        engine: RetranscribeEngine,
        partIndex: Int,
        partCount: Int
    ) async -> SegmentOutcome {
        let path = url.path
        // 进度里的「已转 X / 共 Y 秒」靠回调报上来。窗口级回调在**工作线程**上，
        // 所以过一道 MainActor；每窗一次（3~6 秒一个），这点开销可以忽略
        let onWindow: @Sendable (WhisperFileTranscription.WindowFacts) -> Void = { facts in
            let covered = Double(facts.windowEndMillis) / 1000
            Task { @MainActor [weak self] in
                guard let self, self.isRetranscribing else { return }
                self.retranscribeProgress = String(
                    format: "正在重转第 %d/%d 段 %@ · 已转 %.0f 秒（第 %d 窗）",
                    partIndex + 1, partCount, url.lastPathComponent, covered, facts.index
                )
            }
        }

        let work = Task.detached(priority: .userInitiated) { () -> SegmentOutcome in
            do {
                let loaded = try WhisperFileTranscription.loadSamples(path: path)
                // 术语表前移：和实时链路同一条来源（磁盘上的 glossary.json）。
                // 每个片段各算一次——术语表的开关是全局的，重转一个片段
                // 和重转十个片段用同一份词表
                let result = try WhisperFileTranscription.run(
                    samples: loaded.samples, engine: whisper,
                    initialPrompt: GlossaryStore.promptResolution(
                        tokenCount: { whisper.promptTokenCount($0) }
                    ).text,
                    onWindow: onWindow
                )
                guard !result.segments.isEmpty else {
                    return .failed("第 \(partIndex + 1) 段重转没有产出内容，保留原有转录")
                }
                // 重转出来的段要补上质量分档和提问标记：这两件事在实时链路里
                // 是定稿时做的（见 TranscriptionEngine.upsert），文件路径没有
                // 那个环节，不补的话重转完质量标记会整片消失
                var enriched = result.segments
                let detector = QuestionDetector(sensitivity: .normal)
                for i in enriched.indices {
                    if let hit = detector.detect(enriched[i].text) {
                        enriched[i].questionLevel = hit.level
                        enriched[i].coreQuestion = hit.coreQuestion
                    }
                }
                return .success(enriched)
            } catch let failure as WhisperFileTranscription.Failure {
                if case .cancelled = failure { return .cancelled }
                return .failed("第 \(partIndex + 1) 段：\(failure.localizedDescription)")
            } catch {
                return .failed("第 \(partIndex + 1) 段：\(error.localizedDescription)")
            }
        }

        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: - 删除

    /// 删除会话记录，**保留 wav**。
    ///
    /// 为什么默认留音频：wav 是原始素材，误删不可恢复；转录记录是从素材
    /// 派生的，真删错了还能拿 --transcribe-file 重转一份。删东西的时候，
    /// 「可恢复的那个先走」是默认答案
    func delete(id: UUID) {
        cache.removeValue(forKey: id)
        summaries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        persistIndex()
    }

    /// 删除会话记录**并删掉对应的 wav 文件**。
    ///
    /// 拆成独立方法而不是 delete 的一个参数：调用点必须把这行字完整
    /// 打出来，不存在「顺手传了个 true」的余地。只有确定音频也是垃圾
    /// （录废的、隐私内容）时才该调它
    func deleteWithAudio(id: UUID) {
        // 先拿正文再删：片段的文件名只在会话里，删了会话就找不到 wav 了
        let fileNames = session(id: id)?.parts.compactMap(\.fileName) ?? []
        for name in fileNames {
            try? FileManager.default.removeItem(
                at: recordingsDirectory.appendingPathComponent(name)
            )
        }
        delete(id: id)
    }

    // MARK: - 索引

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persistIndex() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summaries).write(to: indexURL, options: .atomic)
        } catch {
            statusMessage = "❌ 会话索引保存失败: \(error.localizedDescription)"
            // 索引是派生数据（下次启动会重建），比正文丢失轻，但它坏掉时
            // 用户看到的是「列表页少了几条」——那种现象最容易被归咎于
            // 「App 把我的录音弄丢了」，所以这里要留下「是索引，不是正文」
            DiagnosticLog.error(.storage, "会话索引保存失败", fields: [
                .init("原因", error.localizedDescription),
            ])
        }
    }

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([SessionSummary].self, from: data) {
            summaries = decoded.sorted { $0.startedAt > $1.startedAt }
            return
        }
        // index 不在/坏了：扫会话文件重建。摘要是派生数据，
        // 正文才是事实，重建代价是每次事故一次性的全量解码
        rebuildIndex()
    }

    private func rebuildIndex() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        var rebuilt: [SessionSummary] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "index.json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(RecordingSession.self, from: data)
            else { continue }
            rebuilt.append(SessionSummary(session: session))
        }
        summaries = rebuilt.sorted { $0.startedAt > $1.startedAt }
        if !rebuilt.isEmpty { persistIndex() }
    }

    // MARK: - 自检

    /// `--session-selftest`：Codable 往返、追加的时间轴、删除语义。
    /// 全程在临时目录里跑，不碰真实的 sessions/ 和 recordings/
    static func selfTest() -> [String] {
        var lines: [String] = ["会话持久化自检（临时目录，不碰真实数据）"]
        var allPassed = true

        func report(_ ok: Bool, _ name: String, _ detail: String = "") {
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-selftest-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = scratch.appendingPathComponent("sessions", isDirectory: true)
        let recordingsDir = scratch.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // ── 1. Codable 往返：字段逐个过，尤其 UUID / Date(带小数秒) / 枚举 ──
        let stamp = Date(timeIntervalSince1970: 1_858_464_000.123) // 2028-11-22, 带毫秒
        let segmentsA = [
            TranscriptSegment(
                text: "今天我们讲梯度下降。", isFinal: true,
                startTimeMillis: 0, endTimeMillis: 2600,
                timestamp: stamp, languages: ["zh-CN"]
            ),
            TranscriptSegment(
                text: "谁来回答一下，学习率为什么不能太大？", isFinal: true,
                startTimeMillis: 2600, endTimeMillis: 5400,
                timestamp: stamp, languages: ["zh-CN"]
            ),
            TranscriptSegment(
                text: "Machin learning 的课先到这里。", isFinal: true,
                startTimeMillis: 5400, endTimeMillis: 8100,
                timestamp: stamp, languages: ["zh-CN", "en-US"]
            ),
        ]
        var s1 = segmentsA[1]
        s1.questionLevel = 2
        s1.coreQuestion = "学习率为什么不能太大？"
        var s2 = segmentsA[2]
        s2.qualityGrade = .poor
        let builtSegments = [segmentsA[0], s1, s2]

        let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
        let session = store.ingest(SessionDraft(
            sessionID: nil,
            recordingFileName: "课堂-20281122-100000.wav",
            startedAt: stamp,
            durationMillis: 8_100,
            segments: builtSegments
        ))

        report(session.parts.count == 1, "新会话建立", "1 个片段")
        report(session.parts[0].offsetMillis == 0, "首片段偏移为 0")

        // 换一个全新 Store 实例读回（走磁盘，不吃缓存）
        let reread = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
        let back = reread.session(id: session.id)
        report(back != nil, "重新打开后能取到会话")
        if let back {
            let got = back.parts[0].segments
            report(got == builtSegments, "segments 逐字段往返一致", "\(got.count) 段（含 UUID/Date/枚举/数组）")
            report(got[1].questionLevel == 2 && got[1].coreQuestion == "学习率为什么不能太大？",
                   "提问标记往返")
            report(got[2].qualityGrade == .poor && got[2].languages == ["zh-CN", "en-US"],
                   "质量分档 + 多语言往返")
            report(got[0].timestamp == stamp, "Date 精度往返（带小数秒）")
            report(back.startedAt == stamp, "会话 startedAt 往返")
        }

        // ── 2. 追加（接着录）：第二段录音进来，两段都在、时间轴拼得上 ──
        let segmentsB = [
            TranscriptSegment(
                text: "接着刚才的，梯度怎么求？", isFinal: true,
                startTimeMillis: 0, endTimeMillis: 1800,
                timestamp: stamp, languages: ["zh-CN"]
            ),
        ]
        let updated = reread.ingest(SessionDraft(
            sessionID: session.id,
            recordingFileName: "课堂-20281122-101500.wav",
            startedAt: stamp.addingTimeInterval(900),
            durationMillis: 3_000,
            segments: segmentsB
        ))

        report(updated.parts.count == 2, "追加后 2 个片段")
        report(updated.id == session.id, "追加落在同一条会话上（id 不变）")
        let offsetOK = updated.parts[1].offsetMillis == updated.parts[0].durationMillis
        report(offsetOK, "片段 2 偏移 = 片段 1 时长",
               "\(updated.parts[1].offsetMillis)ms")
        if let segB = updated.parts[1].segments.first {
            let range = RecordingSession.absoluteRange(of: segB, in: updated.parts[1])
            // 片段 1 长 8100ms，片段 2 这段相对 0–1800 → 绝对 8100–9900
            report(range == 8_100..<9_900, "绝对时间轴正确",
                   "相对 \(segB.startTimeMillis)–\(segB.endTimeMillis) → 绝对 \(range.lowerBound)–\(range.upperBound)")
        }
        report(updated.segmentCount == 4, "两段的 segments 都在", "共 4 段")

        // ── 2b. 反向段（end < start）：底层不许 trap，也不许把起点悄悄改掉 ──
        //
        // 触发条件与现场见 `RecordingSession.absoluteRange` 的注释：修之前这一段
        // 会在 `..<` 上 SIGTRAP（exit 133，release 下一个字都不打印）。用户撞得到
        // 它的入口是「生成课后笔记」，而那条要联网、要 key，进不了这条自检——
        // 所以在这里钉住
        var reversedSession = updated
        reversedSession.parts[1].segments[0].startTimeMillis = 5_000
        reversedSession.parts[1].segments[0].endTimeMillis = 3_000
        let reversedRange = RecordingSession.absoluteRange(
            of: reversedSession.parts[1].segments[0], in: reversedSession.parts[1])
        report(reversedRange.isEmpty && reversedRange.lowerBound == 8_100 + 5_000,
               "反向段：不 trap，是空区间且起点为声明的那个",
               "绝对 \(reversedRange.lowerBound)–\(reversedRange.upperBound)"
                + "（片段 2 偏移 8100 + start 5000）")

        // 追加后再换实例读回，确认落盘的不只是内存态
        let reread2 = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
        report(reread2.session(id: session.id)?.parts.count == 2, "追加结果已落盘")

        // ── 3. 索引摘要：列表页看到的数据必须和正文一致 ──
        let summary = reread2.summaries.first { $0.id == session.id }
        report(reread2.summaries.count == 1 && summary != nil, "索引里有且只有这条会话")
        if let summary {
            report(
                summary.segmentCount == 4 && summary.questionCount == 1
                    && summary.poorCount == 1 && summary.partCount == 2,
                "摘要统计正确",
                "4 段 · 1 提问 · 1 不可信 · 2 片段"
            )
            report(summary.firstText == String(segmentsA[0].text.prefix(30)), "摘要首段文本正确")
        }

        // ── 4. 删除：默认保留 wav，显式才删音频 ──
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        for name in ["课堂-20281122-100000.wav", "课堂-20281122-101500.wav"] {
            FileManager.default.createFile(
                atPath: recordingsDir.appendingPathComponent(name).path,
                contents: Data([0x00])
            )
        }

        reread2.delete(id: session.id)
        let wavKept = FileManager.default.fileExists(
            atPath: recordingsDir.appendingPathComponent("课堂-20281122-100000.wav").path
        )
        report(reread2.session(id: session.id) == nil, "delete 后会话取不到")
        report(wavKept, "delete 保留 wav（原始素材，默认不删）")
        report(reread2.summaries.isEmpty, "delete 后索引同步移除")

        // 再来一条，走显式删音频
        let session2 = reread2.ingest(SessionDraft(
            sessionID: nil,
            recordingFileName: "课堂-20281122-101500.wav",
            startedAt: stamp, durationMillis: 1_000,
            segments: segmentsB
        ))
        reread2.deleteWithAudio(id: session2.id)
        let wavGone = !FileManager.default.fileExists(
            atPath: recordingsDir.appendingPathComponent("课堂-20281122-101500.wav").path
        )
        report(reread2.session(id: session2.id) == nil, "deleteWithAudio 后会话取不到")
        report(wavGone, "deleteWithAudio 删掉 wav（显式调用才发生）")

        lines.append(allPassed ? "全部通过 ✅" : "存在失败用例 ❌")
        return lines
    }
}
