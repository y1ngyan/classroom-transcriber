import AVFoundation
import Foundation

/// `--whisper-window-file <wav>`：把滑窗链路在**真实录音**上离线跑一遍。
///
/// 走的必须是接线后的那条路径（`WhisperWindowPipeline`：取窗 → 转写 → 合并 →
/// 定稿），只把「麦克风」换成文件、把「等一个步长」换成「喂够一个步长的音频
/// 就取一窗」。自己另写一遍取窗 + 合并的话，验的是那份复制品——而这一包要
/// 回答的恰恰是「接线后的那条路径在真实录音上表现如何」。
///
/// **全程不碰主 actor**：这个入口在主线程上用信号量等结果（见 App.swift）。
/// 任何一次跳回主 actor 的 await 都会死锁——`--mic-selftest` 当初就是因为
/// 主线程被阻塞把引擎饿死，才改成「不 exit、照常起窗口」的。
enum WhisperWindowFileRun {

    /// 喂音频的块长。比 4096 帧的回调块（约 85ms）粗、比步长细：
    /// 取窗的时机由「累计喂够一个步长」决定，块长只影响它对齐得准不准
    private static let chunkSeconds = 0.5

    static func run(path: String) async -> [String] {
        var lines: [String] = ["═══ Whisper 滑窗 · 真实录音离线跑（走接线后的管线）═══"]

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let file = try? AVAudioFile(forReading: url) else {
            return lines + ["❌ 打不开音频: \(url.path)"]
        }
        let format = file.processingFormat
        let totalFrames = file.length
        let seconds = Double(totalFrames) / format.sampleRate
        lines.append(String(format: "输入: %@", url.lastPathComponent))
        lines.append(String(
            format: "  格式 %@ · %d 帧 · %.1f 秒 · 声道 %d",
            format.description, totalFrames, seconds, format.channelCount
        ))

        // 一次读满整个文件：按 min(chunk, 剩余) 读，不要固定块长 + catch break
        // （那个写法在文件末尾不足一整块时会静默丢尾，本项目踩过）
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ) else { return lines + ["❌ 分配缓冲失败"] }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(totalFrames))
        } catch {
            return lines + ["❌ 读音频失败: \(error)"]
        }
        guard buffer.frameLength == totalFrames else {
            return lines + ["❌ 短读：\(buffer.frameLength) / \(totalFrames) 帧——覆盖率不足，先修这个再看质量"]
        }
        lines.append("  ✅ 读满 \(buffer.frameLength) 帧（无短读）")

        guard let samples = WhisperEngine.resampleTo16k(buffer) else {
            return lines + ["❌ 重采样到 16k 失败"]
        }
        let audioSeconds = Double(samples.count) / WhisperWindowPipeline.sampleRate
        lines.append(String(format: "  ✅ 重采样到 16k 单声道：%d 采样点 · %.1f 秒",
                            samples.count, audioSeconds))

        lines.append("")
        lines.append("─── 加载引擎 ───")
        let engine: WhisperEngine
        let loadStarted = ContinuousClock.now
        do {
            engine = try WhisperEngine()
        } catch {
            return lines + ["❌ 引擎构造失败: \(error.localizedDescription)（模型路径 \(WhisperEngine.resolvedModelURL.path)）"]
        }
        lines.append(String(format: "  ✅ 引擎就绪（%.2f 秒）· 模型 %@",
                            secondsSince(loadStarted), WhisperEngine.resolvedModelURL.lastPathComponent))

        lines.append("")
        lines.append("─── 跑滑窗（窗口 \(Int(WhisperWindowPipeline.windowSeconds)) 秒 / 步长 \(Int(WhisperWindowPipeline.stepSeconds)) 秒）───")
        let pipeline = WhisperWindowPipeline()
        let chunk = max(1, Int(chunkSeconds * WhisperWindowPipeline.sampleRate))
        var fed = 0
        var nextWindowAt = WhisperWindowPipeline.stepMillis
        var windows = 0
        var failure: String?
        let runStarted = ContinuousClock.now

        while fed < samples.count {
            let end = min(fed + chunk, samples.count)
            pipeline.append(Array(samples[fed..<end]))
            fed = end

            // 实时链路是「每过一个步长取一次窗」，这里用「已喂进去的音频够一个
            // 步长了」代替——喂进来的音频就是时间轴本身，两者的取窗时刻一致
            let fedMillis = Int(Double(fed) / WhisperWindowPipeline.sampleRate * 1000)
            if fedMillis >= nextWindowAt {
                do {
                    if try pipeline.advance(engine: engine) != nil { windows += 1 }
                } catch {
                    failure = error.localizedDescription
                    break
                }
                nextWindowAt += WhisperWindowPipeline.stepMillis
            }
        }

        guard failure == nil else {
            return lines + ["❌ 中途失败: \(failure ?? "")"]
        }

        let final: WhisperWindowPipeline.Update
        do {
            final = try pipeline.finish(engine: engine)
        } catch {
            return lines + ["❌ 收尾转写失败: \(error.localizedDescription)"]
        }
        lines.append(String(format: "  %d 窗 · 离线全程 %.1f 秒（音频 %.1f 秒）",
                            windows, secondsSince(runStarted), audioSeconds))
        lines.append("  \(pipeline.statsLine)")

        lines.append("")
        lines.append("─── 结果 ───")
        let segments = final.segments
        let finalized = segments.filter(\.isFinal).count
        lines.append("  段数 \(segments.count)（定稿 \(finalized)）")
        if segments.count != finalized {
            lines.append("  ⚠️ 有 \(segments.count - finalized) 段没收尾定稿（收尾定稿应当把最后一段也带上）")
        }

        // 质量档位分布。用四个具名计数而不是字典：字典要 `!` 取键，
        // 而这是诊断入口，没必要为了一行输出留一个能崩的点
        var good = 0, fair = 0, poor = 0, ungraded = 0
        for segment in segments {
            switch segment.qualityGrade {
            case .good: good += 1
            case .fair: fair += 1
            case .poor: poor += 1
            case nil: ungraded += 1
            }
        }
        lines.append("  质量档位: 可信 \(good) / 存疑 \(fair) / 不可信 \(poor) / 未评（nil） \(ungraded)")

        // 逐字符置信度的原始分布。**含窗口重叠导致的重复计入**（10 秒窗 / 3 秒
        // 步长 → 同一句平均被转 3 次左右），所以它是「分布参考」，不是阈值标定
        // 的唯一依据——下一包要标定 `TranscriptQualityAssessor` 的 Whisper 阈值
        // 时，这一点必须先说清楚
        let confidences = pipeline.recognizedConfidences
        if !confidences.isEmpty {
            let sorted = confidences.sorted()
            let mean = confidences.reduce(0, +) / Double(confidences.count)
            let low = Double(confidences.filter { $0 < 0.5 }.count) / Double(confidences.count)
            lines.append(String(
                format: "  逐字符置信度（含重叠重复计入）：n=%d 均 %.3f 中位 %.3f <0.5 占 %.1f%%",
                confidences.count, mean, sorted[sorted.count / 2], low * 100
            ))
        }

        // 合并器吐回来的顺序不保证按时间（它按候选追加），引擎在 adopt 里会
        // 调 restoreOrderIfNeeded 排一遍——这里自己排，否则这份输出看起来像
        // 「界面上的段落是乱的」，而界面不是。逆序处数出来是为了别把这件事藏掉
        let inversions = zip(segments, segments.dropFirst())
            .filter { $0.startTimeMillis > $1.startTimeMillis }.count
        let ordered = segments.sorted { $0.startTimeMillis < $1.startTimeMillis }

        // 提问检出：用的是引擎那条路径上的同一个检测器与默认灵敏度
        let detector = QuestionDetector(sensitivity: .normal)
        var level1 = 0, level2 = 0
        for segment in segments {
            guard let hit = detector.detect(segment.text) else { continue }
            if hit.level >= 2 { level2 += 1 } else { level1 += 1 }
        }
        lines.append("  提问检出（灵敏度 NORMAL）: level1 \(level1) 段 / level2 \(level2) 段")

        // 覆盖率：最后一段结束时间 vs 音频总长。**先看覆盖率再看质量**——
        // 覆盖不全的话，下面的档位分布只是「被覆盖的那部分」的分布
        let lastEnd = ordered.map(\.endTimeMillis).max() ?? 0
        lines.append(String(
            format: "  覆盖率: 最晚段结束 %.1f 秒 / 音频 %.1f 秒 = %.1f%%",
            Double(lastEnd) / 1000, audioSeconds,
            Double(lastEnd) / 1000 / audioSeconds * 100
        ))
        lines.append("  守卫触发 \(pipeline.guardTrips) 次")

        lines.append("")
        lines.append("─── 前 12 段（按时间排；合并器原序逆序 \(inversions) 处，界面侧会排）───")
        for segment in ordered.prefix(12) {
            let grade = segment.qualityGrade?.label ?? "—"
            let question = segment.isQuestion ? " ❓L\(segment.questionLevel)" : ""
            lines.append("  [\(segment.formattedTimestamp)] (\(grade))\(question) \(segment.text)")
        }

        return lines
    }

    private static func secondsSince(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
