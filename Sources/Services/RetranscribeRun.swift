import Foundation

/// 无头入口：**把一条会话（的某些片段）用指定的 Whisper 模型重转一遍，
/// 结果写到别处的一份副本里**。
///
/// 它是 P11-1 的可复跑判据，所以三件事是刻意的：
///
/// 1. **打印「实际加载的模型」的路径和字节数**，不是打一句「已用 large」。
///    一句话可以由任何一个常量拼出来，而**路径是 whisper 真的打开的那个文件**。
///    「重转引擎被写死回 medium」这个变异就是靠这条红的，见下面的用法说明。
/// 2. **只写 `--out` 里的一份副本**，输入会话文件一个字节都不动
///    （验收要求 ③ 拿 sha256 前后比对的就是它）。
/// 3. **带 `--head` 又不给 `--allow-partial` 时拒绝落盘**：截断的音频转出来的
///    是一份只有前 N 秒的转录，而它**看起来和一份完整转录一模一样**
///    （段数、字数、时间戳都自洽）。这种「看起来完整的半份」比报错坏得多，
///    所以测量用的开关必须显式带一个「我知道这是半份」的牌子
enum RetranscribeRun {

    struct Options {
        var sessionPath: String
        var outDirectory: String
        var engine: RetranscribeEngine
        /// 只取每段音频的前 N 秒（0 = 整段）。验收用：一条会话最短的片段也有
        /// 6 分钟，large 跑一遍十分钟起步，断言不能等那么久
        var headSeconds: Double = 0
        var allowPartial = false
        /// 只跑第 N 段（1 起数）。nil = 全部有音频的片段
        var onlyPart: Int?
    }

    struct Usage: Error { var message: String }

    static let usage = """
    用法：--retranscribe <会话.json> --out <目录> [--engine large|medium]
                        [--part N] [--head <秒>] [--allow-partial]
      · --out 必填，且不许指向真实库（入口只往那里写副本）
      · --head 不给 --allow-partial 时**拒绝落盘**：截断音频转出的是半份转录，
        而半份在输出上完全看不出来
    """

    // MARK: - 参数

    static func parse(_ arguments: [String]) -> Result<Options, Usage> {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }

        guard let sessionPath = value(after: "--retranscribe") else {
            return .failure(Usage(message: "缺 --retranscribe <会话.json>"))
        }
        guard let outDirectory = value(after: "--out") else {
            return .failure(Usage(message: "缺 --out <目录>——这个入口不许写到别处去"))
        }
        // 认不出来就拒绝，**不猜**：猜错的表现是「以为跑的是 large，其实是 medium」
        let engine: RetranscribeEngine
        if let raw = value(after: "--engine") {
            guard let parsed = RetranscribeEngine.parse(raw) else {
                return .failure(Usage(message: "--engine \(raw) 认不出来（只认 large / medium）"))
            }
            engine = parsed
        } else {
            engine = RetranscribeEngine.preferred
        }

        var options = Options(sessionPath: sessionPath, outDirectory: outDirectory, engine: engine)
        if let raw = value(after: "--head"), let seconds = Double(raw) {
            options.headSeconds = max(0, seconds)
        }
        if let raw = value(after: "--part"), let n = Int(raw), n > 0 {
            options.onlyPart = n
        }
        options.allowPartial = arguments.contains("--allow-partial")
        return .success(options)
    }

    // MARK: - 入口

    /// 跑一趟。**边跑边吐行**（`emit`），不是攒到最后——一条课堂量级的会话
    /// 要跑一节课的时间，攒到最后的话中途超时/被打断就一个字都看不到
    @discardableResult
    static func run(arguments: [String], emit: @escaping @Sendable (String) -> Void) async -> Int32 {
        let options: Options
        switch parse(arguments) {
        case .failure(let usageError):
            emit("❌ \(usageError.message)")
            emit(usage)
            return 2
        case .success(let parsed):
            options = parsed
        }

        let inputURL = URL(fileURLWithPath: (options.sessionPath as NSString).expandingTildeInPath)
        let outURL = URL(fileURLWithPath: (options.outDirectory as NSString).expandingTildeInPath,
                         isDirectory: true)

        // 闸①：输出目录不许和真实库沾边。理由和 `--mic-level` 那条一样——
        // 这个入口要写文件，写错地方就是把用户的存档盖了
        if let rejection = RecordingStorage.libraryContainmentRejection(outURL) {
            emit("❌ 拒绝运行：--out \(rejection)")
            emit("   这个入口只该往临时目录里写副本（真实库：\(RecordingStorage.libraryRoot.path)）")
            return 2
        }
        // 闸②：输入和输出不许是同一处。分开写两条闸是因为它们拦的不是同一件事：
        // 上面那条拦「写进真实库」，这条拦「把输入当输出」——输入文件在临时目录里时
        // 上面那条放行，而这一条仍然要拦
        if inputURL.deletingLastPathComponent().standardizedFileURL
            == outURL.standardizedFileURL {
            emit("❌ 拒绝运行：--out 就是输入文件所在的目录，等于原地覆盖")
            return 2
        }

        guard let data = try? Data(contentsOf: inputURL) else {
            emit("❌ 读不出会话文件：\(inputURL.path)")
            return 2
        }
        let session: RecordingSession
        do {
            session = try JSONDecoder().decode(RecordingSession.self, from: data)
        } catch {
            emit("❌ 会话 JSON 解不开：\(error.localizedDescription)")
            return 2
        }

        emit("═══ 课后重转 · \(inputURL.lastPathComponent)（走接线后的 Whisper 滑窗）═══")
        emit("输入: \(inputURL.path)")
        emit("输出目录: \(outURL.path)")
        emit("引擎: \(options.engine.label) · \(options.engine.fileName)")
        if options.headSeconds > 0 {
            emit(String(format: "⚠️ 只取每段前 %.0f 秒（--head）——这是**测量用**的截断，"
                       + "输出不是完整转录%@",
                       options.headSeconds, options.allowPartial ? "（带了 --allow-partial，允许落盘）" : ""))
        }

        // 要跑哪几段
        let partIndices: [Int]
        if let only = options.onlyPart {
            guard session.parts.indices.contains(only - 1) else {
                emit("❌ --part \(only)：这条会话只有 \(session.parts.count) 段")
                return 2
            }
            partIndices = [only - 1]
        } else {
            partIndices = Array(session.parts.indices)
        }

        // 预计时长：**跑之前**就报出来（派单目标 3 的第一条）。倍率是常量，
        // 见 `RetranscribeEngine.realtimeRate` 里贴的实测出处
        let audioSeconds = partIndices.reduce(0.0) { sum, index in
            sum + Double(session.parts[index].durationMillis) / 1000
        }
        emit("音频: \(partIndices.count) 段 · 共 \(Int(audioSeconds.rounded())) 秒 · "
             + options.engine.estimatedText(audioSeconds: audioSeconds))

        // 模型裁决：缺/不完整就**响亮失败**，不回落别的档
        let decision = RetranscribeRequirement.resolve(engine: options.engine)
        let modelPath: String
        let modelBytes: Int64
        let revision: String
        switch decision {
        case .blocked(let reason):
            emit("")
            emit(reason)
            return 3
        case .ready(let path, let bytes, let rev):
            modelPath = path
            modelBytes = bytes
            revision = rev
        }

        emit("")
        emit("─── 加载引擎 ───")
        // 「用的是哪个模型」这条判据：**打印的是一个真实存在的文件**，
        // 而且是下面真的交给 `WhisperEngine(modelURL:)` 的那一个。
        // 现读一遍字节数（不是抄裁决里的那份）：从裁决到这一步之间
        // 文件可能被换掉，而这一行是给人当判据看的
        let engineURL = URL(fileURLWithPath: modelPath)
        let liveBytes = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size] as? Int64) ?? modelBytes
        emit("🔎 实际加载的模型: \(engineURL.path)")
        emit("🔎 模型字节数: \(liveBytes)（\(ModelAvailability.mbText(liveBytes))）"
             + " · 上游 \(String(revision.prefix(12)))…")

        let whisper: WhisperEngine
        let loadStarted = ContinuousClock.now
        do {
            whisper = try WhisperEngine(modelURL: engineURL)
        } catch {
            emit("❌ 引擎构造失败：\(error.localizedDescription)")
            return 3
        }
        emit(String(format: "  ✅ 引擎就绪（%.2f 秒）", secondsSince(loadStarted)))

        let provenance = TranscriptionProvenance(
            modelFile: options.engine.fileName, revision: revision, bytes: liveBytes,
            retranscribedAt: Date()
        )

        // 术语表前移（P12-1）。**和界面走同一个出处**（`GlossaryStore.promptResolution()`）：
        // 探针无头跑出来的 A/B 数字要拿来当判据，它就必须描述界面实际跑的那条路。
        // 这一行是「送了什么」的唯一凭证——不能只说「已启用」
        let glossaryPrompt = GlossaryStore.promptResolution(
            tokenCount: { whisper.promptTokenCount($0) }
        )
        emit("  \(glossaryPrompt.reportLine)")
        if let text = glossaryPrompt.text {
            emit("    prompt 前 200 字：\(String(text.prefix(200)))")
        }

        emit("")
        emit("─── 重转 ───")
        var produced: [(index: Int, segments: [TranscriptSegment])] = []
        var totalWindows = 0
        for (ordinal, index) in partIndices.enumerated() {
            let part = session.parts[index]
            guard let fileName = part.fileName else {
                emit("  ⏭ 第 \(ordinal + 1) 段没有音频文件（那次录制没开存档）")
                continue
            }
            let audioURL = RecordingStorage.directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                emit("  ❌ 第 \(ordinal + 1) 段音频不在：\(audioURL.path)")
                continue
            }
            emit("  ▸ 第 \(ordinal + 1)/\(partIndices.count) 段 \(fileName)"
                 + "（\(Int(Double(part.durationMillis) / 1000)) 秒）")

            do {
                let loaded = try WhisperFileTranscription.loadSamples(
                    path: audioURL.path, headSeconds: options.headSeconds
                )
                let result = try WhisperFileTranscription.run(
                    samples: loaded.samples, engine: whisper,
                    initialPrompt: glossaryPrompt.text
                ) { facts in
                    // 进度：每窗一行。**和界面用的是同一份回调**（每窗的
                    // `WindowFacts`），所以「进度说跑了几窗」和「最终统计说几窗」
                    // 不会各说各话
                    emit(String(format: "      第 %d 窗 · 覆盖 %.1f 秒 · 这一窗 %.2f 秒 · 原始认出 %d 字",
                                facts.index, Double(facts.windowEndMillis) / 1000,
                                facts.elapsedSeconds, facts.charsRecognized))
                }
                totalWindows += result.windowCount
                var enriched = result.segments
                let detector = QuestionDetector(sensitivity: .normal)
                for i in enriched.indices {
                    if let hit = detector.detect(enriched[i].text) {
                        enriched[i].questionLevel = hit.level
                        enriched[i].coreQuestion = hit.coreQuestion
                    }
                }
                for segment in enriched {
                    emit("      · [\(segment.formattedTimestamp)] \(segment.text)")
                }
                emit(String(format: "    ✅ %d 段 · %d 字 · %d 窗 · 墙钟 %.1f 秒（音频 %.1f 秒）",
                            enriched.count, enriched.reduce(0) { $0 + $1.text.count },
                            result.windowCount, result.wallSeconds, result.audioSeconds))
                // 回读核对（`TranscriptionEngine` 的 contextualStrings 也有一条同名的）：
                // 「我打算送 X」和「管线实际送的是 X」是两件事，中间隔着一次传参。
                // 传丢了这个不报任何错，只表现为「开了但没用」
                emit(result.initialPrompt == glossaryPrompt.text
                     ? "      ✅ 管线回读的 initial_prompt 与送出去的一致"
                     : "      ❌ 管线回读的 initial_prompt 与送出去的不一致（实际 \(result.initialPrompt.map { "\($0.count) 字" } ?? "nil")）")
                produced.append((index, enriched))
            } catch {
                emit("    ❌ 这一段转写失败：\(error.localizedDescription)")
            }
        }

        var updated = session
        for entry in produced {
            updated.parts[entry.index].segments = entry.segments
            updated.parts[entry.index].transcriptionProvenance = provenance
        }

        emit("")
        emit("─── 结果 ───")
        emit("  段数 \(produced.reduce(0) { $0 + $1.segments.count })"
             + " · 字数 \(produced.reduce(0) { sum, entry in sum + entry.segments.reduce(0) { $0 + $1.text.count } })"
             + " · 窗数 \(totalWindows)")
        emit("  出处（写进副本的 transcriptionProvenance）: \(provenance.summary)")

        // 落盘的门。截断音频转出来的是**半份转录**，而半份在输出上完全看不出来
        if options.headSeconds > 0 && !options.allowPartial {
            emit("")
            emit("⛔️ 拒绝落盘：这次跑的是 --head \(Int(options.headSeconds)) 秒的截断音频，"
                 + "转出来只有前 \(Int(options.headSeconds)) 秒的内容")
            emit("   它看起来和一份完整转录一样（段数/字数/时间戳都自洽），所以不许悄悄写出去。")
            emit("   确认要这份半成品就显式加 --allow-partial。输入文件一个字都没动。")
            return 4
        }

        do {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            let outFile = outURL.appendingPathComponent(inputURL.lastPathComponent)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(updated).write(to: outFile, options: .atomic)
            emit("")
            emit("  ✅ 写出 \(outFile.path)（输入会话文件未动）")
        } catch {
            emit("❌ 写不出去：\(error.localizedDescription)")
            return 5
        }
        return 0
    }

    private static func secondsSince(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}
