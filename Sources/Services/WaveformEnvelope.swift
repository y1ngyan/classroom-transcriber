import Foundation
import AVFoundation
import CryptoKit

/// 录音列表缩略图用的**真实包络**（P15-1）。
///
/// 为什么要有它：列表以前只有文字和圆角矩形，没有任何承载音频信息的东西。
/// 缩略图必须是**这条录音自己的形状**——随机数装饰出来的波形在视觉上成立，
/// 但它对用户是假的：两条不同录音会长得一样，长度也对不上。
///
/// ## 流式读，不整段进内存
///
/// 一节课 1.5 小时 = 48 kHz × 5400 秒 ≈ 2.6 亿帧；整读成 float 就是 1 GB 量级。
/// 这里每次只读 **4096 帧**（约 85 ms），记一个块峰值就丢掉，内存占用与
/// 音频长度无关。
///
/// ## 缓存
///
/// 落盘在 `Application Support/ClassroomTranscriber/waveforms/<键>.json`。
/// 键是**文件路径的 SHA-1 前 16 位**，不是文件内容哈希：内容哈希要先读完整段
/// 音频才知道键是什么，那缓存就失去意义了。内容有没有变由条目里的
/// `size + mtime` 校验——文件被替换/追加时这两个数会变，缓存自动失效。
///
/// ## 线程
///
/// `compute` 是同步纯函数，调用方负责**不要在主线程上直接调用**；
/// 列表行走 `Task.detached(priority: .utility)`。自检里的调用计数由调用方
/// 用 `onAudioOpen` 回调数，缓存命中时该回调一次都不会触发。
enum WaveformEnvelope {

    /// 列表缩略图固定 64 桶。派单写死的规格，不跟宽度走——
    /// 波形是缩略图，不是可缩放的图表
    static let bucketCount = 64

    /// 缓存目录。测试可注入自己的临时目录，生产走用户库根
    static var defaultCacheDirectory: URL {
        RecordingStorage.libraryRoot.appendingPathComponent("waveforms", isDirectory: true)
    }

    /// `--ui-snapshot` 下列表行用的固定数组。
    ///
    /// 快照夹具的会话**没有对应 wav**（`fileName == nil`），真算只会得到空数组；
    /// 而快照要验的正是「卡片上有波形条」。
    ///
    /// **按会话 id 做种子**，不是全局一个常量：三条录音的缩略图必须各不同，
    /// 否则截图上看不出「这是这条录音的波形」，只会像一套重复的装饰纹样。
    /// 种子只取 UUID 的字节，不取 `Hasher`——后者每个进程随机，快照
    /// 就不可复现了。形态按人说话造：成串的短促音节峰 + 段落间明显的静音，
    /// 不是一条均匀正弦（24pt 高的正弦看起来就是等宽条纹）
    static func snapshotFixture(seed: UUID) -> [Float] {
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
        var state = bytes.reduce(UInt64(0xcbf29ce484222325)) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        func unit() -> Float { Float(next() >> 11) / Float(1 << 53) }

        var values = [Float](repeating: 0.04, count: bucketCount)
        var index = Int(next() % 4)          // 起头留一点空白
        let runCount = 3 + Int(next() % 3)   // 一场说话 3–5 串
        for _ in 0..<runCount {
            guard index < bucketCount else { break }
            // 每串由若干组「音节」构成：2–3 个桶一个峰，峰间有浅谷。
            // 组数随机，整串长度天然不规则——这正是口语的重音节奏
            let syllables = 2 + Int(next() % 3)
            for _ in 0..<syllables {
                let length = 2 + Int(next() % 2)
                let peak = 0.45 + 0.55 * unit()
                let shape: [Float] = [0.55, 1.0, 0.45]
                for offset in 0..<length {
                    guard index < bucketCount else { break }
                    values[index] = min(1, peak * shape[min(offset, shape.count - 1)])
                    index += 1
                }
                // 音节之间偶尔留一个很浅的谷，不是归零——同一串说话里的换气
                if next() % 3 == 0, index < bucketCount {
                    values[index] = 0.10 + 0.08 * unit()
                    index += 1
                }
            }
            // 串与串之间：明显的静音段（0.02–0.07），长度 3–8 桶
            index += 3 + Int(next() % 6)
        }
        return values
    }

    /// 进程是不是在跑界面快照。放在这里而不是让 `RecordingsView` 去查参数：
    /// 快照下**整条计算路径都不该起**，判定点只能有一个
    static var isSnapshotMode: Bool {
        CommandLine.arguments.contains("--ui-snapshot")
    }

    // MARK: - 计算

    /// 算一条音频的 64 桶包络。读失败（文件不在、不是音频）返回空数组；
    /// 读得到但没有样本返回 64 个 0（长度恒等于 `buckets`）。
    ///
    /// - Parameters:
    ///   - cacheDirectory: nil = 生产缓存目录；自检传临时目录
    ///   - onAudioOpen: 真的去打开音频文件时调用一次（缓存命中不调用）。
    ///     给自检数「第二次有没有再读音频」用
    static func compute(
        url: URL,
        buckets: Int = bucketCount,
        cacheDirectory: URL? = nil,
        onAudioOpen: (@Sendable () -> Void)? = nil
    ) -> [Float] {
        guard buckets > 0 else { return [] }
        let cache = cacheDirectory ?? defaultCacheDirectory
        let cacheURL = cache.appendingPathComponent(cacheKey(for: url) + ".json")
        let fingerprint = fileFingerprint(url)

        if let fingerprint,
           let entry = readCache(cacheURL),
           entry.size == fingerprint.size,
           entry.mtime == fingerprint.mtime,
           entry.buckets == buckets {
            return entry.values
        }

        guard let fingerprint else { return [] }
        onAudioOpen?()
        guard let peaks = streamBlockPeaks(url: url) else { return [] }
        let values = merge(peaks: peaks, buckets: buckets)
        writeCache(CacheEntry(size: fingerprint.size, mtime: fingerprint.mtime,
                             buckets: buckets, values: values), to: cacheURL, in: cache)
        return values
    }

    /// 每 4096 帧一块，取块内 `max(abs)`。只保留峰值数组，不保留 PCM
    private static func streamBlockPeaks(url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
        else { return nil }

        var peaks: [Float] = []
        peaks.reserveCapacity(1024)
        // 按文件长度读，而不是「一直读到 0 帧」：`AVAudioFile.read` 在
        // 越过 EOF 时**抛错**（nilError），不会安静地返回 0 帧。按剩余
        // 帧数算好每次的 frameCount，最后一块就不会踩到 EOF。
        // 自检第一版就是在这上面红的——包络长度 0，而文件本身是好的
        var consumed: AVAudioFramePosition = 0
        while consumed < file.length {
            let remaining = file.length - consumed
            let toRead = AVAudioFrameCount(min(4096, remaining))
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                return nil
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            consumed += AVAudioFramePosition(frames)
            guard let channels = buffer.floatChannelData else { return nil }
            var peak: Float = 0
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for i in 0..<frames {
                    peak = max(peak, abs(samples[i]))
                }
            }
            peaks.append(peak)
        }
        return peaks
    }

    /// 块峰值 → 桶。文件比桶数短时（少于 64 块），多个桶取到同一块，
    /// 形状会被拉宽但长度仍是 64——缩略图要的是固定的宽度
    private static func merge(peaks: [Float], buckets: Int) -> [Float] {
        guard !peaks.isEmpty else { return Array(repeating: 0, count: buckets) }
        var values = [Float](repeating: 0, count: buckets)
        let count = peaks.count
        for i in 0..<buckets {
            let start = i * count / buckets
            let end = min(count, max(start + 1, (i + 1) * count / buckets))
            var peak: Float = 0
            for j in start..<end { peak = max(peak, peaks[j]) }
            values[i] = peak
        }
        // 归一化到 0…1。全静音（max == 0）保持全 0，不做除零
        guard let maximum = values.max(), maximum > 0 else { return values }
        return values.map { min(1, max(0, $0 / maximum)) }
    }

    // MARK: - 缓存

    private struct CacheEntry: Codable {
        var size: Int64
        var mtime: Double
        var buckets: Int
        var values: [Float]
    }

    private struct Fingerprint {
        var size: Int64
        var mtime: Double
    }

    private static func fileFingerprint(_ url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Fingerprint(size: size, mtime: modified.timeIntervalSince1970)
    }

    /// 文件路径的 SHA-1 前 16 位。**不是内容哈希**，理由见类型注释
    private static func cacheKey(for url: URL) -> String {
        let digest = Insecure.SHA1.hash(data: Data(url.standardizedFileURL.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private static func readCache(_ url: URL) -> CacheEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private static func writeCache(_ entry: CacheEntry, to url: URL, in directory: URL) {
        // 缓存失败不影响功能：下一次重算就是了，不该因此报错给用户
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil,
            let data = try? JSONEncoder().encode(entry)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 自检

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// `--waveform-selftest`：三条判据，全部离线（临时目录、合成 wav、
    /// 不碰用户录音库、不发声、不加载模型）
    static func selfTest() -> SelfTestResult {
        var lines: [String] = ["波形包络自检（离线 · 临时目录 · 不碰用户录音库）"]
        var passed = 0
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-selftest-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let audio = root.appendingPathComponent("fixture.wav")
        let cacheA = root.appendingPathComponent("cache-a", isDirectory: true)
        let cacheB = root.appendingPathComponent("cache-b", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        guard writeFixture(to: audio) else {
            lines.append("  ❌ 造不出合成 wav（后面两条无法判定）")
            return SelfTestResult(lines: lines, passed: passed, failed: failed + 1)
        }

        let counter = ReadCounter()

        // ① 长度与值域
        let values = compute(url: audio, cacheDirectory: cacheA,
                             onAudioOpen: { counter.bump() })
        check(values.count == bucketCount,
              "包络长度 = 64", "（实得 \(values.count)）")
        check(values.allSatisfy { $0 >= 0 && $0 <= 1 },
              "值域全在 0…1", "（min \(values.min() ?? 0) / max \(values.max() ?? 0)）")

        // ② 确定性：换一个空缓存目录再算一遍，两次必须逐值相同。
        // 不复用 cacheA —— 那第二次会命中缓存，验的是缓存而不是计算
        let again = compute(url: audio, cacheDirectory: cacheB,
                            onAudioOpen: { counter.bump() })
        check(again == values, "同一文件算两次结果一致（确定性）",
              "（两次都是 \(values.count) 个值）")

        // ③ 缓存命中：第三次仍用 cacheA，不该再打开音频。
        // 计数按「打开音频」次数算，不是按函数调用次数——函数每次都被调用，
        // 区别只在它有没有去读文件
        let before = counter.count
        let cached = compute(url: audio, cacheDirectory: cacheA,
                             onAudioOpen: { counter.bump() })
        check(counter.count == before,
              "缓存命中：第二次调用不再读音频",
              "（打开音频次数 \(before) → \(counter.count)）")
        check(cached == values, "缓存读回来的值与首次一致")

        lines.append("")
        lines.append(failed == 0
                     ? "✅ 波形包络自检通过（\(passed) 条）"
                     : "❌ 波形包络自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }

    /// 造一段 64 块、每块振幅不同的 wav。块内是正弦，块间振幅变化，
    /// 这样归并出来的 64 个桶有高有低——全 1 的数组分不出「算对了」和「没算」
    private static func writeFixture(to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let channel = buffer.floatChannelData?[0]
        else { return false }
        buffer.frameLength = 4096
        let blockCount = bucketCount
        for block in 0..<blockCount {
            let amplitude = Float(0.15 + 0.85 * Double(block % 13) / 13.0)
            for i in 0..<4096 {
                let phase = Double(i) / 48_000.0 * 2 * .pi * 440
                channel[i] = amplitude * Float(sin(phase))
            }
            do { try file.write(from: buffer) } catch { return false }
        }
        return true
    }

    /// 自检用的打开计数。`compute` 可能从任意线程调，锁保护
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var opens = 0
        func bump() {
            lock.lock()
            opens += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return opens
        }
    }
}
