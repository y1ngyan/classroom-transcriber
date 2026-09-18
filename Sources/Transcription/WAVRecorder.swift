import AVFoundation
import Foundation

/// 边录边落盘的 16-bit PCM WAV 写入器。
///
/// **为什么不用 `AVAudioFile`**：它的处理格式固定是 Float32，往里写 Int16
/// 缓冲会直接 `CAVerboseAbort` / SIGTRAP 崩溃（本项目踩过）。所以自己写头。
///
/// **为什么流式而不是攒完再写**：48kHz 单声道 Int16 是 96KB/s，
/// 一节课一小时就是 345MB，全放内存不现实。先占 44 字节头，收尾回填长度。
///
/// **为什么不在音频线程直接写盘**：tap 回调跑在实时音频线程上，磁盘 I/O
/// 的抖动会造成采集丢帧。`append` 在音频线程只做 float→Int16 的转换
/// （几千个样本，微秒级），写盘丢给串行队列。
final class WAVRecorder: @unchecked Sendable {

    private let handle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private let queue = DispatchQueue(label: "com.asuka.classroomtranscriber.wavwriter")
    private let lock = NSLock()

    private var dataBytes = 0
    private var isClosed = false

    /// 标准 PCM 头长度
    private static let headerSize = 44

    /// 落在磁盘上的字节数（不含头）
    var recordedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return dataBytes
    }

    var durationSeconds: Double {
        let bytesPerSecond = Double(sampleRate) * Double(channels) * 2
        guard bytesPerSecond > 0 else { return 0 }
        return Double(recordedBytes) / bytesPerSecond
    }

    init?(url: URL, sampleRate: UInt32, channels: UInt16) {
        guard sampleRate > 0, channels > 0 else { return nil }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { return nil }

        self.handle = handle
        self.sampleRate = sampleRate
        self.channels = channels

        // 头先占位，收尾时 seek 回来回填真实长度
        try? handle.write(contentsOf: Data(repeating: 0, count: Self.headerSize))
    }

    /// **在音频线程调用。** 只做转换 + 入队，不做真正的 I/O。
    ///
    /// 只取第 0 声道：源是已经抽好的单声道，但这里不假设——多声道缓冲
    /// 也按第 0 声道处理，避免又踩到 4ch→1ch 静音下混那个坑。
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1

        var samples = [Int16](repeating: 0, count: frames)
        for index in 0..<frames {
            let value = channel[index * stride]
            // 先夹到 [-1, 1]：越界值直接乘 32767 会绕回成反相噪声
            samples[index] = Int16(max(-1, min(1, value)) * 32_767)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        lock.lock(); dataBytes += data.count; lock.unlock()

        // self 是 @unchecked Sendable，捕获它而不是捕获 FileHandle
        queue.async { self.write(data) }
    }

    private func write(_ data: Data) {
        try? handle.write(contentsOf: data)
    }

    /// 收尾：排空队列 → 回填头 → 关闭。返回写入的音频字节数。
    ///
    /// 用 `queue.sync` 而不是 `async`——必须确保所有缓冲都落盘了才能回填
    /// 长度，否则文件头会少算最后几块，播放器会截断。
    @discardableResult
    func finish() -> Int {
        queue.sync {}

        lock.lock()
        guard !isClosed else {
            let total = dataBytes
            lock.unlock()
            return total
        }
        isClosed = true
        let total = dataBytes
        lock.unlock()

        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(
            dataBytes: total,
            sampleRate: sampleRate,
            channels: channels
        ))
        try? handle.close()
        return total
    }

    // MARK: - 头

    private static func header(dataBytes: Int, sampleRate: UInt32, channels: UInt16) -> Data {
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        let byteRate = sampleRate * UInt32(channels) * 2

        ascii("RIFF"); u32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(channels * 2); u16(16)
        ascii("data"); u32(UInt32(dataBytes))

        return data
    }
}

extension WAVRecorder {

    /// 无头自检：写入一段已知正弦波，再把文件读回来逐项核对。
    ///
    /// 不用麦克风，纯确定性——这样音频存档这条链路可以脱离「有没有权限 /
    /// 说没说话 / 环境吵不吵」独立回归验证。
    static func selfTest() -> [String] {
        var lines: [String] = []

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wav-selftest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let sampleRate: UInt32 = 48_000
        let totalFrames = 48_000  // 整 1 秒
        let chunkFrames = 4_096
        let frequency = 440.0
        let amplitude: Float = 0.5

        guard let recorder = WAVRecorder(url: url, sampleRate: sampleRate, channels: 1) else {
            return ["❌ 无法创建 WAVRecorder"]
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            return ["❌ 无法创建缓冲格式"]
        }

        // 分块写入，顺带验证「多次 append + finish 排空」这条路径，
        // 而不是一次性写完——真实录音正是每 4096 帧一块
        var written = 0
        while written < totalFrames {
            let frames = min(chunkFrames, totalFrames - written)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ), let channel = buffer.floatChannelData?[0] else {
                return lines + ["❌ 无法创建 PCM 缓冲"]
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            for index in 0..<frames {
                let time = Double(written + index) / Double(sampleRate)
                channel[index] = Float(sin(2 * Double.pi * frequency * time)) * amplitude
            }
            recorder.append(buffer)
            written += frames
        }

        let dataBytes = recorder.finish()
        let expectedBytes = totalFrames * 2

        lines.append("写入 \(written) 帧（\(written / chunkFrames + 1) 块）")
        lines.append("  \(dataBytes == expectedBytes ? "✅" : "❌") 音频数据 \(dataBytes) 字节，期望 \(expectedBytes)")

        guard let data = try? Data(contentsOf: url) else {
            return lines + ["❌ 文件读不回来"]
        }
        lines.append("  \(data.count == 44 + expectedBytes ? "✅" : "❌") 文件总长 \(data.count) 字节，期望 \(44 + expectedBytes)")

        func ascii(_ offset: Int, _ length: Int) -> String {
            String(data: data.subdata(in: offset..<(offset + length)), encoding: .ascii) ?? "?"
        }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        func u16(_ offset: Int) -> UInt16 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        }
        func check(_ name: String, _ actual: String, _ expected: String) {
            lines.append("  \(actual == expected ? "✅" : "❌") \(name) = \(actual)\(actual == expected ? "" : "，期望 \(expected)")")
        }

        lines.append("头字段:")
        check("RIFF", ascii(0, 4), "RIFF")
        check("RIFF 长度字段", String(u32(4)), String(36 + expectedBytes))
        check("WAVE", ascii(8, 4), "WAVE")
        check("fmt ", ascii(12, 4), "fmt ")
        check("编码（1=PCM）", String(u16(20)), "1")
        check("声道数", String(u16(22)), "1")
        check("采样率", String(u32(24)), String(sampleRate))
        check("字节率", String(u32(28)), String(sampleRate * 2))
        check("位深", String(u16(34)), "16")
        check("data", ascii(36, 4), "data")
        check("data 长度字段", String(u32(40)), String(expectedBytes))

        // 全量回读比对。
        //
        // 不能只抽查几个点：440Hz 正弦在 0 / 0.25s / 0.5s 处恰好都过零，
        // 期望值本来就是 0，写进去全是静音也会「通过」——那种抽查是假通过。
        // 这里逐帧比对，并且额外报出回读峰值：真的是静音的话峰值会是 0。
        var maxError = 0.0
        var peak = 0.0
        for frame in 0..<totalFrames {
            let raw = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 44 + frame * 2, as: Int16.self)
            }
            let actual = Double(raw) / 32_767
            let expected = sin(2 * Double.pi * frequency * Double(frame) / Double(sampleRate)) * Double(amplitude)
            maxError = max(maxError, abs(actual - expected))
            peak = max(peak, abs(actual))
        }

        lines.append("内容回读（逐帧比对 \(totalFrames) 帧）:")
        lines.append("  \(abs(peak - Double(amplitude)) < 0.001 ? "✅" : "❌") 回读峰值 \(String(format: "%.4f", peak))，期望 \(String(format: "%.4f", Double(amplitude)))（静音会是 0）")
        // 16-bit 量化本身的误差上限约 1/32767，留一点余量
        lines.append("  \(maxError < 0.001 ? "✅" : "❌") 逐帧最大偏差 \(String(format: "%.5f", maxError))（16-bit 量化误差上限约 0.00003）")

        lines.append(contentsOf: clippingCheck(sampleRate: sampleRate, format: format))
        return lines
    }

    /// 越界输入必须被夹到满量程。
    ///
    /// 不做夹取的话，`Float(4.0) * 32767` 转 Int16 会绕回成一个小值——
    /// 听感上是爆音，而且完全反相，比单纯削顶难查得多。
    private static func clippingCheck(sampleRate: UInt32, format: AVAudioFormat) -> [String] {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wav-clip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let frameCount = 8
        guard let recorder = WAVRecorder(url: url, sampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0]
        else {
            return ["❌ 越界夹取测试：无法创建缓冲"]
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount { channel[index] = index < 4 ? 4.0 : -4.0 }
        recorder.append(buffer)
        recorder.finish()

        guard let data = try? Data(contentsOf: url) else {
            return ["❌ 越界夹取测试：文件读不回来"]
        }

        var overshoot: Int16 = 0
        for index in 0..<frameCount {
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 44 + index * 2, as: Int16.self)
            }
            if abs(Int(value)) > abs(Int(overshoot)) { overshoot = value }
        }

        let ok = overshoot == 32_767 || overshoot == -32_767
        return ["  \(ok ? "✅" : "❌") 越界输入(±4.0)被夹到满量程，实测 \(overshoot)（期望 ±32767）"]
    }
}

/// 录音存档目录：`~/Library/Application Support/ClassroomTranscriber/recordings/`
enum RecordingStorage {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }

    static func makeURL(at date: Date = Date()) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("课堂-\(formatter.string(from: date)).wav")
    }

    /// 已存档的录音，新的在前
    static func existing() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
