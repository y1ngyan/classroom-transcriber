import AVFoundation
import Foundation

// 端到端探针：整段真实录音走完整 Transcribe，报覆盖率 / 逐字符置信度对齐 / 概率分布 / 与官方 CLI 的逐字重合。
// 跑法: ./tools/probe.sh e2e <wav> [whisper-cli 的 --output-txt 输出]
//
// 把项目的真实模块（WhisperEngine / ChineseText / TranscriptQuality）
// 编译进来，跑**真实录音**，验证三件在纯本地自检里测不到的事：
//
//   1. 覆盖：我们的引擎输出 vs whisper-cli 的输出，是不是同一份内容
//      （两条**不同**的代码路径：嵌入式 libwhisper vs 官方 CLI 二进制）
//   2. 对齐：逐字符置信度的个数，是否等于段落正文的可见字符数
//      （这是接进界面做逐字高亮/低置信标记的前提）
//   3. 分布：Whisper token 概率在真实音频上的实际区间
//      —— Apple 那套阈值（0.5 / 0.85 / 0.70）是按 Apple 的置信度定的，
//      能不能直接套在 Whisper 的概率上，要用这个分布回答，不能猜
//
// 用法: probe <wav> <模型路径> [whisper-cli 的 --output-txt 输出]

@main
struct WhisperProbe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("用法: probe <wav> <模型> [cli_output.txt]")
            exit(2)
        }
        let wavURL = URL(fileURLWithPath: args[1])
        let modelURL = URL(fileURLWithPath: args[2])
        let cliTextPath: String? = args.count > 3 ? args[3] : nil

        print("═══ Whisper 引擎 · 真实录音端到端探针 ═══\n")

        // ---- 读音频 ----
        guard let file = try? AVAudioFile(forReading: wavURL) else {
            print("❌ 打不开音频: \(wavURL.path)"); exit(1)
        }
        let format = file.processingFormat
        let totalFrames = file.length
        let seconds = Double(totalFrames) / format.sampleRate
        print(String(format: "输入: %@", wavURL.lastPathComponent))
        print(String(format: "      格式 %@ · %d 帧 · %.1f 秒 · 声道 %d",
                     format.description, totalFrames, seconds, format.channelCount))

        // 一次读满整个文件：按 min(chunk, 剩余) 读，不要固定块长 + catch break
        // （那个写法在文件末尾不足一整块时会静默丢尾，本项目踩过）
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            print("❌ 分配缓冲失败"); exit(1)
        }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(totalFrames))
        } catch {
            print("❌ 读音频失败: \(error)"); exit(1)
        }
        guard buffer.frameLength == totalFrames else {
            print("❌ 短读：拿到 \(buffer.frameLength) / \(totalFrames) 帧 —— 覆盖率不足，先修这个再看质量")
            exit(1)
        }
        print("      ✅ 读满 \(buffer.frameLength) 帧（无短读）")

        guard let samples = WhisperEngine.resampleTo16k(buffer) else {
            print("❌ 重采样到 16k 失败"); exit(1)
        }
        print(String(format: "      ✅ 重采样到 16k 单声道：%d 采样点 · %.1f 秒",
                     samples.count, Double(samples.count) / 16_000))

        // ---- 跑引擎 ----
        print("\n─── 加载引擎 ───")
        let engine: WhisperEngine
        do {
            engine = try WhisperEngine(modelURL: modelURL)
            print("✅ 引擎就绪")
        } catch {
            print("❌ 引擎构造失败: \(error)"); exit(1)
        }

        print("\n─── 转录中（8GB 机器上 medium-q5_0 大约 10-30 秒）───")
        let started = Date()
        let segments: [WhisperSegment]
        do {
            segments = try engine.transcribe(samples)
        } catch {
            print("❌ 转录失败: \(error)"); exit(1)
        }
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "✅ 转完 %d 段，用时 %.2f 秒（%.1f× 实时）",
                     segments.count, elapsed, seconds / elapsed))

        // ---- 逐段输出 ----
        print("\n─── 逐段（时间 · 档位 · 平均置信 · 低置信占比 · 文本）───")
        var coveredSeconds = 0.0
        var allConfidences: [Double] = []
        var alignmentFailures = 0

        for (index, segment) in segments.enumerated() {
            let visible = segment.text.filter { !$0.isWhitespace }.count
            let aligned = visible == segment.confidences.count
            if !aligned { alignmentFailures += 1 }
            allConfidences.append(contentsOf: segment.confidences)
            coveredSeconds += Double(segment.endMillis - segment.startMillis) / 1000

            let average = segment.averageConfidence.map { String(format: "%.3f", $0) } ?? "—"
            let lowRatio = segment.confidences.isEmpty ? 0
                : Double(segment.confidences.filter { $0 < 0.5 }.count) / Double(segment.confidences.count)
            print(String(format: "[%2d] %6.1f–%6.1fs · %@ · 平均 %@ · 低置信 %3.0f%% · 置信度 %d 个 / 可见字 %d %@",
                         index,
                         Double(segment.startMillis) / 1000,
                         Double(segment.endMillis) / 1000,
                         segment.grade?.label ?? "—",
                         average,
                         lowRatio * 100,
                         segment.confidences.count,
                         visible,
                         aligned ? "" : "❌ 对不齐"))
            print("      \(segment.text)")
        }

        // ---- 阶段三：分布（回答「Apple 的阈值能不能直接用」）----
        print("\n─── token 概率分布（真实音频）───")
        if allConfidences.isEmpty {
            print("❌ 一个置信度都没拿到 —— 逐 token 概率这条链断了")
        } else {
            let sorted = allConfidences.sorted()
            func quantile(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            let mean = allConfidences.reduce(0, +) / Double(allConfidences.count)
            let lowCount = allConfidences.filter { $0 < 0.5 }.count
            print(String(format: "  字符级置信度 %d 个", allConfidences.count))
            print(String(format: "  平均 %.3f · 中位 %.3f", mean, quantile(0.5)))
            print(String(format: "  分位  1%%=%.3f  5%%=%.3f  25%%=%.3f  75%%=%.3f  95%%=%.3f  99%%=%.3f",
                         quantile(0.01), quantile(0.05), quantile(0.25), quantile(0.75), quantile(0.95), quantile(0.99)))
            print(String(format: "  最小 %.3f · 最大 %.3f", sorted.first ?? 0, sorted.last ?? 0))
            print(String(format: "  <0.5 占比 %.1f%%（Apple 那套把 0.5 当「在蒙」的线）",
                         Double(lowCount) / Double(allConfidences.count) * 100))
            print(String(format: "  整体档位（直接套 Apple 阈值）：%@",
                         TranscriptQualityAssessor.grade(confidences: allConfidences)?.label ?? "nil"))
        }

        print("\n─── 覆盖与对齐 ───")
        print(String(format: "  时间覆盖：%.1f / %.1f 秒（%.1f%%）", coveredSeconds, seconds, coveredSeconds / seconds * 100))
        print("  逐字符置信度对齐：\(alignmentFailures == 0 ? "✅ 全部段一致" : "❌ \(alignmentFailures) 段对不齐")")

        // ---- 阶段四：跟官方 CLI 交叉核对内容 ----
        if let cliTextPath, let raw = try? String(contentsOfFile: cliTextPath, encoding: .utf8) {
            let cliConverted = ChineseText.toSimplified(raw)
            let ours = segments.map(\.text).joined()
            func normalize(_ text: String) -> String {
                text.filter { !$0.isWhitespace && !"\n\r".contains($0) }
            }
            let a = normalize(ours)
            let b = normalize(cliConverted)
            print("\n─── 与 whisper-cli 交叉核对（两条不同代码路径）───")
            print("  我们的引擎 \(a.count) 字 / CLI \(b.count) 字")

            // 逐字最长公共子序列长度：内容一致则应该 ≈ 全长的 90%+
            let aa = Array(a), bb = Array(b)
            var previous = Array(repeating: 0, count: bb.count + 1)
            var current = previous
            for i in 1...max(aa.count, 1) {
                for j in 1...max(bb.count, 1) where aa.count >= i && bb.count >= j {
                    current[j] = aa[i - 1] == bb[j - 1]
                        ? previous[j - 1] + 1
                        : max(previous[j], current[j - 1])
                }
                previous = current
                if aa.isEmpty || bb.isEmpty { break }
            }
            let lcs = aa.isEmpty || bb.isEmpty ? 0 : previous[bb.count]
            let ratio = Double(lcs) / Double(max(aa.count, bb.count))
            print(String(format: "  逐字重合 %d 字 · %.1f%% 一致", lcs, ratio * 100))
            print(ratio > 0.9 ? "  ✅ 内容一致（差异应在断句/标点层面）" : "  ⚠️ 差异偏大，需要逐段比对")
        } else if cliTextPath != nil {
            print("\n⚠️ 读不到 CLI 输出（\(cliTextPath!)），跳过交叉核对")
        }

        print("\n探针结束")
    }
}
