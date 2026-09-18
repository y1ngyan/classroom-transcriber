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
