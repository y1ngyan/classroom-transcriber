import FluidAudio
import Foundation

/// `download` 是唯一允许联网的子命令（设计稿 §2.2）。
///
/// 只下载 + 写 revision marker，**不加载、不编译、不推理**（走 `ModelHub.download`，
/// 而不是 `OfflineDiarizerModels.load`）：这样「下载」这一步不会顺带跑任何预测，
/// 也不会触发 `prepareModels` 在失败时的 purge。
enum DownloadCommand {
    static func run(_ options: DownloadOptions) async -> Int32 {
        ModelHub.offlineMode = false
        let modelsDir = URL(fileURLWithPath: options.modelsDir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            try await ModelHub.download(.diarizer, to: modelsDir, variant: "offline")
        } catch {
            Diagnostics.stderr("modelLoadFailed: 下载失败：\(error.localizedDescription)")
            return HelperExitCode.modelLoadFailed.rawValue
        }

        let probe = ModelPresence.evaluate(modelsDir: modelsDir)
        guard probe.ready else {
            Diagnostics.stderr(
                "modelMissing: 下载后仍缺 \(probe.missing.joined(separator: ", "))（\(probe.repoPath)）")
            return HelperExitCode.modelMissing.rawValue
        }
        Diagnostics.stderr("download ok: \(probe.repoPath)")
        return HelperExitCode.success.rawValue
    }
}
