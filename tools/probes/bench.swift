import AVFoundation
import Foundation

// 耗时探针：量「N 秒滑窗 + 步长」在这台 8GB 机器上的真实单次耗时与占用率（决定滑窗方案能不能成立）。
// 跑法: ./tools/probe.sh bench <wav> [窗口秒=10] [轮数=5]
//
// 如果单次窗口耗时 > 步长，推理必然堆积 —— 那就要放宽步长或缩短窗口，不要硬上。
//
// 用法: window_bench <wav> <model> [窗口秒数=10] [轮数=5]

@main
struct WindowBench {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("用法: window_bench <wav> <model> [窗口秒] [轮数]"); exit(2) }
        let wavURL = URL(fileURLWithPath: args[1])
        let modelURL = URL(fileURLWithPath: args[2])
        let windowSeconds = args.count > 3 ? (Double(args[3]) ?? 10) : 10
        let rounds = args.count > 4 ? (Int(args[4]) ?? 5) : 5

        print("═══ 滑窗单次耗时探针（窗口 \(Int(windowSeconds)) 秒）═══\n")

        guard let file = try? AVAudioFile(forReading: wavURL),
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: inBuf, frameCount: AVAudioFrameCount(file.length))) != nil,
              let samples = WhisperEngine.resampleTo16k(inBuf)
        else { print("❌ 读音频失败"); exit(1) }

        print(String(format: "音频 %.1f 秒（16k 单声道 %d 采样点）", Double(samples.count) / 16_000, samples.count))

        let loadStart = Date()
        guard let engine = try? WhisperEngine(modelURL: modelURL) else { print("❌ 引擎构造失败"); exit(1) }
        print(String(format: "模型加载：%.2f 秒\n", Date().timeIntervalSince(loadStart)))

        let windowSamples = Int(windowSeconds * 16_000)
        // 从音频中段开始取，避开开头的静音
        var cursor = max(0, samples.count / 2)
        var times: [Double] = []

        for round in 0..<rounds {
            guard cursor + windowSamples <= samples.count else { break }
            let window = Array(samples[cursor..<(cursor + windowSamples)])
            let started = Date()
            do {
                let segments = try engine.transcribe(window)
                let elapsed = Date().timeIntervalSince(started)
                times.append(elapsed)
                let text = segments.map(\.text).joined()
                print(String(format: "第 %d 窗：%.2f 秒 · %d 段 · %@", round + 1, elapsed, segments.count, String(text.prefix(30))))
            } catch {
                print("❌ 第 \(round + 1) 窗失败: \(error)")
            }
            cursor += Int(3 * 16_000)   // 3 秒步长
        }

        guard !times.isEmpty else { print("❌ 没有有效测量"); exit(1) }
        let sorted = times.sorted()
        let mean = times.reduce(0, +) / Double(times.count)
        let median = sorted[sorted.count / 2]
        print(String(format: "\n单次窗口耗时：平均 %.2f 秒 · 中位 %.2f 秒 · 最小 %.2f · 最大 %.2f",
                     mean, median, sorted.first!, sorted.last!))
        print(String(format: "步长 3 秒 → 占用率 %.0f%%（%.0f%% 以上就会开始堆积）",
                     median / 3 * 100, 100.0))
        print(median < 3 ? "✅ 结论：单次窗口快于步长，3 秒步长可行"
              : "⚠️ 结论：单次窗口慢于步长，必须放宽步长或缩短窗口")
        print("探针结束")
    }
}
