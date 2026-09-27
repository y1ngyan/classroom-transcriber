import CoreML
import FluidAudio
import Foundation

extension ComputeUnitsArg {
    /// 默认 `.ane`（`.cpuAndNeuralEngine`）——把 GPU 留给 Whisper（设计稿 §2.1）。
    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .ane: return .cpuAndNeuralEngine
        case .cpu: return .cpuOnly
        case .all: return .all
        }
    }
}

enum DiarizeCommand {
    static func run(_ options: DiarizeOptions) async -> Int32 {
        let startedAt = Date()
        let modelsDir = URL(fileURLWithPath: options.modelsDir, isDirectory: true)

        // 生产恒开；download 是唯一允许联网的子命令。必须在使用任何 FluidAudio loader 之前设置。
        ModelHub.offlineMode = options.noNetwork

        // 1) 模型就位判定（不加载、不推理）。**与 `probe` 子命令共用同一份实现**
        //    `ModelPresence.evaluate`（C-1 裁决 3）——不允许这里另写一套「文件在不在」。
        //    这样 probe 说「在」而 diarize 说「缺」（或反过来）的假象从结构上被排除。
        let probe = ModelPresence.evaluate(modelsDir: modelsDir)
        guard probe.ready else {
            return fail(
                .modelMissing,
                "离线模型不完整：\(probe.missing.joined(separator: ", "))（\(probe.repoPath)）",
                output: options.output)
        }

        // 2) 复合音频源。
        let config = OfflineDiarizerConfig.default
        let sampleRate = config.segmentation.sampleRate
        let built: BuiltCompositeSource
        do {
            built = try CompositeSourceBuilder.build(inputs: options.inputs, sampleRate: sampleRate)
        } catch let failure as HelperFailure {
            return fail(failure.code, failure.message, output: options.output)
        } catch {
            return fail(.audioUnsupported, "构建音频源失败：\(error.localizedDescription)", output: options.output)
        }
        defer { built.cleanup() }

        // 3) 加载模型。**必须**用 `OfflineDiarizerModels.load` + `manager.initialize`，
        //    **绝不**换回 `OfflineDiarizerManager.prepareModels`（C-1 裁决 4）。
        //
        //    理由不是风格，是**数据安全**：`prepareModels` 在首轮 load 失败时走
        //    catch 分支，先 `purgeDiarizerRepo(at:)` —— 也就是**删掉用户的整个模型
        //    缓存目录**（FluidAudio OfflineDiarizerManager.swift 的两个 purge 调用），
        //    然后「fallback download」。离线 / 网络不可用时，这等于：
        //    加载失败 → 用户的模型被删 → 又下不回来。本项目最忌讳的失败模式就是
        //    毁用户数据。`OfflineDiarizerModels.load` 内部走 `ModelHub.loadModels`，
        //    离线模式下 load 失败只抛 `modelMissing`/`networkDisabled`，**不会 purge**
        //    （FluidAudio ModelHub.swift 的 offline 分支显式 return 原错误）。
        //
        //    下一个因为 `prepareModels` 名字更顺手、代码更少而想换回去的人：别换。
        let manager = OfflineDiarizerManager(config: config)
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = options.computeUnits.mlComputeUnits

        let loadedModels: OfflineDiarizerModels
        do {
            loadedModels = try await OfflineDiarizerModels.load(
                from: modelsDir, configuration: mlConfig)
            manager.initialize(models: loadedModels)
        } catch let downloadError as DownloadError {
            switch downloadError {
            case .modelMissing(let repo, let missing):
                // 预检（ModelPresence）说就位，而 FluidAudio 真正 load 时说缺 ——
                // 这正是裁决 3 最担心的分叉。行为不变（仍 exit 5），但**必须**把
                // 分叉喊出来，提示 ModelPresence 的复刻已过期。
                Diagnostics.stderr(
                    "internalInconsistency: ModelPresence 判断就位，但 FluidAudio load 报 modelMissing"
                        + "（repo=\(repo)，missing=\(missing.joined(separator: ", "))）；"
                        + "ModelPresence 的复刻已与 FluidAudio 分叉，请对照更新")
                return fail(.modelMissing, "模型缺失：\(downloadError.localizedDescription)", output: options.output)
            case .networkDisabled(let operation):
                Diagnostics.stderr(
                    "internalInconsistency: ModelPresence 判断就位，但离线 load 仍尝试下载"
                        + "（operation=\(operation)）；ModelPresence 的复刻已与 FluidAudio 分叉，请对照更新")
                return fail(.modelMissing, "模型缺失：\(downloadError.localizedDescription)", output: options.output)
            default:
                return fail(.modelLoadFailed, "模型加载失败：\(downloadError.localizedDescription)", output: options.output)
            }
        } catch {
            return fail(.modelLoadFailed, "模型加载/编译失败：\(error.localizedDescription)", output: options.output)
        }

        // 4) 推理。`noSpeechDetected` 是**正常结果，不是失败**（C-1 裁决 2）：
        //    它等价于「0 个说话人」，产出 `status == "ok"` + 空 `segments` +
        //    `speakerCount == 0` 的成功信封。失败才走 error 信封——「没人说话」
        //    与「helper 坏了」必须在信封层就能分开（status / error.code）。
        //
        //    App 侧硬约定（C-1 裁决 2，写在这里防止被改坏）：
        //      * `speakerCount == 0` 时**不许重试** helper；
        //      * **更不许贴 S1**（把安静当成单人讲授是最坏的假阳性）；
        //      * 「有字却没语音」的前后矛盾由 App 第 5 条校验判失败（设计稿 §2.6）：
        //        有 ≥1s 转录段却 speakerCount == 0 → 回退 nil，不伪装任何说话人。
        var result: DiarizationResult?
        do {
            result = try await manager.process(
                audioSource: built.source,
                audioLoadingSeconds: built.loadSeconds)
        } catch OfflineDiarizationError.noSpeechDetected {
            Diagnostics.stderr("noSpeechDetected: 输出空 segments（speakerCount=0，status 仍为 ok）")
            result = nil
        } catch {
            return fail(.inferenceFailed, "推理失败：\(error.localizedDescription)", output: options.output)
        }

        // 5) 物化信封（时间一律整数毫秒、会话时间轴）。
        let pairs = (result?.segments ?? []).map { segment -> (SpeakerSpanJSON, [Float]) in
            let span = SpeakerSpanJSON(
                speakerId: segment.speakerId,
                startMillis: Int((Double(segment.startTimeSeconds) * 1000).rounded()),
                endMillis: Int((Double(segment.endTimeSeconds) * 1000).rounded()),
                qualityScore: Double(segment.qualityScore)
            )
            return (span, segment.embedding)
        }.sorted { lhs, rhs in
            if lhs.0.startMillis != rhs.0.startMillis { return lhs.0.startMillis < rhs.0.startMillis }
            if lhs.0.endMillis != rhs.0.endMillis { return lhs.0.endMillis < rhs.0.endMillis }
            return lhs.0.speakerId < rhs.0.speakerId
        }

        let spans = pairs.map { $0.0 }
        let rawEmbeddings = pairs.map { $0.1 }
        let audioSeconds = Double(built.source.sampleCount) / Double(sampleRate)
        let timings = result?.timings
        // 物化走纯函数 `makeSuccessEnvelope`：空 spans 也是合法成功结果
        //（noSpeechDetected），`--selftest` 直接对该函数加用例（C-1 裁决 2）。
        let envelope = makeSuccessEnvelope(
            inputs: built.inputs,
            spans: spans,
            audioSeconds: audioSeconds,
            timings: EnvelopeTimings(
                wallSeconds: Date().timeIntervalSince(startedAt),
                loadSeconds: loadedModels.compilationDuration + built.loadSeconds,
                segmentationSeconds: timings?.segmentationSeconds ?? 0,
                embeddingSeconds: timings?.embeddingExtractionSeconds ?? 0,
                clusteringSeconds: timings?.speakerClusteringSeconds ?? 0
            )
        )

        // 6) 输出。embedding 旁路先写：主信封若已 ok，就不该留一个「请求了却没写」的旁路。
        if let embeddingsPath = options.embeddingsOut {
            do {
                try EmbeddingsEnvelope.write(
                    EmbeddingsEnvelope.make(from: spans, raw: rawEmbeddings),
                    to: embeddingsPath)
            } catch {
                return fail(.outputWriteFailed, "embedding 旁路写失败：\(error.localizedDescription)", output: options.output)
            }
        }

        do {
            try Envelope.write(envelope, to: options.output)
        } catch {
            return fail(.outputWriteFailed, "输出写失败：\(error.localizedDescription)", output: options.output)
        }
        return HelperExitCode.success.rawValue
    }

    /// 纯函数：把手里的说话人 span（**可能为空**）物化成成功信封。
    ///
    /// 空 span 不是错误路径：`noSpeechDetected`（近静音 / 无人说话）就走这里，
    /// 得到 `status == "ok"` + `segments == []` + `speakerCount == 0`（C-1 裁决 2）。
    /// 抽成纯函数的唯一目的，是让 `--selftest` 在不加载模型、不跑推理的前提下
    /// 覆盖这条「近静音样本」路径（自检是硬要求）。
    static func makeSuccessEnvelope(
        inputs: [EnvelopeInput],
        spans: [SpeakerSpanJSON],
        audioSeconds: Double,
        timings: EnvelopeTimings
    ) -> Envelope {
        Envelope.ok(
            inputs: inputs,
            result: EnvelopeResult(
                audioSeconds: audioSeconds,
                speakerCount: Set(spans.map(\.speakerId)).count,
                segments: spans
            ),
            timings: timings
        )
    }

    /// 失败也要落一个 error 信封（设计稿 §2.4）；信封本身写不出去 → 退出码 8。
    private static func fail(_ code: HelperExitCode, _ message: String, output: String?) -> Int32 {
        Diagnostics.stderr("\(code.errorCode): \(message)")
        if let output {
            do {
                try Envelope.write(Envelope.failure(code: code.errorCode, message: message), to: output)
            } catch {
                Diagnostics.stderr("outputWriteFailed: \(error.localizedDescription)")
                return HelperExitCode.outputWriteFailed.rawValue
            }
        }
        return code.rawValue
    }
}
