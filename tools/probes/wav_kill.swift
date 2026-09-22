import AVFoundation
import Darwin
import Foundation

/// 「录音中途被杀，文件不能废」的端到端判据。
///
/// 用 `WAVRecorder`（**生产代码本体**）灌合成样本，写到第 N 秒时
/// `kill(getpid(), SIGKILL)` 把自己杀掉——模拟崩溃 / 强杀 / 退出收尾没走完。
/// SIGKILL 不可捕获，进程当场消失，任何收尾代码都跑不到；随后由
/// `wav_kill.sh` 用 `afinfo` 检查磁盘上那个文件还能不能打开、时长对不对。
///
/// **为什么不用麦克风**：这条判据测的是「写入器在任意时刻的磁盘状态自洽」，
/// 与音频从哪来无关。绑上麦克风就等于把「能不能测」绑到「有没有权限、
/// 有没有人说话、用户是不是正在用麦」上——而这三样都不该决定一个格式判据
/// 能不能跑。真实录音链路的端到端验证另有其人（真人说话那条）。
///
/// **`drainForTesting()` 每块调一次**：不做的话 `append` 还是异步的，
/// 杀在哪个字节上就不确定了。判据要的是「在**已知**的写入位置上被杀」，
/// 所以先确保这块真的落盘，再决定要不要杀。
@main
struct WavKillProbe {

    static func main() {
        // SIGKILL 之前必须确保输出已经出去了——否则报告里什么都看不到
        setvbuf(stdout, nil, _IONBF, 0)

        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("用法: wav_kill <输出.wav> [总秒数=10] [第几秒杀=6]")
            exit(2)
        }
        let url = URL(fileURLWithPath: args[1])
        let totalSeconds = args.count > 2 ? (Double(args[2]) ?? 10) : 10
        let killAfterSeconds = args.count > 3 ? (Double(args[3]) ?? 6) : 6

        let sampleRate: UInt32 = 48_000
        guard let recorder = WAVRecorder(url: url, sampleRate: sampleRate, channels: 1) else {
            print("❌ 无法创建 WAVRecorder")
            exit(3)
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            print("❌ 无法创建缓冲格式")
            exit(3)
        }

        // 0.25 秒一块：够细，杀点能落在秒级精度上；又不会块小到测不出批量写的路径
        let chunkFrames = Int(Double(sampleRate) * 0.25)
        let totalFrames = Int(Double(sampleRate) * totalSeconds)
        let killAfterFrames = Int(Double(sampleRate) * killAfterSeconds)

        print("录音写入器 · 中途 SIGKILL 判据")
        print("  目标文件: \(url.path)")
        print("  计划写入 \(totalSeconds) 秒，写到 \(killAfterSeconds) 秒时自杀（SIGKILL）")

        var written = 0
        while written < totalFrames {
            let frames = min(chunkFrames, totalFrames - written)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ), let channel = buffer.floatChannelData?[0] else {
                print("❌ 无法创建 PCM 缓冲")
                exit(3)
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            for index in 0..<frames {
                let time = Double(written + index) / Double(sampleRate)
                channel[index] = Float(sin(2 * Double.pi * 440 * time)) * 0.5
            }
            recorder.append(buffer)
            written += frames

            // 先确保这一块真的落到磁盘上，杀点才是确定的
            recorder.drainForTesting()

            if written >= killAfterFrames { break }
        }

        // 自杀前把磁盘上的**此刻状态**打出来。这是探针自己看到的证据，
        // 与 `wav_kill.sh` 事后用 afinfo 看到的那份互相独立
        print("  自杀前已落盘 \(written) 帧（\(String(format: "%.2f", Double(written) / Double(sampleRate))) 秒）")
        if let data = try? Data(contentsOf: url) {
            func ascii(_ offset: Int) -> String {
                String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) ?? "?"
            }
            let declared = data.count >= 44
                ? data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }
                : 0
            print("  此刻磁盘上的文件: \(data.count) 字节 · 头 \(ascii(0))/\(ascii(8)) · data 声明 \(declared) 字节")
        }

        print("  → kill(getpid(), SIGKILL)")
        kill(getpid(), SIGKILL)

        // 走不到这里。写一行是为了让「SIGKILL 没生效」这件事显式地有个出口，
        // 而不是让进程正常退出、被 shell 误判成「判据通过」
        print("❌ SIGKILL 没有生效——进程活着走到了结尾，这条判据失效")
        exit(4)
    }
}
