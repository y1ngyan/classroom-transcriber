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

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("glossary.json")
    }()

    static var storeFilePath: String { storeURL.path }

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
