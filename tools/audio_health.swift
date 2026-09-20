#!/usr/bin/env swift
//
// 录音体检：逐时间窗看底噪、动态范围、语音帧占比。
//
// 为什么需要它：电平表只能回答「录得响不响」，而排查采集链路时
// 更常见的问题是「同一场录音内部稳不稳」——前 20 秒好好的、中间塌了
// 又恢复，只看整段平均会把这个塌陷完全平均掉。所以它按时间窗出读数。
//
// **这个指标不预测转录准确率。** 曾经以为它预测（底噪抬到离语音 17 dB
// 时「模型只能连蒙带猜」），后来用 tools/dsp_lab.swift 做剂量-反应实测，
// 结论是反的：白噪声压到 15 dB SNR 转录仍然近乎完美，而唯一真正致命的是
// 混响（RT60 ≥1s 开始出音素混淆，与底噪无关）。动态范围仍然值得看——
// 它描述音频本身的质量，也确实是采集链出问题的信号——但**不要拿它
// 推断「这场转录准不准」**，那条因果链没有实测支撑。
//
// 用法：
//   swift tools/audio_health.swift <文件.wav> [...]
//   swift tools/audio_health.swift --spectrum <文件.wav>   另看频带分布

import AVFoundation
import Accelerate
import Foundation

// MARK: - 读数

/// 一个窗口的动态范围读数能不能用。
///
/// 动态范围的算法是拿两个分位数相减（p90 当语音、p5 当底噪），
/// 这只有在**窗口里既有说话的帧、也有安静的帧**时才成立。
/// 两头都不成立，而且是两种不同的失败，读数都仍然是一个漂亮的
/// 十几二十 dB 的数字——所以必须分别识别出来，不能让它冒充结论。
enum RangeQuality: Equatable {
    /// p5 真的是底噪、p90 真的是语音，相减有意义
    case ok
    /// 整窗都在说话（连续朗读、有声书）：p5 取到的还是语音电平，
    /// 算出来的「范围」只是语音自身的起伏。实测拿干净的合成语音就误报过。
    case noPause
    /// 几乎没人在说话：p90 取到的是噪声的上尾，不是语音。
    /// 实测 095806 的 60–75s（语音帧占比 5.6%）就这么报出了 17.5 dB，
    /// 看着像塌陷，其实那 15 秒里本来就没人出声。
    case noSpeech
}

struct Window {
    let start: Double
    let floor: Double      // p5，代表底噪
    let median: Double
    let speech: Double     // p90，代表语音
    let speechRatio: Double
    let centroid: Double   // 频谱质心，Hz

    /// 语音帧占比的下限：低于它，p90 就落在噪声里了。
    ///
    /// 推导而不是拍的：排序后 p90 取的是 `frames[count * 9 / 10]`，
    /// 当语音帧占比为 r 时，这个下标落在语音区里当且仅当 `1 - r < 0.9`，
    /// 即 `r > 0.10`。低于这个值，「语音电平」量到的根本不是语音。
    static let minimumSpeechRatio = 0.10

    /// 语音帧占比的上限：高于它，p5 就落在语音里了。
    ///
    /// 严格算 p5 落在底噪里的条件是 `r < 0.95`，但这里卡在 0.80——
    /// 留下 0.15 的余量，因为「安静帧」未必是底噪，可能只是轻声、
    /// 呼吸、翻页。宁可少给一行读数，也不要给一行看着像塌陷的假数。
    static let maximumSpeechRatio = 0.80

    var range: Double {
        20 * log10(max(speech, 1e-7) / max(floor, 1e-7))
    }

    var rangeQuality: RangeQuality {
        if speechRatio < Self.minimumSpeechRatio { return .noSpeech }
        if speechRatio > Self.maximumSpeechRatio { return .noPause }
        return .ok
    }

    var isMeasurable: Bool { rangeQuality == .ok }

    /// 读数不可用时，一句话说明为什么——表格里直接印出来，
    /// 免得看图的人自己猜「这个 17 dB 到底算不算塌陷」
    var qualityNote: String? {
        switch rangeQuality {
        case .ok: return nil
        case .noPause: return "整窗都在说话，量不到底噪"
        case .noSpeech: return "几乎没人说话，量不到语音"
        }
    }
}

func loadSamples(_ path: String) -> (samples: [Float], sampleRate: Double, channels: Int)? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let format = file.processingFormat
    let total = AVAudioFrameCount(file.length)
    guard total > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
    do { try file.read(into: buffer) } catch { return nil }
    guard let data = buffer.floatChannelData?[0] else { return nil }
    return (Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))),
            format.sampleRate, Int(format.channelCount))
}

/// 频谱质心。人声集中在低频，噪声往往更「白」——质心突然上移
/// 通常意味着高频噪声被注进来了，而不是有人提高了嗓门。
/// 返回的是 FFT bin 序号，乘 `sampleRate / Double(fftSize)` 才是 Hz
let fftSize = 2048

func centroid(_ s: [Float], from start: Int, count: Int) -> Double {
    let n = fftSize
    let log2n = vDSP_Length(log2(Double(n)))
    guard count >= n, let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    else { return 0 }

    var real = [Float](repeating: 0, count: n / 2)
    var imag = [Float](repeating: 0, count: n / 2)
    var windowFn = [Float](repeating: 0, count: n)
    vDSP_hann_window(&windowFn, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var chunk = Array(s[start..<(start + n)])
    vDSP_vmul(chunk, 1, windowFn, 1, &chunk, 1, vDSP_Length(n))

    var weighted = 0.0
    var total = 0.0
    real.withUnsafeMutableBufferPointer { rp in
        imag.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            chunk.withUnsafeBytes { raw in
                vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                          vDSP_Length(n / 2))
            }
            fft.forward(input: split, output: &split)
            for k in 1..<(n / 2) {
                let mag = Double(rp[k] * rp[k] + ip[k] * ip[k])
                weighted += mag * Double(k)
                total += mag
            }
        }
    }
    guard total > 0 else { return 0 }
    return weighted / total
}

/// 窗口跨度按录音长度自适应：固定 10 秒的话，短录音一个窗口都切不出来，
/// 而短录音恰恰是最该先看一眼的（它跑得完，结论来得快）。
/// 但下限是 5 秒：再短就常常整窗都落在一次连续说话里，切不出安静的帧，
/// 底噪也就无从量起。宁可少给几行，也不要给一行假的。
func windowSpan(for samples: [Float], sampleRate: Double) -> Double {
    let duration = Double(samples.count) / sampleRate
    if duration >= 180 { return 30 }
    if duration >= 90 { return 15 }
    return 5
}

func windows(_ samples: [Float], sampleRate: Double) -> [Window] {
    let span = windowSpan(for: samples, sampleRate: sampleRate)
    let windowSize = Int(sampleRate * span)
    let frameSize = max(1, Int(sampleRate * 0.02))
    guard windowSize > frameSize, samples.count >= windowSize else { return [] }

    var result: [Window] = []
    var start = 0
    while start + windowSize <= samples.count {
        var frames: [Double] = []
        frames.reserveCapacity(windowSize / frameSize)
        var i = start
        while i + frameSize <= start + windowSize {
            var sum = 0.0
            for j in i..<(i + frameSize) { sum += Double(samples[j]) * Double(samples[j]) }
            frames.append((sum / Double(frameSize)).squareRoot())
            i += frameSize
        }
        frames.sort()
        guard !frames.isEmpty else { start += windowSize; continue }

        // 底噪取 p5 而不是 p10：底噪本来就该由「最安静的那些帧」代表，
        // 取 p10 时窗口里说话的成分一多，分位数就被往上抬，
        // 连续朗读的音频会被误判成动态范围塌陷（实测误报过）
        let floor = frames[frames.count / 20]
        let median = frames[frames.count / 2]
        let speech = frames[frames.count * 9 / 10]
        let threshold = max(floor * 3, 0.005)
        let ratio = Double(frames.filter { $0 > threshold }.count) / Double(frames.count)

        result.append(Window(
            start: Double(start) / sampleRate,
            floor: floor, median: median, speech: speech,
            speechRatio: ratio,
            centroid: centroid(samples, from: start, count: windowSize) * sampleRate / Double(fftSize)
        ))
        start += windowSize
    }
    return result
}

// MARK: - 判定

/// 相对落差阈值：比这段录音自己的最好水平低这么多，才算「明显低于自身」。
///
/// 「和自身比」是这个工具的立足点：教室、录音棚、耳机麦的绝对电平差得远，
/// 但同一场录音内部应该是稳定的——内部不稳，就是链路的问题。
/// 但**光靠它不够**，见下面那个绝对下限。
let collapseRelativeDropDB = 12.0

/// 绝对下限：低于这个数才谈得上「塌陷」。
///
/// 加它是因为只看相对落差会把「整体很好、只是内部有起伏」的录音也报成塌陷。
/// 和 `report()` 里「整体偏低」那一档共用同一个数，改的时候一起改——
/// 两处对「多少 dB 算低」的说法必须一致，否则报告自己跟自己打架。
let collapseAbsoluteFloorDB = 30.0

/// 塌陷 = 某窗口的动态范围**既**明显低于这段录音自己的水平，
/// **又**低到绝对不健康。两个条件都满足才报。
func collapseVerdict(_ list: [Window]) -> String? {
    // 只用两个分位数都真的落在它们该落的地方的窗口判。
    // 全在说话的窗口、几乎没说话的窗口，算出来的范围都是假的
    // （见 `RangeQuality`），拉进来做基准或者做低谷都会得出错的区间。
    let usable = list.filter(\.isMeasurable)
    guard usable.count >= 3 else { return nil }

    let ranges = usable.map(\.range).sorted()
    let best = ranges.last!

    // **两个条件缺一不可**：既明显低于这段录音自己的水平，又低到绝对不健康。
    //
    // 少了绝对下限就会误报：实测 095806 最好 55.5 dB、最差 37.0 dB，
    // 37 dB 本身相当健康，却因为比最好值低 18 dB 被判成「塌陷」。
    // 少了相对落差又会丢掉这个工具存在的理由——教室、录音棚、耳机麦的
    // 绝对电平差得远，同一场录音内部稳不稳才是链路问题的信号。
    let bad = usable.filter {
        $0.range < best - collapseRelativeDropDB && $0.range < collapseAbsoluteFloorDB
    }
    guard let worst = bad.map(\.range).min() else { return nil }

    // 把连续的低谷并成区间。逐个列出「20s, 30s, 40s…」等于没总结——
    // 要看的是「从哪到哪塌了」，不是有多少个 10 秒窗不合格
    let step = list.count > 1 ? list[1].start - list[0].start : 10
    var spans: [(Double, Double)] = []
    for w in bad {
        if var last = spans.last, abs(last.1 - w.start) < 0.01 {
            last.1 = w.start + step
            spans[spans.count - 1] = last
        } else {
            spans.append((w.start, w.start + step))
        }
    }
    let text = spans.map { "\(Int($0.0))–\(Int($0.1))s" }.joined(separator: "、")
    return "⚠️ 动态范围塌陷：最好 \(String(format: "%.0f", best)) dB，"
        + "最差 \(String(format: "%.0f", worst)) dB；塌陷区间 \(text)"
}

// MARK: - 输出

func report(path: String) {
    guard let (samples, sr, channels) = loadSamples(path) else {
        print("❌ 读不了 \(path)")
        return
    }

    let name = (path as NSString).lastPathComponent
    print("")
    print("── \(name)")
    print("   \(channels)ch/\(Int(sr))Hz · \(String(format: "%.1f", Double(samples.count) / sr))s")

    let list = windows(samples, sampleRate: sr)
    guard !list.isEmpty else {
        print("   （太短，不足以分窗）")
        return
    }

    let span = windowSpan(for: samples, sampleRate: sr)
    print("")
    print("    时间窗     底噪(p5)    中位        语音(p90)   动态范围   语音帧   质心")
    for w in list {
        // 两种不可测的情况分别写清楚原因：读数照印（它是真的量出来的），
        // 但后面跟一句为什么这个读数不能当结论用
        let flag = w.qualityNote.map { "  （\($0)，此行读数不可用）" }
            ?? (w.range < 25 ? "  ← 偏低" : "")
        print(String(format: "   %4.0f–%-4.0fs  %.5f    %.5f    %.5f   %6.1f dB  %5.1f%%  %5.0fHz%@",
                     w.start, w.start + span,
                     w.floor, w.median, w.speech, w.range, w.speechRatio * 100, w.centroid, flag))
    }

    let usable = list.filter(\.isMeasurable)
    let skipped = list.count - usable.count
    guard !usable.isEmpty else {
        print("")
        print("   （\(list.count) 个窗口没有一个是「又有人在说话、又有停顿」的，"
              + "量不出动态范围——这种情况直接看转录结果，不要看这份读数）")
        return
    }

    let ranges = usable.map(\.range)
    let avg = ranges.reduce(0, +) / Double(ranges.count)
    print("")
    print(String(format: "   平均动态范围 %.1f dB（最好 %.1f / 最差 %.1f，%d/%d 个窗口可测%@）",
                 avg, ranges.max()!, ranges.min()!, usable.count, list.count,
                 skipped > 0 ? "，\(skipped) 个不可测已排除" : ""))

    if let verdict = collapseVerdict(list) {
        print("   \(verdict)")
    } else if avg >= 40 {
        print("   ✅ 全程稳定，语音和底噪分得开")
    } else if avg >= collapseAbsoluteFloorDB {
        print("   ⚠️ 整体偏低，底噪离语音比较近")
    } else {
        print("   ⚠️ 动态范围小，语音和底噪差不多响")
    }

    // 这段是刻意留的：「动态范围 → 转录准确率」这条因果链没有实测支撑，
    // 而这个工具的输出很容易被当成那个结论来用（曾经就是这么用的）
    print("   注：动态范围描述的是音频本身，不预测转录准确率——"
          + "实测噪声压到 15dB SNR 转录仍然近乎完美，真正致命的是混响。")
}

/// 频带分布。用于确认「高频是不是被砍掉了」这类问题——
/// 电话带宽的音频听感上「很清楚」，但对识别模型是致命的。
func spectrum(path: String) {
    guard let (samples, sr, _) = loadSamples(path) else {
        print("❌ 读不了 \(path)")
        return
    }
    let edges: [Double] = [0, 80, 200, 500, 1_000, 2_000, 4_000, 6_000, 8_000, 12_000, 16_000, 24_000]
    let n = 4096
    let log2n = vDSP_Length(log2(Double(n)))
    guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return }

    var band = [Double](repeating: 0, count: edges.count - 1)
    var real = [Float](repeating: 0, count: n / 2)
    var imag = [Float](repeating: 0, count: n / 2)
    var windowFn = [Float](repeating: 0, count: n)
    vDSP_hann_window(&windowFn, vDSP_Length(n), Int32(vDSP_HANN_NORM))

    var pos = 0
    while pos + n <= samples.count {
        var chunk = Array(samples[pos..<(pos + n)])
        vDSP_vmul(chunk, 1, windowFn, 1, &chunk, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                chunk.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                              vDSP_Length(n / 2))
                }
                fft.forward(input: split, output: &split)
                for b in 0..<(edges.count - 1) {
                    let lo = max(1, Int(edges[b] / (sr / 2) * Double(n / 2)))
                    let hi = min(n / 2 - 1, Int(edges[b + 1] / (sr / 2) * Double(n / 2)))
                    guard lo <= hi else { continue }
                    var sum = 0.0
                    for k in lo...hi { sum += Double(rp[k] * rp[k] + ip[k] * ip[k]) }
                    band[b] += sum / Double(hi - lo + 1)
                }
            }
        }
        pos += n
    }

    let total = band.reduce(0, +)
    print("")
    print("── \((path as NSString).lastPathComponent) 频带分布")
    for b in 0..<(edges.count - 1) {
        let share = total > 0 ? band[b] / total : 0
        let db = share > 0 ? 10 * log10(share) : -99
        let bar = String(repeating: "█", count: max(0, Int((db + 45) / 1.6)))
        print(String(format: "   %6.0f–%-6.0f Hz  %6.1f dB  %@", edges[b], edges[b + 1], db, bar))
    }
}

// MARK: - 入口

var args = Array(CommandLine.arguments.dropFirst())
let wantsSpectrum = args.contains("--spectrum")
args.removeAll { $0.hasPrefix("--") }

guard !args.isEmpty else {
    print("用法: swift tools/audio_health.swift [--spectrum] <文件.wav> [...]")
    exit(1)
}
for path in args {
    if wantsSpectrum { spectrum(path: path) } else { report(path: path) }
}
