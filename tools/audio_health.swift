#!/usr/bin/env swift
//
// 录音体检：逐时间窗看底噪、动态范围、语音帧占比。
//
// 为什么需要它：一场录音「转录得准不准」和「录得响不响」几乎无关。
// 电平表只能回答后者——这恰恰是排查转录准确率时最容易走进的死胡同
// （电平正常、帧数正常、什么都不报错，但转出来全是错的）。
//
// 真正决定成败的是**动态范围**：语音电平和底噪之间差多少。
// 安静时底噪 0.0002、说话时 0.05，差 48 dB，模型轻松；
// 底噪被抬到 0.008，差 17 dB，模型就只能连蒙带猜。
//
// 而且**必须分时间窗看**。这次就是靠它定位的：同一场 191 秒的录音，
// 前 20 秒 48 dB（转录完美），20–60 秒塌到 17 dB（转录崩坏），
// 60 秒后又恢复。只看整段的平均数，这个塌陷会被完全平均掉。
//
// 用法：
//   swift tools/audio_health.swift <文件.wav> [...]
//   swift tools/audio_health.swift --spectrum <文件.wav>   另看频带分布

import AVFoundation
import Accelerate
import Foundation

// MARK: - 读数

struct Window {
    let start: Double
    let floor: Double      // p10，代表底噪
    let median: Double
    let speech: Double     // p90，代表语音
    let speechRatio: Double
    let centroid: Double   // 频谱质心，Hz

    var range: Double {
        20 * log10(max(speech, 1e-7) / max(floor, 1e-7))
    }

    /// 这个窗口里量到的「底噪」是不是真的底噪。
    ///
    /// 动态范围只在窗口内有停顿、有安静帧时才成立。要是整窗都在说话
    /// （连续朗读、有声书），p10 取到的仍然是语音电平，算出来的「范围」
    /// 就只剩语音自身的起伏——十几 dB，看着像塌陷，其实什么事都没有。
    /// 实测拿一段干净的合成语音试，它就误报过。
    var floorIsReal: Bool { speechRatio < 0.80 }
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

/// 塌陷 = 某窗口的动态范围明显低于这段录音自己的水平。
/// 用「和自身比」而不是绝对阈值：教室、录音棚、耳机麦的绝对电平差得远，
/// 但同一场录音内部应该是稳定的——内部不稳，就是链路的问题。
func collapseVerdict(_ list: [Window]) -> String? {
    // 只用「量到了真底噪」的窗口判：全在说话的窗口算出来的范围是假的
    let usable = list.filter(\.floorIsReal)
    guard usable.count >= 3 else { return nil }

    let ranges = usable.map(\.range).sorted()
    let best = ranges.last!
    let worst = ranges.first!
    guard best - worst > 12 else { return nil }

    // 把连续的低谷并成区间。逐个列出「20s, 30s, 40s…」等于没总结——
    // 要看的是「从哪到哪塌了」，不是有多少个 10 秒窗不合格
    let bad = usable.filter { $0.range < best - 12 }
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
    print("    时间窗     底噪(p10)   中位        语音(p90)   动态范围   语音帧   质心")
    for w in list {
        let flag = !w.floorIsReal ? "  （整窗都在说话，量不到底噪）"
            : (w.range < 25 ? "  ← 偏低" : "")
        print(String(format: "   %4.0f–%-4.0fs  %.5f    %.5f    %.5f   %6.1f dB  %5.1f%%  %5.0fHz%@",
                     w.start, w.start + span,
                     w.floor, w.median, w.speech, w.range, w.speechRatio * 100, w.centroid, flag))
    }

    let usable = list.filter(\.floorIsReal)
    guard !usable.isEmpty else {
        print("")
        print("   （全程连续说话，没有停顿可量底噪——这种情况看识别结果就行）")
        return
    }

    let ranges = usable.map(\.range)
    let avg = ranges.reduce(0, +) / Double(ranges.count)
    print("")
    print(String(format: "   平均动态范围 %.1f dB（最好 %.1f / 最差 %.1f，%d/%d 个窗口可测）",
                 avg, ranges.max()!, ranges.min()!, usable.count, list.count))

    if let verdict = collapseVerdict(list) {
        print("   \(verdict)")
    } else if avg >= 40 {
        print("   ✅ 全程稳定，这样的录音识别器能处理得很好")
    } else if avg >= 30 {
        print("   ⚠️ 整体偏低，识别会明显变差（离麦远、或房间底噪大）")
    } else {
        print("   ❌ 动态范围太小，语音和噪声差不多响，识别基本没戏")
    }
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
