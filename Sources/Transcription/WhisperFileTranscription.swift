import AVFoundation
import Foundation

/// 把一段**已经录好的音频**交给接线后的 Whisper 滑窗管线跑完，拿回转录段。
///
/// 它存在的理由（P11-1）：课后重转要从 Apple 那条链路换成 Whisper large-v3。
/// 重转的驱动方式**必须和探针 `--whisper-window-file` 是同一段代码**——
/// 探针量出来的数字（覆盖率、段数、字数、单窗耗时）是要拿来当判据的，
/// 而「探针跑了一条复制品」就意味着那些数字说的不是这条路。
/// 所以取窗节奏（喂 0.5 秒一块、累计够一个步长取一窗、收尾补一窗 + 强制定稿）
/// 只有这一份实现，探针和重转都调它。
///
/// 它**不是**实时链路：实时那条在 `TranscriptionEngine.runWhisperLoop` 里，
/// 由麦克风回调和定时器驱动。这里由「文件读完了没」驱动，没有定时器、
/// 也没有「跟不跟得上」这回事——离线跑得再慢也只是慢。
enum WhisperFileTranscription {

    /// 喂音频的块长。比 4096 帧的回调块（约 85ms）粗、比步长细：
    /// 取窗的时机由「累计喂够一个步长」决定，块长只影响它对齐得准不准
    static let chunkSeconds = 0.5

    // MARK: - 读文件

    struct Loaded {
        /// 16kHz 单声道 Float32——Whisper 唯一接受的输入格式
        let samples: [Float]
        let audioSeconds: Double
        let totalFrames: AVAudioFramePosition
        let formatDescription: String
        let channelCount: AVAudioChannelCount
        /// `--head` 截断后的实际秒数；nil = 没截
        let truncatedFrom: Double?
    }

    enum Failure: LocalizedError, Equatable {
        case open(String)
        case allocate
        case read(String)
        /// 短读 = 覆盖率不足。**不静默继续**：这条录音转出来的东西会缺尾巴，
        /// 而缺尾巴在输出上完全看不出来（本项目踩过：144.8 秒只转到 131.6 秒）
        case shortRead(got: Int, expected: Int)
        case resample
        case cancelled
        case inference(String)

        var errorDescription: String? {
            switch self {
            case .open(let path): return "打不开音频：\(path)"
            case .allocate: return "分配音频缓冲失败"
            case .read(let reason): return "读音频失败：\(reason)"
            case .shortRead(let got, let expected): return "短读 \(got)/\(expected) 帧——覆盖率不足，先修这个再看质量"
            case .resample: return "重采样到 16kHz 失败"
            case .cancelled: return "已取消"
            case .inference(let reason): return "转写失败：\(reason)"
            }
        }
    }

    /// 读文件 → 16kHz 单声道 Float32。
    ///
    /// **一次读满**，按 `min(chunk, 剩余)` 读、不固定块长：固定块长在文件末尾
    /// 不足一整块时会静默丢尾（`AVAudioFile.read` 在 `frameCount` 超过剩余帧数
    /// 时抛错，而不是短读），本项目在这上面踩过两次。
    static func loadSamples(path: String, headSeconds: Double = 0) throws -> Loaded {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let file = try? AVAudioFile(forReading: url) else {
            throw Failure.open(url.path)
        }
        let format = file.processingFormat
        let totalFrames = file.length
        let seconds = Double(totalFrames) / format.sampleRate

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ) else { throw Failure.allocate }

        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(totalFrames))
        } catch {
            throw Failure.read(error.localizedDescription)
        }
        guard buffer.frameLength == totalFrames else {
            throw Failure.shortRead(got: Int(buffer.frameLength), expected: Int(totalFrames))
        }

        guard var samples = WhisperEngine.resampleTo16k(buffer) else {
            throw Failure.resample
        }

        var truncatedFrom: Double?
        if headSeconds > 0 {
            let keep = min(samples.count, Int(headSeconds * WhisperWindowPipeline.sampleRate))
            samples = Array(samples.prefix(keep))
            truncatedFrom = seconds
        }

        return Loaded(
            samples: samples,
            audioSeconds: Double(samples.count) / WhisperWindowPipeline.sampleRate,
            totalFrames: totalFrames,
            formatDescription: format.description,
            channelCount: format.channelCount,
            truncatedFrom: truncatedFrom
        )
    }

    // MARK: - 跑管线

    /// 一次取窗的事实。探针的逐窗表（`--timing`）和重转的进度都从它来——
    /// **同一条来源**，所以「进度显示的窗数」和「耗时表里的窗数」不会各说各话
    struct WindowFacts {
        /// 第几次取窗（1 起数；含收尾窗）
        let index: Int
        /// 收尾窗（录音最后那一段补转）。它也是一次 `merge()`、也进
        /// `transcriptionSeconds`，只是不经过 `advance()`
        let isFinishWindow: Bool
        /// nil = 这一轮没取到窗（缓冲不够一窗，或起点没往前走）
        let startMillis: Int?
        let elapsedSeconds: Double
        /// 这一窗实际覆盖的音频秒数
        let audioSeconds: Double
        let windowEndMillis: Int
        /// 这一窗**原始**认出多少字符（合并之前）。判断「慢窗是不是说话密集」
        /// 靠它，不靠新增段数——滑窗与上一窗重叠 7 秒，同一句被反复认出，
        /// 合并器把它当旧段丢掉，于是慢窗的「新增段」常常是 0
        let charsRecognized: Int
        /// 这一窗之后的段快照（合并结果）。空数组 = 空转/收尾无变化
        let segments: [TranscriptSegment]
    }

    struct Result {
        let segments: [TranscriptSegment]
        let windowCount: Int
        let wallSeconds: Double
        let audioSeconds: Double
        let transcriptionSeconds: [Double]
        /// 生产链路丢掉的幻觉段（管线自己的记录，不是从结果反推的）
        let hallucinations: [String]
        let guardTrips: Int
        let confidences: [Double]
        /// 这一趟实际送进 whisper 的 `initial_prompt`。**从管线回读、不是
        /// 把入参回显一遍**——探针/A-B 要拿它证明「两趟唯一的差别就是这个」，
        /// 回显入参证明不了（入参可能是 nil，也可能中途被谁改了）。
        /// nil = 没送
        let initialPrompt: String?
    }

    /// 把样本喂完、定稿，返回最终段。
    ///
    /// **取消点是「每一窗之前」**：单次 `whisper_full` 是秒级的阻塞调用，
    /// 中途插不进去。所以取消的粒度就是「这一窗转完之后」——
    /// 对用户来说这最多等几秒，而且**不许留下半个转录**这件事由调用方保证
    /// （结果只在跑完之后才交给调用方，取消时抛 `cancelled`、什么都不返回）
    static func run(
        samples: [Float],
        engine: WhisperEngine,
        firstWindowSeconds: Double = WhisperWindowPipeline.stepSeconds,
        initialPrompt: String? = nil,
        onWindow: ((WindowFacts) -> Void)? = nil
    ) throws -> Result {
        let started = ContinuousClock.now
        let pipeline = WhisperWindowPipeline(initialPrompt: initialPrompt)
        let chunk = max(1, Int(chunkSeconds * WhisperWindowPipeline.sampleRate))
        let windowFrames = Int(WhisperWindowPipeline.windowSeconds * WhisperWindowPipeline.sampleRate)
        var fed = 0
        // 首窗要攒够多少音频。默认 = 步长（实时链路的行为）。
        // 只有探针会传别的值——那是它排查「首段碎片」留的旋钮，
        // 重转永远走默认值（见 `WhisperWindowFileRun.Options.firstWindowSeconds`）
        var nextWindowAt = Int(firstWindowSeconds * 1000)
        var attempts = 0

        func windowBounds(_ startMillis: Int?) -> (start: Int, end: Int, seconds: Double) {
            let startSamples = (startMillis ?? 0) * 16      // 16kHz → 毫秒 × 16
            let endSamples = max(startSamples, min(startSamples + windowFrames, fed))
            return (startSamples, endSamples,
                    Double(endSamples - startSamples) / WhisperWindowPipeline.sampleRate)
        }

        while fed < samples.count {
            // 取消粒度 = 一窗。理由见 `run` 的注释
            if Task.isCancelled { throw Failure.cancelled }

            let end = min(fed + chunk, samples.count)
            pipeline.append(Array(samples[fed..<end]))
            fed = end

            let fedMillis = Int(Double(fed) / WhisperWindowPipeline.sampleRate * 1000)
            guard fedMillis >= nextWindowAt else { continue }
            nextWindowAt += WhisperWindowPipeline.stepMillis
            attempts += 1

            let callStarted = ContinuousClock.now
            let charsBefore = pipeline.recognizedConfidences.count
            let update = try pipeline.advance(engine: engine)
            let charsRecognized = pipeline.recognizedConfidences.count - charsBefore
            let elapsed = secondsSince(callStarted)

            let startMillis = update == nil ? nil : pipeline.lastWindowStartMillis
            let bounds = windowBounds(startMillis)

            onWindow?(WindowFacts(
                index: attempts,
                isFinishWindow: false,
                startMillis: startMillis,
                elapsedSeconds: elapsed,
                audioSeconds: bounds.seconds,
                windowEndMillis: (startMillis ?? 0) + Int(bounds.seconds * 1000),
                charsRecognized: charsRecognized,
                segments: update?.segments ?? []
            ))
        }

        if Task.isCancelled { throw Failure.cancelled }

        // 收尾：缓冲里最后那段补转 + 强制定稿（接线后的路径就是这么收的）。
        // 少了它会丢掉「最后一个窗口之后」的那段音频（最多一个步长）
        let transcriptionsBeforeFinish = pipeline.transcriptionSeconds.count
        let charsBeforeFinish = pipeline.recognizedConfidences.count
        let final = try pipeline.finish(engine: engine)
        if pipeline.transcriptionSeconds.count > transcriptionsBeforeFinish {
            let startMillis = pipeline.lastWindowStartMillis
            let bounds = windowBounds(startMillis)
            onWindow?(WindowFacts(
                index: attempts + 1,
                isFinishWindow: true,
                startMillis: startMillis,
                elapsedSeconds: pipeline.transcriptionSeconds.last ?? 0,
                audioSeconds: bounds.seconds,
                windowEndMillis: (startMillis ?? 0) + Int(bounds.seconds * 1000),
                charsRecognized: pipeline.recognizedConfidences.count - charsBeforeFinish,
                segments: final.segments
            ))
        }

        return Result(
            segments: final.segments,
            windowCount: pipeline.transcriptionSeconds.count,
            wallSeconds: secondsSince(started),
            audioSeconds: Double(samples.count) / WhisperWindowPipeline.sampleRate,
            transcriptionSeconds: pipeline.transcriptionSeconds,
            hallucinations: pipeline.hallucinationLog,
            guardTrips: pipeline.guardTrips,
            confidences: pipeline.recognizedConfidences,
            initialPrompt: pipeline.initialPrompt
        )
    }

    /// 已实现里的公共读秒：探针那边也有一个同名私有函数，
    /// 这里**不共用**（那个在 `WhisperWindowFileRun` 内部），但算法是同一个
    private static func secondsSince(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}
