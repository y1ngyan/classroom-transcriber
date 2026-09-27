import Foundation
import Observation

/// 从转录文本中切出可核查的完整句子。
///
/// 只处理 final 的 segment——未定稿的文字还在被模型改写，
/// 拿去核查既浪费请求也会得到错误结论。
enum ClaimExtractor {

    private static let terminators: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";", "\n"]

    /// 一句话短于这个长度就不值得核查（多半是「对」「嗯」「好的」这类）
    private static let minimumLength = 8

    static func extract(from text: String) -> [String] {
        var sentences: [String] = []
        var buffer = ""

        for character in text {
            if terminators.contains(character) {
                buffer.append(character)
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= minimumLength {
                    sentences.append(trimmed)
                }
                buffer = ""
            } else {
                buffer.append(character)
            }
        }

        // 结尾没有标点的残余部分，够长也算一句
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count >= minimumLength {
            sentences.append(tail)
        }

        return sentences
    }
}

/// 一段转录的整体核查状态。
///
/// 核查粒度其实是「句」（一段可能抽出多句，各自独立核查），但用户
/// 在转录列表里看到的是「段」——这是把多句结果汇成一个段级状态
/// 的规则，放在这里而不是视图里，因为「这段整体什么情况」是数据语义
enum SegmentCheckState: Equatable {
    /// 没提交过核查
    case none
    /// 有任意一句还在跑
    case checking
    /// 没有在跑的了，但有句子失败
    case failed
    /// 全部完成，value 是各句里最严重的结论
    case done(FactCheckResult.Status)
}

/// 核查结果的存储，按 segmentID 关联。
@MainActor
@Observable
final class FactCheckStore {

    private(set) var results: [FactCheckResult] = []
    private(set) var isConfigured: Bool = AppConfig.deepSeekAPIKey != nil

    /// 键是 `segmentID|句子`——同一段转录可能抽出多句，各自独立核查
    private var index: [String: Int] = [:]
    private var inFlight: Set<String> = []

    var pendingCount: Int {
        results.filter { $0.phase == .searching || $0.phase == .analyzing }.count
    }

    /// 这一段整体是什么状态。
    ///
    /// 汇总规则（按优先级依次判定，顺序本身就是规则）：
    /// 1. 有任意一句还在跑 → `.checking`。**这一条排最前**：一段里两句，
    ///    一句已出结论、一句还在跑，此时报结论会让用户以为整段查完了，
    ///    而实际上后面还会冒出新的结论。
    /// 2. 有任意一句失败 → `.failed`。失败比结论更该被看见：用户点了核查
    ///    却没看到任何结果，如果不报失败，他会以为这段「没问题」。
    /// 3. 全部完成 → `.done(最严重的结论)`。取最严重而不是最常见：
    ///    一段里有一句存疑、三句已证实，这段整体就该是「存疑」——
    ///    用户扫一眼列表时的判断是「这段能不能信」，不是「多数句子如何」。
    /// 4. 一句都没提交过 → `.none`。
    func state(for segmentID: UUID) -> SegmentCheckState {
        let mine = results.filter { $0.segmentID == segmentID }
        guard !mine.isEmpty else { return .none }

        if mine.contains(where: { $0.phase == .searching || $0.phase == .analyzing }) {
            return .checking
        }
        if mine.contains(where: { if case .failed = $0.phase { return true }; return false }) {
            return .failed
        }

        // 严重度：存疑 > 无法核实 > 已证实。disputed 排最前是因为它
        // 明确指向「这条内容是错的」，另两个都不含此意
        let severity: [FactCheckResult.Status] = [.disputed, .unverifiable, .verified]
        for level in severity where mine.contains(where: { $0.phase == .done && $0.status == level }) {
            return .done(level)
        }
        return .none
    }

    /// 这一段有没有已完成的结论（决定悬停按钮显示「核查」还是「重新核查」）
    func hasResolvedCheck(for segmentID: UUID) -> Bool {
        results.contains { result in
            guard result.segmentID == segmentID else { return false }
            if case .done = result.phase { return true }
            return false
        }
    }

    /// 提交一段转录文本，抽取句子后逐句核查
    func submit(segment: TranscriptSegment) {
        guard segment.isFinal else { return }
        for claim in ClaimExtractor.extract(from: segment.text) {
            submit(claim: claim, segmentID: segment.id)
        }
    }

    func submit(claim: String, segmentID: UUID) {
        let key = "\(segmentID.uuidString)|\(claim)"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        // 先插入占位结果，UI 立刻能看到「核查中」
        let placeholder = FactCheckResult(
            segmentID: segmentID,
            claim: claim,
            status: .unverifiable,
            explanation: "",
            confidence: 0,
            sources: [],
            phase: .searching
        )
        insert(placeholder)

        Task {
            do {
                let result = try await FactCheckService.check(
                    segmentID: segmentID,
                    claim: claim
                ) { [weak self] phase in
                    Task { @MainActor in self?.updatePhase(segmentID: segmentID, claim: claim, phase: phase) }
                }
                replace(segmentID: segmentID, claim: claim, with: result)
            } catch {
                updatePhase(
                    segmentID: segmentID,
                    claim: claim,
                    phase: .failed(error.localizedDescription)
                )
                // API 调用失败。**只记错误本身，不记请求体**——上面那句
                // `claim` 是这一段的待核查主张，属于用户正文，不进日志。
                // 要定位是哪一段，`segmentId` 够用了
                DiagnosticLog.error(.network, "联网核查失败", fields: [
                    .init("segmentId", segmentID),
                    .init("原因", error.localizedDescription),
                ])
            }
            inFlight.remove(key)
        }
    }

    func retry(_ result: FactCheckResult) {
        remove(segmentID: result.segmentID, claim: result.claim)
        submit(claim: result.claim, segmentID: result.segmentID)
    }

    func clear() {
        results.removeAll()
        index.removeAll()
        inFlight.removeAll()
    }

    // MARK: - 自检

    /// 离线自检：只验「按段汇总状态」这条纯规则，不发任何网络请求。
    ///
    /// 为什么要专测这条：核查结果其实是「句」粒度的，而用户在列表里看到
    /// 的是「段」。这个汇总是两者之间唯一的转换点，规则错了的表现是
    /// 「一段里有一句存疑，列表却显示已证实」——用户据此判断内容可信度，
    /// 错了比不显示更糟。
    static func selfTest() -> [String] {
        var lines: [String] = ["核查状态汇总自检（纯本地，不发网络请求）"]
        var allPassed = true

        func check(_ name: String, _ actual: SegmentCheckState, _ expect: SegmentCheckState) {
            let ok = actual == expect
            allPassed = allPassed && ok
            lines.append("  \(ok ? "✅" : "❌") \(name)：\(describe(actual))（期望 \(describe(expect))）")
        }

        func make(_ id: UUID, _ claim: String, phase: FactCheckResult.Phase,
                  status: FactCheckResult.Status = .unverifiable) -> FactCheckResult {
            FactCheckResult(segmentID: id, claim: claim, status: status,
                            explanation: "", confidence: 0, sources: [], phase: phase)
        }

        let store = FactCheckStore()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID()

        func add(_ result: FactCheckResult) { store.results.append(result) }

        // 1. 没提交过
        check("未提交过", store.state(for: a), .none)

        // 2. 有任意一句在跑 → checking（哪怕另一句已有结论）。
        //    这是最要紧的一条：报结论会让用户以为整段查完了
        add(make(a, "句一", phase: .done, status: .verified))
        add(make(a, "句二", phase: .searching))
        check("一句完成 + 一句在跑", store.state(for: a), .checking)

        add(make(b, "句一", phase: .analyzing))
        check("单句在跑", store.state(for: b), .checking)

        // 3. 有失败 → failed（用户点了核查却看不到结果，必须让他知道）
        add(make(c, "句一", phase: .done, status: .verified))
        add(make(c, "句二", phase: .failed("超时")))
        check("一句完成 + 一句失败", store.state(for: c), .failed)

        // 4. 全部完成 → 取最严重
        add(make(d, "句一", phase: .done, status: .verified))
        add(make(d, "句二", phase: .done, status: .verified))
        check("全部已证实", store.state(for: d), .done(.verified))

        add(make(e, "句一", phase: .done, status: .verified))
        add(make(e, "句二", phase: .done, status: .disputed))
        add(make(e, "句三", phase: .done, status: .unverifiable))
        check("已证实 + 存疑 + 无法核实", store.state(for: e), .done(.disputed))

        add(make(f, "句一", phase: .done, status: .verified))
        add(make(f, "句二", phase: .done, status: .unverifiable))
        check("已证实 + 无法核实", store.state(for: f), .done(.unverifiable))

        // 5. 段之间互不串扰
        check("另一段不受影响", store.state(for: UUID()), .none)

        // 6. hasResolvedCheck：决定按钮措辞
        let g = UUID()
        add(make(g, "句一", phase: .searching))
        let pendingOnly = store.hasResolvedCheck(for: g)
        lines.append("  \(pendingOnly ? "❌" : "✅") 只有核查中的段不算「已核查过」：\(pendingOnly)")
        allPassed = allPassed && !pendingOnly

        let resolved = store.hasResolvedCheck(for: d)
        lines.append("  \(resolved ? "✅" : "❌") 已完成结论的段算「已核查过」：\(resolved)")
        allPassed = allPassed && resolved

        lines.append(allPassed ? "✅ 核查状态汇总自检通过" : "❌ 核查状态汇总自检未通过")
        return lines
    }

    private static func describe(_ state: SegmentCheckState) -> String {
        switch state {
        case .none: return "未核查"
        case .checking: return "核查中"
        case .failed: return "失败"
        case .done(let status): return "完成(\(status.label))"
        }
    }

    // MARK: - 内部

    private func key(segmentID: UUID, claim: String) -> String {
        "\(segmentID.uuidString)|\(claim)"
    }

    private func insert(_ result: FactCheckResult) {
        index[key(segmentID: result.segmentID, claim: result.claim)] = results.count
        results.append(result)
    }

    private func replace(segmentID: UUID, claim: String, with result: FactCheckResult) {
        guard let position = index[key(segmentID: segmentID, claim: claim)] else {
            insert(result)
            return
        }
        results[position] = result
    }

    private func updatePhase(segmentID: UUID, claim: String, phase: FactCheckResult.Phase) {
        guard let position = index[key(segmentID: segmentID, claim: claim)] else { return }
        results[position].phase = phase
    }

    private func remove(segmentID: UUID, claim: String) {
        guard let position = index[key(segmentID: segmentID, claim: claim)] else { return }
        results.remove(at: position)
        reindex()
    }

    private func reindex() {
        index = Dictionary(
            uniqueKeysWithValues: results.enumerated().map {
                (key(segmentID: $1.segmentID, claim: $1.claim), $0)
            }
        )
    }
}
