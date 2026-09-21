import AVFoundation
import Speech
import Foundation

/// 无头文件转录：把音频文件喂给 SpeechAnalyzer，把结果打到 stdout。
///
/// 两个用途：
/// 1. 终端验证整条转录链路（不需要麦克风权限）
/// 2. 「录音文件转录」功能的底座
enum FileTranscription {

    /// 可选的识别预设。progressive 系列为实时低延迟设计，精度较低；
    /// 文件转录应该用非 progressive 系列。
    enum PresetChoice: String, CaseIterable {
        case progressive
        case timeIndexed
        case timeIndexedAlternatives
        case plain

        var preset: SpeechTranscriber.Preset {
            switch self {
            case .progressive: return .progressiveTranscription
            case .timeIndexed: return .timeIndexedProgressiveTranscription
            case .timeIndexedAlternatives: return .timeIndexedTranscriptionWithAlternatives
            case .plain: return .transcription
            }
        }
    }

    /// 文件转录的预处理。
    ///
    /// **重转默认不过 AGC。** 原因是实测出来的，和直觉相反：
    ///
    /// 存档刻意排在软件增益之前（见 TranscriptionEngine 的
    /// MicTap.handle），所以 wav 里是未加增益的原始电平。直觉上重转该
    /// 补上 AGC，但同一条录音三种处理各跑一遍的实测结果是：
    ///
    /// ```
    ///   原始（不补）        平均置信度 0.684 · 可信段 3
    ///   补 AGC 7.67×        平均置信度 0.619 · 可信段 0
    ///   补 AGC 9.74×        平均置信度 0.613 · 可信段 0
    /// ```
    ///
    /// 补了反而更差，而且不是增益不够（修掉开局 7 秒哑火期、把增益从
    /// 7.67× 提到 9.74× 之后仍然更差）。原因是 AGC 是**逐帧变速**增益，
    /// 给识别器引入了时变特性：原始音频虽然电平低，但电平是**时不变**
    /// 的，识别器在训练时见过各种音量，能正常处理；增益每帧都在变，
    /// 反而破坏了声学模型的输入分布假设。
    ///
    /// 所以这个参数保留成可选项而不是默认行为——它是可测的（见
    /// App.swift 的 --preprocess-gain），留着是为了将来有新的证据时
    /// 能再验一次，而不是因为现在推荐用它。
    ///
    /// **不要补高通**：存档已经过一次 80Hz 高通了（同一处链路），
    /// 再滤一遍会在 80Hz 处衰减 6dB 而不是 3dB，把男声基频下沿削掉。
    struct Preprocess {
        var gainMode: MicGainMode
        /// 每块喂给前级的帧数。和实时的 tap 回调块长一致，
        /// 让 AGC 的包络跟随行为与实时链路可比
        var blockFrames: AVAudioFrameCount = 4096
    }

    /// 文件转录的可选结果回收。
    ///
    /// 现在的调用方分两类：`--transcribe-file` 只要打印（传 nil），
    /// 重转要把 segments 收回去写进会话（传闭包）。用回调而不是返回值，
    /// 是因为结果是在 analyzer 消费过程中流式产生的，收完才返回会
    /// 让「边转边能看到进度」这件事做不到
    typealias SegmentSink = @Sendable (TranscriptSegment) -> Void

    static func run(
        path: String,
        locales: [String] = ["zh-CN"],
        presetChoice: PresetChoice = .timeIndexedAlternatives,
        preprocess: Preprocess? = nil,
        sink: SegmentSink? = nil
    ) async {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ 文件不存在: \(path)")
            return
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            print("❌ 无法读取音频: \(error.localizedDescription)")
            return
        }

        let duration = Double(file.length) / file.fileFormat.sampleRate
        print("📁 \(url.lastPathComponent) · \(String(format: "%.1f", duration))s · \(Int(file.fileFormat.sampleRate))Hz")

        // 1. 匹配受支持的 locale（标识符形式可能是 zh-CN / zh_CN / zh-Hans，做宽松匹配）
        let supported = await SpeechTranscriber.supportedLocales
        let usable = resolve(locales, against: supported)

        guard !usable.isEmpty else {
            print("❌ 没有可用语言模型")
            print("   请求: \(locales.joined(separator: ", "))")
            print("   SpeechTranscriber 支持 \(supported.count) 个:")
            for l in supported { print("     · \(l.identifier)") }
            return
        }
        print("🌐 挂载语言模型: \(usable.map(\.identifier).joined(separator: " + "))")

        // 2. 构建 transcriber。attributeOptions 加逐字符置信度：
        //    质量自评的唯一可信信号，也是这条命令的端到端验证手段
        //    （--quality-selftest 只测分档纯函数，置信度本身准不准要在这里看）
        let transcribers = usable.map { locale in
            var presetWithConfidence = presetChoice.preset
            presetWithConfidence.attributeOptions.insert(.transcriptionConfidence)
            return SpeechTranscriber(locale: locale, preset: presetWithConfidence)
        }

        // 3. 下载设备端模型
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: transcribers) {
                print("⬇️  正在下载语言模型（首次运行需要几分钟）…")

                let poller = Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        let p = request.progress
                        if p.totalUnitCount > 0 {
                            print(String(format: "      … %.0f%%", p.fractionCompleted * 100))
                        } else {
                            print("      …")
                        }
                    }
                }
                try await request.downloadAndInstall()
                poller.cancel()
                print("✅ 模型就绪")
            } else {
                print("✅ 模型已安装，无需下载")
            }
        } catch {
            print("❌ 模型下载失败: \(error.localizedDescription)")
            return
        }

        // 4. 创建 analyzer
        let modules: [any SpeechModule] = transcribers
        let analyzer = SpeechAnalyzer(modules: modules)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            print("❌ 无法确定音频格式")
            return
        }

        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            print("❌ 分析器初始化失败: \(error.localizedDescription)")
            return
        }

        // 5. 并发消费每个语言模型的结果
        print("")
        print("──────────── 转录结果 ────────────")

        await withTaskGroup(of: Void.self) { group in
            for (transcriber, locale) in zip(transcribers, usable) {
                let label = locale.identifier
                group.addTask {
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }

                            guard result.isFinal else { continue }

                            let start = result.range.start.seconds
                            let end = (result.range.start + result.range.duration).seconds
                            // 每段报平均置信度和分档：质量自评的端到端验证
                            // 就靠这行——好音频该看到 0.9+，崩坏音频 0.6 上下
                            let confidences = TranscriptQualityAssessor.confidences(from: result.text)
                            let grade = TranscriptQualityAssessor.grade(confidences: confidences)
                            let confidenceNote = confidences.isEmpty ? "无置信度" : String(
                                format: "置信度 %.3f · %@",
                                confidences.reduce(0, +) / Double(confidences.count),
                                grade?.label ?? "未评"
                            )

                            print(String(
                                format: "[%@] %6.2f → %6.2f  %@（%@）",
                                label, start, end, text, confidenceNote
                            ))

                            // 回收 segments（重转路径要用）
                            sink?(TranscriptSegment(
                                text: text,
                                isFinal: true,
                                startTimeMillis: Int(start * 1000),
                                endTimeMillis: Int(end * 1000),
                                languages: [label]
                            ))
                        }
                    } catch {
                        print("[\(label)] ⚠️ 中断: \(error.localizedDescription)")
                    }
                }
            }

            // 6. 喂文件
            //
            // 有预处理时改走流式输入：`start(inputAudioFile:)` 一次把文件
            // 交给 analyzer，我们插不进手；要过前级就得自己读文件、按块
            // 处理后 yield 进 stream。块长取 4096 与实时 tap 一致，
            // 让 AGC 的包络跟随行为与当时实时转录可比
            do {
                if let preprocess {
                    try await feedWithPreprocess(
                        file: file, into: analyzer,
                        targetFormat: format, preprocess: preprocess
                    )
                } else {
                    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                }
            } catch {
                print("❌ 转录失败: \(error.localizedDescription)")
            }

            await group.waitForAll()
        }
        print("──────────────────────────────────")
        print("完成")
    }

    // MARK: - 带预处理的文件输入

    /// 把文件读成块、过一遍软件增益、再喂给 analyzer。
    ///
    /// 为什么不用 `analyzer.start(inputAudioFile:)`：那个入口把文件一次性
    /// 交给框架，中间插不进任何处理。重转要补 AGC（存档是未加增益的原始
    /// 电平），所以只能自己读、自己处理、自己 yield。
    ///
    /// 格式链路（每一段都有实测依据）：
    ///   存档 1ch/48kHz/Int16
    ///   → 转成 Float32（`AudioPreamp` 只吃 Float32，它的 tanh 软限幅
    ///     和包络计算都按 [-1,1] 的浮点做的）
    ///   → 过 AudioPreamp（按 4096 帧一块，和实时 tap 的块长一致）
    ///   → 转成 analyzer 要的格式（可能是 16kHz Int16）
    ///   → yield
    ///
    /// **不过高通**：存档已经过一次 80Hz 高通了（见 TranscriptionEngine
    /// 的 MicTap.handle，存档卡在高通之后、增益之前），再滤一遍会在
    /// 80Hz 处衰减 6dB 而不是 3dB
    private static func feedWithPreprocess(
        file: AVAudioFile,
        into analyzer: SpeechAnalyzer,
        targetFormat: AVAudioFormat,
        preprocess: Preprocess
    ) async throws {
        let sourceFormat = file.processingFormat

        // 存档是 Int16，先转成前级要的 Float32 单声道
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("❌ 无法构建 Float32 单声道格式")
            return
        }

        guard let toFloat = AVAudioConverter(from: sourceFormat, to: floatFormat),
              let toTarget = AVAudioConverter(from: floatFormat, to: targetFormat) else {
            print("❌ 无法创建转换器")
            return
        }

        // 每段新转都要 reset：AGC 的包络和增益是跟着这一路信号收敛出来的，
        // 跨文件复用会把上一条录音末尾的增益当成这条的起点
        let preamp = AudioPreamp(mode: preprocess.gainMode)
        preamp.reset()

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feeder = Task {
            defer { continuation.finish() }

            var gainSum = 0.0
            var gainSamples = 0

            let totalFrames = file.length
            var readFrames: AVAudioFramePosition = 0

            while readFrames < totalFrames {
                // 按「还剩多少」而不是固定块长来读。
                //
                // `AVAudioFile.read(into:frameCount:)` 在 `frameCount` 超过
                // 剩余帧数时**会抛错**（_GenericObjCError），而不是安静地
                // 返回短读——固定读 4096 的话，文件末尾不足一块的那部分
                // 直接丢失。实测一条 144.8 秒的录音因此只转出到 131.6 秒，
                // 最后 13 秒整段消失，而报错只出现在一行日志里
                let remaining = totalFrames - readFrames
                let want = AVAudioFrameCount(min(AVAudioFramePosition(preprocess.blockFrames), remaining))

                guard let raw = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: want
                ) else { break }

                do {
                    try file.read(into: raw, frameCount: want)
                } catch {
                    print("⚠️ 读取中断（已读 \(readFrames)/\(totalFrames) 帧）: \(error.localizedDescription)")
                    break
                }
                guard raw.frameLength > 0 else { break }
                readFrames += AVAudioFramePosition(raw.frameLength)

                guard let floats = convertBuffer(raw, using: toFloat, to: floatFormat) else { continue }

                // 过前级（原地改 floats 的内容）
                let gain = preamp.process(floats)
                gainSum += Double(gain)
                gainSamples += 1

                guard let out = convertBuffer(floats, using: toTarget, to: targetFormat) else { continue }
                continuation.yield(AnalyzerInput(buffer: out))
            }

            // 平均增益报出来：重转到底有没有被放大，是这次操作最该被
            // 确认的一件事（不报的话，用户只能靠转录质量反推）
            if gainSamples > 0 {
                let average = gainSum / Double(gainSamples)
                print(String(format: "🎛  重转前级：%d 块 · 平均增益 %.2f×（%+.1f dB）",
                             gainSamples, average, 20 * log10(max(average, 0.0001))))
            }
        }

        try await analyzer.start(inputSequence: stream)
        await feeder.value

        // 必须显式定稿，不能只等喂完。
        //
        // 喂完 stream 和「analyzer 把最后几段吐出来」是两件事：结果消费
        // 任务在另一个 Task 里跑，`feeder.value` 只保证音频都 yield 完了，
        // 此时 analyzer 可能还在处理队尾。不调这个的话末尾会被整段丢掉——
        // 实测一条 144.8 秒的录音只转出到 131.6 秒，末尾 13 秒消失，
        // 而且不报任何错。
        //
        // 这和 CLAUDE.md 第 5 条（stop() 必须先定稿再取消消费任务）
        // 是同一类顺序约束。用 inputAudioFile 那条路径时框架自己管这件事，
        // 所以之前没暴露过
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    /// 用 AVAudioConverter 转一块缓冲。输出每块新分配——
    /// 复用同一块会让已经被 yield 出去的缓冲被下一块覆盖
    private static func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// 该语言在没指定地区时优先选用的地区。
    /// 不做这层映射的话，「en」会按字母序匹配到 en-ZA（南非英语）。
    private static let preferredRegions: [String: String] = [
        "en": "US", "zh": "CN", "ja": "JP", "ko": "KR",
        "fr": "FR", "de": "DE", "es": "ES", "pt": "BR",
    ]

    /// 把请求的语言标识符映射到系统实际支持的 Locale 上。
    /// 文件转录和实时转录共用，避免两边对标识符形式的假设不一致。
    static func resolve(_ requested: [String], against supported: [Locale]) -> [Locale] {
        var result: [Locale] = []

        for raw in requested {
            let normalized = raw.replacingOccurrences(of: "_", with: "-").lowercased()

            // 1. 完整标识符精确匹配
            if let exact = supported.first(where: { $0.identifier.lowercased() == normalized }) {
                result.append(exact)
                continue
            }

            // 2. 语言码匹配，优先取指定地区，其次取该语言的默认地区
            let parts = normalized.split(separator: "-").map(String.init)
            let languageCode = parts.first ?? normalized
            let wantedRegion = parts.count > 1
                ? parts[1].uppercased()
                : preferredRegions[languageCode]?.uppercased()

            let candidates = supported.filter {
                $0.language.languageCode?.identifier.lowercased() == languageCode
            }

            if let wantedRegion,
               let hit = candidates.first(where: {
                   $0.region?.identifier.uppercased() == wantedRegion
               }) {
                result.append(hit)
                continue
            }

            if let first = candidates.first {
                result.append(first)
            }
        }

        return result
    }
}
