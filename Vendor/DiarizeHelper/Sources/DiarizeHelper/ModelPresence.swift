import FluidAudio
import Foundation

/// 「模型在不在」的**唯一判定实现**（C-1 裁决 3）。
///
/// probe、diarize、download 三个子命令**只能**调用这里的 `evaluate`；任何一处
/// 都不允许再写一份「文件在不在 / revision marker 对不对」的判定。
///
/// 为什么是复刻而不是直接调用：真正的判定在 FluidAudio `ModelHub.loadModelsOnce`
/// 里，而 `loadModelsOnce`、`ModelCache`、`ModelRegistry.mapRevision` 都是
/// FluidAudio 的 internal（本包只能看到 public API），无法直接调用；同时
/// `probe` 又必须在**不加载、不编译 CoreML 模型**的前提下给出结论。
/// 所以这里逐行复刻 FluidAudio @ `5c51c5c` 的就位判定：
///
/// ```swift
/// // ModelHub.loadModelsOnce(...)
/// let revisionMatches = ModelCache.matchesRevision(at: repoPath, revision: revision)
/// if !revisionMatches || !ModelCache.allModelsExist(at: repoPath, models: effectiveModels) {
///     let missing = revisionMatches
///         ? ModelCache.missingModels(at: repoPath, models: effectiveModels)
///         : effectiveModels.sorted()
///     throw DownloadError.modelMissing(repo: repo.folderName, missing: missing)
/// }
/// ```
///
/// 刻意对齐的细节（都是两边曾经可能分叉的点）：
///   - `matchesRevision`：marker 缺失时**仅** `revision == "main"` 通过；marker 存在
///     但非 UTF-8 或值不等则一律不通过（`ModelCache.matchesRevision`）。
///   - 只看路径是否存在（`allModelsExist`），**不**校验 `.mlmodelc` 内部布局
///     （`coremldata.bin` / `.partial`）。布局坏了属于真正 load 时的 exit 6
///     `modelLoadFailed`，不是 exit 5 `modelMissing`。
///   - revision 不匹配时 `missing` 报**全部** required（FluidAudio 就是这么报的），
///     而不是只报缺的文件——这样 probe 的 JSON 与 diarize 将抛出的
///     `DownloadError.modelMissing.missing` 形状一致。
///
/// 已知的、刻意的假设：本进程从不设置 `ModelRegistry.revisionOverrides`，所以
/// `ModelRegistry.mapRevision(repo.remotePath, default: repo.revision)` 恒等于
/// `Repo.diarizer.revision`。若将来要支持镜像覆盖 revision，必须在这里同步，
/// 否则 probe 与 diarize 会再次分叉。
///
/// 守卫：`--selftest` 里有一条**一致性用例**，对同一个合成模型目录分别走
/// `ModelProbe.inspect`（probe 面）与 `ModelPresence.evaluate`（diarize 面），
/// 断言两者结论必须相同（C-1 裁决 3 的硬要求）。
enum ModelPresence {
    /// revision marker 文件名。复刻 `ModelCache.revisionMarkerName`（internal）。
    /// FluidAudio 升级若改这个常量，这里必须同步；自检的一致性用例会失败提醒。
    static let revisionMarkerName = ".fluidaudio-revision"

    /// `Repo.diarizer` + `variant: "offline"` 真正使用的 required 集合。
    ///
    /// 等于 FluidAudio internal 的
    /// `ModelNames.getRequiredModelNames(for: .diarizer, variant: "offline")`
    /// （该分支直接返回 `ModelNames.OfflineDiarizer.requiredModels`），
    /// 也就是 `OfflineDiarizerModels.load` 传给 `ModelHub.loadModels` 的那一组。
    static let offlineDiarizerRequiredModels = ModelNames.OfflineDiarizer.requiredModels

    struct Verdict: Equatable {
        /// 文件层就位（revision 匹配 + 每个 required 路径都在）。true 不代表能 load 成功。
        var ready: Bool
        /// `<modelsDir>/<Repo.diarizer.folderName>`。
        var repoPath: String
        /// 与 FluidAudio `DownloadError.modelMissing.missing` 同形状、同排序。
        var missing: [String]
        /// revision marker 是否匹配。false 时 `missing` 会是全部 required。
        var revisionOK: Bool
    }

    /// `ModelCache.matchesRevision(at:revision:)` 的等价实现（含 "main" 特例）。
    static func matchesRevision(at repoPath: URL, revision: String) -> Bool {
        let marker = repoPath.appendingPathComponent(revisionMarkerName)
        guard let data = try? Data(contentsOf: marker) else {
            // marker 缺失：历史 main 缓存没有 marker，仍然有效；钉死的 revision 必须有。
            return revision == "main"
        }
        guard
            let stored = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        return stored == revision
    }

    /// 唯一的就位判定入口。
    static func evaluate(modelsDir: URL) -> Verdict {
        let repo = Repo.diarizer
        let repoPath = modelsDir.appendingPathComponent(repo.folderName, isDirectory: true)
        let required = offlineDiarizerRequiredModels
        let revision = repo.revision

        let revisionMatches = matchesRevision(at: repoPath, revision: revision)
        let missing: [String]
        if revisionMatches {
            missing = required
                .filter {
                    !FileManager.default.fileExists(
                        atPath: repoPath.appendingPathComponent($0).path)
                }
                .sorted()
        } else {
            missing = required.sorted()
        }

        return Verdict(
            ready: missing.isEmpty,
            repoPath: repoPath.path,
            missing: missing,
            revisionOK: revisionMatches
        )
    }
}
