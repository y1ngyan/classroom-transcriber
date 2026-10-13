import Foundation
import Observation

/// 术语表的增删改 + 一轮校正的执行与落地。
@MainActor
@Observable
final class GlossaryStore {

    /// 刻意不加 `private(set)`：视图用 `ForEach($store.entries)` 逐行绑定编辑，
    /// 需要可写。改动由视图层的 `onChange(of: store.entries)` 触发 `persist()` 落盘。
    var entries: [GlossaryEntry] = []
    /// 最近一次校正的前后对照，UI 用它展示「改了什么」
    private(set) var corrections: [GlossaryCorrection] = []
    private(set) var isRunning = false
    private(set) var statusMessage = ""

    /// 从转录里提出来的候选术语，等用户逐条挑。
    /// 不直接进 `entries`——提取是模型猜的，而 `entries` 会直接灌进识别器，
    /// 猜错一个词就是把识别器往错的方向推一整场课。必须过一道人眼。
    private(set) var candidates: [GlossaryEntry] = []
    private(set) var isExtracting = false

    /// 候选是从哪来的。两种来源共用同一套「逐条采纳」交互，但说明文字不能共用：
    /// - `.extracted` 是**这场课真正讲到**的词，录完之后才能拿到；
    /// - `.web` 是**这门课通用**的术语，联网检索来的，只能在开录前用
    ///   （它是先验）。两者对用户的含义完全不同，界面必须分开讲。
    enum CandidateSource: Equatable {
        case extracted
        case web
    }
    private(set) var candidateSource: CandidateSource = .extracted

    /// 联网生成词表这一段的状态。和 `isExtracting` 分开，
    /// 因为两者的前置条件与耗时完全不同（联网要检索 + 两次模型调用）
    private(set) var isSuggesting = false
    /// 上一次联网生成实际用了哪些检索式。给用户看「它到底搜了什么」——
    /// 结果不对时，第一眼看的就是这个
    private(set) var lastQueries: [String] = []

    /// 校正后的片段，等用户确认再写回引擎。
    /// 不直接改引擎是因为模型偶尔会顺手改对的地方，得让人看一眼。
    private(set) var pending: [TranscriptSegment]?

    var isConfigured: Bool { AppConfig.deepSeekAPIKey != nil }
    var hasPending: Bool { pending != nil }

    /// 灌给识别器的自定义词表（见 `TranscriptionEngine.contextualTerms`）。
    ///
    /// **只给 `term`，不给 aliases。** aliases 装的是「同一个词的错误拼写」
    /// （Machin learning 之类），把它们当词表喂进去，等于在教识别器往错的
    /// 方向偏——词表的作用是抬高正确写法的先验，不是复现历史错误。
    var contextualTerms: [String] {
        entries
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `nonisolated`：下面两条非隔离的读取器（`termsFromDisk` / `promptResolution`）
    /// 要用它，而它们必须在没有主 actor 的无头入口里可用
    nonisolated private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("glossary.json")
    }()

    /// `nonisolated`：无头入口（自检、`--retranscribe`）没有主 actor 上下文，
    /// 但它们要能把这个路径打出来——「词表从哪读的」是这个功能的一部分解释，
    /// 说不出来就没法排查「为什么它没起作用」
    nonisolated static var storeFilePath: String { storeURL.path }

    /// 从磁盘读术语（只要 `term`，去空白、丢掉空串）。**给无头入口和
    /// 文件链路用**——`--retranscribe` 和文件转录不启动界面，没有 store 实例，
    /// 但它们必须看到和界面**同一份**词表：不然「A/B 探针测出来的效果」
    /// 和「用户点重转实际跑的效果」是两份词表，探针的数字就不再描述那条路。
    ///
    /// 文件不存在 → 返回空，**不返回 `GlossaryDefaults.entries`**。
    /// 界面首次启动会种下默认词表，所以正常机器上这个文件总是在的；
    /// 而这里回落到默认词表等于**替用户决定**「这节课用的是那批内置词」，
    /// 而他可能从没打开过术语表页面。宁可返回空（= 不送 prompt，
    /// 与今天的行为一致），也不要凭空给一段他没选过的先验。
    nonisolated static func termsFromDisk() -> [String] {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([GlossaryEntry].self, from: data)
        else { return [] }
        return decoded
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// **「本次录音的术语表 → initial_prompt」的唯一出处。**
    /// 实时链路（`TranscriptionEngine`）、文件链路（`WhisperFileTranscription`）、
    /// 无头入口（`--retranscribe`）都调它，谁都不许自己拼那串字符串——
    /// 拼法一旦分家，探针量出来的效果就不描述实际跑的那条路。
    /// - Parameter tokenCount: 分词器的计数函数（生产传 `WhisperEngine.promptTokenCount`）。
    ///   **必须从外面传进来**：磁盘这层没有模型，而「装得下几条」只有模型算得出来。
    ///   传 `{ $0.count }`（1 token/字）只该出现在自检里
    /// - Parameter enabled: 送不送。`nil`（生产）= 读 `AppConfig.glossaryPromptEnabled`，
    ///   也就是用户在设置里那个开关。**无头探针不许走 `nil`**——见下。
    ///
    /// **为什么这里必须留一个显式覆盖口**（2026-10-13 被真事抓出来的）：
    /// A/B 探针的「开」那一臂原先直接走 `nil`，等于「跟着 App 缺省走」。
    /// 缺省是 true 的时候它碰巧是对的；缺省一翻成 false，`--glossary-prompt`
    /// 就**静默退化成了关**——两臂跑出同一份结果（13 段 / 141 字，一模一样），
    /// 而报告只说「术语前移：关」，探针的三条判据同时红。
    /// 量尺不能跟着被测对象的缺省走：探针要的「开」是**我让你开**，
    /// 不是「App 现在恰好开着」。所以探针显式传 `true`。
    nonisolated static func promptResolution(
        tokenCount: (String) -> Int,
        enabled: Bool? = nil
    ) -> GlossaryPrompt.Resolution {
        let terms = termsFromDisk()
        return GlossaryPrompt.resolve(
            terms: terms,
            enabled: enabled ?? AppConfig.glossaryPromptEnabled,
            sourceNote: "磁盘术语表 \(terms.isEmpty ? "读不出来或为空" : "\(terms.count) 条")",
            tokenCount: tokenCount
        )
    }

    init() {
        load()
    }

    // MARK: - 术语表维护

    func addEntry() {
        entries.append(GlossaryEntry(term: "", aliases: [], note: ""))
        persist()
    }

    func remove(_ entry: GlossaryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func resetToDefaults() {
        entries = GlossaryDefaults.entries
        persist()
        statusMessage = "已恢复默认术语表（\(entries.count) 个）"
    }

    /// 载入一个课程预设。
    ///
    /// **合并而不是替换。** 用户手加的条目、上一个预设里改过的条目都是
    /// 他的劳动成果，换一包词就整个抹掉太粗暴；而按 term 去重之后，
    /// 合并的结果是可预期的：不会重复，也不会丢东西。
    /// 真要清空走「恢复默认」，那是一个用户主动选择的动作。
    func apply(_ preset: CoursePreset) {
        let existing = Set(entries.map { $0.term.lowercased() })
        let fresh = preset.entries.filter { !existing.contains($0.term.lowercased()) }

        entries.append(contentsOf: fresh)
        persist()

        // 把预设的说明也念一遍：菜单里只能塞下名字，
        // 载入之后得让用户确认自己选的这包词到底覆盖什么
        let skipped = preset.entries.count - fresh.count
        let tail = skipped == 0
            ? "新增 \(fresh.count) 个术语"
            : "新增 \(fresh.count) 个，跳过 \(skipped) 个已有"
        statusMessage = "已载入「\(preset.name)」（\(preset.summary)）· \(tail)"
    }

    // MARK: - 从转录内容提词

    /// 从当前转录里提候选术语。
    ///
    /// 这条路是为「没有对应预设的课」准备的兜底，**不是默认路径**：
    /// 提取发生在录完之后，而术语表要在开录前就位，所以提出来的词
    /// 救不了它自己那场课的识别阶段（能救事后校正，能救下一场同类课）。
    /// 界面上必须把这句话说出来，否则用户会以为点一下就把录坏的修好了。
    func extract(segments: [TranscriptSegment]) async {
        guard !isExtracting else { return }
        guard isConfigured else {
            statusMessage = "❌ DeepSeek 密钥未配置"
            return
        }
        guard !segments.isEmpty else {
            statusMessage = "❌ 还没有转录内容"
            return
        }

        isExtracting = true
        candidateSource = .extracted
        statusMessage = "正在从转录里提取术语…"
        defer { isExtracting = false }

        do {
            let found = try await GlossaryService.extractTerms(from: segments)
            let existing = Set(entries.map { $0.term.lowercased() })
            candidates = found.filter { !existing.contains($0.term.lowercased()) }

            if candidates.isEmpty {
                statusMessage = "提取完成 · 没有发现词表里没有的术语"
            } else {
                statusMessage = "提取完成 · \(candidates.count) 个候选待确认"
            }
        } catch {
            candidates = []
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    /// 联网生成这门课的术语候选：规划检索式 → 检索 → 抽成条目。
    ///
    /// **编排放在 store 而不是 service 里**：每一阶段的进度都要写进
    /// `statusMessage`，而那是 MainActor 上的状态。放进 service 就得跨隔离
    /// 传闭包，得不偿失。service 那边保持「纯函数 + 三段 async 原语」。
    ///
    /// 这是**备课动作**：术语表是喂给识别器的先验，音频流一开始就改不了。
    /// 所以它和「从转录提取」的差别不是实现，而是**生效时机**——界面上的
    /// 说明文字必须把这件事讲清楚（见 `candidateSource`）。
    func suggestFromWeb(course: String) async {
        guard !isSuggesting else { return }
        guard isConfigured else {
            statusMessage = "❌ DeepSeek 密钥未配置"
            return
        }
        guard AppConfig.searchAPIKey != nil else {
            statusMessage = "❌ 搜索 API 密钥未配置——联网生成要用它检索"
            return
        }

        let cleaned = GlossarySuggestionService.cleanCourseName(course)
        guard !cleaned.isEmpty else {
            statusMessage = "❌ 先填一个课程名"
            return
        }

        isSuggesting = true
        candidateSource = .web
        lastQueries = []
        defer { isSuggesting = false }

        do {
            statusMessage = "正在规划检索式…"
            let queries = try await GlossarySuggestionService.planQueries(course: cleaned)
            lastQueries = queries

            statusMessage = "正在联网检索（\(queries.count) 条检索式）…"
            // 全都失败时会抛 searchUnavailable（通道不通），与「搜到了但没内容」
            // 分开——前者用户该去查网络，后者才是换个说法重试。
            let hits = try await GlossarySuggestionService.search(queries)
            guard !hits.isEmpty else {
                throw GlossarySuggestionService.SuggestionError.noSearchResults
            }

            statusMessage = "正在从 \(hits.count) 条资料里提取术语…"
            let found = try await GlossarySuggestionService.extract(
                hits: hits,
                course: cleaned,
                existingTerms: entries.map(\.term)
            )

            candidates = found
            if candidates.isEmpty {
                statusMessage = "「\(cleaned)」没提取到词表里没有的术语（检索到 \(hits.count) 条资料）"
            } else {
                statusMessage = "「\(cleaned)」生成 \(candidates.count) 个候选 · 逐条看一眼再采纳"
            }
        } catch {
            candidates = []
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    /// 采纳一条候选
    func accept(_ candidate: GlossaryEntry) {
        candidates.removeAll { $0.id == candidate.id }
        guard !entries.contains(where: {
            $0.term.lowercased() == candidate.term.lowercased()
        }) else { return }

        entries.append(candidate)
        persist()
    }

    func acceptAllCandidates() {
        let existing = Set(entries.map { $0.term.lowercased() })
        let fresh = candidates.filter { !existing.contains($0.term.lowercased()) }
        entries.append(contentsOf: fresh)
        candidates = []
        persist()
        statusMessage = "已采纳 \(fresh.count) 个术语"
    }

    func dismissCandidates() {
        candidates = []
        statusMessage = "已忽略本次提取结果"
    }

    /// 视图里用 `ForEach($store.entries)` 直接改数组，改完调这里落盘
    func persist() {
        do {
            try FileManager.default.createDirectory(
                at: Self.storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: Self.storeURL, options: .atomic)
        } catch {
            statusMessage = "❌ 术语表保存失败: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([GlossaryEntry].self, from: data)
        else {
            // 首次启动：种下实测里真被转错的那批词
            entries = GlossaryDefaults.entries
            persist()
            return
        }
        entries = decoded
    }

    // MARK: - 校正

    func run(segments: [TranscriptSegment]) async {
        guard !isRunning else { return }

        guard isConfigured else {
            statusMessage = "❌ DeepSeek 密钥未配置"
            return
        }
        guard !entries.isEmpty else {
            statusMessage = "❌ 术语表是空的，先加几个术语"
            return
        }
        guard !segments.isEmpty else {
            statusMessage = "❌ 还没有转录内容"
            return
        }

        isRunning = true
        corrections = []
        pending = nil
        statusMessage = "正在校正术语…"
        defer { isRunning = false }

        do {
            let outcome = try await GlossaryService.correct(segments, entries: entries)
            corrections = outcome.corrections

            if outcome.changedCount == 0 {
                statusMessage = "校正完成 · 没有需要修改的地方"
            } else {
                pending = outcome.segments
                statusMessage = "校正完成 · \(outcome.changedCount) 处改动，确认后应用到转录"
            }
        } catch {
            corrections = []
            pending = nil
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    /// 把校正结果写回转录引擎
    func apply(to engine: TranscriptionEngine) {
        guard let pending else { return }
        engine.applyCorrections(pending)
        self.pending = nil
        statusMessage = "已应用到转录 · \(corrections.count) 处改动"
    }

    func discard() {
        pending = nil
        corrections = []
        statusMessage = "已放弃本次校正"
    }

    func clearStatus() {
        statusMessage = ""
        corrections = []
        pending = nil
    }
}
