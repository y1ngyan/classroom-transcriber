import SwiftUI
import Speech
import AVFoundation
// 只给 `--diarize-real` 用：证明它没动用户那条会话文件（前/后 sha256 一致）。
// App 别处不引它——`SpeakerDiarizationService` 的段指纹刻意不用哈希
import CryptoKit

// `HeadlessEntry` 在 Sources/HeadlessEntry.swift——**故意不在这个文件里**，
// 因为 `AppState.swift` 要引用它，而三个探针脚本组源码表时排除本文件（见那里的注释）

@main
struct ClassroomTranscriberApp: App {
    init() {
        // 界面快照：--ui-snapshot <输出目录>（P13-1）
        //
        // **不起 GUI**：不进 `NSApplicationMain`、不开窗口、不装 run loop，
        // 渲染完直接退出。用离屏 `NSHostingView` 而不是 `ImageRenderer`：
        // 后者会静默不画 ScrollView 里的内容（详见 `UISnapshot` 的注释）。
        // 色板确实换了亮/暗两套，由入口自带的自检 ⑤ 用角落像素钉住。
        //
        // 排在所有会构造 `AppState` 的分支之前：快照自己按夹具建 store，
        // 不该顺带把用户真实的录音库读进来
        if let i = CommandLine.arguments.firstIndex(of: "--ui-snapshot") {
            // 缺参数时**不能静默落回正常启动**：那样会直接起 GUI，调用方
            // 以为在拍无头快照，实际弹出一个窗口。宁可报用法然后退出
            guard i + 1 < CommandLine.arguments.count else {
                FileHandle.standardError.write(
                    Data("用法：ClassroomTranscriber --ui-snapshot <输出目录>\n".utf8)
                )
                exit(64)
            }
            setvbuf(stdout, nil, _IONBF, 0)
            UISnapshot.run(outputDirectory: CommandLine.arguments[i + 1])
        }

        // 无头自检模式：把能力探测结果打到 stdout 后退出，用于终端 / CI 验证
        if CommandLine.arguments.contains("--selftest") {
            for line in EnvironmentChecks.run() {
                print(line)
            }
            exitReleasingGgml()
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
            exitReleasingGgml()
        }

        // 声道转换探针：--conv-probe（纯计算，不需要麦克风 / 不说话也能跑）
        if CommandLine.arguments.contains("--conv-probe") {
            for line in TranscriptionEngine.conversionProbe() {
                print(line)
            }
            exitReleasingGgml()
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
                exitReleasingGgml()
            }
        }

        // Whisper 预热自检：--whisper-prewarm
        //
        // 验两件事：① warmUp() 调用**立刻返回**（不阻塞界面）；② 预热结果落到
        // 状态上（就绪 / 不可用，含模型路径）。模型缺失那条分支用
        // CLASSROOM_WHISPER_MODEL 指一个不存在的路径即可覆盖。
        if CommandLine.arguments.contains("--whisper-prewarm") {
            setvbuf(stdout, nil, _IONBF, 0)
            let runtime = WhisperRuntime()
            Task.detached {
                let modelPath = runtime.modelURL.path
                print("模型路径: \(modelPath)")
                print("文件存在: \(FileManager.default.fileExists(atPath: modelPath) ? "是" : "否")")

                await MainActor.run { runtime.warmUp() }
                let state = await runtime.state
                print("warmUp() 返回后状态: \(describe(state))（应当立刻可见，调用本身不阻塞）")
                let firstLine = await runtime.statusLine
                print("   状态行: \(firstLine ?? "（无，idle 状态）")")

                // 轮询等预热结束。这里轮询而不是 await：warmUp() 刻意不返回
                // Task 给调用方等——界面那条路就是不等的，这里要验的正是它
                let started = ContinuousClock.now
                while true {
                    let current = await runtime.state
                    if case .preparing = current {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    let elapsed = ContinuousClock.now - started
                    let seconds = Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18
                    print(String(format: "预热结束（自 warmUp() 起 %.2f 秒）: %@", seconds, describe(current)))
                    let line = await runtime.statusLine
                    print("   状态行: \(line ?? "（无，idle 状态）")")
                    break
                }

                // 幂等：就绪后再调一次不该重新构造（否则每次点录制都要重来一遍）
                await MainActor.run { runtime.warmUp() }
                let after = await runtime.state
                print("重复 warmUp() 后状态: \(describe(after))")

                // 退出前放掉引擎。走正规所有权这一步是**为了验它**——这条自检
                // 要覆盖的就是「warmUp 之后 unload 能不能干净收场」。
                //
                // 但**不能靠它来避免 abort**：它放掉的只是本对象持有的那一份。
                // （这条路上 `AppState` 曾经也按配置预热一份，所以这一步调过之后
                // 仍然 exit=134；那份预热现在在无头入口里关掉了，见 `HeadlessEntry`。
                // 但兜底不因此改为「靠所有权」——真正的兜底是 `exitReleasingGgml()`，
                // 它放掉进程里所有 context，再卸后端）
                await MainActor.run { runtime.unload() }
                print("已放掉本对象持有的引擎（退出前必须做，否则 ggml 静态析构会 abort）")

                // 133 那条判据的**正面**证据：这个进程一共构造了几份 ggml context。
                // 无头入口应当是 1（`AppState` 不再预热，入口自己那份是唯一的）。
                // 等一秒再读，是为了让「万一还有第二份」来得及把它的构造登记上——
                // 这个数要能看见第二份才有意义，否则它永远是 1，等于没测
                try? await Task.sleep(for: .seconds(1))
                let stats = GgmlTeardown.constructionStats
                // 「不是 1」的三种读法都写在括号里：核验者 2026-09-24 指出，
                // 只说「应为 1」会把「模型没就位」（0）和「同一来源重试」（2）
                // 一起误导成「又冒出一个构造来源」。读法详见 `GgmlTeardown.constructed`
                print("🔎 构造 ggml context 次数: \(stats.constructed)（无头入口应为 1；0 = 模型没就位、构造没开始；≥2 = 多了一个来源，也见同来源重试）")
                // 峰值只打不断言，理由见 `GgmlTeardown.peakInside`
                print("🔎 构造期同时在造的峰值: \(stats.peakInside)（≥2 就是 133 那个形状；顺序两次则为 1）")
                exitReleasingGgml()
            }
        }

        // Whisper 滑窗离线跑真实录音：--whisper-window-file <wav>
        // （不碰麦克风；走的是接线后的那条管线，见 WhisperWindowFileRun）
        if let i = CommandLine.arguments.firstIndex(of: "--whisper-window-file"),
           i + 1 < CommandLine.arguments.count {
            setvbuf(stdout, nil, _IONBF, 0)
            let path = CommandLine.arguments[i + 1]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                for line in await WhisperWindowFileRun.run(path: path) {
                    print(line)
                }
                semaphore.signal()
            }
            // 等结果的上限。默认 1800 秒，**默认值一个字节没动**（既有入口的
            // 行为不变）；`--window-timeout <秒>` 可以显式抬高，给课堂量级的
            // 输入用。
            //
            // 为什么需要这个覆盖（P9-2 实测，不是推测）：这条入口把结果
            // **攒到最后一次性交出来**（`run()` 返回 `[String]`），所以超时被
            // 掐掉时一个字都还没落地——一整跑全废，而一整跑是小时级的。
            //
            // 这台机器（Apple A18 Pro · 6 核 · 8 GB）上的两次实测：
            //   · 短录音 368.2 秒 → 427.5 秒墙钟（0.86 倍实时）。这一跑被
            //     ~37 秒的固定开销（读文件 + 构造引擎）压得很重，**别拿它
            //     外推**——我第一版就是这么算的，把 122.7 分钟估成了 2.4 小时；
            //   · 课堂量级 122.7 分钟（拼接输入）→ **7210.2 秒墙钟 = 1.02 倍
            //     实时**，窗循环本身 7173.3 秒。固定开销摊薄之后就这个数。
            //     `tools/probes/longrun_rss.sh --out /tmp/p9-2/longrun \
            //          --wav <122.7 分钟的 wav> --timing --window-timeout 24000`
            //
            // **长的那次远超 1800 秒**（7210.2 > 1800），所以课堂量级的输入
            // 必须能抬上限；短的那次 427.5 秒其实没超，别拿它当论据。
            // （这句原先写的是「两种长度都远超」，是假的——本包的**核验子
            // agent** 2026-09-28 指出，作者复核 `427.5 < 1800` 成立。
            // 记录见 `tools/probes/longrun-verification.md`。注意「核验者」在这个
            // 项目里专指 Hermes，作者侧派出的子 agent 不能写成「核验者」。）
            // 慢到这个地步的原因（**那次实测发生在 P12-2 之前**）：当时是
            // 3 秒步长 / 10 秒窗 = 每秒音频被转 3.3 次，2452 个窗 × 10 秒 =
            // 6.8 小时窗内音频压进 2 小时 = 窗内音频 3.4 倍实时。原注释假设的
            // 「4.5 倍速算余量」在这台机器上不成立。**P12-2 试过把步长压到
            // 9.6 秒（窗数降到 1/3.2），但那一版没上生产**——生产仍是 3 秒
            // 步长，所以 7210 秒这个量级照旧成立；结论（课堂量级必须能抬
            // 上限）也不变。别把它当成精确预算，它是一次实测的现场数。
            let timeoutSeconds: Double = {
                guard let j = CommandLine.arguments.firstIndex(of: "--window-timeout"),
                      j + 1 < CommandLine.arguments.count,
                      let parsed = Double(CommandLine.arguments[j + 1]), parsed > 0
                else { return 1800 }
                return parsed
            }()
            if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                // 超时意味着 `whisper_full` **还在跑**。这时候绝不能往下走到
                // `exitReleasingGgml()`——它会从正在计算的图底下把后端抽走，
                // 实测当场 `GGML_ASSERT(backend) failed` + exit=134（栈见
                // `exitWithoutReleasingGgml`；同一竞态也会以 139 落地）。所以这
                // 一支就地退出，不释放。
                //
                // 也不「等它算完再释放」：那就等于没有超时。
                let stats = GgmlTeardown.constructionStats
                print("❌ 离线跑超时（上限 \(Int(timeoutSeconds)) 秒）——`run()` 攒到最后一次性交出来，所以这一跑一个字都没落地")
                print("🔎 构造 ggml context 次数: \(stats.constructed)")
                exitWithoutReleasingGgml(124)
            }
            // 同 `--whisper-prewarm` 报同一个计数（那是 133 的正面判据，见那边的
            // 注释）。**但这一条 `exit_codes.sh` 不断言它**，只打出来给人看：
            // 这条入口把主线程堵在 semaphore 上，`AppState` 那条预热是 MainActor
            // 上的 Task，压根没机会跑——把 fix ① 拿掉重编，这里照样打 1（实测）。
            // 一个不会红的断言不配当判据（见 exit_codes.sh 里的同一句）
            //
            // 带 `--fallback-probe N` 时**本来就该是 2**（那条探针要另开一个
            // context 来做对照），别把它当回归
            let windowStats = GgmlTeardown.constructionStats
            print("🔎 构造 ggml context 次数: \(windowStats.constructed)（无头入口应为 1；0 = 模型没就位；带 --fallback-probe 时另开 context，则为 2）")
            print("🔎 构造期同时在造的峰值: \(windowStats.peakInside)（≥2 就是 133 那个形状；顺序两次则为 1）")
            exitReleasingGgml()
        }

        // 课后重转（P11-1）：--retranscribe <会话.json> --out <目录> [--engine large|medium]
        //                [--part N] [--head <秒>] [--allow-partial]
        //
        // **只处理已经录好的音频**：读一条会话 JSON + 它指向的 wav，把重转结果
        // 写到 `--out` 的一份副本里。输入会话文件一个字节都不动（验收要求 ③ 的
        // sha256 比对就是它），也**一次都不碰麦克风**。
        //
        // 判据是输出里那两行 `🔎 实际加载的模型` / `🔎 模型字节数`——它们是
        // whisper 真的打开的那个文件，不是一句「已用 large」
        if CommandLine.arguments.contains("--retranscribe") {
            setvbuf(stdout, nil, _IONBF, 0)
            // 退出码要**从 detached 任务带回主线程**再退出。
            //
            // 这里踩过一个坑（首次跑出来 exit=1，而输出全对）：原写法是
            // detached 任务里 `semaphore.signal()` 之后**自己也**调
            // `exitReleasingGgml(code)`，而主线程被唤醒后紧接着调
            // `exitReleasingGgml(1)`——两边抢着退出，谁先到谁说了算。
            // 退出码是由**主线程**决定的那一个：`RetranscribeRun.run` 的返回值
            // 不上路，跑得再对也可能落地成 1。
            //
            // `@unchecked Sendable` 的依据：只写一次，且**写在 signal 之前**；
            // 读发生在 `semaphore.wait` 返回之后，两边有明确的 happens-before
            // 关系（同 `MicTap` 那类「由调用顺序保证」的包装）
            final class ExitCodeBox: @unchecked Sendable {
                var value: Int32 = 1
            }
            let box = ExitCodeBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                // 边跑边打：一条课堂量级的会话要跑一节课的时间，攒到最后
                // 一次性交的话中途超时/被打断就一个字都看不到
                box.value = await RetranscribeRun.run(arguments: CommandLine.arguments) { print($0) }
                semaphore.signal()
            }
            // 同 `--whisper-window-file`：默认 1800 秒，`--timeout <秒>` 可以抬高
            // （课堂量级的整条重转是小时级的）。超时那一刻 `whisper_full` **还在算**，
            // 所以走 `exitWithoutReleasingGgml`——释放会把后端从正在计算的图底下
            // 抽走，实测当场 `GGML_ASSERT(backend) failed` + exit=134
            let retranscribeTimeout: Double = {
                guard let j = CommandLine.arguments.firstIndex(of: "--timeout"),
                      j + 1 < CommandLine.arguments.count,
                      let parsed = Double(CommandLine.arguments[j + 1]), parsed > 0
                else { return 1800 }
                return parsed
            }()
            if semaphore.wait(timeout: .now() + retranscribeTimeout) == .timedOut {
                print("❌ 课后重转超时（上限 \(Int(retranscribeTimeout)) 秒）——"
                      + "抬上限用 --timeout <秒>；输入会话文件一个字都没动")
                exitWithoutReleasingGgml(124)
            }
            exitReleasingGgml(box.value)
        }

        // 麦克风链路自检：--mic-selftest
        // 端到端跑一遍「点开始录制」实际走的路径：TCC 权限 → analyzer → tap → 采集 → 停止。
        // 刻意不 exit：主 actor 的调度依赖主线程 run loop，在 init 里阻塞主线程
        // 会把引擎饿死（本项目踩过的坑），所以这里让 App 照常启动、窗口照常出现。
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
                // 后端要能指定：③ 号验证（真实麦克风）就是「同一个入口跑两遍，
                // 一遍 whisper 一遍 apple」，入口不能只认默认后端。
                // 认不出来的值回落 .apple，和 TranscriptionBackend.of 一致——
                // 自检里最不该发生的就是「打错一个词结果跑的是另一个后端还以为在验它」
                if let i = CommandLine.arguments.firstIndex(of: "--backend"),
                   i + 1 < CommandLine.arguments.count {
                    let raw = CommandLine.arguments[i + 1]
                    let parsed = TranscriptionBackend.of(raw)
                    if parsed.rawValue != raw.lowercased() {
                        print("⚠️ --backend \(raw) 认不出来，按 \(parsed.rawValue) 跑")
                    }
                    await MainActor.run { engine.backend = parsed }
                }
                var seconds = 8
                if let i = CommandLine.arguments.firstIndex(of: "--seconds"),
                   i + 1 < CommandLine.arguments.count,
                   let parsed = Int(CommandLine.arguments[i + 1]) {
                    seconds = parsed
                }

                print("🎤 麦克风授权(同步查询): \(AVCaptureDevice.authorizationStatus(for: .audio).displayName)")
                print("🗣 语音识别授权(同步查询): \(SFSpeechRecognizer.authorizationStatus().displayName)")

                let backend = await engine.backend
                print("🧭 后端: \(backend.rawValue)（\(backend.label)）")
                if backend == .whisper {
                    // 正式路径是「设置页点保存」触发预热。自检里手动触发一次，
                    // 否则 start() 里的 engineForRecording() 要把 17 秒冷启动
                    // 算进「启动耗时」——那样量到的不是录音路径的耗时
                    print("→ 预热 Whisper（等就绪再开始，冷启动不算进启动耗时）")
                    await MainActor.run { engine.whisper.warmUp() }
                    let warmStarted = ContinuousClock.now
                    while true {
                        let state = await engine.whisper.state
                        if case .preparing = state {
                            try? await Task.sleep(for: .milliseconds(100))
                            continue
                        }
                        let elapsed = ContinuousClock.now - warmStarted
                        let seconds = Double(elapsed.components.seconds)
                            + Double(elapsed.components.attoseconds) / 1e18
                        print(String(format: "   %@（%.2f 秒）", describe(state), seconds))
                        break
                    }
                }

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
                // 实时那条路线的两个必看读数：占用率（能不能跟上步长）和
                // 跳轮数（跟不上时跳了几次）。不给这两个数，「延迟可接受」
                // 就只是一句自我感觉
                if let stats = await engine.whisperStats {
                    print("   \(stats)")
                }
                if backend == .whisper {
                    let grade = finalized.compactMap(\.qualityGrade)
                    print("   质量档位: 可信 \(grade.filter { $0 == .good }.count) / 存疑 \(grade.filter { $0 == .fair }.count) / 不可信 \(grade.filter { $0 == .poor }.count) / 未评 \(finalized.count - grade.count)")
                    print("   提问检出: L1 \(finalized.filter { $0.isQuestion && $0.questionLevel < 2 }.count) / L2 \(finalized.filter { $0.questionLevel >= 2 }.count)")
                }
                // --switch：**在同一个进程里**切回 Apple 再录一段。
                //
                // 为什么必须这一个进程内做：新开一个进程跑 Apple 只证明了
                // 「Apple 自己没坏」，证明不了「切回来能用」——真正的风险在状态
                // 没清干净：麦克风是独占资源，Whisper 那条路如果没把 tap 交还，
                // 第二次 start() 就会失败；analyzer 不重建则还是旧的后端在吃数据。
                // 这两件事只有在同一个进程里连续跑两遍才看得见。
                if CommandLine.arguments.contains("--switch") {
                    print("")
                    print("════ 切回 Apple（同一进程内）════")
                    await MainActor.run {
                        engine.backend = .apple
                        engine.clear()
                    }
                    await engine.start()
                    print("   启动: \(await engine.statusMessage)")
                    print("   格式: \(await engine.formatDescription)")
                    try? await Task.sleep(for: .seconds(seconds))
                    let live = await engine.segments
                    print("   采集 \(seconds) 秒 → \(live.count) 段，实时电平 \(String(format: "%.3f", await engine.audioLevel))")
                    for segment in live {
                        print("     · [\(segment.formattedTimestamp)] \(segment.text)")
                    }
                    await engine.stop()
                    await engine.waitUntilStopped()
                    print("   停止后: \(await engine.statusMessage)")
                    let finalized = await engine.segments
                    print("   共 \(finalized.count) 段")
                    if let leftover = await engine.whisperStats {
                        print("   ⚠️ 切回 Apple 之后还能拿到 Whisper 统计（应当为 nil）: \(leftover)")
                    } else {
                        print("   ✅ 切回 Apple 后 Whisper 状态已清（whisperStats 为 nil）")
                    }
                }

                // 优雅路径：放掉自检自己那个引擎，顺带覆盖 unload()。
                //
                // **刻意不再按 `backend == .whisper` 判定**——那个判据正是漏放的
                // 来源：它问的是「这条入口这次跑的是哪个后端」，而真正漏掉的是
                // 「这条入口让 App 照常启动，于是 AppState 按**配置**预热的那一份」。
                // 两者可以不一致（配置是 whisper、命令行没给 --backend），
                // 判据为假就跳过释放，进程照样 abort。
                // 现在无条件走一遍，兜底交给 exitReleasingGgml()
                await MainActor.run { engine.whisper.unload() }
                print("✅ 麦克风链路自检结束，未崩溃")
                exitReleasingGgml()
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
            exitReleasingGgml()
        }

        // 配置存取往返：--config-selftest。
        //
        // **不再动 config.json**：往返全程落在一个临时目录里（见
        // `AppConfig.selfTest()`），真实配置这一节一个字节都不碰，
        // 自检最后一条判据就是钉这一点
        if CommandLine.arguments.contains("--config-selftest") {
            print("配置读写往返自检（在临时目录里做，不动你的配置文件）")
            print("  真实配置: \(AppConfig.configFilePath)（本节不参与，末尾有判据）")
            print("")
            for line in AppConfig.selfTest() {
                print(line)
            }
            print("")
            print("现状:")
            for line in AppConfig.statusLines {
                print("  \(line)")
            }
            exitReleasingGgml()
        }

        // 无头录音存档自检：--wav-selftest（写已知正弦波再读回核对，不用麦克风）
        if CommandLine.arguments.contains("--wav-selftest") {
            for line in WAVRecorder.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头高通自检：--hp-selftest（量幅频响应，和解析解对照，不用麦克风）
        if CommandLine.arguments.contains("--hp-selftest") {
            for line in HighPassFilter.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头音频前级自检：--preamp-selftest（量增益与噪声门，不用麦克风）
        if CommandLine.arguments.contains("--preamp-selftest") {
            for line in AudioPreamp.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头提问检测自检：--question-selftest（纯规则，不依赖任何设备）
        if CommandLine.arguments.contains("--question-selftest") {
            for line in QuestionDetector.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头转录质量自评自检：--quality-selftest（真实样本回归，不依赖任何设备）
        if CommandLine.arguments.contains("--quality-selftest") {
            for line in TranscriptQualityAssessor.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头 Whisper 引擎自检：--whisper-selftest
        // （纯本地：繁简转换 + 概率聚合纯函数 + 缺模型分支；
        //   不跑推理、不发网络请求、不需要麦克风、不依赖已下载的模型）
        if CommandLine.arguments.contains("--whisper-selftest") {
            for line in WhisperEngine.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头幻觉治理自检：--hallucination-selftest（纯函数，不依赖模型/麦克风）
        if CommandLine.arguments.contains("--hallucination-selftest") {
            for line in WhisperHallucination.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 幻觉判据的离线重算：--hallucination-replay <探针日志> [<日志> …]
        //
        // 为什么要有：判据改一次就要重跑一遍 whisper 才有对照，一条 3 分钟的
        // 录音两分半——而判据是纯函数，输入（文本/电平/静音门）早就被探针写进
        // TSV 了。这个入口读那些日志、调**同一份**判据重算，所以「重算出来的数」
        // 和「生产会做的事」是同一回事（外面另写一份 Python 就会漂）。
        // 不需要模型、麦克风、网络。
        if CommandLine.arguments.contains("--hallucination-replay") {
            let args = CommandLine.arguments
            let start = args.firstIndex(of: "--hallucination-replay").map { $0 + 1 } ?? args.count
            let logs = Array(args.dropFirst(start))
            guard !logs.isEmpty else {
                print("用法：--hallucination-replay <探针日志> [更多日志 …]")
                print("（日志由 --whisper-window-file … --probe-only 产生）")
                exitReleasingGgml(1)
            }
            for path in logs {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    print("❌ 读不了 \(path)")
                    continue
                }
                let label = (path as NSString).lastPathComponent.replacingOccurrences(of: ".log", with: "")
                for line in HallucinationReplay.report(log: text, label: label) {
                    print(line)
                }
            }
            exitReleasingGgml()
        }

        // 无头语义切分自检：--split-selftest（纯函数，不依赖任何设备）
        if CommandLine.arguments.contains("--split-selftest") {
            for line in TranscriptSplitter.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头补标点自检：--punct-selftest（校验纯函数 + 切分器标点优先，
        // 不发网络请求——补标点本身不进自检）
        if CommandLine.arguments.contains("--punct-selftest") {
            for line in PunctuationService.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头重复段去重自检：--dedup-selftest（纯内存驱动 upsert，不依赖设备）
        if CommandLine.arguments.contains("--dedup-selftest") {
            for line in TranscriptionEngine.dedupSelfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 静音门控自检：--speech-gate-selftest（纯函数／合成波形；不依赖模型与麦克风）
        if CommandLine.arguments.contains("--speech-gate-selftest") {
            for line in SpeechGate.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头 Whisper 滑窗合并自检：--whisper-window-selftest（纯函数，不依赖模型/麦克风）
        if CommandLine.arguments.contains("--whisper-window-selftest") {
            for line in WhisperWindowMerger.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头 Whisper 滑窗攒帧自检：--whisper-buffer-selftest（纯内存，不碰麦克风）
        if CommandLine.arguments.contains("--whisper-buffer-selftest") {
            for line in WhisperWindowBuffer.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头课程词库联网生成自检：--glossary-suggest-selftest（纯函数：检索式规划、
        // 响应解析、术语抽取边界；不发网络请求）
        if CommandLine.arguments.contains("--glossary-suggest-selftest") {
            for line in GlossarySuggestionService.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 无头会话持久化自检：--session-selftest（临时目录，不碰真实数据）
        if CommandLine.arguments.contains("--session-selftest") {
            for line in RecordingsStore.selfTest() {
                print(line)
            }
            exitReleasingGgml()
        }

        // 波形包络自检：--waveform-selftest（临时目录 + 合成 wav；不碰真实录音库、
        // 不加载模型、不发声）。退出码跟着红绿走，理由同下面几条
        if CommandLine.arguments.contains("--waveform-selftest") {
            let result = WaveformEnvelope.selfTest()
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 录音概览聚合自检：--recording-stats-selftest（固定日历 + 内存夹具；
        // 不读真实库、不联网、不碰界面）
        if CommandLine.arguments.contains("--recording-stats-selftest") {
            let result = RecordingStats.selfTest()
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 时间轴节点自检：--timeline-selftest（纯函数；不读库、不联网、
        // 不碰界面）。状态→颜色的映射和 live 标记在这里验，竖线覆盖
        // 只能看像素，那条在 `--ui-snapshot` 的 p15-3 模式里
        if CommandLine.arguments.contains("--timeline-selftest") {
            let result = TimelineNodeStatus.selfTest()
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 提问数据层自检：--questions-selftest（B 包 §4 / §6.2 / §6.3 / §4.6）
        // （离线：临时目录夹具；不联网、不调模型、不碰麦克风、不发声、不读真实库）
        //
        // 和 `--question-selftest`（检测器那件）是**两件事**，名字只差一个 s：
        // 那件验的是「这句话算不算提问」，这件验的是「提问存下来之后怎么活」。
        // 退出码跟着红绿走，理由同下面几条：只看退出码的探针要能分出红绿
        if CommandLine.arguments.contains("--questions-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let result = QuestionDataSelfTest.run()
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 提问流程自检：--question-flow-selftest（B 包 §5 状态机 / §6.5 闸门 /
        // §7 元问题表 / 拍板第 1 条占位会话）。离线：桩检索和桩模型，不联网、
        // 不读真实库、不碰麦克风、不发声。注意名字比上面那条少一个 s：
        // 那是数据层，这条是「点下去之后发生什么」
        if CommandLine.arguments.contains("--question-flow-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let result = QuestionFlowSelfTest.run()
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 说话人映射自检：--speaker-mapping-selftest [--session-file <会话 json>]
        // （纯函数 + 旧会话解码；不联网、不加载模型、不碰麦克风、不发声）
        //
        // 带 `--session-file` 时**额外**拿一条现存会话文件解码一遍（**只读，不写回**）：
        // 自检里那份「旧格式」夹具是我自己造的，而磁盘上那些是 App 真正写下的东西，
        // 两者不是一回事。这个开关存在的唯一目的就是把后者也过一遍
        //
        // **退出码跟着红绿走**（`SpeakerMapper.SelfTestResult`）：`--whisper-selftest`
        // 那边踩过的坑——自检失败不改退出码，于是只看退出码的探针**分不出这个入口
        // 是红的还是绿的**。新入口不重复它
        if CommandLine.arguments.contains("--speaker-mapping-selftest") {
            let args = CommandLine.arguments
            var sessionFile: String?
            if let i = args.firstIndex(of: "--session-file"), i + 1 < args.count {
                sessionFile = args[i + 1]
            }
            let result = SpeakerMapper.selfTest(sessionFile: sessionFile)
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 反向转录段自检：--reverse-selftest
        // （离线：内存夹具 + 只读扫真实会话报数；不联网、不加载模型、不碰音频、不发声）
        //
        // 修的是 `RecordingSession.absoluteRange` 对反向段（end < start）的
        // `..<` trap：那条路径原来能让 `--study-notes <会话 json>` 直接 exit 133
        // 且一个字都不打印。退出码跟着红绿走，理由同上面那条
        if CommandLine.arguments.contains("--reverse-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let result = ReverseSegmentSelfTest.run()
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 课后重转自检：--retranscribe-selftest（P11-1）
        // （离线：纯函数 + 内存夹具；不加载模型、不联网、不碰音频、不发声）
        //
        // 它守两条机器判据，而这两条都**只在特定输入下才现形**，所以必须有
        // 一条不依赖磁盘现状的路把它们跑红一次：
        //   · 实时链路的模型仍是 medium——谁把 large 改成全默认，这里就红；
        //   · 缺 / 残 / 张冠李戴（文件名 large、内容 medium）→ 拦住且
        //     **不会静默回落**。
        // 退出码跟着红绿走，理由同上面那条
        if CommandLine.arguments.contains("--retranscribe-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let result = RetranscribeSelfTest.run()
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 课后重转 · **store 那条路**的自检：--retranscribe-store-selftest（P11-1）
        // （要真模型 + 合成音频；全部落在临时目录，**不碰真实库、不碰麦克风、不发声**）
        //
        // 上一条 `--retranscribe-selftest` 守的是纯函数，`--retranscribe` 那个入口
        // 走的是 `RetranscribeRun`；而**用户点「重转」走的是 `RecordingsStore`**——
        // 第三条路。这条自检把 store 真的驱动一遍（真的加载模型、真的转音频），
        // 因为「取消之后旧转录还在不在」这句话只有跑起来才验得了，而那是本包
        // 唯一会**悄悄毁掉用户看过的内容**的地方。
        // 走 Task + MainActor：store 是 @MainActor 的，**不能在主线程上用信号量等**
        // （等的那件事正要回主 actor，死锁）——同 `--diarize-ui-selftest`
        if CommandLine.arguments.contains("--retranscribe-store-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            Task { @MainActor in
                let result = await RetranscribeStoreSelfTest.run()
                for line in result.lines { print(line) }
                exitReleasingGgml(result.failed == 0 ? 0 : 1)
            }
        }

        // 术语表前移自检：--glossary-prompt-selftest（P12-1）
        // （离线：纯函数 + 只读扫磁盘词表；不加载模型、不联网、不碰音频、不发声）
        //
        // 它守的三条只在**特定输入**下现形：空词表、超限截断、开关关掉。
        // 真实词表有 100 多条，这三件事一个都不占——错了转录照样出结果、
        // 什么都不报。所以构造做成纯函数，这里直接喂边界值把它跑红一次。
        // 退出码跟着红绿走，理由同上面那条
        if CommandLine.arguments.contains("--glossary-prompt-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let result = GlossaryPromptSelfTest.run()
            for line in result.lines { print(line) }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 说话人识别的界面自检：--diarize-ui-selftest
        // （离线：helper 打桩、不写盘、不联网、不加载模型、不碰音频、不发声）
        //
        // 两组：`DiarizationPanelState` 那组是「输入 → 该显示哪一档」的纯函数；
        // `DiarizationStore` 那组是三条闸（手动触发 / 不并发 / 失败不落盘）。
        // 后者要 `await`，所以这条入口走 Task + MainActor——**不能在主线程上
        // 用信号量等**（等的那件事正要回主 actor，直接死锁，本项目踩过）
        //
        // 退出码跟着红绿走，理由同下面几条：只看退出码的探针要能分出红绿
        if CommandLine.arguments.contains("--diarize-ui-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            Task { @MainActor in
                print("说话人识别 · 界面自检（离线 · 零花费 · 不写盘）")
                print("")
                print("【一】面板档位（纯函数）")
                let panel = DiarizationPanelState.selfTest()
                for line in panel.lines { print(line) }
                print("")
                print("【二】store 的三条闸")
                let store = await DiarizationStore.selfTest()
                for line in store.lines { print(line) }
                print("")
                let passed = panel.passed + store.passed
                let failed = panel.failed + store.failed
                print(failed == 0
                    ? "全部通过 ✅ \(passed) 条"
                    : "存在失败用例 ❌ \(failed) 条（通过 \(passed)）")
                exitReleasingGgml(failed == 0 ? 0 : 1)
            }
        }

        // 诊断日志自检：--log-selftest（P6-1）
        //
        // **离线**：不联网、不加载模型、不碰音频、不发声；所有写入都落在自己造的
        // 临时目录里，**用户真实的 `logs/` 一个字都不碰**（同 `--study-notes-ui-selftest`
        // 立的那条规矩）。它验的是：级别过滤 · 环形轮转（最老的被丢、最新的在）·
        // 上限不增长 · 脱敏（假密钥形状的串不出现在文件里）· 崩溃前最后 N 条可读。
        //
        // 退出码跟着红绿走——不看退出码的探针分不出它是红是绿
        if CommandLine.arguments.contains("--log-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let result = DiagnosticLogSelfTest.run()
            for line in result.lines { print(line) }
            print(result.failed == 0
                  ? "✅ 日志自检通过（\(result.passed) 条）"
                  : "❌ 日志自检未通过（过 \(result.passed) / 红 \(result.failed)）")
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 脏数据自检：--integrity-selftest（P6-2）
        //
        // **离线**：不联网、不加载模型、不碰麦克风、不发声；读写全在自己造的
        // 临时目录里。验两件事：whisper 段落时间戳守卫（`t1 < t0` 不落成反向段、
        // 有诊断、正常片段逐字节不受影响）与全库脏数据体检（七类各自点名、
        // 干净会话零误报、扫描前后每个文件 sha256 不变＝只读）
        if CommandLine.arguments.contains("--integrity-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let result = IntegrityScanSelfTest.run()
            for line in result.lines { print(line) }
            print(result.failed == 0
                  ? "✅ 脏数据自检通过（\(result.passed) 条）"
                  : "❌ 脏数据自检未通过（过 \(result.passed) / 红 \(result.failed)）")
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 全库脏数据体检：--integrity-scan [--sessions <目录>] [--recordings <目录>]
        //
        // **只读**：这个入口不删、不改、不修任何东西（自检里有一条判据把
        // 「扫描前后每个文件 sha256 一致」钉住）。它也不提供自动修复——
        // 「扫出什么」和「该拿它怎么办」是两个决定，后者要人看着具体那几条定。
        //
        // **退出码恒 0**（除非扫不动）：这是一份报告，不是一道闸。「库里有脏数据」
        // 是它的输出，不是它失败。要拿它当闸的调用方去读那几行 `⚠️`
        if CommandLine.arguments.contains("--integrity-scan") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            func directory(_ flag: String, _ fallback: URL) -> URL {
                guard let raw = value(flag) else { return fallback }
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
                .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            let sessionsDir = directory("--sessions", base.appendingPathComponent("sessions", isDirectory: true))
            let recordingsDir = directory("--recordings", base.appendingPathComponent("recordings", isDirectory: true))

            print("全库脏数据体检（只读 · 不删不改 · 不播放音频）")
            print("  会话目录：\(sessionsDir.path)")
            print("  录音目录：\(recordingsDir.path)")
            print("")
            let report = IntegrityScan.scan(sessionsDirectory: sessionsDir,
                                            recordingsDirectory: recordingsDir)
            print("扫了 \(report.sessionCount) 条会话 · \(report.audioFileCount) 个 wav 文件")
            print("")
            for line in report.summaryLines { print(line) }
            print("")
            if report.isClean {
                print("✅ 没有发现脏数据")
            } else {
                for kind in IntegrityScan.Kind.allCases {
                    let hits = report.findings(of: kind)
                    guard !hits.isEmpty else { continue }
                    print("── \(kind.label)（\(hits.count)）──")
                    for hit in hits {
                        let who = hit.sessionID.map { String($0.uuidString.prefix(8)) } ?? "（无会话）"
                        print("  [\(who)] \(hit.detail)")
                    }
                }
            }
            exitReleasingGgml(0)
        }

        // 模型下载自检：--model-download-selftest（P7-1）
        //
        // **离线、零花费、不发声、不起 GUI**，而且**绝不去 hf-mirror 下那 539MB**：
        // 所有下载都打给本机回环上现起的一个夹具服务器（`LocalHTTPServer`），
        // body 是几百 KB 的假模型。要验的是传输层行为——Range 被接受/被忽略、
        // 半路断线、取消、重试上限——这些用真模型验只会更慢更不可复现。
        //
        // **硬闸**：进程必须带 `CLASSROOM_MODELS_DIR`。没有它，这个自检写的
        // 就是用户真实的 `models/`（约 1.5GB）。见 `ModelDownloadSelfTest` 里
        // 那段拒绝运行的说明。
        //
        // 退出码跟着红绿走
        if CommandLine.arguments.contains("--model-download-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            // 必须用 detached + 信号量：`App.init` 是 `@MainActor` 隔离的，
            // 普通 Task 会继承主 actor，而主线程正阻塞在下面的 wait 上 → 死锁
            // （同 `--transcribe-file` 那条；本项目在别处踩过这个死锁）
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                let result = await ModelDownloadSelfTest.run()
                for line in result.lines { print(line) }
                print("")
                print(result.failed == 0
                      ? "✅ 模型下载自检通过（\(result.passed) 条）"
                      : "❌ 模型下载自检未通过（过 \(result.passed) / 红 \(result.failed)）")
                exitReleasingGgml(result.failed == 0 ? 0 : 1)
            }
            if semaphore.wait(timeout: .now() + 600) == .timedOut {
                print("❌ 模型下载自检超时（600 秒）")
                exitReleasingGgml(1)
            }
            // 走到这里说明 detached 任务异常退出了而没有 exit —— 不进 GUI
            exitReleasingGgml(1)
        }

        // 模型路径速查：--model-paths
        //
        // 只打印这几个值然后退出。存在的理由：`CLASSROOM_MODELS_DIR` 这条
        // 重定向**必须能被从进程外面验证**——「自检说它认这个变量」是自证，
        // 而「换个目录起一次，它真的指过去了」才是外部证据
        if CommandLine.arguments.contains("--model-paths") {
            setvbuf(stdout, nil, _IONBF, 0)
            print("modelDirectory   \(WhisperEngine.modelDirectory.path)")
            print("modelPath        \(WhisperEngine.modelPath.path)")
            print("resolvedModelURL \(WhisperEngine.resolvedModelURL.path)")
            print("isModelReady     \(WhisperEngine.isModelReady)")
            exitReleasingGgml(0)
        }

        // 输入设备清单：--audio-devices（P0-1 ①）
        //
        // **只读**：整条路走 CoreAudio 的 HAL 属性读取，一次都不碰
        // `AVAudioEngine` 的输入节点（碰了就会把设备占住）。不录音、不发声、
        // 不改任何系统音频设置、不弹授权框
        if CommandLine.arguments.contains("--audio-devices") {
            setvbuf(stdout, nil, _IONBF, 0)
            for line in AudioDeviceProbe.run() { print(line) }
            // 未授权时**照样退 0**：这个入口的契约是「把系统现在是什么样说出来」，
            // 而「未授权」正是它要说出来的事实之一。用非零退出码会让
            // `exit_codes.sh` 把它当成「这个入口坏了」——那不是同一件事。
            // 「未授权就拒绝」是 `--mic-level` 的规矩，不是这一条的
            exitReleasingGgml(0)
        }

        // 采集设备自检：--mic-device-selftest（纯离线，**不开麦**）
        //
        // 覆盖「该记哪只设备」的判定、换设备状态机、存档的读写与旧格式兼容、
        // 电平判据的算法。全部用构造出来的输入驱动，**不碰真实设备**
        if CommandLine.arguments.contains("--mic-device-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            var legacyPath: String?
            if let i = args.firstIndex(of: "--legacy-session"), i + 1 < args.count {
                legacyPath = args[i + 1]
            }
            let result = MicDeviceSelfTest.run(legacySessionPath: legacyPath)
            for line in result.lines { print(line) }
            print("")
            print(result.failed == 0
                  ? "✅ 采集设备自检通过（\(result.passed) 条）"
                  : "❌ 采集设备自检未通过（过 \(result.passed) / 红 \(result.failed)）")
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 麦克风电平探针：--mic-level（P0-1 ①，**会真的开麦录音**）
        //
        // 必须用 detached + 信号量：`App.init` 是 `@MainActor` 隔离的，
        // 普通 Task 会继承主 actor，而主线程正阻塞在下面的 wait 上 → 死锁
        // （同 `--model-download-selftest` 那条）
        if CommandLine.arguments.contains("--mic-level") {
            setvbuf(stdout, nil, _IONBF, 0)
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                let outcome = await MicLevelProbe.run(arguments: CommandLine.arguments)
                for line in outcome.lines { print(line) }
                exitReleasingGgml(outcome.exitCode)
            }
            // 上限给得比录音时长宽：探针最多录 600 秒，这里留够余量
            if semaphore.wait(timeout: .now() + 700) == .timedOut {
                print("❌ 麦克风电平探针超时（700 秒）")
                exitReleasingGgml(1)
            }
            exitReleasingGgml(1)
        }

        // 模型目录占用：--model-cache（只看）/ --model-cache-clean（真删）
        //
        // 对应「占用可见可清理」。**默认只看不动**——只有显式多打一个
        // `-clean` 才真的删。界面上那一步是一个写明「将释放多少」的确认框，
        // 这里换成「多打一个开关」，规矩是同一条：先看见要释放多少，再动手。
        //
        // 删的**只有 `.part` 和它的版本记录**。正式模型文件一根手指都不碰，
        // 哪怕它明显是个下坏了的残骸——那是用户的文件，不归我们清
        if CommandLine.arguments.contains("--model-cache")
            || CommandLine.arguments.contains("--model-cache-clean") {
            setvbuf(stdout, nil, _IONBF, 0)
            let directory = WhisperEngine.modelDirectory
            let manifest = try? ModelManifest.loadBundled()
            if let pin = manifest?.defaultPin {
                print("清单 \(pin.file) @ \(pin.shortRevision)… · \(pin.size) 字节 · \(pin.url.absoluteString)")
            } else {
                print("清单 读不出来（下载会拒绝运行，见 --model-download-selftest 的硬闸说明）")
            }
            let report = ModelCacheReport.scan(directory: directory, manifest: manifest)
            for line in report.summaryLines { print(line) }

            guard CommandLine.arguments.contains("--model-cache-clean") else {
                exitReleasingGgml(0)
            }
            let plan = report.plan
            guard !plan.isEmpty else {
                print("没有可清理的残留（未完成的下载 0 项）")
                exitReleasingGgml(0)
            }
            print("")
            // 只印逐条明细：那句总账（About to delete …）上面报告里已经印过了
            for line in plan.itemLines { print(line) }
            print("（已确认清理：--model-cache-clean）")
            do {
                let freed = try report.clean()
                let after = ModelCacheReport.scan(directory: directory, manifest: manifest)
                print("✅ 释放 \(ModelCache.byteText(freed))")
                print("清理后：Found \(after.partials.count) incomplete download(s)")
                if !after.models.isEmpty {
                    print("正式模型文件仍在：\(after.models.map(\.url.lastPathComponent).joined(separator: "、"))")
                }
                exitReleasingGgml(0)
            } catch {
                print("❌ 清理失败：\(error.localizedDescription)")
                exitReleasingGgml(1)
            }
        }

        // 无头下载一个模型文件：--model-fetch <url> --to <路径> [--min-bytes N]
        //                    [--expect-sha256 <hex> --expect-size <n>]
        //
        // 给 `tools/probes/model_resume.sh` 用的：那条探针要真的把进程
        // `kill -9` 掉，再看 `.part` 有没有接着长——那必须要有一个能被外部
        // 掐死的进程，所以这里只做「下载这一个文件」这一件事，不碰 App 状态。
        // **退出码跟着成败走**
        //
        // 两个可选旋钮给 `tools/probes/model_download_url.sh` 用：给了就按清单
        // 那条路校验（`--expect-sha256` 是内容身份，`--expect-size` 是精确大小）。
        // **不给就一个字都不变**——还是原来那条「单 URL、无 pin」的降级路径，
        // 大小只按 `--min-bytes` 那条下界判。
        //
        // 404 回落（`ModelURLPlan`）在这条路上**默认开**，因为这条入口的 URL
        // 形状和清单拼出来的完全一样（`/resolve/<40位sha>/<file>`）——而今天
        // 镜像对这个形状一律 404。`CLASSROOM_MODEL_URL_FALLBACK=0` 关掉它，
        // 那是探针的对照组。
        if let i = CommandLine.arguments.firstIndex(of: "--model-fetch") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
                return args[j + 1]
            }
            guard i + 1 < args.count, let to = value("--to") else {
                print("用法：--model-fetch <url> --to <路径> [--min-bytes N]"
                      + " [--expect-sha256 <hex> --expect-size <n>]")
                exitReleasingGgml(2)
            }
            guard let url = URL(string: args[i + 1]) else {
                print("❌ 不是合法的 URL：\(args[i + 1])")
                exitReleasingGgml(2)
            }
            let destination = URL(fileURLWithPath: (to as NSString).expandingTildeInPath)
            let minimum = value("--min-bytes").flatMap { Int64($0) } ?? WhisperEngine.expectedModelBytes
            let partURL = ModelDownloader.partURL(for: destination)
            let counter = ProgressLineCounter()

            // 内容身份。**两个都给**才建 pin：少了 size 就只能按大小下界判，
            // 那样「下到的内容对不对」这句话是假的——所以宁可退回无 pin 那条
            // 明确的降级路径，也不假装在按清单校验
            var expectedPIN: ModelPin?
            if let sha = value("--expect-sha256")?.trimmingCharacters(in: .whitespaces).lowercased(),
               let size = value("--expect-size").flatMap({ Int64($0) }) {
                guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else {
                    print("❌ --expect-sha256 不是 64 位十六进制：\(sha)")
                    exitReleasingGgml(2)
                }
                // revision 从 URL 自己那一段取（清单那种形状里就是那个 commit）。
                // 它同时是回落链的锚：短的那条由**它**切出来，不是另一个 ref。
                // 没有那一段就不建 pin —— 一个 revision 是空的 pin 会在源报了
                // `x-repo-commit` 时判成「源漂了」，那是一条和内容无关的假错
                if let ref = ModelURLPlan.resolveRef(of: url) {
                    expectedPIN = ModelPin(file: destination.lastPathComponent, repo: "",
                                           revision: ref, size: size, sha256: sha,
                                           isDefault: false, url: url)
                } else {
                    print("⚠️ URL 里没有 /resolve/<ref>/ 那一段（没法确定钉的是哪一版）；"
                          + "这次按无清单的降级路径下")
                }
            } else if value("--expect-sha256") != nil || value("--expect-size") != nil {
                print("⚠️ --expect-sha256 与 --expect-size 要一起给；这次按无清单的降级路径下")
            }

            let fallbackPolicy = URLFallbackPolicy.fromEnvironment()
            print("取件形状：\(ModelURLPlan.shapeLabel(of: url))"
                  + " · 404 回落：\(fallbackPolicy == .on ? "开" : "关（\(URLFallbackPolicy.environmentKey)=0）")"
                  + " · 内容判据：\(expectedPIN == nil ? "大小下界 + 文件头（无清单）" : "清单式 size + sha256")")

            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let report = try await ModelDownloader().download(
                        from: url, to: destination, partURL: partURL, minimumBytes: minimum,
                        pin: expectedPIN, urlFallback: fallbackPolicy,
                        onProgress: { p in counter.report(p) },
                        onRetry: { next, max, reason in
                            print("↻ 自动重试 第 \(next)/\(max) 次 · 上次失败：\(reason)")
                        })
                    print("✅ 下完 \(report.bytesWritten) 字节（从 \(report.resumedFrom) 接上）"
                          + " · 请求 \(report.attempts) 次"
                          + " · 取件形状：\(report.urlShape ?? "?") · 回落 \(report.fallbacks) 次")
                    for notice in report.notices { print("ℹ️ \(notice)") }
                    exitReleasingGgml(0)
                } catch {
                    // 文案从这**一个**出口取：`--model-fetch` 与界面那两个 catch
                    // 必须是同一句话。天书（`…(…Failure error 0.)`，2026-10-13 实测）
                    // 是被 `Failure` 那句 `LocalizedError` conformance 修掉的，
                    // 不是被这个函数修掉的——见 `ModelDownloader.message(for:)`
                    print("❌ \(ModelDownloader.message(for: error))")
                    exitReleasingGgml(1)
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 3600) == .timedOut {
                print("❌ 下载超时（3600 秒）")
                exitReleasingGgml(1)
            }
            exitReleasingGgml(1)
        }

        // 夹具服务器：--model-fixture-server [--port-file <路径>]
        //
        // 配合 `--model-fetch` 做**真的 `kill -9` 续传实验**：探针要先有个
        // 慢速的源在跑，才能在中途把下载进程掐死。它只绑回环，探针用完就杀。
        // 路由见 `ModelFixture.routes`（和 `--model-download-selftest` 共用同一份，
        // 免得两处的假模型长得不一样）
        if CommandLine.arguments.contains("--model-fixture-server") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
                return args[j + 1]
            }
            do {
                let server = try LocalHTTPServer(handler: ModelFixture.handler)
                print("PORT=\(server.port)")
                if let path = value("--port-file") {
                    try? "\(server.port)".write(toFile: (path as NSString).expandingTildeInPath,
                                                atomically: true, encoding: .utf8)
                }
                // 一直服务到被外面杀掉。**不用信号量等**：这里本来就要活着
                let semaphore = DispatchSemaphore(value: 0)
                semaphore.wait()
            } catch {
                print("❌ 起不了夹具服务器：\(error.localizedDescription)")
                exitReleasingGgml(1)
            }
        }

        // 崩溃恢复自检：--recovery-selftest（P9-1）
        //
        // **离线**：不联网、不加载模型、**不录音、不发声**；音频全是往临时目录里
        // 写的静音缓冲，读写不碰用户真实的 sessions/ 与 recordings/。验三件事：
        // WAV 头修复（正常的不动、过期的修对、非音频拒绝）· 草稿写入 → 模拟强杀
        // → 恢复（逐字段相等）· 误报为零
        if CommandLine.arguments.contains("--recovery-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let result = RecoverySelfTest.run()
            for line in result.lines { print(line) }
            print(result.failed == 0
                  ? "✅ 崩溃恢复自检通过（\(result.passed) 条）"
                  : "❌ 崩溃恢复自检未通过（过 \(result.passed) / 红 \(result.failed)）")
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 恢复扫描：--recovery-scan [--sessions <目录>] [--recordings <目录>] [--drafts <目录>]
        //
        // **只读、只报**：列出「有音频但没有完整会话」的录音，分类成
        // 「未完成（有草稿可恢复）」「无会话的录音」「转录在、音频不在」。
        // 它**不恢复也不删**——那是用户在录音列表里点了确认之后的事。
        // 退出码恒 0：这是一份报告，不是一道闸
        if CommandLine.arguments.contains("--recovery-scan") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            func directory(_ flag: String, _ fallback: URL) -> URL {
                guard let raw = value(flag) else { return fallback }
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
                .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            let sessionsDir = directory("--sessions", base.appendingPathComponent("sessions", isDirectory: true))
            let recordingsDir = directory("--recordings", base.appendingPathComponent("recordings", isDirectory: true))
            let draftsDir = directory("--drafts", sessionsDir.appendingPathComponent("drafts", isDirectory: true))

            print("崩溃恢复扫描（只读 · 不恢复、不删除 · 不播放音频）")
            print("  会话目录：\(sessionsDir.path)")
            print("  录音目录：\(recordingsDir.path)")
            print("  草稿目录：\(draftsDir.path)")
            print("")
            let items = RecoveryScan.scan(sessionsDirectory: sessionsDir,
                                          recordingsDirectory: recordingsDir,
                                          draftsDirectory: draftsDir)
            if items.isEmpty {
                print("✅ 没有「未完成」的录音")
            } else {
                print("共 \(items.count) 条待处置：")
                for item in items {
                    print("  [\(item.kindLabel)] \(item.summary)")
                }
                print("")
                print("（这里只列出来。恢复或丢弃要在 App 的录音列表里逐条确认）")
            }
            exitReleasingGgml(0)
        }

        // WAV 头修复：--wav-repair [--dir <目录>] [--apply]
        //
        // **默认只报不改**。要改必须显式加 `--apply`，而且每一处都会打印
        // 「改了什么、原值是什么」、改完立刻用系统读取器验一遍。正常 wav
        // 不在报告里、也一个字节不会被碰；非音频（文本存成 .wav 那种）拒绝修复
        if CommandLine.arguments.contains("--wav-repair") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            let target = value("--dir")
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? RecordingStorage.directory
            let apply = args.contains("--apply")

            print("WAV 头体检\(apply ? "（**已加 --apply：会真的改文件**）" : "（只报不改）")")
            print("  目录：\(target.path)")
            print("")
            let defects = WAVHeaderRepair.scan(directory: target)
            if defects.isEmpty {
                print("✅ 所有 wav 的头都是对的")
            } else {
                let repairable = defects.filter { $0.defect.isRepairable }
                // 「可修」这个数**不含空录音**：给它补一个 0 秒的头不是恢复内容。
                // 计数单独说出来，免得那句「可修 N 个」对用户过度承诺
                let refusedList = defects.filter { !$0.defect.isRepairable }
                print("共 \(defects.count) 个有问题的 wav"
                      + "（可修 \(repairable.count) 个，另外 \(refusedList.count) 个不会被动）：")
                for defect in defects { print("  \(defect.fileName) · \(defect.summary)") }

                if apply {
                    print("")
                    print("── 开始修复 ──")
                    for inspection in repairable {
                        do {
                            let outcome = try WAVHeaderRepair.apply(inspection)
                            for line in outcome.lines { print(line) }
                        } catch {
                            print("  ❌ \(inspection.fileName)：\(error)")
                        }
                    }
                    print("")
                    // 这句话在「没有需要拒绝的文件」时也要读得通：
                    // 「剩下 0 个一个字节都没动」会被读成「0 个文件没被动过」，
                    // 而事实恰好相反——正常的 wav 本来就不进这份报告。
                    // 而且不能一律说「非音频」：空录音也不是非音频
                    if refusedList.isEmpty {
                        print("没有需要拒绝的文件；报告之外的 wav 本来就没进这份名单，也一个字节都没动")
                    } else {
                        print("剩下 \(refusedList.count) 个**一个字节都没动**：")
                        for refused in refusedList {
                            print("  \(refused.fileName) · \(refused.defect.refusedLabel)")
                        }
                    }
                } else {
                    print("")
                    print("（要真的修，加 `--apply`。改之前请确认这些文件已经不需要保留原样了）")
                }
            }
            exitReleasingGgml(0)
        }

        // 诊断日志导出：--log-export [--tail N] [--out <文件>] [--dir <目录>]
        //
        // 给用户/接手者取现场用。不给 `--out` 就打到 stdout（默认最后 200 条）；
        // 给了就写成一个文件并打印路径。`--dir` 只有探针用得上——默认读的就是
        // App 真实那份日志
        if CommandLine.arguments.contains("--log-export") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            let limit = value("--tail").flatMap(Int.init) ?? 200
            let directory = value("--dir")
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? DiagnosticLog.defaultDirectory

            // 正文由 `DiagnosticLog.exportText` 出——和设置页那个按钮同一份，
            // 免得两处的头各写各的、哪天对不上
            let exported = DiagnosticLog.exportText(directory: directory, limit: limit)

            if let out = value("--out") {
                let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
                do {
                    // `.atomic`：导出的这份是要发给别人看的东西，
                    // 写一半被打断留下半个文件比没有更糟
                    try exported.text.write(to: url, atomically: true, encoding: .utf8)
                    print("✅ 已导出 \(exported.count) 条到 \(url.path)")
                } catch {
                    print("❌ 导出失败：\(error.localizedDescription)")
                    exitReleasingGgml(1)
                }
            } else {
                print(exported.text, terminator: "")
            }
            exitReleasingGgml(0)
        }

        // 崩溃恢复探针：--log-crash-probe [--dir <目录>] [--lines N] [--message <串>]
        //
        // `--message` 是给「脱敏实测」用的：把一条假密钥塞进消息里，走**真实的
        // 那个 sink**（脱敏 → 写盘），再从盘上 grep 它——在内存里断言
        // 「我脱敏对了」证明不了落盘的那一串是干净的
        //
        // **它活着的唯一目的是被 `kill -9`**。写 N 条日志之后打一个死循环，
        // 等外面把它打死，再由 `--log-export` 读回来——那是「崩溃后仍能读到
        // 崩溃前最后 N 条」这句要求的**唯一**验证方式：在同一个进程里
        // 「写完再读」证明不了任何事，那时进程还活着、缓冲（如果有的话）
        // 还在内存里。配套脚本见 `tools/probes/log_crash.sh`
        if CommandLine.arguments.contains("--log-crash-probe") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            let count = value("--lines").flatMap(Int.init) ?? 50
            let directory = value("--dir")
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("ct-log-crash-probe", isDirectory: true)

            // 每次从干净状态开始：上一轮的残留混进来，读回的「最后 N 条」
            // 就分不清是哪一次的现场了
            let writer = LogRingWriter(directory: directory)
            writer.removeAllFiles()

            let message = value("--message") ?? "崩溃探针"
            let sink = DiagnosticLogSink(directory: directory, minimumLevel: .debug, mirrorToOSLog: false)
            for i in 1...max(1, count) {
                sink.log(.info, .app, "\(message)第 \(i) 条", fields: [.init("序号", i)])
            }
            print("已写入 \(count) 条到 \(directory.path)（消息前缀：\(message)）")
            print("PID=\(getpid())")
            print("现在等我被打死（kill -9）…")

            // 死循环而不是 `exit()`：退出是「正常结束」，盘上有东西是理所当然的。
            // 这条探针要证的是**进程被打死**之后盘上还有东西，两者不是一回事
            while true { sleep(3600) }
        }

        // 崩溃恢复探针：--recovery-crash-probe [--dir <目录>] [--recover]
        //
        // **它活着的唯一目的是被 `kill -9`**，理由和上面那条日志探针逐字相同：
        // 在同一个进程里「写完草稿再恢复」证明不了任何事——那时进程还活着，
        // 录制循环也还活着，落盘路径根本没被中断过。只有真被打死（收不到任何
        // 信号回调、没有 `atexit`、没有 `deinit`）之后，下一个进程还能从盘上
        // 把草稿和音频捡回来，才说明 **P9-1 那条恢复路径是真的**。
        //
        // 不带 `--recover`：造出「用户音频已流式落盘、进程在头回填之前被杀」
        // 那个现场（`WAVRecorder.drainForTesting()` 正是这个语义），打一个
        // 死循环等死。带 `--recover`：打开同一个目录，走**和界面上点「恢复」
        // 完全相同的那条路**（`RecordingsStore.recover`），把结果打出来。
        //
        // 配套脚本 `tools/probes/recovery_crash.sh`，一条命令跑完全部。
        // **不录音、不发声、不联网、不加载模型**：音频是 `WAVRecorder` 写进
        // 临时目录的静音缓冲，喇叭一动不动
        if CommandLine.arguments.contains("--recovery-crash-probe") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            let root = value("--dir")
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("ct-recovery-crash-probe", isDirectory: true)
            let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
            let recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)

            // **硬闸，必须排在所有删除/写入之前**：这个入口会删掉 `--dir` 下的
            // `sessions/` 和 `recordings/`。规则与理由见
            // `RecordingStorage.probeDirectoryRejection`
            if let rejection = RecordingStorage.probeDirectoryRejection(root) {
                print("❌ \(rejection)")
                exitReleasingGgml(2)
            }

            if args.contains("--recover") {
                // ── 第二个进程：重启之后走恢复 ──
                print("崩溃恢复（第二个进程 · 走界面上那条 `RecordingsStore.recover`）")
                let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
                let items = store.recoveryItems
                print("  重启后扫出 \(items.count) 条待处置")
                for item in items {
                    print("    · \(item.kindLabel) · \(item.summary)")
                    if let note = item.headerRepairNote { print("      音频头：\(note)") }
                }
                for item in items where item.isRecoverable { store.recover(item) }
                if !store.recoveryNotes.isEmpty {
                    print("  恢复时对音频头做的改动（原值 → 新值）：")
                    for line in store.recoveryNotes { print(line) }
                }
                print("  恢复之后：\(store.summaries.count) 条正式会话 · 还剩 \(store.recoveryItems.count) 条待处置")
                for summary in store.summaries {
                    guard let session = store.session(id: summary.id) else { continue }
                    for part in session.parts {
                        print("    会话 \(session.id.uuidString) · 音频 \(part.fileName ?? "nil")"
                              + " · \(part.segments.count) 段 · \(part.durationMillis)ms")
                        for segment in part.segments {
                            print("      [\(segment.startTimeMillis)–\(segment.endTimeMillis)] \(segment.text)")
                        }
                    }
                }
                exitReleasingGgml(0)
            }

            // ── 第一个进程：造出崩溃现场，然后等死 ──
            // 每次从干净状态开始：上一轮的残留混进来，读回的现场就不是这一次的了。
            // **只清自己那两个子目录，不动 `root` 本身**——调用方（探针脚本）会把
            // stdout 重定向到 `root` 底下的文件里，把整个 root 删掉等于把那个 fd
            // 指向的 inode 摘了：进程还在写，文件却从目录里消失（踩过）
            for dir in [sessionsDir, recordingsDir] {
                try? FileManager.default.removeItem(at: dir)
            }
            try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

            let fileName = "课堂-20260928-090000.wav"
            let wav = recordingsDir.appendingPathComponent(fileName)
            // 写到 2.3 秒**不 finish**：头停在 2.0 秒那一档
            // （`headerRefreshBytes` = 96000 = 1 秒），正是被杀那一刻盘上的样子
            guard let recorder = WAVRecorder(url: wav, sampleRate: 48_000, channels: 1) else {
                print("❌ 建不出录音器"); exitReleasingGgml(1)
            }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                       channels: 1, interleaved: false)!
            let frames = AVAudioFrameCount(48_000 / 10)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                print("❌ 建不出缓冲"); exitReleasingGgml(1)
            }
            buffer.frameLength = frames
            for _ in 0..<23 { recorder.append(buffer) }
            recorder.drainForTesting()

            let startedAt = Date()
            let segments = [
                TranscriptSegment(text: "今天讲梯度下降。", isFinal: true,
                                  startTimeMillis: 0, endTimeMillis: 1_200,
                                  timestamp: startedAt, languages: ["zh-CN"]),
                TranscriptSegment(text: "学习率太大会震荡。", isFinal: true,
                                  startTimeMillis: 1_200, endTimeMillis: 2_000,
                                  timestamp: startedAt, languages: ["zh-CN"]),
                TranscriptSegment(text: "谁来回答一下？", isFinal: true,
                                  startTimeMillis: 2_000, endTimeMillis: 2_300,
                                  timestamp: startedAt, languages: ["zh-CN"]),
            ]
            let draft = RecordingDraft(
                id: UUID(), targetSessionID: nil, recordingFileName: fileName,
                startedAt: startedAt, durationMillis: 2_300, segments: segments, savedAt: startedAt
            )
            let store = RecordingsStore(directory: sessionsDir, recordingsDirectory: recordingsDir)
            store.saveDraft(draft)

            let draftURL = store.draftsDirectory.appendingPathComponent("\(draft.id.uuidString).json")
            print("崩溃现场已就位（全部在临时目录，用户真实的库一个字节都没碰）")
            print("  目录        \(root.path)")
            print("  音频        \(wav.path)")
            print("  音频字节    \((try? FileManager.default.attributesOfItem(atPath: wav.path))?[.size] as? Int ?? 0)")
            print("  草稿        \(draftURL.path)")
            print("  草稿段数    \(segments.count)")
            print("PID=\(getpid())")
            print("现在等我被打死（kill -9）…")

            // 死循环而不是 `exit()`：退出是「正常结束」，盘上有东西是理所当然的。
            // 这条探针要证的是**进程被打死**之后盘上还有东西，两者不是一回事
            while true { sleep(3600) }
        }

        // 真实端到端，**走用户点按钮那条完整的落盘路径**：--diarize-ui-real <会话 json>
        //
        // 与 `--diarize-real` 的区别只有一处，但正是 C-3-2 要验的那一处：
        // 那个入口跑完**不落盘**（它验的是服务层），这个入口把结果**真的写下来**，
        // 而且写的是 `RecordingsStore.save`（App 里那条 `.atomic` 的路）。
        //
        // 三条「没动用户数据」的判据由入口自己打出来，不靠人另跑一次命令：
        //   ① 原会话文件前后 sha256 一致；
        //   ② 写下去的会话与原来的**除说话人 3 个字段外逐字段相等**
        //      （覆盖文本、时间、质量分档——「绝不回写文本/时间」的实测）；
        //   ③ 落盘只发生在临时目录里
        if let idx = CommandLine.arguments.firstIndex(of: "--diarize-ui-real"),
           idx + 1 < CommandLine.arguments.count {
            setvbuf(stdout, nil, _IONBF, 0)
            let path = CommandLine.arguments[idx + 1]
            Task { @MainActor in
                func sha256(of url: URL) -> String {
                    guard let data = try? Data(contentsOf: url) else { return "读不到" }
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                func strippingSpeakerFields(_ s: RecordingSession) -> RecordingSession {
                    var copy = s
                    for p in copy.parts.indices {
                        for i in copy.parts[p].segments.indices {
                            copy.parts[p].segments[i].speakerId = nil
                            copy.parts[p].segments[i].speakerOverlapRatio = nil
                            copy.parts[p].segments[i].speakerMixed = false
                        }
                    }
                    return copy
                }

                let original = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let digestBefore = sha256(of: original)
                var failures = 0
                defer { exitReleasingGgml(failures == 0 ? 0 : 1) }

                print("说话人识别 · 界面链路端到端（只读原会话 · 本地模型 · 零 API 花费）")
                print("原会话：\(original.path)")
                print("原文件 sha256（跑之前）：\(digestBefore)")

                guard let source = try? Data(contentsOf: original),
                      let session = try? JSONDecoder().decode(RecordingSession.self, from: source)
                else {
                    print("❌ 会话文件读不出来或解不开")
                    failures += 1
                    return
                }
                print("会话 \(session.id.uuidString.prefix(8)) · \(session.segmentCount) 段"
                    + " · \(session.durationMillis / 60_000) 分钟 · \(session.parts.count) 个片段")

                // 临时目录当 sessions/。**这是这条入口唯一的写点**——
                // 真实目录一个字节都不会被碰
                let sandbox = FileManager.default.temporaryDirectory
                    .appendingPathComponent("diarize-ui-real-\(session.id.uuidString)")
                let sessions = sandbox.appendingPathComponent("sessions", isDirectory: true)
                try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
                let store = RecordingsStore(directory: sessions)

                // **和 AppState 里一模一样的接线**：save 走 RecordingsStore.save，
                // run 用默认那条生产路径（含模型首跑就位 + 找 helper）
                let ui = DiarizationStore(save: { store.save($0) })

                let before = ui.state(session: session)
                print("跑之前那一档：\(before.phase)"
                    + " · 按钮\(before.canRun ? "可点" : "点不动：\(before.runDisabledReason ?? "（没说原因！）")")")
                if !before.canRun { failures += 1 }

                print("──────────── 推理中 ────────────")
                let startedAt = Date()
                let ran = await ui.run(session: session)
                let elapsed = Date().timeIntervalSince(startedAt)
                print(String(format: "本次耗时（含起进程/首跑就位）：%.2f 秒", elapsed))
                guard ran else {
                    print("❌ 这一次没跑（当成了重复触发）")
                    failures += 1
                    return
                }

                let after = ui.state(session: session)
                print("跑之后那一档：\(after.phase)")
                if let error = ui.errors[session.id] {
                    print("失败原因（用户看到的就是这一句）：\(error)")
                }
                if let stats = ui.lastStats[session.id] {
                    print("   音频 \(String(format: "%.1f", stats.audioSeconds)) 秒"
                        + " · 说话人 \(stats.speakerCount) 人 · diar 段 \(stats.spanCount) 个"
                        + " · helper 墙钟 \(String(format: "%.2f", stats.helperWallSeconds)) 秒")
                    print("   转录段 \(stats.transcriptSegments) 个：已标注 \(stats.labeled)"
                        + "（\(String(format: "%.1f", stats.annotationRate * 100))%）"
                        + " · 含多人 \(stats.mixed)"
                        + " · 未标注·无有效重叠 \(stats.unlabeledNoOverlap)"
                        + " · 未标注·无多数派 \(stats.unlabeledNoMajority)")
                }

                // 落盘文件：路径 + sha256 + 字节数
                let written = sessions.appendingPathComponent("\(session.id.uuidString).json")
                guard let writtenData = try? Data(contentsOf: written) else {
                    print("❌ 期望的落盘文件不在：\(written.path)")
                    failures += 1
                    return
                }
                print("落盘文件：\(written.path)")
                print("   sha256 \(sha256(of: written))")
                print("   \(writtenData.count) 字节")

                guard let saved = try? JSONDecoder().decode(RecordingSession.self, from: writtenData) else {
                    print("❌ 落盘文件解不回来")
                    failures += 1
                    return
                }

                // ② 只有说话人那 3 个字段变了
                if strippingSpeakerFields(saved) == strippingSpeakerFields(session) {
                    print("✅ 落盘的会话与原来**除说话人字段外逐字段相等**"
                        + "（转录文字、时间、质量分档、提问标记全没动）")
                } else {
                    print("❌ 落盘改动了说话人之外的字段！")
                    failures += 1
                }

                // 从**落盘文件**上数（不是从内存里的对象数）：这才是用户明天打开看到的东西
                var total = 0
                var labeled = 0
                var hidden = 0
                var speakers = Set<String>()
                for part in saved.parts {
                    for segment in part.segments {
                        total += 1
                        if let id = segment.speakerId, !id.isEmpty {
                            labeled += 1
                            speakers.insert(id)
                        } else {
                            hidden += 1
                        }
                    }
                }
                let rate = total == 0 ? 0 : Double(labeled) / Double(total) * 100
                print("从落盘文件数：说话人 \(speakers.count) 人（\(speakers.sorted().joined(separator: "/"))）"
                    + " · 标注 \(labeled)/\(total)（\(String(format: "%.1f", rate))%）"
                    + " · 低置信不显示 \(hidden) 段")
                if labeled == 0 {
                    print("❌ 一段都没标上——这条端到端没验到东西")
                    failures += 1
                }

                let digestAfter = sha256(of: original)
                print("原文件 sha256（跑完）：\(digestAfter)")
                if digestAfter == digestBefore {
                    print("✅ 原会话文件前后一致（sha256 未变，只读）")
                } else {
                    print("❌ 原会话文件被改动了！")
                    failures += 1
                }
                try? FileManager.default.removeItem(at: sandbox)
            }
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
                exitReleasingGgml()
            }
            dispatchMain()
        }

        // 无头核查状态汇总自检：--manual-check-selftest（纯本地，不发网络请求）
        //
        // 走 MainActor：FactCheckStore 是 @MainActor 的，自检要构造它。
        // 不用 semaphore 阻塞主线程（那会和 MainActor 死锁——本项目踩过的坑），
        // 让 App 照常启动、跑完自己 exit
        if CommandLine.arguments.contains("--manual-check-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            Task { @MainActor in
                for line in FactCheckStore.selfTest() {
                    print(line)
                }
                exitReleasingGgml()
            }
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
            exitReleasingGgml()
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
            exitReleasingGgml()
        }

        // 无头术语校正：--glossary（用内置示例转录，验证整条链路）
        //
        // 刻意直接调 GlossaryService 而不是 GlossaryStore：Store 是
        // @MainActor 的，而这里主线程要阻塞在 semaphore 上等结果，
        // 从 detached task 去碰 MainActor 必然死锁（本项目踩过的坑）。
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
            exitReleasingGgml()
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
            exitReleasingGgml()
        }

        // 无头导出笔记：--export-notes <目录或文件路径>
        // 不弹面板、不联网、不发声，就是把一段 Markdown 写出去——
        // 用它把「导出」这条没有 GUI 面板就走得通的路径跑穿
        if let idx = CommandLine.arguments.firstIndex(of: "--export-notes"),
           idx + 1 < CommandLine.arguments.count {
            setvbuf(stdout, nil, _IONBF, 0)
            let path = CommandLine.arguments[idx + 1]
            do {
                let target = try NotesExporter.resolveTarget(path: path)
                // 固定夹具，不是模型产出：这一入口要能离线跑，就不能依赖网络。
                // 它验的是**写文件那一段**，不是笔记质量
                try NotesExporter.write(NotesExporter.sampleMarkdown, to: target)
                print("✅ 已导出 \(target.path)")
                exitReleasingGgml()
            } catch {
                // 不再加「导出失败：」前缀——NotesExportError 的 errorDescription
                // 自己就带着它，加一次会打成「导出失败：导出失败：…」
                print("❌ \(error.localizedDescription)")
                exitReleasingGgml(1)
            }
        }

        // 导出笔记自检：--export-notes-selftest
        // （纯本地：临时目录里写文件，不弹面板、不联网、不加载模型、不发声）
        //
        // 退出码跟着红绿走——`--whisper-selftest` 那边踩过的坑是自检失败不改
        // 退出码，于是只看退出码的探针分不出它是红是绿
        if CommandLine.arguments.contains("--export-notes-selftest") {
            print("笔记导出自检（纯本地 · 不弹面板、不联网、不加载模型、不发声）")
            let result = NotesExporter.selfTest()
            for line in result.lines { print(line) }
            if result.failed == 0 {
                print("✅ 笔记导出自检通过（\(result.passed) 条）")
            } else {
                print("❌ 笔记导出自检未通过（过 \(result.passed) / 红 \(result.failed)）")
            }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 转录导出自检：--transcript-export-selftest
        // （纯本地：临时目录里写文件，不弹面板、不联网、不加载模型、不发声）
        //
        // 和 `--export-notes-selftest` 同一条规矩：退出码跟着红绿走。
        // 四种格式的渲染全是纯函数，所以这条自检能把「序号、进位、跨小时、
        // 空段、最后一句没结束时间、说话人为空」这些**用户真会撞上**的
        // 形状一次钉住，而不只是在界面上点一遍看文件名出没出来
        if CommandLine.arguments.contains("--transcript-export-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            print("转录导出自检（纯本地 · 不弹面板、不联网、不加载模型、不发声）")
            let result = TranscriptExporter.selfTest()
            for line in result.lines { print(line) }
            if result.failed == 0 {
                print("✅ 转录导出自检通过（\(result.passed) 条）")
            } else {
                print("❌ 转录导出自检未通过（过 \(result.passed) / 红 \(result.failed)）")
            }
            exitReleasingGgml(result.failed == 0 ? 0 : 1)
        }

        // 学习笔记自检：--study-notes-selftest
        // （离线：模型调用打桩，不联网、不花钱、不加载模型、不碰音频、不发声）
        //
        // 退出码跟着红绿走——`--whisper-selftest` 那边踩过的坑是自检失败不改
        // 退出码，于是只看退出码的探针分不出它是红是绿
        //
        // 走 `Task { @MainActor in }` 而不是信号量阻塞主线程：那是本项目踩过的坑
        // （主线程占着不放，MainActor 的任务永远排不上）。跑完自己 exit
        if CommandLine.arguments.contains("--study-notes-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            Task { @MainActor in
                let result = await StudyNotesService.selfTest()
                for line in result.lines { print(line) }
                exitReleasingGgml(result.failed == 0 ? 0 : 1)
            }
        }

        // 真实会话跑一遍：--study-notes <会话 json 路径>
        //
        // 会话文件**只读**（`Data(contentsOf:)` 解一份出来，不回写）。
        // 产出写到临时目录而不是真实的 study-notes/：这条入口是拿来验链路的，
        // 不该在用户的笔记目录里留下半成品。要落进真实目录走 UI（6a-2）
        if let idx = CommandLine.arguments.firstIndex(of: "--study-notes"),
           idx + 1 < CommandLine.arguments.count {
            setvbuf(stdout, nil, _IONBF, 0)
            let path = CommandLine.arguments[idx + 1]
            Task { @MainActor in
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let session = try JSONDecoder().decode(RecordingSession.self, from: data)
                    // 术语表照生产那条路注入：不注入的话，模型写出来的英文术语
                    // 会保持转录里那种错拼，然后被「术语原文里没有」全部拒掉——
                    // 那是判据在罚一个我们本可以避免的问题
                    let glossary = GlossaryStore().entries
                    print("会话 \(session.id.uuidString.prefix(8)) · \(session.segmentCount) 段"
                        + " · \(session.durationMillis / 60_000) 分钟 · 术语表 \(glossary.count) 条")
                    // 反向段**要看得见**。C-4 给了它们定义好的行为（当零长处理，
                    // 不再 SIGTRAP），但那等于「不崩也不喊」——这条入口是最容易
                    // 撞上它的地方（锚点索引要遍历每一段的起点），所以在这里报一句。
                    // 修之前这条路径在这行之后直接 exit 133，一个字的告警都没有
                    let reversedSegments = RecordingSession.reversedSegments(in: session)
                    if !reversedSegments.isEmpty {
                        print("⚠️ 这条会话有 \(reversedSegments.count) 段时间反向（end < start）："
                            + "按零长处理，不参与锚点与说话人判定")
                        for segment in reversedSegments.prefix(5) {
                            print("   \(segment.startTimeMillis) → \(segment.endTimeMillis)"
                                + " · \(segment.text.prefix(20))")
                        }
                    }
                    print("──────────── 生成中 ────────────")

                    let outcome = try await StudyNotesService.generate(
                        session: session, glossary: glossary
                    )
                    for line in outcome.report() { print(line) }

                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ct-study-notes-probe", isDirectory: true)
                    try StudyNotesStorage.save(outcome.notes, in: directory)
                    print("")
                    print("已写入（临时目录，不碰真实笔记目录）："
                        + StudyNotesStorage.fileURL(sessionID: session.id, in: directory).path)
                    exitReleasingGgml()
                } catch {
                    print("❌ \(error.localizedDescription)")
                    exitReleasingGgml(1)
                }
            }
        }

        // 详情页那条「课后笔记」区块的显示档位自检：--study-notes-ui-selftest
        //
        // **离线**：不联网、不花钱、不加载模型、不碰音频、不发声。它测的是
        // 「输入 → 该显示哪一档」的纯映射，外加渲染/导出往返——一次模型调用
        // 都不该发生。界面本身点不了（无头进程没有窗口），所以那条路只能
        // 靠把判断抽成纯函数来覆盖，见 `StudyNotesPanelState`
        if CommandLine.arguments.contains("--study-notes-ui-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            // 走 `Task { @MainActor in }`：store 那组自检要真的起 Task、真的等
            // 落盘，是 async 的；而 `@MainActor` 那部分只能在主 actor 上跑
            Task { @MainActor in
                var lines = ["课后笔记界面自检（离线 · 不联网、不花钱、不发音）"]
                var passed = 0
                var failed = 0

                let panel = StudyNotesPanelState.selfTest()
                lines += panel.lines
                passed += panel.passed
                failed += panel.failed

                let markdown = StudyNotesMarkdown.selfTest()
                lines += markdown.lines
                passed += markdown.passed
                failed += markdown.failed

                let store = await StudyNotesStore.selfTest()
                lines += store.lines
                passed += store.passed
                failed += store.failed

                for line in lines { print(line) }
                print(failed == 0
                      ? "✅ 课后笔记界面自检通过（\(passed) 条）"
                      : "❌ 课后笔记界面自检未通过（过 \(passed) / 红 \(failed)）")
                exitReleasingGgml(failed == 0 ? 0 : 1)
            }
        }

        // 说话人识别自检：--diarize-selftest
        //
        // **离线**：不联网、不加载模型、不碰麦克风、不发声。helper 是临时目录里的
        // 桩脚本，读写全在临时目录。它验的是「5 条校验各自会不会红」「失败会不会
        // 被伪装成全员 S1」「低置信会不会硬标」「编号是不是从 S1 起」
        //
        // 退出码跟着红绿走——不看退出码的话，探针分不出它是红是绿
        if CommandLine.arguments.contains("--diarize-selftest") {
            setvbuf(stdout, nil, _IONBF, 0)
            // 起真进程（桩）+ 真等子进程退出，是 async 的，只能在主 actor 上收尾
            Task { @MainActor in
                let result = await SpeakerDiarizationService.selfTest()
                for line in result.lines { print(line) }
                print(result.failed == 0
                      ? "✅ 说话人识别自检通过（\(result.passed) 条）"
                      : "❌ 说话人识别自检未通过（过 \(result.passed) / 红 \(result.failed)）")
                exitReleasingGgml(result.failed == 0 ? 0 : 1)
            }
        }

        // 真实端到端：--diarize-real <会话 json>
        //
        // **只读**用户的会话文件与录音。派单第 5 条要的就是「拿一条真会话跑真模型」，
        // 所以这条入口：① 把会话 json 复制到临时目录再跑（原文件一个字节都不碰）；
        // ② 前后各算一次原文件 sha256 并对比，把「没动用户数据」变成**入口自己
        // 打出来的判据**，而不是靠人另外跑一次 shasum；③ 零 API 花费（纯本地模型）
        //
        // 结果**不落盘**：写真实会话由用户在详情页点击触发，那是 C-3-2
        if let idx = CommandLine.arguments.firstIndex(of: "--diarize-real"),
           idx + 1 < CommandLine.arguments.count {
            setvbuf(stdout, nil, _IONBF, 0)
            let path = CommandLine.arguments[idx + 1]
            Task { @MainActor in
                func sha256(of url: URL) -> String {
                    guard let data = try? Data(contentsOf: url) else { return "读不到" }
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                let original = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let digestBefore = sha256(of: original)
                var failures = 0
                defer { exitReleasingGgml(failures == 0 ? 0 : 1) }

                print("说话人识别 · 真实端到端（只读原会话 · 本地模型 · 零 API 花费）")
                print("原会话：\(original.path)")
                print("原文件 sha256（跑之前）：\(digestBefore)")

                guard let source = try? Data(contentsOf: original),
                      let session = try? JSONDecoder().decode(RecordingSession.self, from: source)
                else {
                    print("❌ 会话文件读不出来或解不开")
                    failures += 1
                    return
                }

                // 复制到临时目录再跑。原文件本来就是只读打开的，这一步是**多一层保险**：
                // 把「跑的时候到底对着哪份文件」也变成可打印的事实
                let sandbox = FileManager.default.temporaryDirectory
                    .appendingPathComponent("diarize-real-\(session.id.uuidString)")
                let copy = sandbox.appendingPathComponent("session.json")
                try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
                try? source.write(to: copy)

                print("会话 \(session.id.uuidString.prefix(8)) · \(session.segmentCount) 段"
                    + " · \(session.durationMillis / 60_000) 分钟 · \(session.parts.count) 个片段")
                print("临时副本：\(copy.path)")

                guard let helper = DiarizeHelperLocator.locate() else {
                    print("❌ app bundle 里找不到 diarize-helper")
                    failures += 1
                    return
                }
                print("helper：\(helper.path)")

                // 首跑就位。**只在这里做**——每跑一次都去碰用户的模型目录，
                // 而那个动作（搬移）是有破坏性的
                let provision = SpeakerModelStore.provision()
                let modelsDirectory = SpeakerModelStore.modelsDirectory
                print("模型目录：\(modelsDirectory.path)")
                switch provision {
                case .inPlace:
                    print("模型就位：已在位（什么都不动）")
                case .moved(let bytes, let seconds):
                    print(String(format: "模型就位：首跑搬移 · %.2f MB · 耗时 %.3f 秒",
                                 Double(bytes) / 1_048_576, seconds))
                case .unavailable(let reason):
                    print("❌ 模型没就位：\(reason)")
                    failures += 1
                    return
                }

                print("──────────── 推理中 ────────────")
                let startedAt = Date()
                let report = await SpeakerDiarizationService.diarize(
                    session: session, helper: helper, modelsDirectory: modelsDirectory)
                for line in report.evaluation.report() { print(line) }
                print(String(format: "   本次墙钟（含起进程）：%.2f 秒 · 超时上限 %.0f 秒",
                             Date().timeIntervalSince(startedAt), report.timeoutSeconds))

                if !report.evaluation.isOK, !report.run.stderrTail.isEmpty {
                    print("   helper stderr 尾巴：")
                    for line in report.run.stderrTail.split(separator: "\n").suffix(8) {
                        print("     \(line)")
                    }
                }

                // 原文件没被动过——这条判据**会红**：哪个环节回写了会话文件，
                // 前后 sha 就不一样
                let digestAfter = sha256(of: original)
                print("原文件 sha256（跑完）：\(digestAfter)")
                if digestAfter == digestBefore {
                    print("✅ 原会话文件前后一致（sha256 未变，只读）")
                } else {
                    print("❌ 原会话文件被改动了！")
                    failures += 1
                }
                if !report.evaluation.isOK { failures += 1 }
            }
        }

        // 真实端到端：--study-notes-real <会话 json> [--export <目录或 .md 路径>]
        //
        // 和 `--study-notes` 的区别只有一个：**它落进真实的笔记目录**
        // （`StudyNotesStorage.defaultDirectory`），因为验收要的就是「用户点一下
        // 生成之后，磁盘上到底有没有东西、在哪」。所以它多一条硬规则：
        // **该会话已经有笔记文件时拒绝覆盖**，直接退出——自动重跑把用户已有的
        // 产出盖掉是这一包最不能出的错，而这条规则让「不覆盖」这件事可复现地
        // 验一遍（跑第二遍就会看到它拒绝）
        //
        // 会话文件仍然**只读**：`Data(contentsOf:)` 解一份出来，一个字不回写
        if let idx = CommandLine.arguments.firstIndex(of: "--study-notes-real"),
           idx + 1 < CommandLine.arguments.count {
            setvbuf(stdout, nil, _IONBF, 0)
            let path = CommandLine.arguments[idx + 1]
            var exportPath: String?
            if let ei = CommandLine.arguments.firstIndex(of: "--export"), ei + 1 < CommandLine.arguments.count {
                exportPath = CommandLine.arguments[ei + 1]
            }
            Task { @MainActor in
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let session = try JSONDecoder().decode(RecordingSession.self, from: data)
                    let directory = StudyNotesStorage.defaultDirectory
                    let target = StudyNotesStorage.fileURL(sessionID: session.id, in: directory)

                    // ① 已经有笔记就不覆盖。放在生成**之前**：生成要花钱
                    if FileManager.default.fileExists(atPath: target.path) {
                        print("⏭ 这条会话已经有笔记，拒绝覆盖：\(target.path)")
                        print("   （要重跑就先自己把它移走——这条入口不做删除）")
                        exitReleasingGgml()
                    }

                    let glossary = GlossaryStore().entries
                    print("会话 \(session.id.uuidString.prefix(8)) · \(session.segmentCount) 段"
                        + " · \(session.durationMillis / 60_000) 分钟 · 术语表 \(glossary.count) 条")
                    print("笔记目录：\(directory.path)")
                    print("──────────── 生成中 ────────────")

                    let outcome = try await StudyNotesService.generate(
                        session: session, glossary: glossary
                    )
                    for line in outcome.report() { print(line) }

                    // ② 再查一次再写：上面那次检查到现在隔着几分钟的生成时间，
                    //    期间另一个进程完全可能写了一份进来（App 里自动跑那一次）。
                    //    两次检查之间是真实的竞态窗口，不是防御性冗余
                    guard !FileManager.default.fileExists(atPath: target.path) else {
                        print("⏭ 生成期间这条会话被写入了笔记，仍然不覆盖：\(target.path)")
                        exitReleasingGgml()
                    }
                    try StudyNotesStorage.save(outcome.notes, in: directory)

                    let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
                    let size = (attributes?[.size] as? Int) ?? 0
                    print("")
                    print("已落盘：\(target.path)")
                    print("         \(size) 字节 · \(outcome.notes.items.count) 条要点")

                    // ③ 从刚落的这份笔记导出 Markdown。走的是 **NotesExporter**
                    //    那条路径（`--export-notes-selftest` 覆盖过的同一条），
                    //    不是在这里另写一份写文件的代码
                    if let exportPath {
                        let url = try NotesExporter.resolveTarget(path: exportPath)
                        try NotesExporter.write(StudyNotesMarkdown.render(outcome.notes), to: url)
                        let exportAttrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                        print("已导出 Markdown：\(url.path)")
                        print("         \((exportAttrs?[.size] as? Int) ?? 0) 字节")
                    }
                    exitReleasingGgml()
                } catch {
                    print("❌ \(error.localizedDescription)")
                    exitReleasingGgml(1)
                }
            }
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
            exitReleasingGgml()
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

            // 可选预处理：--preprocess-gain <档位>
            //
            // 存在的理由：重转要补 AGC（存档是未加增益的原始电平），
            // 而这条能力需要一个能在终端里单独验证的入口——「重转后
            // 到底好没好」只有把同一段音频转过、比过置信度才知道
            var preprocess: FileTranscription.Preprocess?
            if let gi = CommandLine.arguments.firstIndex(of: "--preprocess-gain"),
               gi + 1 < CommandLine.arguments.count,
               let mode = MicGainMode(rawValue: CommandLine.arguments[gi + 1]) {
                preprocess = FileTranscription.Preprocess(gainMode: mode)
                print("🎛  预处理增益档: \(mode.label)")
            }

            let semaphore = DispatchSemaphore(value: 0)
            // 必须用 detached：App.init 是 @MainActor 隔离的，
            // 普通 Task 会继承主 actor，而主线程正阻塞在下面的 wait 上 → 死锁
            Task.detached {
                await FileTranscription.run(
                    path: path, locales: locales,
                    presetChoice: preset, preprocess: preprocess
                )
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 900) == .timedOut {
                print("❌ 转录超时")
            }
            exitReleasingGgml()
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

        // 转录导出：四种格式的渲染全是纯函数，在这里跑一遍就能拿到红绿。
        // **不另开一份夹具**：用的是 `TranscriptExporter.selfTest()`
        // 自己那份，`--transcript-export-selftest` 打的也是它——
        // 两处各写一份的话，「--selftest 绿、导出闸红」会变成查不出来的谜
        lines.append("")
        lines.append("📤 转录导出（SRT / VTT / Markdown / JSON）:")
        let exportResult = TranscriptExporter.selfTest()
        lines += exportResult.lines
        lines.append(exportResult.failed == 0
            ? "   ✅ 导出格式检查 \(exportResult.passed) 条全过"
            : "   ❌ 导出格式检查：过 \(exportResult.passed) / 红 \(exportResult.failed)")

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

/// `--whisper-prewarm` 用：把预热状态说成人话（自检输出要能直接贴进报告）
private func describe(_ state: WhisperRuntime.State) -> String {
    switch state {
    case .idle: return "idle（还没开始）"
    case .preparing: return "preparing（准备中）"
    case .ready(let seconds): return String(format: "ready（用时 %.2f 秒）", seconds)
    case .unavailable(let reason): return "unavailable（\(reason)）"
    }
}
