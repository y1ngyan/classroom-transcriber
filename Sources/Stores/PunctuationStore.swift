import Foundation
import Observation

/// LLM 补标点的执行与落地。
///
/// 形态对齐 GlossaryStore.run：用户主动触发（要联网、要花额度，绝不自动跑）、
/// 一次处理整场转录。但**没有 pending/确认那一步**，理由有两个：
/// 一是校验已经保证了「剥掉标点后逐字一致」，模型没有改内容的空间，
/// 预览看到的只会是原文加逗号句号，没有需要人判断的东西；
/// 二是补标点几乎每段都会变，逐条 diff 淹没了真正要看的信息。
/// 校验失败的段在 Service 层就回退原文了，这里只负责照实汇报。
@MainActor
@Observable
final class PunctuationStore {

    private(set) var isRunning = false
    private(set) var statusMessage = ""

    var isConfigured: Bool { AppConfig.deepSeekAPIKey != nil }

    func run(on engine: TranscriptionEngine) async {
        guard !isRunning else { return }
        guard isConfigured else {
            statusMessage = "❌ DeepSeek 密钥未配置"
            return
        }
        guard !engine.segments.isEmpty else {
            statusMessage = "❌ 还没有转录内容"
            return
        }

        isRunning = true
        statusMessage = "正在补标点…"
        defer { isRunning = false }

        do {
            let outcome = try await PunctuationService.punctuate(engine.segments)
            engine.applyCorrections(outcome.segments)

            var parts = ["补标点完成 · 补了 \(outcome.applied) 段"]
            if outcome.skippedShort > 0 {
                parts.append("\(outcome.skippedShort) 段太短跳过")
            }
            if outcome.rejected > 0 {
                parts.append("\(outcome.rejected) 段校验失败保持原文")
            }
            if outcome.applied == 0 && outcome.rejected == 0 {
                parts.append("没有需要改的地方")
            }
            statusMessage = parts.joined(separator: " · ")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    func clearStatus() {
        statusMessage = ""
    }
}
