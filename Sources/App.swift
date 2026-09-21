import SwiftUI
import Speech
import AVFoundation

@main
struct ClassroomTranscriberApp: App {
    init() {
        // 无头自检模式：把能力探测结果打到 stdout 后退出，用于终端 / CI 验证
        if CommandLine.arguments.contains("--selftest") {
            for line in EnvironmentChecks.run() {
                print(line)
            }
            exit(0)
        }

        // 文件通道转换：--conv-file <输入> <输出>
        if let i = CommandLine.arguments.firstIndex(of: "--conv-file"),
           i + 2 < CommandLine.arguments.count {
            for line in TranscriptionEngine.convertFile(
                CommandLine.arguments[i + 1],
                to: CommandLine.arguments[i + 2]
            ) {
                print(line)
            }
            exit(0)
        }

        // 声道转换探针：--conv-probe（纯计算，不需要麦克风 / 不说话也能跑）
        if CommandLine.arguments.contains("--conv-probe") {
            for line in TranscriptionEngine.conversionProbe() {
                print(line)
            }
            exit(0)
        }

        // 语音处理 A/B：--mic-ab [--seconds N]
        // 同一进程内先后用「降噪开 / 降噪关」各录一段，并把 tap 到的音频落盘。
        // 目的：判定「听不到外部声音」是采集端没收到，还是收到了但识别不出来。
        if CommandLine.arguments.contains("--mic-ab") {
            setvbuf(stdout, nil, _IONBF, 0)
            let engine = TranscriptionEngine()
            var seconds = 10
            if let i = CommandLine.arguments.firstIndex(of: "--seconds"),
               i + 1 < CommandLine.arguments.count,
               let parsed = Int(CommandLine.arguments[i + 1]) {
                seconds = parsed
            }

            Task.detached {
                await engine.requestPermissions()

                // 三组而不是两组：中间那组才是关键。
                // 「降噪开/关」只能回答「要不要它」，回答不了「能不能只要其中一半」
                // ——实测底噪跳高 40 倍，到底是噪声抑制自己吐出来的，还是 AGC
                // 把底噪一起放大出来的？这两种结论对应完全不同的处置：
                // 前者整个关掉，后者只关 AGC 就能留住降噪。
                let arms: [(name: String, voiceProcessing: Bool, agc: Bool)] = [
                    ("降噪开 + AGC 开", true, true),
                    ("降噪开 + AGC 关", true, false),
                    ("降噪关（默认）", false, false),
                ]

                for arm in arms {
                    await MainActor.run {
                        engine.useVoiceProcessing = arm.voiceProcessing
                        engine.useAGC = arm.agc
                    }

                    print("")
                    print("════════ \(arm.name) ════════")
                    print("🎙  请现在开始持续说话（\(seconds) 秒）…")

                    await engine.start()
                    var status = await engine.statusMessage
                    let formats = await engine.formatDescription
                    print("   启动: \(status)")
                    print("   格式: \(formats)")

                    try? await Task.sleep(for: .seconds(seconds))

                    let live = await engine.segments
                    let stats = await engine.micStats
                    print("   音频链路: \(stats)")
                    print("   实时阶段 \(live.count) 段:")
                    for segment in live {
                        print("      · [\(segment.formattedTimestamp)] \(segment.text)")
                    }

                    await engine.stop()
                    await engine.waitUntilStopped()
                    status = await engine.statusMessage
                    let finalized = await engine.segments
                    print("   \(status)")
                    // 存档路径要打出来：这一组的结论最终要靠 tools/audio_health.swift
                    // 量这条文件的动态范围来定，光看实时转录会漏掉「为什么」。
                    // 录音文件名只有时间戳，不打出来就分不清哪条对应哪一组
                    if let url = await engine.recordingURL {
                        print("   存档: \(url.path)")
                    }
                    if finalized.count > live.count {
                        print("   定稿补出 \(finalized.count - live.count) 段:")
                        for segment in finalized.dropFirst(live.count) {
                            print("      · [\(segment.formattedTimestamp)] \(segment.text)")
                        }
                    }

                    await MainActor.run { engine.clear() }
                    try? await Task.sleep(for: .seconds(1))
                }

                print("")
                print("✅ A/B 结束")
                exit(0)
            }
        }

        // 麦克风链路自检：--mic-selftest
        // 端到端跑一遍「点开始录制」实际走的路径：TCC 权限 → analyzer → tap → 采集 → 停止。
        // 刻意不 exit：主 actor 的调度依赖主线程 run loop，在 init 里阻塞主线程
        // 会把引擎饿死（阶段 2 踩过的坑），所以这里让 App 照常启动、窗口照常出现。
        if CommandLine.arguments.contains("--mic-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let engine = TranscriptionEngine()

            Task.detached {
                if CommandLine.arguments.contains("--no-voice-processing") {
                    await MainActor.run { engine.useVoiceProcessing = false }
                }
                if CommandLine.arguments.contains("--no-agc") {
                    await MainActor.run { engine.useAGC = false }
                }
                if let i = CommandLine.arguments.firstIndex(of: "--preset"),
                   i + 1 < CommandLine.arguments.count,
                   let parsed = FileTranscription.PresetChoice(rawValue: CommandLine.arguments[i + 1]) {
                    await MainActor.run { engine.preset = parsed }
                }
                // 增益档要能指定，否则没法把「同一段话、开与关」跑成 A/B——
                // 而这一级到底有没有用，只有 A/B 说了算
                if let i = CommandLine.arguments.firstIndex(of: "--gain"),
                   i + 1 < CommandLine.arguments.count,
                   let parsed = MicGainMode(rawValue: CommandLine.arguments[i + 1]) {
                    await MainActor.run { engine.micGain = parsed }
                }
                var seconds = 8
                if let i = CommandLine.arguments.firstIndex(of: "--seconds"),
                   i + 1 < CommandLine.arguments.count,
                   let parsed = Int(CommandLine.arguments[i + 1]) {
                    seconds = parsed
                }

                print("🎤 麦克风授权(同步查询): \(AVCaptureDevice.authorizationStatus(for: .audio).displayName)")
                print("🗣 语音识别授权(同步查询): \(SFSpeechRecognizer.authorizationStatus().displayName)")

                print("→ requestPermissions()  ← 过去必崩的一步")
                await engine.requestPermissions()
                var status = await engine.statusMessage
                print("   \(status)")

                print("→ start()  ← tap 装在音频线程，第二步雷")
                await engine.start()
                status = await engine.statusMessage
                let installed = await engine.installedLocales
                let voiceProcessing = await engine.voiceProcessingActive
                print("   状态: \(status)")
                print("   格式: \(await engine.formatDescription)")
                print("   设备端模型: \(installed.isEmpty ? "无" : installed.joined(separator: ", "))")
                print("   系统降噪: \(voiceProcessing ? "已启用" : "未启用")")

                try? await Task.sleep(for: .seconds(seconds))

                let segments = await engine.segments
                let level = await engine.audioLevel
                let micStats = await engine.micStats
                print("   采集 \(seconds) 秒 → \(segments.count) 段，实时电平 \(String(format: "%.3f", level))")
                print("   音频链路: \(micStats)")
                for segment in segments {
                    print("     · [\(segment.formattedTimestamp)] \(segment.text)")
                    if segment.isQuestion {
                        print("       ⤷ 提问 L\(segment.questionLevel): \(segment.coreQuestion ?? segment.text)")
                    }
                }

                await engine.stop()
                await engine.waitUntilStopped()
                status = await engine.statusMessage
                print("   停止后: \(status)")
                let finalized = await engine.segments
                if finalized.count != segments.count {
                    print("   定稿阶段又补出 \(finalized.count - segments.count) 段:")
                }
                for segment in finalized.dropFirst(segments.count) {
                    print("     · [\(segment.formattedTimestamp)] \(segment.text)")
                }
                print("✅ 麦克风链路自检结束，未崩溃")
                exit(0)
            }
        }

        // 无头 COS 上传自检：--cos-selftest（配合 tools/mock_cos.py）
        if CommandLine.arguments.contains("--cos-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)

            let semaphore = DispatchSemaphore(value: 0)
            // 同 --notes：COSSelfTest 全程不碰 MainActor，detached 才安全
            Task.detached {
                for line in await COSSelfTest.run() {
                    print(line)
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 300) == .timedOut {
                print("❌ COS 自检超时")
            }
            exit(0)
        }

        // 配置存取往返：--config-selftest（会临时改写 config.json，结束还原）
        if CommandLine.arguments.contains("--config-selftest") {
            print("配置读写往返自检（结束会还原原文件）")
            print("  路径: \(AppConfig.configFilePath)")
            print("")
            for line in AppConfig.selfTest() {
                print(line)
            }
            print("")
            print("还原后现状:")
            for line in AppConfig.statusLines {
                print("  \(line)")
            }
            exit(0)
        }

        // 无头录音存档自检：--wav-selftest（写已知正弦波再读回核对，不用麦克风）
        if CommandLine.arguments.contains("--wav-selftest") {
            for line in WAVRecorder.selfTest() {
                print(line)
            }
            exit(0)
        }

        // 无头高通自检：--hp-selftest（量幅频响应，和解析解对照，不用麦克风）
        if CommandLine.arguments.contains("--hp-selftest") {
            for line in HighPassFilter.selfTest() {
                print(line)
            }
            exit(0)
        }

        // 无头音频前级自检：--preamp-selftest（量增益与噪声门，不用麦克风）
        if CommandLine.arguments.contains("--preamp-selftest") {
            for line in AudioPreamp.selfTest() {
                print(line)
            }
            exit(0)
        }

        // 无头提问检测自检：--question-selftest（纯规则，不依赖任何设备）
        if CommandLine.arguments.contains("--question-selftest") {
            for line in QuestionDetector.selfTest() {
                print(line)
            }
            exit(0)
        }

        // 无头转录质量自评自检：--quality-selftest（真实样本回归，不依赖任何设备）
        if CommandLine.arguments.contains("--quality-selftest") {
            for line in TranscriptQualityAssessor.selfTest() {
                print(line)
            }
            exit(0)
        }

        // 无头语义切分自检：--split-selftest（纯函数，不依赖任何设备）
        if CommandLine.arguments.contains("--split-selftest") {
            for line in TranscriptSplitter.selfTest() {
                print(line)
            }
            exit(0)
        }

        // 无头重复段去重自检：--dedup-selftest（纯内存驱动 upsert，不依赖设备）
        if CommandLine.arguments.contains("--dedup-selftest") {
            for line in TranscriptionEngine.dedupSelfTest() {
                print(line)
            }
            exit(0)
        }

        // 真实录音回归重复段去重：--dedup-file <wav>
        // 走引擎的 upsert（实时同款 progressive 预设），同时用旧逻辑离线重放
        // 作对照——--transcribe-file 只打印定稿结果，复现不了重复段
        if let di = CommandLine.arguments.firstIndex(of: "--dedup-file"),
           di + 1 < CommandLine.arguments.count {
            setvbuf(stdout, nil, _IONBF, 0)
            let path = CommandLine.arguments[di + 1]
            // 引擎是 @MainActor 的,主线程不能像 --transcribe-file 那样
            // 阻塞在 semaphore 上( MainActor 的 hop 需要主队列空转);
            // 改用 dispatchMain 让主队列继续服务,任务结束自己 exit
            Task { @MainActor in
                await TranscriptionEngine.dedupFileRun(path: path)
                exit(0)
            }
            dispatchMain()
        }

        // 无头术语提词：--extract-terms（走真实模型，验证整条提词链路）
        //
        // 和 --glossary 一样直接调 Service 不走 Store：Store 是 @MainActor 的，
        // 主线程要阻塞在 semaphore 上等结果，从 detached task 碰 MainActor 必死锁。
        if CommandLine.arguments.contains("--extract-terms") {
            setvbuf(stdout, nil, _IONBF, 0)

            // 刻意混三样东西：真实录音里被转错的词（cludelod Clod）、
            // 本来就写对的词（Kimi）、以及不该被收进来的东西
            // （中文词、常见英文词）——一次性看清提取器的边界
            let sample: [(Int, String)] = [
                (0, "上次我们讲了怎么用 cludelod Clod 来改作业，今天讲另一个工具。"),
                (8_000, "Kimi 在处理长文档的时候表现不错，但是要注意它的上下文窗口。"),
                (19_000, "写 prompt 的时候，temperature 这个参数设得太高，输出就会很不稳定。"),
                (31_000, "我建议大家把课堂笔记做成一个 RAG 的检索库，后面查起来方便。"),
                (44_000, "这个作业你们用 ChatGPT 或者 DeepSeek 都可以，但是要自己检查。"),
                (56_000, "好，那今天的内容就讲到这里，下课。"),
            ]
            let segments = sample.map {
                TranscriptSegment(
                    text: $1,
                    isFinal: true,
                    startTimeMillis: $0,
                    endTimeMillis: $0 + 7_000,
                    languages: ["zh-CN"]
                )
            }

            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let entries = try await GlossaryService.extractTerms(from: segments)
                    print("从 \(segments.count) 段转录里提取到 \(entries.count) 个术语：")
                    for entry in entries {
                        let aliases = entry.aliases.isEmpty ? "—" : entry.aliases.joined(separator: "、")
                        print("  \(entry.term)  |  误转写: \(aliases)  |  \(entry.note)")
                    }
                } catch {
                    print("❌ \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }

        // 无头术语提词解析自检：--terms-parser
        // 提词的返回值是模型自由生成的，解析器必须能扛住格式漂移。
        // 这里把见过和没见过的几种写法都喂一遍，不需要联网。
        if CommandLine.arguments.contains("--terms-parser") {
            let sample = """
            1. Claude|cludelod Clod|Anthropic 的模型
            Kubernetes|Kubenetes|容器编排
            eigenvalue||特征值
            RAG
            以上就是这堂课里出现的专业术语
            中文术语|不该被收进来
            Claude|重复的，应该被去重|重复
            API|应用程序接口
            """
            let parsed = GlossaryService.parseTerms(sample)
            print("解析出 \(parsed.count) 条：")
            for entry in parsed {
                let aliases = entry.aliases.isEmpty ? "—" : entry.aliases.joined(separator: "、")
                print("  \(entry.term) | \(aliases) | \(entry.note)")
            }
            exit(0)
        }

        // 无头术语校正：--glossary（用内置示例转录，验证整条链路）
        //
        // 刻意直接调 GlossaryService 而不是 GlossaryStore：Store 是
        // @MainActor 的，而这里主线程要阻塞在 semaphore 上等结果，
        // 从 detached task 去碰 MainActor 必然死锁（阶段 2 踩过的坑）。
        // 示例文本里刻意混入「本来就正确」的中文和英文，用来验证
        // 「只改明显错误的术语」这条约束真的守住了。
        if CommandLine.arguments.contains("--glossary") {
            setvbuf(stdout, nil, _IONBF, 0)

            let sample: [(Int, String)] = [
                (0, "今天我们讲 Machin learning 里的 gredion destent 算法。"),
                (9_000, "它的核心思想是沿着 loss function 的负梯度方向迭代更新参数。"),
                (23_000, "大家注意 learning rate 这个超参数，如果设得太大，模型就会 diverge，训练不收敛。"),
                (38_000, "gradient descent 和 stochastic gradient decent 的区别要搞清楚。"),
                (55_000, "课后请大家把这个算法在 minist 数据集上实现一遍。"),
            ]
            let segments = sample.map {
                TranscriptSegment(
                    text: $1,
                    isFinal: true,
                    startTimeMillis: $0,
                    endTimeMillis: $0 + 7_000,
                    languages: ["zh-CN"]
                )
            }
            let entries = GlossaryDefaults.entries

            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                print("术语表（\(entries.count) 个）:")
                print(GlossaryService.makeGlossaryText(entries))
                print("")
                print("输入转录（\(segments.count) 段）:")
                for segment in segments {
                    print("  [\(segment.formattedTimestamp)] \(segment.text)")
                }
                print("")
                print("──────────── 校正中 ────────────")

                do {
                    let outcome = try await GlossaryService.correct(segments, entries: entries)
                    print("改动 \(outcome.changedCount) 处")
                    print("")
                    if outcome.corrections.isEmpty {
                        print("（没有改动）")
                    } else {
                        for correction in outcome.corrections {
                            print("[\(correction.timestamp)]")
                            print("  改前: \(correction.before)")
                            print("  改后: \(correction.after)")
                        }
                    }
                    print("")
                    print("──────────── 校正后全文 ────────────")
                    for segment in outcome.segments {
                        print("  [\(segment.formattedTimestamp)] \(segment.text)")
                    }
                } catch {
                    print("❌ \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 240) == .timedOut {
                print("❌ 术语校正超时")
            }
            exit(0)
        }

        // 无头笔记生成：--notes（用内置示例转录，验证整条链路）
        if CommandLine.arguments.contains("--notes") {
            setvbuf(stdout, nil, _IONBF, 0)

            let sample: [(Int, String)] = [
                (0, "今天我们讲 machine learning 里的 gradient descent 算法。"),
                (8_000, "它的核心思想是沿着 loss function 的负梯度方向迭代更新参数。"),
                (22_000, "大家注意 learning rate 这个超参数，如果设得太大，模型就会 diverge，训练不收敛。"),
                (41_000, "反过来设得太小，收敛速度会非常慢，可能需要很多个 epoch。"),
                (58_000, "课后请大家把这个算法在 MNIST 数据集上实现一遍，下节课我们讲 stochastic gradient descent。"),
                (76_000, "另外预习一下 backpropagation，下次课会用到。"),
            ]
            let segments = sample.map {
                TranscriptSegment(
                    text: $1,
                    isFinal: true,
                    startTimeMillis: $0,
                    endTimeMillis: $0 + 7_000,
                    languages: ["zh-CN"]
                )
            }

            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                print("输入转录（\(segments.count) 段）:")
                print(NotesService.makeTranscript(segments))
                print("")
                print("──────────── 生成的笔记 ────────────")
                do {
                    print(try await NotesService.generate(from: segments))
                } catch {
                    print("❌ \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 180) == .timedOut {
                print("❌ 笔记生成超时")
            }
            exit(0)
        }

        // 无头事实核查：--factcheck "待核查的陈述"
        if let idx = CommandLine.arguments.firstIndex(of: "--factcheck"),
           idx + 1 < CommandLine.arguments.count {
            let claim = CommandLine.arguments[idx + 1]
            setvbuf(stdout, nil, _IONBF, 0)

            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                print("核查: \(claim)")
                do {
                    let result = try await FactCheckService.check(segmentID: UUID(), claim: claim) { phase in
                        switch phase {
                        case .searching: print("🔍 检索来源…")
                        case .analyzing: print("🤔 分析中…")
                        default: break
                        }
                    }
                    print("")
                    print("状态: \(result.status.label) (\(result.status.rawValue))")
                    print("把握: \(Int(result.confidence * 100))%")
                    print("解释: \(result.explanation)")
                    print("来源:")
                    for source in result.sources {
                        print("  · \(source.title)")
                        print("    \(source.url)")
                    }
                } catch {
                    print("❌ \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 120) == .timedOut {
                print("❌ 核查超时")
            }
            exit(0)
        }

        // 无头文件转录：--transcribe-file <path> [--locales zh-CN,en-US]
        if let idx = CommandLine.arguments.firstIndex(of: "--transcribe-file"),
           idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            var locales = ["zh-CN"]
            if let li = CommandLine.arguments.firstIndex(of: "--locales"),
               li + 1 < CommandLine.arguments.count {
                locales = CommandLine.arguments[li + 1].split(separator: ",").map(String.init)
            }

            // stdout 无缓冲，便于实时观察下载 / 转录进度
            setvbuf(stdout, nil, _IONBF, 0)

            var preset = FileTranscription.PresetChoice.timeIndexed
            if let pi = CommandLine.arguments.firstIndex(of: "--preset"),
               pi + 1 < CommandLine.arguments.count,
               let parsed = FileTranscription.PresetChoice(rawValue: CommandLine.arguments[pi + 1]) {
                preset = parsed
            }

            let semaphore = DispatchSemaphore(value: 0)
            // 必须用 detached：App.init 是 @MainActor 隔离的，
            // 普通 Task 会继承主 actor，而主线程正阻塞在下面的 wait 上 → 死锁
            Task.detached {
                await FileTranscription.run(path: path, locales: locales, presetChoice: preset)
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 900) == .timedOut {
                print("❌ 转录超时")
            }
            exit(0)
        }
    }

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("Classroom Transcriber") {
            RootView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 660)
        }
        .windowResizability(.contentMinSize)
    }
}

/// 工具链与语音能力探测，`App` 与 UI 共用
enum EnvironmentChecks {
    static func run() -> [String] {
        var lines: [String] = []

        let locales = SFSpeechRecognizer.supportedLocales()
        lines.append("✅ Speech 框架已链接")
        lines.append("   SFSpeechRecognizer 支持 \(locales.count) 个 locale")

        let zh = locales.contains { $0.identifier.hasPrefix("zh") }
        let en = locales.contains { $0.identifier.hasPrefix("en") }
        lines.append("   zh-*: \(zh ? "✅" : "❌")   en-*: \(en ? "✅" : "❌")")

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        lines.append("🎤 麦克风授权: \(mic.displayName)")

        let speech = SFSpeechRecognizer.authorizationStatus()
        lines.append("🗣 语音识别授权: \(speech.displayName)")

        if #available(macOS 26.0, *) {
            lines.append("✅ SpeechAnalyzer (macOS 26+) 可用")
        } else {
            lines.append("❌ SpeechAnalyzer 不可用")
        }

        // 中英着色验证：把分段结果打出来，因为 UI 看不到时可以这样核对
        lines.append("")
        lines.append("🎨 中英着色（[英] = #0071E3）:")
        let sample = "今天我们讲 Machin learning里的 gredie andestent算法，大家注意 learning rate 这个参数"
        let styled = TextHighlight.styled(sample)
        for run in styled.runs {
            let fragment = String(styled[run.range].characters)
            let isAccent = run.foregroundColor == Theme.accent
            lines.append("   [\(isAccent ? "英" : "中")] \(fragment)")
        }

        lines.append("")
        lines.append("✂️ 句子抽取（只取 final 段，短于 8 字的丢弃）:")
        let transcript = "今天我们讲梯度下降算法。它的核心思想是沿着负梯度方向迭代。对。嗯。"
        for sentence in ClaimExtractor.extract(from: transcript) {
            lines.append("   · \(sentence)")
        }

        lines.append("")
        lines.append("📄 Markdown 渲染:")
        let sampleMarkdown = """
        ## 核心知识点大纲
        - 属于 **machine learning** 中的算法 [00:08]
        ### 子标题

        | 术语 | 解释 |
        | --- | --- |
        | gradient descent | 梯度下降 |

        > 引用

        ---
        """
        let html = MarkdownRenderer.html(from: sampleMarkdown)
        let expectations: [(String, String)] = [
            ("二级标题", "<h2>"),
            ("三级标题", "<h3>"),
            ("无序列表", "<ul>"),
            ("列表项", "<li>"),
            ("粗体", "<strong>"),
            ("表格", "<table>"),
            ("表头", "<th>"),
            ("单元格", "<td>"),
            ("引用", "<blockquote>"),
            ("分隔线", "<hr>"),
            ("时间戳高亮", "class=\"ts\""),
        ]
        for (name, needle) in expectations {
            lines.append("   \(html.contains(needle) ? "✅" : "❌") \(name)  \(needle)")
        }

        lines.append("")
        lines.append("🔑 API 配置:")
        for line in AppConfig.statusLines {
            lines.append("   \(line)")
        }

        lines.append("系统: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        return lines
    }
}

extension AVAuthorizationStatus {
    var displayName: String {
        switch self {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未决定"
        @unknown default: return "未知"
        }
    }
}

extension SFSpeechRecognizerAuthorizationStatus {
    var displayName: String {
        switch self {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未决定"
        @unknown default: return "未知"
        }
    }
}
