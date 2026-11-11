import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// 采「系统正在播放的声音」（网课、会议、任何 App 的音频输出）。
///
/// 为什么用 ScreenCaptureKit 而不是虚拟声卡（BlackHole 那类）：
/// 虚拟声卡要用户装内核扩展/驱动、再手动把系统输出切过去，装完还会把
/// 「自己听到的声音」和「采集到的声音」拆成两条路；SCK 只要一次「屏幕录制」
/// 权限，就能只取音频、不取画面，卸载也干净。代价是 macOS 13+ 且必须是一个
/// 真实的 SCStream（没有纯音频的独立 API）。
///
/// 这条链路只负责「拿到 16kHz 单声道 Float32」，后面的滑窗/门控/合并全部复用
/// 现有管线——两套音频路径会立刻长出两套行为，而转录质量是拿一条链路验证出来的。
/// `@unchecked Sendable` 的理由：跨线程的真正共享只有 `pending` 与 `stream`，
/// 前者走 `NSLock`、后者只在启动/停止时由同一个调用序列改；采样本身通过
/// `drain()` 一次性交出去，不做共享引用传递
final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case noDisplay
        case permissionDenied
        case converterUnavailable
        case streamFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "没有可采集的显示器（屏幕录制权限可能被拒）"
            case .permissionDenied: return "没有「屏幕录制」权限：系统设置 → 隐私与安全性 → 屏幕录制"
            case .converterUnavailable: return "无法创建音频转换器（系统音频格式异常）"
            case .streamFailed(let detail): return "系统声音采集启动失败：\(detail)"
            }
        }
    }

    static let sampleRate: Double = 16_000

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    /// 采样先攒在锁里，由调用方按节奏 `drain()` 取走。
    ///
    /// **为什么不直接回调**：回调要把 `[Float]` 和「往管线 append」一起跨到
    /// 采集队列上，而管线不是 Sendable（Swift 6 会直接报错）。攒+取的形状
    /// 让跨线程只发生「一段 Float 数组」，管线始终留在自己的 actor 上
    private var pending: [Float] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "classroom.system-audio")

    /// 清空缓冲。抽成同步方法：`stop()` 是 async，Swift 6 不许在 async 上下文里
    /// 直接 `NSLock.lock()/unlock()`（会把锁跨 suspension 持有）
    private func clearPending() {
        lock.lock()
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// 取走攒下的采样（线程安全）
    func drain() -> [Float] {
        lock.lock()
        let out = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    /// 收过多少帧（自检/诊断用：能证明「真的有数据进来」，而不是只有流对象）
    private(set) var receivedFrames: Int = 0

    /// 是否有「屏幕录制」权限。**不弹窗**：只查能不能列出可共享内容
    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// 主动请求一次（会弹系统权限框，仅第一次）
    static func requestPermission() async -> Bool {
        await hasPermission()
    }

    func start() async throws {
        receivedFrames = 0

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // 画面压到最小：只要音频，但 SCK 必须给一个视频配置
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)   // 1 fps，够触发但不费电
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamFailed(error.localizedDescription)
        }
        self.stream = stream

        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Self.sampleRate,
                                     channels: 1,
                                     interleaved: false)
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        converter = nil
        clearPending()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let phones = Self.samples(from: sampleBuffer, targetRate: Self.sampleRate) else { return }
        receivedFrames += phones.count
        lock.lock()
        pending.append(contentsOf: phones)
        if pending.count > 16_000 * 30 { pending.removeFirst(pending.count - 16_000 * 30) }  // 兜底 30 秒
        lock.unlock()
    }

    /// CMSampleBuffer（可能是 48k 立体声 float）→ 16k 单声道 Float。
    ///
    /// 抽成 `static` 是为了能在自检里用合成数据直接测这一段：
    /// 它是整条链路里唯一「格式换算」的地方，算错了表现为「声音进去了但字幕是空的」
    static func samples(from sampleBuffer: CMSampleBuffer, targetRate: Double) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        let sourceFormat = AVAudioFormat(streamDescription: asbd)
        guard let sourceFormat else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer
        else { return nil }

        let channels = Int(sourceFormat.channelCount)
        let isInterleaved = !sourceFormat.isStandard
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                  frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        sourceBuffer.frameLength = AVAudioFrameCount(frames)

        // 直接把原始字节拷进 AVAudioPCMBuffer：SCK 给的就是这个格式的 PCM
        if let destination = sourceBuffer.floatChannelData {
            let bytes = min(length, frames * channels * MemoryLayout<Float>.size)
            if isInterleaved {
                memcpy(destination[0], pointer, bytes)
            } else {
                let perChannel = frames * MemoryLayout<Float>.size
                for channel in 0..<channels {
                    memcpy(destination[channel], pointer + channel * perChannel, min(perChannel, bytes))
                }
            }
        } else {
            return nil
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else { return nil }

        let ratio = targetRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return sourceBuffer
        }
        if error != nil { return nil }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
