import AVFoundation
import Foundation
import whisper

// token 流探针：把 whisper 的**原始 token 流**（id / 概率 / 原始字节）逐条打出来，定位置信度或正文对不齐类问题。
// 跑法: ./tools/probe.sh tokens <wav> [段数=20]
//
// 直接调 whisper 的 C API
// 用来定位「逐字符置信度和段落正文对不齐」的根因。
// 不从症状猜，把 token id / 概率 / 原始文本逐条列出来对照。

@main
struct TokenDump {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("用法: token_dump <wav> <model> [段数]"); exit(2) }
        let wavURL = URL(fileURLWithPath: args[1])
        let modelPath = args[2]
        let limit = args.count > 3 ? (Int(args[3]) ?? 20) : 20

        // 读音频 → 16k 单声道 float
        guard let file = try? AVAudioFile(forReading: wavURL),
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: inBuf, frameCount: AVAudioFrameCount(file.length))) != nil
        else { print("❌ 读音频失败"); exit(1) }

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000.0 / file.processingFormat.sampleRate) + 1024
        let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var supplied = false
        var err: NSError?
        _ = converter.convert(to: outBuf, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return inBuf
        }
        let samples = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))

        ggml_backend_load_all()
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            print("❌ 模型加载失败"); exit(1)
        }

        var wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        wparams.language = UnsafePointer(strdup("zh"))
        wparams.print_progress = false
        wparams.print_realtime = false
        wparams.print_timestamps = false
        wparams.print_special = false
        wparams.no_timestamps = false
        wparams.max_len = 60
        wparams.n_threads = 4

        var mutable = samples
        let rc = mutable.withUnsafeMutableBufferPointer { buf in
            whisper_full(ctx, wparams, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { print("❌ 推理失败 \(rc)"); exit(1) }

        let eot = whisper_token_eot(ctx)
        let nSeg = whisper_full_n_segments(ctx)
        print("eot token id = \(eot) · 共 \(nSeg) 段 · 只列前 \(limit) 段\n")

        for i in 0..<min(nSeg, Int32(limit)) {
            let segText = whisper_full_get_segment_text(ctx, i).map { String(cString: $0) } ?? ""
            let visible = segText.filter { !$0.isWhitespace }.count
            let nTok = whisper_full_n_tokens(ctx, i)
            print("── 段 \(i) · 正文「\(segText)」· 可见字符 \(visible) · token 数 \(nTok)")

            var tokenVisible = 0
            for j in 0..<nTok {
                let data = whisper_full_get_token_data(ctx, i, j)
                let raw = whisper_full_get_token_text(ctx, i, j).map { String(cString: $0) } ?? ""
                let isSpecial = data.id >= eot
                let vis = raw.filter { !$0.isWhitespace }.count
                if !isSpecial { tokenVisible += vis }
                let marker = isSpecial ? "★特殊" : (raw.trimmingCharacters(in: .whitespaces).isEmpty ? "·空白" : "")
                print(String(format: "   j=%2d id=%6d p=%.3f 可见%d %@「%@」%@",
                             j, data.id, whisper_full_get_token_p(ctx, i, j), vis, raw, marker))
            }
            print("   → 正文可见 \(visible) vs token 可见合计 \(tokenVisible) \(visible == tokenVisible ? "✅" : "❌ 差 \(tokenVisible - visible)")")
            print("")
        }
        whisper_free(ctx)
    }
}
