#!/usr/bin/env swift
//
// DSP 实验台：在**离线**状态下先验证「降噪 + 增益」到底有没有用、用哪一种。
//
// 为什么要有这个工具：直接改 MicTap 是拿真实课堂做实验，跑坏了要等下一节课
// 才知道。这里可以拿合成语音（有标准答案）和已有录音（有真实底噪）反复试，
// 试出结论再落到音频线程上。
//
// 处理链刻意写成**流式分块**（固定块长、块间带状态），而不是整段一次算——
// 整段算法能拿到「未来」的样本，离线看着好，搬到实时代码里就崩。
// 这里的结论必须能直接搬到 MicTap。
//
// 用法：
//   swift tools/dsp_lab.swift <输入.wav> <输出.wav> --mode <none|gain|gate|sub> [选项]
//
// 选项：
//   --target -20     增益归一化目标电平（dBFS），目标按语音帧算
//   --max-gain 30    增益上限（dB），防止安静段被推成噪声
//   --over 2.0       谱减法的过减因子
//   --floor -18      谱减法残留增益下限（dB）
//   --snr 15         注入噪声的信噪比（dB），配合 --add-noise
//   --add-noise      给干净素材注入白噪声（合成实验用）
//   --atten 20       先整体衰减 N dB（模拟「离麦太远」）
//   --report         逐块打印估计出的底噪/语音电平/增益

import AVFoundation
import Accelerate
import Foundation

// MARK: - 参数

struct Options {
    var mode = "none"
    var target: Double = -20
    var maxGain: Double = 30
    var over: Double = 2.0
    var floorDB: Double = -18
    var snr: Double = 15
    var addNoise = false
    var atten: Double = 0
    var report = false
    var highpass: Double = 0
    var trimStart: Double = 0
    var trimDuration: Double = 0
    var reverb: Double = 0
    var mixPath: String?
    var mixGain: Double = 0
}

/// 合成混响：Schroeder 梳状 + 全通网络。
///
/// 为什么需要它：教室里对识别的伤害有三个来源——噪声、电平、**混响**。
/// 前两个可以用注入的方式单独试，混响不行，但它恰恰是「离麦远」时最主要
/// 的那个：直达声之后紧跟一串越来越弱的反射声，把每个音素的起始和结尾糊
/// 在一起，而识别器正是靠这些边界切分音节的。
///
/// 为什么不用「合成脉冲响应 + 卷积」：第一版就是那么写的，对 6400 抽头的
/// 滤波器调 vDSP_conv 直接段错误，而且卷积要求拿到**整段**音频——搬到实时
/// 链路里根本用不了。Schroeder 网络是逐样本递推的，两边都能用。
///
/// 参数 RT60 = 混响衰减 60dB 所需秒数。录音棚 <0.3s，普通教室 0.4–0.8s，
/// 体育馆/大礼堂 >1.5s。
func applyReverb(_ samples: [Float], rt60: Double, sampleRate: Double) -> [Float] {
    // 梳状滤波器的延迟（样本数）。取互质的长度，避免几个延迟的驻波叠在同一点
    let combDelays = [1116, 1188, 1277, 1356, 1422, 1491]
    let allpassDelays = [225, 556, 441]

    var combs = combDelays.map { delay -> (buffer: [Float], index: Int, feedback: Float) in
        // g = 10^(-3D/(RT60·fs))：延迟 D 个样本后衰减到 -60dB 所对应的反馈系数
        let g = pow(10, -3 * Double(delay) / (rt60 * sampleRate))
        return ([Float](repeating: 0, count: delay), 0, Float(g))
    }
    var allpasses = allpassDelays.map { delay -> (buffer: [Float], index: Int, g: Float) in
        (([Float](repeating: 0, count: delay), 0, 0.5))
    }

    var output = [Float](repeating: 0, count: samples.count)
    let combCount = Float(combs.count)

    for i in 0..<samples.count {
        let x = samples[i]

        // 并联梳状：每一条都是「直达声 + 衰减后的自己」
        var sum: Float = 0
        for c in 0..<combs.count {
            let delayed = combs[c].buffer[combs[c].index]
            combs[c].buffer[combs[c].index] = x + delayed * combs[c].feedback
            combs[c].index = (combs[c].index + 1) % combs[c].buffer.count
            sum += delayed
        }
        var y = sum / combCount

        // 串联全通：把梳状产生的规则梳齿抹平成扩散的尾巴
        for a in 0..<allpasses.count {
            let delayed = allpasses[a].buffer[allpasses[a].index]
            let v = y + delayed * allpasses[a].g
            allpasses[a].buffer[allpasses[a].index] = v
            allpasses[a].index = (allpasses[a].index + 1) % allpasses[a].buffer.count
            y = delayed - y * allpasses[a].g
        }

        // 直达声单独补回来：Schroeder 网络会把它摊进梳状和里，
        // 不补的话「离得近」这件事就被一起模拟掉了，试的就不是混响了
        output[i] = y + x
    }
    return output
}

/// 二阶 Butterworth 高通，双线性变换系数，直接算不查表。
///
/// 加它的理由是实测的：102756 那条录音 0–80Hz 的底噪是 **-3.7 dBFS**
/// （几乎满量程的低频轰鸣），而这个频带里语音只比底噪高 5dB——也就是说
/// 这一整段能量几乎不含信息，却在扯整段录音的动态范围。
struct HighPass {
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private let b0, b1, b2, a1, a2: Double

    init(cutoff: Double, sampleRate: Double) {
        let omega = 2 * Double.pi * cutoff / sampleRate
        let k = tan(omega / 2)
        let q = 1 / 2.0.squareRoot()   // Butterworth
        let norm = 1 / (1 + k / q + k * k)
        b0 = norm
        b1 = -2 * norm
        b2 = norm
        a1 = 2 * (k * k - 1) * norm
        a2 = (1 - k / q + k * k) * norm
    }

    mutating func process(_ block: inout [Float]) {
        for i in 0..<block.count {
            let x0 = Double(block[i])
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            block[i] = Float(y0)
        }
    }
}

// MARK: - 读写

func loadMono(_ path: String) -> (samples: [Float], sampleRate: Double)? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let format = file.processingFormat
    let total = AVAudioFrameCount(file.length)
    guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
    do { try file.read(into: buffer) } catch { return nil }
    guard let data = buffer.floatChannelData else { return nil }
    // 多声道仍按第 0 声道取，和实时链路保持一致
    return (Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))), format.sampleRate)
}

func writeWAV(_ samples: [Float], sampleRate: Double, to path: String) {
    var pcm = Data(capacity: samples.count * 2)
    for value in samples {
        let clamped = max(-1, min(1, value))
        var int16 = Int16(clamped * 32_767).littleEndian
        withUnsafeBytes(of: &int16) { pcm.append(contentsOf: $0) }
    }
    var data = Data()
    func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let rate = UInt32(sampleRate)
    ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(1)
    u32(rate); u32(rate * 2); u16(2); u16(16)
    ascii("data"); u32(UInt32(pcm.count))
    data.append(pcm)
    try? data.write(to: URL(fileURLWithPath: path))
}

// MARK: - 素材加工

func atten(_ samples: [Float], by db: Double) -> [Float] {
    let gain = Float(pow(10, -db / 20))
    return samples.map { $0 * gain }
}

/// 注入白噪声到指定 SNR。SNR 按**整段语音的有效值**算——
/// 这样「注入 15dB SNR」的含义和 audio_health 量出来的动态范围可比。
func addNoise(_ samples: [Float], snrDB: Double, seed: UInt64 = 42) -> [Float] {
    var sum = 0.0
    for s in samples { sum += Double(s) * Double(s) }
    let signalRMS = (sum / Double(samples.count)).squareRoot()
    let noiseRMS = signalRMS / pow(10, snrDB / 20)

    var rng = seed
    func next() -> Double {
        // xorshift64*：确定性，同样的输入永远得到同样的素材
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        // 移位必须作用在**乘积**上，不能作用在常数上：`>>` 的优先级高于 `&*`，
        // 写成 `rng &* C >> 11` 会被解析成 `rng &* (C >> 11)`，常数被砍到 2^50，
        // 结果不再落在 2^64 上均匀分布，除以 2^53 后是 0…2048 而非 0…1
        // ——注入的就成了接近满量程的随机电报噪声，而不是白噪声。
        let product = rng &* 0x2545F4914F6CDD1D
        return Double(product >> 11) / Double(1 << 53) * 2 - 1
    }
    var noise = [Double](repeating: 0, count: samples.count)
    // 均匀分布 [-1,1] 的 RMS 是 1/√3，不是 1；不补这个 √3，
    // 标注的 SNR 会比实际好 4.8dB（差得不多，但会让「悬崖在哪」判断偏一档）
    let uniformToRMS = 3.0.squareRoot()
    for i in 0..<noise.count { noise[i] = next() * noiseRMS * uniformToRMS }

    // 自校验：噪声生成这种地方出错是**静默**的——波形看着仍在正常范围、
    // 文件照样能播，只有转录结果莫名其妙。所以量一下实际注入的 RMS，
    // 和要求值对不上就直接报出来，别让实验结论建立在坏素材上。
    var check = 0.0
    for v in noise { check += v * v }
    let actual = (check / Double(noise.count)).squareRoot()
    let errorDB = 20 * log10(max(actual, 1e-12) / max(noiseRMS, 1e-12))
    if abs(errorDB) > 1.0 {
        print(String(format: "⚠️ 噪声注入自校验失败：要求 RMS %.6f，实际 %.6f（差 %.1f dB）",
                     noiseRMS, actual, errorDB))
    }

    var mixed = [Float](repeating: 0, count: samples.count)
    for i in 0..<samples.count { mixed[i] = Float(Double(samples[i]) + noise[i]) }
    return mixed
}

// MARK: - 流式处理链

/// 分块处理，块间保留状态。块长固定 4096，和 MicTap 实际拿到的缓冲一致。
private let blockSize = 4_096

/// 逐块 RMS 的**包络跟踪器**：底噪往下跟得快、往上跟得慢。
///
/// 为什么不用「整段取 p5」：实时场景没有「整段」。底噪只能靠时间上的
/// 最小值跟踪来估——它必须快速认领一个更安静的瞬间（说话间隙），
/// 但在说话时又不能跟着语音往上爬，否则说着说着底噪估计就被抬高、
/// 增益随之降下去，声音忽大忽小。
struct EnvelopeTracker {
    var value: Double = 0
    var riseDBPerSecond: Double = 3.0
    var fallDBPerSecond: Double = 60.0
    var initialized = false

    mutating func update(_ rms: Double, blockSeconds: Double) -> Double {
        let x = max(rms, 1e-9)
        guard initialized else {
            value = x; initialized = true
            return value
        }
        let currentDB = 20 * log10(max(value, 1e-9))
        let targetDB = 20 * log10(x)
        let rate = targetDB < currentDB ? fallDBPerSecond : riseDBPerSecond
        let step = rate * blockSeconds
        let clamped = max(currentDB - step, min(currentDB + step, targetDB))
        value = pow(10, clamped / 20)
        return value
    }
}

/// 增益归一化：把**语音电平**拉到目标，而不是把整段拉到目标。
///
/// 关键在「语音电平」怎么认。用峰值会被单个爆音带偏，用整段 RMS 会被
/// 底噪拉低。这里用「语音帧的中位数级别的上包络」——语音包络本身，
/// 配一个上限增益和慢释放，避免把安静段连底噪一起推上去。
struct GainNormalizer {
    var speech = EnvelopeTracker(riseDBPerSecond: 12, fallDBPerSecond: 6)
    var gainDB: Double = 0
    var targetDB: Double
    var maxGainDB: Double
    var attackDBPerSecond: Double = 40
    var releaseDBPerSecond: Double = 8
    var muted = false

    mutating func process(_ block: inout [Float], blockSeconds: Double) -> Double {
        var sum = 0.0
        for s in block { sum += Double(s) * Double(s) }
        let rms = (sum / Double(block.count)).squareRoot()
        let level = speech.update(rms, blockSeconds: blockSeconds)

        let levelDB = 20 * log10(max(level, 1e-9))
        let want = max(-maxGainDB, min(maxGainDB, targetDB - levelDB))

        let rate = want < gainDB ? attackDBPerSecond : releaseDBPerSecond
        let step = rate * blockSeconds
        gainDB = max(gainDB - step, min(gainDB + step, want))

        let g = Float(pow(10, gainDB / 20))
        for i in 0..<block.count { block[i] *= g }
        return levelDB
    }
}

/// 宽带噪声门。存在的意义是**和谱减法对照**——我预期它伤语音，
/// 但这个预期必须拿数据说话，不能凭感觉否掉用户提的方案。
struct BroadbandGate {
    var noise = EnvelopeTracker(riseDBPerSecond: 1.0, fallDBPerSecond: 80.0)
    var openDB: Double = 9
    var state: Double = 1

    mutating func process(_ block: inout [Float], blockSeconds: Double) -> (noiseDB: Double, open: Bool) {
        var sum = 0.0
        for s in block { sum += Double(s) * Double(s) }
        let rms = (sum / Double(block.count)).squareRoot()
        let floor = noise.update(rms, blockSeconds: blockSeconds)

        let rmsDB = 20 * log10(max(rms, 1e-9))
        let floorDB = 20 * log10(max(floor, 1e-9))
        let isOpen = rmsDB - floorDB > openDB

        // 平滑开关，避免块边界的咔哒声
        let want: Double = isOpen ? 1 : 0
        let rate = isOpen ? 1.0 / 0.005 : 1.0 / 0.080   // 5ms 开、80ms 关
        let step = blockSeconds / rate
        state = max(0, min(1, state + (want - state) * min(1, step)))

        let g = Float(state)
        for i in 0..<block.count { block[i] *= g }
        return (floorDB, isOpen)
    }
}

/// 谱减法。逐 bin 估计噪声幅度，从幅度谱里减掉，再做增益下限保护。
///
/// 为什么不用宽带门：门只有「开/关」两档，语音里的清音、字头本身就
/// 比元音低 20–30dB，宽带门会把它们和底噪一起切掉——而识别器恰恰靠
/// 这些部分分辨辅音。谱减法按频率分别判断，低频的空调噪声被压掉的同时，
/// 高频的齿音能留下。
///
/// 实现要点（都是坑）：
/// - 50% 重叠 + Hann，且分析/合成各加一次窗，保证 COLA 求和为常数；
/// - 过减因子 > 1，宁可多减一点，残留噪声比残留语音更伤识别；
/// - 增益下限不设 0，否则会产生「音乐噪声」——一种比原底噪更伤识别的
///   随机音调，听起来像水声。
struct SpectralSubtractor {
    let fftSize: Int
    let hop: Int
    var over: Double
    var floorGain: Double

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var noiseMag: [Float]
    private var inBuffer: [Float]
    private var outBuffer: [Float]
    private var pending: [Float] = []

    init?(fftSize: Int = 1024, over: Double, floorGain: Double) {
        self.fftSize = fftSize
        self.hop = fftSize / 2
        self.over = over
        self.floorGain = floorGain

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fft = fft

        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        self.window = w

        self.noiseMag = [Float](repeating: 0, count: fftSize / 2)
        self.inBuffer = [Float](repeating: 0, count: fftSize)
        self.outBuffer = [Float](repeating: 0, count: fftSize)
    }

    /// 逐块处理，块内按 hop 切帧。返回和输入等长的输出。
    mutating func process(_ block: [Float]) -> [Float] {
        pending.append(contentsOf: block)

        var produced: [Float] = []
        produced.reserveCapacity(block.count)

        while pending.count >= fftSize {
            let frame = Array(pending[0..<fftSize])
            let output = processFrame(frame)
            // 合成时也加窗（分析窗 × 合成窗 = Hann²，50% 重叠下和恒定）
            for i in 0..<fftSize { outBuffer[i] += output[i] * window[i] }

            // 前半个窗已经攒够重叠，可以吐出
            produced.append(contentsOf: outBuffer[0..<hop])
            outBuffer.removeFirst(hop)
            outBuffer.append(contentsOf: [Float](repeating: 0, count: hop))

            pending.removeFirst(hop)
        }
        return produced
    }

    private mutating func processFrame(_ frame: [Float]) -> [Float] {
        let n = fftSize
        let half = n / 2

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)

                // 1. 噪声幅度估计：最小值快跟、慢抬
                for k in 0..<half {
                    let mag = (rp[k] * rp[k] + ip[k] * ip[k]).squareRoot()
                    if mag < noiseMag[k] {
                        noiseMag[k] = mag
                    } else {
                        noiseMag[k] = min(mag, noiseMag[k] * 1.002)
                    }
                }

                // 2. 逐 bin 增益
                for k in 0..<half {
                    let mag = max((rp[k] * rp[k] + ip[k] * ip[k]).squareRoot(), 1e-9)
                    let clean = mag - Float(over) * noiseMag[k]
                    let ratio = Double(max(clean, 0) / mag)
                    let g = Float(max(floorGain, ratio))
                    rp[k] *= g
                    ip[k] *= g
                }

                fft.inverse(input: split, output: &split)
            }
        }

        // vDSP 的 inverse 结果需要除以 N 还原幅度
        var result = [Float](repeating: 0, count: n)
        let scale = 1 / Float(n)
        for k in 0..<half {
            result[2 * k] = real[k] * scale
            if 2 * k + 1 < n { result[2 * k + 1] = imag[k] * scale }
        }
        return result
    }
}

// MARK: - 入口

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("用法: swift tools/dsp_lab.swift <输入.wav> <输出.wav> --mode <none|gain|gate|sub> [选项]")
    exit(1)
}
let inputPath = args.removeFirst()
let outputPath = args.removeFirst()

var opts = Options()
var i = 0
while i < args.count {
    func nextDouble() -> Double? {
        guard i + 1 < args.count, let v = Double(args[i + 1]) else { return nil }
        i += 1
        return v
    }
    switch args[i] {
    case "--mode": if i + 1 < args.count { i += 1; opts.mode = args[i] }
    case "--target": if let v = nextDouble() { opts.target = v }
    case "--max-gain": if let v = nextDouble() { opts.maxGain = v }
    case "--over": if let v = nextDouble() { opts.over = v }
    case "--floor": if let v = nextDouble() { opts.floorDB = v }
    case "--snr": if let v = nextDouble() { opts.snr = v }
    case "--atten": if let v = nextDouble() { opts.atten = v }
    case "--add-noise": opts.addNoise = true
    case "--mix": if i + 1 < args.count { i += 1; opts.mixPath = args[i] }
    case "--mix-gain": if let v = nextDouble() { opts.mixGain = v }
    case "--report": opts.report = true
    case "--hp": if let v = nextDouble() { opts.highpass = v }
    case "--reverb": if let v = nextDouble() { opts.reverb = v }
    case "--trim": if let v = args[i + 1] as String? {
        let parts = v.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { opts.trimStart = parts[0]; opts.trimDuration = parts[1]; i += 1 }
    }
    default:
        print("未知参数: \(args[i])")
        exit(1)
    }
    i += 1
}

guard let loaded = loadMono(inputPath) else {
    print("❌ 读不了 \(inputPath)")
    exit(1)
}
var samples = loaded.samples
let sampleRate = loaded.sampleRate
let blockSeconds = Double(blockSize) / sampleRate
var sourceDuration = Double(samples.count) / sampleRate

// 前置加工（合成实验用），不算在「处理链」里
var preNote = ""
if opts.trimDuration > 0 {
    let from = min(Int(opts.trimStart * sampleRate), samples.count)
    let to = min(from + Int(opts.trimDuration * sampleRate), samples.count)
    samples = Array(samples[from..<to])
    sourceDuration = Double(samples.count) / sampleRate
    preNote += " 截取 \(Int(opts.trimStart))s 起 \(Int(opts.trimDuration))s"
}
if opts.reverb > 0 {
    samples = applyReverb(samples, rt60: opts.reverb, sampleRate: sampleRate)
    preNote += " 混响 RT60 \(opts.reverb)s"
}
// 把一段**已知内容**的干净语音混进真实录音底噪里。
//
// 这是整个诊断里最直接的一问：房间的噪声到底有没有盖住语音？
// 混进去的那段词是已知的——它要是被准确转出来，就说明识别器在这片噪声里
// 听得清清楚楚，「识别不准」的锅不在噪声；它要是糊了，才轮到降噪上场。
if let mixPath = opts.mixPath {
    guard let mixed = loadMono(mixPath) else {
        print("❌ 读不了混入源 \(mixPath)")
        exit(1)
    }
    let gain = Float(pow(10, opts.mixGain / 20))
    let count = min(samples.count, mixed.samples.count)
    for i in 0..<count { samples[i] += mixed.samples[i] * gain }
    preNote += " 混入 \(URL(fileURLWithPath: mixPath).lastPathComponent) @ \(opts.mixGain)dB"
}

if opts.addNoise {
    samples = addNoise(samples, snrDB: opts.snr)
    preNote += " 注入白噪声 SNR \(opts.snr)dB"
}
if opts.atten > 0 {
    samples = atten(samples, by: opts.atten)
    preNote += " 整体衰减 \(opts.atten)dB"
}

func rmsDB(_ s: [Float]) -> Double {
    guard !s.isEmpty else { return -99 }
    var sum = 0.0
    for v in s { sum += Double(v) * Double(v) }
    return 20 * log10(max((sum / Double(s.count)).squareRoot(), 1e-9))
}

// MARK: - 频带分析：噪声和语音分别长什么样
//
// 这是决定「该用哪种降噪」的那一步。
// 宽带动态范围只告诉你「信噪比差」，不告诉你**差在哪个频带**——
// 而低频轰鸣、宽带白噪、混响尾巴这三种，对应的处理手段完全不同：
// 低频轰鸣高通就能解决，宽带噪声要靠谱减，混响则两种都救不了。
func bandAnalysis(_ samples: [Float], sampleRate: Double) {
    let frameSize = Int(sampleRate * 0.02)
    let fftSize = 2048
    let log2n = vDSP_Length(log2(Double(fftSize)))
    guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self),
          samples.count > fftSize else { return }

    var windowFn = [Float](repeating: 0, count: fftSize)
    vDSP_hann_window(&windowFn, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))

    // 先按帧电平排序，取最安静的一批当噪声、最响的一批当语音
    var frames: [(rms: Double, start: Int)] = []
    var start = 0
    while start + fftSize <= samples.count {
        var sum = 0.0
        for i in start..<(start + frameSize) { sum += Double(samples[i]) * Double(samples[i]) }
        frames.append(((sum / Double(frameSize)).squareRoot(), start))
        start += frameSize
    }
    guard frames.count >= 20 else { print("   （太短，无法分帧）"); return }
    let sorted = frames.sorted { $0.rms < $1.rms }
    let decile = max(1, sorted.count / 10)
    let noiseFrames = Array(sorted[0..<decile])
    let speechFrames = Array(sorted[(sorted.count - decile)...])

    let edges: [Double] = [0, 80, 200, 500, 1_000, 2_000, 4_000, 6_000, 8_000, 12_000, 16_000, 24_000]
    var noiseBand = [Double](repeating: 0, count: edges.count - 1)
    var speechBand = [Double](repeating: 0, count: edges.count - 1)

    func accumulate(_ list: [(rms: Double, start: Int)], into band: inout [Double]) {
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        for frame in list {
            var chunk = Array(samples[frame.start..<(frame.start + fftSize)])
            vDSP_vmul(chunk, 1, windowFn, 1, &chunk, 1, vDSP_Length(fftSize))
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    chunk.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                                  vDSP_Length(fftSize / 2))
                    }
                    fft.forward(input: split, output: &split)
                    for b in 0..<(edges.count - 1) {
                        let lo = max(1, Int(edges[b] / (sampleRate / 2) * Double(fftSize / 2)))
                        let hi = min(fftSize / 2 - 1, Int(edges[b + 1] / (sampleRate / 2) * Double(fftSize / 2)))
                        guard lo <= hi else { continue }
                        var sum = 0.0
                        for k in lo...hi { sum += Double(rp[k] * rp[k] + ip[k] * ip[k]) }
                        band[b] += sum / Double(hi - lo + 1)
                    }
                }
            }
        }
    }
    accumulate(noiseFrames, into: &noiseBand)
    accumulate(speechFrames, into: &speechBand)

    // 归一化成每帧平均能量，再转 dBFS 量级
    let nz = Double(noiseFrames.count), sp = Double(speechFrames.count)
    print("")
    print("    频带         底噪         语音        语音−底噪")
    for b in 0..<(edges.count - 1) {
        let n = noiseBand[b] / nz, s = speechBand[b] / sp
        guard n > 0 || s > 0 else { continue }
        let nDB = 10 * log10(max(n, 1e-20))
        let sDB = 10 * log10(max(s, 1e-20))
        let diff = sDB - nDB
        let bar = String(repeating: "█", count: max(0, Int(diff / 2)))
        print(String(format: "   %6.0f–%-6.0f %7.1f dB   %7.1f dB   %+6.1f dB  %@",
                     edges[b], edges[b + 1], nDB, sDB, diff, bar))
    }
    print("")
    print("   （最后一列是这个频带里语音比底噪高多少——低于 6dB 的频带基本不携带信息）")
}

// 这里原本有一个「从录音直接估 RT60」的函数，已删除——它是条死路。
//
// 做法是 Schroeder 反向积分拟合衰减斜率。两个问题：
//   1. 它量的是我自己的 20ms 分析窗的拖尾，不是房间。拿已知 RT60 的合成
//      素材标定，0.05s 和 1.8s 都量成 0.5–0.7s，毫无区分度。
//   2. 改成「余响轮廓」（结束点后 +50/100/200/400ms 还剩多少 dB）仍然不单调：
//      连续说话时根本找不到真正的结束点，检出的全是句子中间的换气。
// 要量准混响得有**已知激励**（扫频、发令枪），录音里没有。
//
// 留这段话是为了别再走一遍。真要判断混响，走 --reverb 那条路：
// 给干净素材注入已知 RT60，看识别什么时候开始崩，比反过来从录音倒推可靠得多。

if opts.mode == "analyze" {
    print("输入: \(inputPath)  \(String(format: "%.1f", sourceDuration))s  \(Int(sampleRate))Hz  整体 \(String(format: "%.1f", rmsDB(samples))) dBFS\(preNote)")
    bandAnalysis(samples, sampleRate: sampleRate)
    exit(0)
}

print("输入: \(inputPath)  \(String(format: "%.1f", sourceDuration))s  \(Int(sampleRate))Hz  整体 \(String(format: "%.1f", rmsDB(samples))) dBFS\(preNote)")
print("模式: \(opts.mode)" + (opts.mode == "sub" ? "（过减 \(opts.over)，增益下限 \(opts.floorDB)dB）" : ""))

// 逐块跑处理链
var output: [Float] = []
output.reserveCapacity(samples.count)

var normalizer = GainNormalizer(targetDB: opts.target, maxGainDB: opts.maxGain)
var gate = BroadbandGate()
guard let subtractorBox = SpectralSubtractor(over: opts.over, floorGain: pow(10, opts.floorDB / 20)) else {
    print("❌ 无法构建谱减法器（FFT 建不出来）")
    exit(1)
}
var subtractor = subtractorBox
// cutoff 为 0 时双线性变换退化成极点落在单位圆上的滤波器（自激），必须显式绕开
var highpass: HighPass? = opts.highpass > 0
    ? HighPass(cutoff: opts.highpass, sampleRate: sampleRate)
    : nil

var reportRows: [String] = []
var pos = 0
var blockIndex = 0

while pos < samples.count {
    let count = min(blockSize, samples.count - pos)
    var block = Array(samples[pos..<(pos + count)])
    // 末尾补零到整块，保证谱减法有完整帧；输出时再截回去
    if block.count < blockSize { block.append(contentsOf: [Float](repeating: 0, count: blockSize - block.count)) }

    var noiseDB = 0.0
    var gateOpen = true

    // 高通放在最前：低频轰鸣不先去掉，谱减法的噪声估计会被它主导，
    // 于是「降噪」把力气全花在 0–80Hz，真正碍事的宽带噪声一点没动
    highpass?.process(&block)

    switch opts.mode {
    case "sub":
        var processed = subtractor.process(block)
        if processed.count < blockSize {
            processed.append(contentsOf: [Float](repeating: 0, count: blockSize - processed.count))
        }
        block = processed
        _ = normalizer.process(&block, blockSeconds: blockSeconds)
    case "gate":
        (noiseDB, gateOpen) = gate.process(&block, blockSeconds: blockSeconds)
        _ = normalizer.process(&block, blockSeconds: blockSeconds)
    case "gain":
        _ = normalizer.process(&block, blockSeconds: blockSeconds)
    default:
        break
    }

    if opts.report, blockIndex % 8 == 0 {
        let t = Double(pos) / sampleRate
        reportRows.append(String(
            format: "   %6.1fs  入 %6.1f dB  底噪 %6.1f dB  增益 %+5.1f dB%@",
            t, rmsDB(block), noiseDB, normalizer.gainDB, gateOpen ? "" : "  门关"
        ))
    }

    output.append(contentsOf: block[0..<count])
    pos += count
    blockIndex += 1
}

if opts.report {
    print("")
    print("    时间      块电平     估计底噪    施加增益")
    for row in reportRows { print(row) }
}

writeWAV(output, sampleRate: sampleRate, to: outputPath)
print("输出: \(outputPath)  整体 \(String(format: "%.1f", rmsDB(output))) dBFS")
