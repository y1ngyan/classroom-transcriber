import AVFoundation
import Foundation

/// `--mic-level`：从**指定设备**录一小段，落一个 wav，并打印可打印判据。
///
/// **这是本仓库唯一一个「会真的开麦录音」的无头入口**（派单书 ⑩）。
/// 所以它有两条别的入口没有的规矩：
///   · **必须带重定向**（`--out <目录>` 或 `CLASSROOM_MIC_OUT`），否则拒绝运行
///     ——它默认要写音频，不重定向就会写进用户真实的 `recordings/`；
///   · **它不进 `exit_codes.sh` 的自动那一段**，只挂在 `WITH_MIC=1` 下面，
///     由人显式触发。任何自动跑的东西都不许抢占用户的麦克风。
///
/// 它不做的事：不起 GUI、不发声、不改任何系统音频设置（不切默认设备、不动音量）。
enum MicLevelProbe {

    struct Outcome {
        var lines: [String]
        var exitCode: Int32
    }

    /// 默认录 5 秒（派单书 ①）
    static let defaultSeconds = 5

    static func run(arguments: [String]) async -> Outcome {
        var lines: [String] = []
        lines.append("麦克风电平探针（**会占用麦克风** · 不发声 · 不改系统音频设置）")
        lines.append("")

        // ── 硬闸 ①：必须重定向 ──
        //
        // 规矩与 P7-1 的 `CLASSROOM_MODELS_DIR` 同一条：**没有重定向就拒绝运行**。
        // 这个入口默认要写音频，不重定向的话写的就是用户真实的
        // `~/Library/Application Support/ClassroomTranscriber/recordings/`
        let explicitOut = value(of: "--out", in: arguments)
        let envOut = ProcessInfo.processInfo.environment["CLASSROOM_MIC_OUT"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let rawOut = explicitOut ?? (envOut.isEmpty ? nil : envOut)

        guard let rawOut, !rawOut.isEmpty else {
            lines.append("❌ 拒绝运行：没有指定输出目录")
            lines.append("   这个入口会录一段音频并落盘。不重定向的话，它写的可能就是")
            lines.append("   \(RecordingStorage.directory.path)")
            lines.append("   ——那是你自己的录音库。请这样跑：")
            lines.append("     CLASSROOM_MIC_OUT=$(mktemp -d) \(CommandLine.arguments[0]) --mic-level")
            lines.append("   或者显式给：--mic-level --out /tmp/mic-probe")
            return Outcome(lines: lines, exitCode: 2)
        }

        let outDir = URL(fileURLWithPath: (rawOut as NSString).expandingTildeInPath, isDirectory: true)

        // ── 硬闸 ②：不许指向真实库 ──
        //
        // 和上面那条不是重复：`CLASSROOM_MIC_OUT=~/Library/.../recordings` 也「带重定向」，
        // 但它指的就是真实库。几何判据复用 `RecordingStorage` 那一处（边界只许一处写法），
        // 后果文案由本入口自己补
        if let rejection = RecordingStorage.libraryContainmentRejection(outDir) {
            lines.append("❌ 拒绝运行：\(rejection)")
            lines.append("   本入口会往那里写新的 wav，不许落在真实录音库里。请换一个目录。")
            return Outcome(lines: lines, exitCode: 2)
        }

        // ── 硬闸 ③：未授权要响亮地说，**绝不去碰设备让它崩** ──
        //
        // 这是派单书 ⑨ 的落点。做法是**读授权状态**（同步、不弹窗），
        // 不是 `requestAccess`——后者会弹窗、会阻塞，而探针没有资格替用户
        // 做授权决定。授权了才往下走，于是那条
        // `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` 的 abort 根本没有机会发生
        let auth = InputDeviceCatalog.microphoneAuthorization
        lines.append("麦克风授权：\(auth.displayName)")
        guard auth == .authorized else {
            lines.append("❌ 麦克风未授权，拒绝录音（**没有崩，是主动退出**，退出码 2）")
            for line in InputDeviceCatalog.unauthorizedAdvice.split(separator: "\n") {
                lines.append("   \(line)")
            }
            return Outcome(lines: lines, exitCode: 2)
        }
        lines.append("")

        let seconds = value(of: "--seconds", in: arguments).flatMap(Int.init) ?? defaultSeconds
        guard seconds > 0, seconds <= 600 else {
            lines.append("❌ --seconds 要在 1…600 之间（给的是 \(seconds)）")
            return Outcome(lines: lines, exitCode: 2)
        }
        let requestedUID = value(of: "--device", in: arguments)

        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // ── 采集 ──
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // `--device <UID>`：真的去做选择。
        //
        // **回读判据放在 start() 之后**，不是这里：实测引擎在**没启动**时
        // `auAudioUnit.deviceID` 报的是一个内部占位值（本机 121，不在设备表里），
        // 拿它回读等于什么都没验。启动之后报的那个才是真设备
        if let requestedUID {
            guard let target = InputDeviceCatalog.allInputDevices()
                .first(where: { $0.info.uid == requestedUID })
            else {
                lines.append("❌ --device \(requestedUID) 不在设备表里。先用 --audio-devices 看有哪些")
                return Outcome(lines: lines, exitCode: 2)
            }
            // **选择设备走的是 AudioUnit 那条老路，不是 `auAudioUnit.deviceID`**：
            // 那个属性在 Swift 里是 get-only（写完编不过）。
            // `kAudioOutputUnitProperty_CurrentDevice` 是 HAL 输出单元选设备的
            // 正式开关，输入单元走的是同一个（名字里的 Output 是历史包袱）
            guard let unit = input.audioUnit else {
                lines.append("❌ 拿不到输入节点的 AudioUnit，没法指定设备")
                return Outcome(lines: lines, exitCode: 2)
            }
            var deviceID = target.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                lines.append("❌ 切换设备失败：AudioUnitSetProperty 返回 \(status)")
                return Outcome(lines: lines, exitCode: 2)
            }
            lines.append("已请求指定设备：\(target.info.name)（ID \(target.id)）")
        }

        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            lines.append("❌ 未找到可用麦克风输入（format 是 \(micFormat)）")
            return Outcome(lines: lines, exitCode: 2)
        }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let fileName = "mic-level-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: ""))"
            + ".wav"
        let wavURL = outDir.appendingPathComponent(fileName)
        guard let recorder = WAVRecorder(
            url: wavURL,
            sampleRate: UInt32(micFormat.sampleRate),
            channels: 1
        ) else {
            lines.append("❌ 建不出 WAV 写入器：\(wavURL.path)")
            return Outcome(lines: lines, exitCode: 2)
        }

        let box = SampleBox()
        installTap(on: input, format: micFormat, recorder: recorder, box: box)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            lines.append("❌ 麦克风启动失败：\(error.localizedDescription)")
            return Outcome(lines: lines, exitCode: 2)
        }

        lines.append(String(format: "正在录 %.1f 秒…（说话、不说话都行——这个入口只看电平）", Double(seconds)))
        try? await Task.sleep(for: .seconds(seconds))

        input.removeTap(onBus: 0)
        engine.stop()
        recorder.finish()

        let samples = box.samples
        lines.append("")

        // ── 「这次实际用的是哪个麦」 ──
        //
        // 读的是**启动之后**引擎自己报的那个（`InputDeviceResolution` 判谁优先），
        // 不是重查一次系统默认就算数
        let actualID = input.auAudioUnit.deviceID
        let resolved = InputDeviceResolution.resolve(
            engineDeviceID: actualID,
            engineInfo: InputDeviceCatalog.info(of: actualID),
            defaultInfo: InputDeviceCatalog.info(of: InputDeviceCatalog.defaultInputDeviceID())
        )
        for line in describeDevice(resolved, requestedUID: requestedUID) {
            lines.append(line)
        }
        lines.append("")

        guard !samples.isEmpty else {
            lines.append("❌ 采样是空的——麦克风一次回调都没有（设备被别处占着？）")
            lines.append("   文件仍在：\(wavURL.path)")
            return Outcome(lines: lines, exitCode: 1)
        }

        // ── 可打印判据 ──
        let reading = MicLevelMetrics.analyze(samples: samples, sampleRate: micFormat.sampleRate)
        for line in report(reading) { lines.append(line) }
        lines.append("")
        lines.append("存档（**不是** App 的录音库）：\(wavURL.path)")
        lines.append("   想再看一遍这条文件：swift tools/audio_health.swift \(wavURL.path)")

        // 指定了设备、但最后用的不是它 —— 必须说不出来，不能静默
        if let requestedUID, resolved?.info.uid != requestedUID {
            lines.append("")
            lines.append("❌ --device 指定的设备**没有被用上**（退出码 2）")
            lines.append("   要的是 \(requestedUID)，实际用的是 \(resolved?.info.uid ?? "（读不到）")")
            return Outcome(lines: lines, exitCode: 2)
        }
        return Outcome(lines: lines, exitCode: 0)
    }

    // MARK: - 输出

    private static func describeDevice(
        _ resolved: InputDeviceResolution.Resolved?,
        requestedUID: String?
    ) -> [String] {
        guard let resolved else {
            return ["使用设备：**读不到**（引擎报了 0 或那只设备已从系统里消失）"]
        }
        let sourceNote = resolved.source == .engine
            ? "引擎输入节点自己报的（source=engine）"
            : "引擎没报出可用设备，回落到系统默认（source=default）"
        var lines = [
            "使用设备：\(resolved.info.name)",
            "   UID \(resolved.info.uid) · \(resolved.info.channels)ch · \(Int(resolved.info.sampleRate))Hz",
            "   来源：\(sourceNote)",
            "   引擎报的 deviceID = \(resolved.engineDeviceID)",
        ]
        if let requestedUID {
            lines.append("   请求的是：\(requestedUID)"
                + (resolved.info.uid == requestedUID ? "（一致 ✅）" : "（**不一致** ❌）"))
        }
        return lines
    }

    /// 高峰值 / 底噪 / 动态范围 / 削顶 + 逐秒窗口表。
    ///
    /// 每个读数后面都跟着**怎么读它**：这几个数字单独摆出来是不够的——
    /// 「-40 dBFS 算不算低」取决于是峰值还是底噪，而人不会每次都记得
    static func report(_ r: MicLevelReading) -> [String] {
        var lines: [String] = []
        lines.append(String(format: "全段 %.1f 秒 · %d 个样本", r.durationSeconds, r.sampleCount))
        lines.append("")
        lines.append("  ── 可打印判据 ──")
        lines.append(String(format: "  峰值        %7.1f dBFS   （离削顶还有 %.1f dB 余量）",
                            r.peakDBFS, -r.peakDBFS))
        lines.append(String(format: "  底噪        %7.1f dBFS   （帧 RMS 的 p5）", r.noiseFloorDBFS))
        lines.append(String(format: "  动态范围    %7.1f dB     （整段 p90 − p5；**逐秒的看下面那张表**）",
                            r.dynamicRangeDB))
        lines.append(String(format: "  削顶样本    %7d 个       （|样本| ≥ %.3f，占 %.4f%%）",
                            r.clippedSamples, MicLevelMetrics.clipThreshold, r.clippedFraction * 100))
        lines.append(String(format: "  最长连续削顶 %5d 个       （零星碰顶和糊成方波是两回事）",
                            r.longestClipRun))
        lines.append("")

        guard !r.windows.isEmpty else {
            lines.append("  （太短，不足以分窗）")
            return lines
        }
        lines.append("    时间窗      底噪(p5)    中位        语音(p90)   动态范围   语音帧")
        for w in r.windows {
            let flag = w.qualityNote.map { "  （\($0)，此行读数不可用）" } ?? ""
            lines.append(String(format: "   %4.0f–%-4.0fs  %.5f    %.5f    %.5f   %6.1f dB  %5.1f%%%@",
                                w.start, w.start + 1,
                                w.floor, w.median, w.speech, w.rangeDB, w.speechRatio * 100, flag))
        }

        let usable = r.windows.filter { $0.quality == .ok }
        if usable.isEmpty {
            lines.append("")
            lines.append("   （没有一个窗口是「又有人在说话、又有停顿」的，逐秒动态范围量不出来）")
            lines.append("    这类录音判断请看**峰值**和**削顶**两项——它们不依赖有人说话")
        } else {
            let ranges = usable.map(\.rangeDB)
            lines.append("")
            lines.append(String(format: "   可测窗口 %d/%d · 平均 %.1f dB（最好 %.1f / 最差 %.1f）",
                                usable.count, r.windows.count,
                                ranges.reduce(0, +) / Double(ranges.count),
                                ranges.max() ?? 0, ranges.min() ?? 0))
        }
        lines.append("   注：这几个数描述的是**音频本身**，不预测转录准确率——"
                     + "实测噪声压到 15dB SNR 转录仍近乎完美，真正致命的是混响（见 tools/audio_health.swift）。")
        return lines
    }

    // MARK: - 采集细节

    /// 采样盒。`@unchecked Sendable` 的依据：`[Float]` 只在 `lock` 里读写。
    /// tap 回调在音频线程上，`Task.sleep` 回来的是另一条线程
    final class SampleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Float] = []

        func append(_ chunk: [Float]) {
            lock.lock(); storage.append(contentsOf: chunk); lock.unlock()
        }

        var samples: [Float] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    /// 同理：`installTap` 的 block 是非 Sendable 的 ObjC block，
    /// 必须在 nonisolated 上下文里构造（见 `MicTap` 上面那段）。
    ///
    /// 和 App 那条采集链的关系是**只有这一段是共用的形状**——它不走
    /// `TranscriptionEngine`，也不碰 analyzer / 增益 / 语音处理。探针要量的是
    /// **设备的原始电平**，中间过一级增益就量不到设备本身了
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        recorder: WAVRecorder,
        box: SampleBox
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder.append(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            // 交错缓冲要按声道数跨步取——不跨步的话多声道源会被当成
            // 「采样率变高了的单声道」，读数全是错的
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            var chunk = [Float](repeating: 0, count: frames)
            for index in 0..<frames { chunk[index] = channel[index * stride] }
            box.append(chunk)
        }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}
