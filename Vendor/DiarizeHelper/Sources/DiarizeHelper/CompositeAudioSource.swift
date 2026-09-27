import FluidAudio
import Foundation

/// 多片段的「复合音频源」（设计稿 §1 第 2 点、§2.2、开放问题 Q1 的选项 A）。
///
/// 把每个 `--input` 解码/重采样到模型采样率（16 kHz、Float32、mono），
/// 按 `--offset-ms` 摆到**会话时间轴**上；片段之间的空洞补零（=静音）。
/// FluidAudio 的离线聚类是全局的，所以整节课一次喂进去，S1/S2 天然课内一致。
///
/// 为什么不用「把所有样本拼成一个大 `[Float]`」：67 min × 16 kHz × 4B ≈ 257 MB，
/// 且与设计稿 §6.3 的 `peakRSS` 观察冲突。这里做成惰性的 `AudioSampleSource`：
/// 每个片段仍是 FluidAudio 的 `DiskBackedAudioSampleSource`（mmap），只在
/// `copySamples` 时按窗口取数。
struct OffsetCompositeAudioSource: AudioSampleSource {
    struct Placement: Sendable {
        /// 该片段在会话时间轴上的起点（样本数）。
        var startSample: Int
        var source: DiskBackedAudioSampleSource
    }

    var sampleCount: Int
    var placements: [Placement]

    func copySamples(
        into destination: UnsafeMutablePointer<Float>,
        offset: Int,
        count: Int
    ) throws {
        guard count > 0 else { return }
        // 先把请求窗口清零，再覆盖各片段覆盖到的部分。片段之间的空洞 = 静音。
        // 与 FluidAudio 自带 source 的约定一致：caller 传进来的 buffer 视为已初始化，
        // 用 `update(repeating:)` 而不是 `initialize`。
        destination.update(repeating: 0, count: count)
        guard sampleCount > 0 else { return }

        let windowStart = max(0, offset)
        let windowEnd = windowStart + count
        for placement in placements {
            let placementStart = placement.startSample
            let placementEnd = placementStart + placement.source.sampleCount
            let overlapStart = max(placementStart, windowStart)
            let overlapEnd = min(placementEnd, windowEnd)
            guard overlapStart < overlapEnd else { continue }
            try placement.source.copySamples(
                into: destination.advanced(by: overlapStart - windowStart),
                offset: overlapStart - placementStart,
                count: overlapEnd - overlapStart
            )
        }
    }
}

struct BuiltCompositeSource {
    var source: OffsetCompositeAudioSource
    var inputs: [EnvelopeInput]
    /// 解码 + 重采样花掉的时间（进 `timings.loadSeconds`）。
    var loadSeconds: Double
    /// 处理结束后必须调用：清掉各片段的临时 mmap 文件。
    var cleanup: () -> Void
}

enum CompositeSourceBuilder {
    /// - Parameter sampleRate: `OfflineDiarizerConfig.default.segmentation.sampleRate`（16000）。
    static func build(inputs: [DiarizeInputArg], sampleRate: Int) throws -> BuiltCompositeSource {
        var placements: [OffsetCompositeAudioSource.Placement] = []
        var envelopeInputs: [EnvelopeInput] = []
        var sources: [DiskBackedAudioSampleSource] = []
        var loadSeconds = 0.0

        for input in inputs {
            guard input.offsetMillis >= 0 else {
                throw HelperFailure(
                    code: .badInvocation,
                    message: "--offset-ms 必须 >= 0，收到 \(input.offsetMillis)")
            }
            let url = URL(fileURLWithPath: input.path)
            guard FileManager.default.fileExists(atPath: url.path),
                FileManager.default.isReadableFile(atPath: url.path)
            else {
                throw HelperFailure(
                    code: .audioUnreadable,
                    message: "输入不存在或不可读：\(input.path)")
            }

            let made: (source: DiskBackedAudioSampleSource, loadDuration: TimeInterval)
            do {
                made = try AudioSourceFactory().makeDiskBackedSource(
                    from: url, targetSampleRate: sampleRate)
            } catch {
                // 文件在、可读，但解不开（格式不支持/解码失败）→ 4。
                throw HelperFailure(
                    code: .audioUnsupported,
                    message: "解码失败：\(input.path)（\(error.localizedDescription)）")
            }

            sources.append(made.source)
            loadSeconds += made.loadDuration

            let durationSeconds = Double(made.source.sampleCount) / Double(sampleRate)
            let startSample = Int(
                (Double(input.offsetMillis) / 1000.0 * Double(sampleRate)).rounded())
            placements.append(
                OffsetCompositeAudioSource.Placement(
                    startSample: startSample,
                    source: made.source))
            envelopeInputs.append(
                EnvelopeInput(
                    path: (input.path as NSString).lastPathComponent,
                    offsetMillis: input.offsetMillis,
                    audioSeconds: durationSeconds))
        }

        let totalSamples = placements.map { $0.startSample + $0.source.sampleCount }.max() ?? 0
        let source = OffsetCompositeAudioSource(sampleCount: totalSamples, placements: placements)
        return BuiltCompositeSource(
            source: source,
            inputs: envelopeInputs,
            loadSeconds: loadSeconds,
            cleanup: { sources.forEach { $0.cleanup() } }
        )
    }
}
