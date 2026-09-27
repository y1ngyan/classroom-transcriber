import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

/// 学习笔记的界面状态。**按会话 id 分开存**，不是「当前会话」一份。
///
/// 为什么按 id 存：详情页和「自动跑一次」都会调这里，而自动跑发生在用户
/// 早就离开那条录音之后。一份「当前会话」的状态意味着自动跑要么把用户正在看的
/// 那个会话的状态覆盖掉，要么被丢弃——两种都不对。id 索引没有这个问题，
/// 也顺带让「同一个会话不许并发跑两次」有一个天然的落点（`running` 集合）
@MainActor
@Observable
final class StudyNotesStore {

    /// 落盘目录。**做成可注入的**：自检要在临时目录里跑，
    /// 而真实的 `study-notes/` 目录是用户的数据，自检一个字都不该写进去
    let directory: URL

    private(set) var notes: [UUID: StudyNotes] = [:]
    private(set) var progress: [UUID: StudyNotesProgress] = [:]
    private(set) var errors: [UUID: String] = [:]

    /// 正在跑的会话。**并发闸就在这里**：同一个会话两个写者会写出两份互相
    /// 覆盖的 `.notes.json`，而「谁最后写的」根本不确定（1400 那条教训）
    private var running: Set<UUID> = []

    /// 生成那一步。**做成参数而不是直接调 `StudyNotesService`**：这一层真正的
    /// 内容是那三条闸（不覆盖、不并发、没 key 不跑），而它们只有在模型那步
    /// 可控的时候才测得出来。默认就是生产那条路，形状参照
    /// `StudyNotesService.ModelCall`（那边是同一个理由）
    typealias Generate = @Sendable (
        _ session: RecordingSession,
        _ glossary: [GlossaryEntry],
        _ onSlice: StudyNotesService.ProgressHook?
    ) async throws -> StudyNotesOutcome

    private let generateHook: Generate

    /// `keyPresent` 是**测试缝**：没配密钥时那三条闸里有一条会短路，
    /// 而自检要在没有密钥的机器上也跑得起来。传 nil 就是看真实配置
    private let keyPresent: Bool?

    init(
        directory: URL = StudyNotesStorage.defaultDirectory,
        keyPresent: Bool? = nil,
        generate: @escaping Generate = StudyNotesStore.defaultGenerate
    ) {
        self.directory = directory
        self.keyPresent = keyPresent
        self.generateHook = generate
    }

    static let defaultGenerate: Generate = { session, glossary, onSlice in
        try await StudyNotesService.generate(
            session: session, glossary: glossary, onSlice: onSlice
        )
    }

    /// 有没有配密钥。**没有 key 时按钮禁用且必须说明原因**——
    /// 静默禁用的形状见 `StudyNotesPanelState.missingKeyReason`
    var hasKey: Bool { keyPresent ?? (AppConfig.deepSeekAPIKey != nil) }

    // MARK: - 读

    /// 从磁盘把某个会话的笔记读进内存。**只读一次**：已经有值就不覆盖，
    /// 否则跑完一轮生成之后，任何一次界面重绘都会把刚生成的那份从内存里
    /// 换成磁盘上的旧版本（磁盘还没写或写的是上一份）
    func load(sessionID: UUID) {
        guard notes[sessionID] == nil else { return }
        notes[sessionID] = StudyNotesStorage.load(sessionID: sessionID, in: directory)
    }

    /// 交给纯函数算该显示哪一档。View 里**不做任何 if/else 判断**
    /// （见 `StudyNotesPanelState` 的注释：散进 View 就没法离线自检）
    func state(sessionID: UUID) -> StudyNotesPanelState {
        StudyNotesPanelState(
            notes: notes[sessionID],
            progress: progress[sessionID],
            error: errors[sessionID],
            hasKey: hasKey
        )
    }

    /// 导出用的 Markdown。和界面上渲染的是**同一份数据**，不是同一段代码——
    /// 界面走 `MarkdownWebView`，导出走 `StudyNotesMarkdown`
    func markdown(sessionID: UUID) -> String? {
        notes[sessionID].map(StudyNotesMarkdown.render)
    }

    // MARK: - 生成

    /// 跑一次生成并落盘。
    ///
    /// 返回 `false` = 这一次没跑（该会话已经在跑）。**不做任何界面提示**：
    /// 「已经在跑」不是失败，用户看到的是进度条还在动
    @discardableResult
    func generate(session: RecordingSession, glossary: [GlossaryEntry]) async -> Bool {
        let id = session.id
        guard !running.contains(id) else { return false }

        running.insert(id)
        errors[id] = nil
        progress[id] = StudyNotesProgress(
            sliceIndex: 0, sliceCount: 0, startedAt: Date()
        )
        defer {
            running.remove(id)
            progress[id] = nil
        }

        do {
            let outcome = try await generateHook(
                session,
                glossary,
                { [weak self] index, count in
                    // 回到主 actor 再改状态：回调是从 generate 的线程上来的
                    await self?.updateProgress(sessionID: id, index: index, count: count)
                }
            )
            notes[id] = outcome.notes
            try StudyNotesStorage.save(outcome.notes, in: directory)
        } catch {
            errors[id] = error.localizedDescription
            // 课后笔记失败原本只落在 `errors[id]` 里。它花钱、要联网、
            // 而且是**录完自动跑**的（用户此刻多半已经合上电脑走了）——
            // 第二天看到「没有笔记」时，除了这条日志没有任何线索
            DiagnosticLog.error(.notes, "课后笔记生成失败", fields: [
                .init("sessionId", id),
                .init("原因", error.localizedDescription),
            ])
        }
        return true
    }

    /// 自动跑一次（拍板 2c）。
    ///
    /// 触发条件三条，缺一不可：
    ///   · 这条会话**还没有笔记**——有笔记就说明用户要么生成过了、要么手工
    ///     留了一份，自动跑会把它覆盖掉；
    ///   · 还没读过磁盘。**先 `load` 再判**：只看内存里的字典会漏掉
    ///     「上次开 App 时生成的」那种情况，于是每转录一次就多花一次钱；
    ///   · 配了密钥。没配就没法跑，这里直接返回——**不报错**：
    ///     用户压根没发起这个动作，弹一条红字是替他决定他该关心什么
    ///
    /// 「静默失败不阻断主流程」的含义：**不弹窗、不抛错、不打断录音收尾**。
    /// 失败仍然记进 `errors`——那不是「静默吞掉」，是留给详情页显示的：
    /// 用户打开那条录音时会看到「自动生成失败：…」和一个重试按钮。
    /// 把错误丢掉才是静默，而静默的代价是用户永远不知道他的笔记为什么没生成
    func autoGenerateIfNeeded(session: RecordingSession, glossary: [GlossaryEntry]) {
        let id = session.id
        load(sessionID: id)
        guard notes[id] == nil, hasKey, !running.contains(id) else { return }

        Task { await generate(session: session, glossary: glossary) }
    }

    /// 进度回调的落点。`sliceIndex` 从 1 起（`generate` 那侧保证），
    /// 这里不改它的语义，只把它和起点一起装进 `StudyNotesProgress`
    private func updateProgress(sessionID: UUID, index: Int, count: Int) {
        let started = progress[sessionID]?.startedAt ?? Date()
        progress[sessionID] = StudyNotesProgress(
            sliceIndex: index, sliceCount: count, startedAt: started
        )
    }

    // MARK: - 导出

    struct ExportResult {
        var message: String
        var failed: Bool
    }

    /// 导出成 Markdown 文件。
    ///
    /// **落盘那一步复用 `NotesExporter.write`**，不在这里再写一份文件写入：
    /// 那条路径 2026-09-24 出过「点了导出生成不了文件」的事故，之后才抽出
    /// `NotesExporter` 并配了 `--export-notes-selftest`。这里另写一份等于
    /// 把修好的那条路绕开，还没人看得见
    ///
    /// 返回 `nil` = 用户取消了保存面板。**取消不是失败**，不该报红
    func export(sessionID: UUID) -> ExportResult? {
        guard let notes = notes[sessionID] else {
            return ExportResult(message: NotesExportError.emptyNotes.errorDescription ?? "没有笔记", failed: true)
        }

        // 面板弹出前把 App 带到前台：不是最前的时候 runModal 出来的面板
        // 可能落到别的窗口后面，用户看到的同样是「点了没反应」（同 NotesStore）
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.title = "导出课后笔记"
        panel.nameFieldStringValue = NotesExporter.defaultFileName(for: notes.generatedAt)
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try NotesExporter.write(StudyNotesMarkdown.render(notes), to: url)
            return ExportResult(message: "已导出到 \(url.path)", failed: false)
        } catch {
            return ExportResult(message: error.localizedDescription, failed: true)
        }
    }
}

// MARK: - 离线自检

extension StudyNotesStore {

    struct SelfTestResult {
        var lines: [String] = []
        var passed = 0
        var failed = 0
    }

    /// 打桩的生成器。和 `StudyNotesService` 自检里那个 `StubModel` 同一个形状：
    /// 计数器和可配置的产出/错误都是一次调用就能读写的状态，而 `Generate` 是
    /// `@Sendable`，所以拿一把锁封起来并显式承诺
    private final class StubGenerator: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var outcome: Result<StudyNotesOutcome, any Error>

        init(outcome: Result<StudyNotesOutcome, any Error>) {
            self.outcome = outcome
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        /// 同步方法里上锁：`NSLock.lock()` 在 **async** 上下文里是编译不过的
        /// （Swift 6 会拒绝），所以临界区必须待在同步函数里
        private func bump() -> Result<StudyNotesOutcome, any Error> {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return outcome
        }

        func call(
            _ session: RecordingSession,
            _ glossary: [GlossaryEntry],
            _ onSlice: StudyNotesService.ProgressHook?
        ) async throws -> StudyNotesOutcome {
            let result = bump()
            // 真的报一次进度：不报的话 `updateProgress` 这条路径一次都没被跑过，
            // 而它是「生成中」那一档唯一的数据来源
            await onSlice?(1, 1)
            return try result.get()
        }
    }

    /// `--study-notes-ui-selftest` 的第二组。
    ///
    /// **离线**：模型那一步是打桩的，不联网、不花钱、不加载模型、不发声。
    /// 写盘在临时目录里，真实的 `study-notes/` 一个字都不碰。
    ///
    /// 这一组钉的是 2c 那三条闸——「已有笔记不覆盖」「同一会话不许并发跑两次」
    /// 「没 key 不跑」。它们全是**否命题**（「不许发生什么」），不测的话，
    /// 把 `guard` 删掉界面上一点异常都看不出来，只是账单和用户数据悄悄变了
    static func selfTest() async -> SelfTestResult {
        var r = SelfTestResult()
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { r.passed += 1; r.lines.append("  ✅ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
            else { r.failed += 1; r.lines.append("  ❌ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ct-study-notes-store-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            check(false, "准备临时目录", "\(error.localizedDescription)")
            return r
        }

        // 夹具：一条有几个片段的会话（内容长度无所谓——模型是打桩的）
        let partID = UUID()
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let session = RecordingSession(
            id: UUID(),
            startedAt: started,
            updatedAt: started,
            parts: [
                RecordingPart(
                    id: partID,
                    fileName: nil,
                    startedAt: started,
                    durationMillis: 120_000,
                    offsetMillis: 0,
                    segments: [
                        TranscriptSegment(
                            text: "本节讲梯度下降",
                            isFinal: true,
                            startTimeMillis: 0,
                            endTimeMillis: 4_000,
                            languages: ["zh-CN"]
                        )
                    ]
                )
            ]
        )

        func makeNotes(_ sessionID: UUID) -> StudyNotes {
            StudyNotes(
                sessionID: sessionID,
                generatedAt: Date(timeIntervalSince1970: 1_800_000_100),
                model: "stub",
                items: [
                    StudyItem(
                        kind: .summary, text: "打桩产出",
                        anchors: [Anchor(partID: partID, segmentID: UUID(), startMillis: 1_000)]
                    )
                ],
                usage: nil
            )
        }

        func makeOutcome(_ sessionID: UUID) -> StudyNotesOutcome {
            StudyNotesOutcome(
                notes: makeNotes(sessionID),
                stats: StudyNotesStats(
                    sliceCount: 1, malformedSlices: 0,
                    countsByKind: [.summary: 1], rejected: [],
                    usage: StudyNotesUsage(
                        promptTokens: 1, completionTokens: 1, cacheHitTokens: 0,
                        sliceCount: 1, elapsedSeconds: 0.1, estimatedYuan: 0
                    )
                )
            )
        }

        // ① 正常跑一遍：落盘、读回、内存里也有
        let stub = StubGenerator(outcome: .success(makeOutcome(session.id)))
        let store = StudyNotesStore(directory: root, keyPresent: true, generate: stub.call)
        let ran = await store.generate(session: session, glossary: [])
        check(ran, "正常跑：这一次真的跑了")
        check(stub.callCount == 1, "正常跑：模型只调了一次", "调了 \(stub.callCount) 次")
        check(store.notes[session.id] != nil, "正常跑：内存里有笔记")
        check(StudyNotesStorage.load(sessionID: session.id, in: root) != nil,
              "正常跑：磁盘上真写下来了")
        // 进度在跑完之后必须收干净，否则详情页会一直显示「正在生成」
        check(store.progress[session.id] == nil, "正常跑：跑完之后进度清空（不该一直转圈）")
        check(store.state(sessionID: session.id).phase == .ready,
              "正常跑：档位变成「有笔记」", "\(store.state(sessionID: session.id).phase)")

        // ② 同一会话并发跑两次 → 只有一次真的跑（1400 那条教训：同一资源两个写者）
        let raceStub = StubGenerator(outcome: .success(makeOutcome(session.id)))
        let raceStore = StudyNotesStore(directory: root, keyPresent: true, generate: raceStub.call)
        // 同一个 id 的另一份实例：并发闸认的是 id，不是对象身份
        let other = RecordingSession(
            id: session.id, startedAt: session.startedAt,
            updatedAt: session.updatedAt, parts: session.parts
        )
        async let first = raceStore.generate(session: session, glossary: [])
        async let second = raceStore.generate(session: other, glossary: [])
        let results = await [first, second]
        check(results.filter { $0 }.count == 1,
              "并发闸：同一会话同时调两次，只有一次真的跑",
              "两次的返回：\(results)")
        check(raceStub.callCount == 1,
              "并发闸：模型只被调了一次（第二次没花钱）", "调了 \(raceStub.callCount) 次")

        // ③ 已经有笔记时自动跑**不覆盖**
        let existingStub = StubGenerator(outcome: .success(makeOutcome(session.id)))
        let existingStore = StudyNotesStore(directory: root, keyPresent: true, generate: existingStub.call)
        existingStore.autoGenerateIfNeeded(session: session, glossary: [])
        // 自动跑起的是 Task，这里给它一点时间；它该做的是一件事都不做
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(existingStub.callCount == 0,
              "自动跑·已有笔记：一次模型都没调（不覆盖用户已有的产出）",
              "调了 \(existingStub.callCount) 次")

        // ④ 没笔记 + 有 key → 自动跑真的会跑
        let freshDirectory = root.appendingPathComponent("fresh")
        let freshStub = StubGenerator(outcome: .success(makeOutcome(session.id)))
        let freshStore = StudyNotesStore(
            directory: freshDirectory, keyPresent: true, generate: freshStub.call
        )
        freshStore.autoGenerateIfNeeded(session: session, glossary: [])
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(freshStub.callCount == 1,
              "自动跑·还没有笔记：自己跑了一次", "调了 \(freshStub.callCount) 次")

        // ⑤ 没 key → 自动跑不跑，且**不报错**（用户没发起这个动作，不该被红字骂）
        let noKeyDirectory = root.appendingPathComponent("nokey")
        let noKeyStub = StubGenerator(outcome: .success(makeOutcome(session.id)))
        let noKeyStore = StudyNotesStore(
            directory: noKeyDirectory, keyPresent: false, generate: noKeyStub.call
        )
        noKeyStore.autoGenerateIfNeeded(session: session, glossary: [])
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(noKeyStub.callCount == 0,
              "自动跑·没 key：一次模型都没调", "调了 \(noKeyStub.callCount) 次")
        check(noKeyStore.errors[session.id] == nil,
              "自动跑·没 key：也没有留下错误（不是失败，是压根没发起）")

        // ⑥ 失败：错误要看得见，**磁盘上不许留下半截**
        let failDirectory = root.appendingPathComponent("fail")
        let failStub = StubGenerator(outcome: .failure(StudyNotesError.allSlicesMalformed(slices: 3)))
        let failStore = StudyNotesStore(
            directory: failDirectory, keyPresent: true, generate: failStub.call
        )
        _ = await failStore.generate(session: session, glossary: [])
        check(failStore.errors[session.id] != nil,
              "失败：错误记下来了（详情页要显示它）", failStore.errors[session.id] ?? "（居然是 nil）")
        check(failStore.notes[session.id] == nil, "失败：内存里没有笔记")
        check(StudyNotesStorage.load(sessionID: session.id, in: failDirectory) == nil,
              "失败：磁盘上什么都没留下")
        check(failStore.state(sessionID: session.id).phase
                == .failed(message: failStore.errors[session.id] ?? ""),
              "失败：档位变成「失败」", "\(failStore.state(sessionID: session.id).phase)")

        return r
    }
}
