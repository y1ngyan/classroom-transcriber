import AVFoundation
import Speech
import Observation

/// 转录引擎：麦克风采集 → SpeechAnalyzer 流式转写 → TranscriptSegment
///
/// 中英混合的实现方式：向同一个 SpeechAnalyzer 挂载**多个** SpeechTranscriber
/// （zh-CN 和 en-US），它们消费同一路音频、各自输出结果。每个结果标注来源语言，
/// 不做自动合并——先把真实数据摆出来，合并策略再根据实测效果决定。
@MainActor
@Observable
final class TranscriptionEngine {

    // MARK: - 对外状态

    private(set) var segments: [TranscriptSegment] = []
    private(set) var isRunning = false
    private(set) var statusMessage = "就绪"
    private(set) var audioLevel: Float = 0
    private(set) var installedLocales: [String] = []

    /// 系统级语音处理（回声消除 + 噪声抑制 + 自动增益）是否生效。
    /// 用 AVAudioInputNode 原生能力，不需要 BlackHole / RNNoise 这类外部方案。
    private(set) var voiceProcessingActive = false

    /// 是否启用系统级语音处理（AEC + 噪声抑制 + AGC）。
    ///
    /// **默认关。这是实测数据推出来的，不是保守起见。**
    ///
    /// 对同一场录音（课堂-20260918-101340.wav，191 秒，全程同一支麦、同一间
    /// 教室、同一个说话人）做逐 10 秒的底噪与动态范围统计，结果是：
    ///
    /// ```
    ///   0– 20s   底噪 0.0002   动态范围 48 dB   ← 转录完美
    ///  20– 60s   底噪 0.0077   动态范围 17 dB   ← 转录崩坏
    ///  60– 70s   底噪 0.0005   动态范围 34 dB   ← 又恢复
    /// ```
    ///
    /// 底噪在 20 秒处**跳高 40 倍**（+32 dB），而同一时间窗里语音电平只涨了
    /// 2 dB——这不是房间变吵，是链路上多出来的东西。语音处理里的自适应滤波器
    /// （AEC、噪声抑制）要一段时间才收敛，收敛之后就开始自己产生噪声。
    ///
    /// 旁证：库里唯二转录完美的两条录音分别是 5.6 秒和 10.9 秒，**都短于滤波器
    /// 收敛所需的时间**；凡是超过 20 秒的录音，动态范围没有一条上过 40 dB。
    ///
    /// 更要命的是这层处理在 tap **之前**，所以存档文件里也是被处理过的音频
    /// ——事后拿文件重转也救不回来，损失是当场发生的。
    ///
    /// 留着这个开关是为了还能做 A/B；但要用它，得先有证据，不能默认开。
    var useVoiceProcessing = false

    /// 语音处理自带的自动增益。只在 `useVoiceProcessing` 为真时才有意义。
    /// 关闭理由同上：它就是那条会随时间漂移的链的一部分。
    var useAGC = false

    /// 自检用：实际协商出来的音频格式
    private(set) var formatDescription = ""

    /// 自定义词表的注入结果。空字符串表示这次没词表，或还没开始
    private(set) var contextStatus = ""

    /// 本次（或最近一次）录音存档的落盘路径。
    /// COS 上传要的就是这个文件——没有它「上传云端」就没有上传对象。
    private(set) var recordingURL: URL?

    /// 是否把音频存成 WAV 存档。
    /// 默认开：上传云端依赖它。关掉则只做实时转录，不落盘。
    var recordsAudio = true

    /// 段落定稿（isFinal 由 false 变 true）时回调一次。
    /// 事实核查挂在这里，而不是让视图去 diff segments 数组。
    var onFinalSegment: (@MainActor (TranscriptSegment) -> Void)?

    /// 段落定稿且被判定为课堂提问时回调一次。在 `onFinalSegment` 之前触发，
    /// 回调拿到的 segment 已经带好 questionLevel / coreQuestion。
    var onQuestion: (@MainActor (TranscriptSegment, QuestionDetection) -> Void)?

    /// 课堂提问检测灵敏度。只在段落**定稿**的那一刻跑一次——
    /// 未定稿的文本还会被反复改写，对半成品跑规则只会得到一会有一会没的假信号。
    var questionSensitivity: QuestionSensitivity = .normal

    /// 要挂载的语言模型。
    ///
    /// 实测结论（见阶段 2 报告）：中文课堂挂单个 `zh-CN` 最优——它会把英文术语
    /// 按读音转成拉丁字母（machine learning → "Machin learning"），这些偏差交给
    /// 术语词表纠正。同时挂 `en-US` 不会融合、反而污染输出，故默认不挂。
    var locales: [String] = ["zh-CN"]

    /// 交给识别器的自定义词表（`AnalysisContext.contextualStrings`）。
    ///
    /// 只放**正确写法**，不放别名，也不放中文释义：词表提高的是这些拼写被
    /// 识别出来的先验，把「Machin learning」这类历史误拼塞进去等于教它往
    /// 错的方向偏。中文同理——理由见 GlossaryDefaults 的注释。
    var contextualTerms: [String] = []

    /// 送进识别器之前的软件增益档。
    ///
    /// **只作用于送入识别器的那一份，存档永远是未加增益的原始音频。**
    /// 理由见 `MicTap.handle` 里的顺序说明。
    ///
    /// 和 `useVoiceProcessing` 是两回事：那一档是系统语音处理链路（AEC +
    /// 噪声抑制 + 它的 AGC），实测会在 20 秒后毁掉音频，默认关；这一档是
    /// 我们自己写的、纯软件、只看帧 RMS，带噪声门，不碰音频设备。
    var micGain: MicGainMode = .auto

    /// 实时转录预设。
    ///
    /// 实测：非 progressive 预设只在音频定稿时才吐结果，实时场景下会长时间空屏；
    /// progressive 系列边听边出。timeIndexedProgressive 兼顾实时性与分段时间戳。
    var preset: FileTranscription.PresetChoice = .timeIndexed

    // MARK: - 内部状态

    private var analyzer: SpeechAnalyzer?
    private var transcribers: [SpeechTranscriber] = []
    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTasks: [Task<Void, Never>] = []
    private var segmentIndex: [SegmentKey: Int] = [:]
    private var micTap: MicTap?
    private var recorder: WAVRecorder?

    private struct SegmentKey: Hashable {
        let startMillis: Int
        let language: String
    }

    // MARK: - 权限

    func requestPermissions() async {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        statusMessage = micGranted ? "麦克风已授权" : "麦克风被拒绝"

        let speechStatus = await Self.speechAuthorizationStatus()
        if speechStatus != .authorized {
            statusMessage = "语音识别未授权（\(speechStatus.rawValue)）"
        }
    }

    /// TCC 保证不了这个 block 在主队列上执行（见 SFSpeechRecognizer.h 注释），
    /// 所以桥接必须放在 nonisolated 上下文里：在 @MainActor 上构造闭包会让它继承
    /// 主 actor 隔离，Swift 6 运行时随即在闭包入口做 executor 校验 ——
    /// 从后台线程进入就直接 dispatch_assert_queue_fail / SIGTRAP。
    private nonisolated static func speechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: - 启动

    func start() async {
        guard !isRunning else { return }
        statusMessage = "准备中…"

        // 1. 确认语言受支持
        //    坑：SpeechTranscriber 吐出的 Locale 标识符不一定是 "zh-CN" 这种形式
        //    （可能是 zh_CN / zh-Hans-CN），直接比字符串会一个都匹配不上，
        //    表现就是「支持 30 个 locale，但没有可用语言模型」。走宽松匹配。
        let supported = await SpeechTranscriber.supportedLocales
        let usableLocales = FileTranscription.resolve(locales, against: supported)
        let usable = usableLocales.map(\.identifier)

        guard !usableLocales.isEmpty else {
            statusMessage = "❌ 没有可用语言模型（支持 \(supported.count) 个 locale）"
            return
        }
        if usable.count < locales.count {
            let missing = Set(locales).subtracting(usable)
            statusMessage = "⚠️ 部分语言不支持: \(missing.sorted().joined(separator: ", "))"
        }

        // 2. 构建 transcriber
        //    预设实测对比（见 speechanalyzer-transcription-findings）：
        //    **实时只该用 timeIndexedProgressiveTranscription。**
        //    差的那个是 progressiveTranscription——它开了 fastResults，
        //    拿精度换延迟，「梯度下降」会被识别成「激动需要 90万发超」。
        //    带 Alternatives 的两个预设只在音频定稿时才吐结果，直播场景下
        //    会长时间空屏，所以留给文件转录（FileTranscription）用。
        transcribers = usableLocales.map { locale in
            // preset 的 attributeOptions 默认不含逐字符置信度——它是质量自评
            // 的唯一可信信号（识别器自己知道每个字有多可信），必须显式打开。
            // Preset 是值类型，拷贝出来加一项不影响那个静态实例
            var presetWithConfidence = preset.preset
            presetWithConfidence.attributeOptions.insert(.transcriptionConfidence)
            return SpeechTranscriber(locale: locale, preset: presetWithConfidence)
        }

        // 3. 确保设备端模型已下载
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: transcribers) {
                statusMessage = "正在下载语言模型…"
                try await request.downloadAndInstall()
            }
        } catch {
            statusMessage = "❌ 模型下载失败: \(error.localizedDescription)"
            return
        }

        let installed = await SpeechTranscriber.installedLocales
        installedLocales = FileTranscription.resolve(usable, against: installed).map(\.identifier)

        // 4. 先建音频引擎并开启系统级语音处理，再协商格式
        //    （必须在读格式、装 tap 之前开，否则输入格式对不上）
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let input = audioEngine.inputNode
        if useVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingActive = true
            } catch {
                // 非致命：降级为无降噪
                voiceProcessingActive = false
            }
            input.isVoiceProcessingAGCEnabled = useAGC
        } else {
            voiceProcessingActive = false
        }

        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            statusMessage = "❌ 未找到可用麦克风输入"
            return
        }

        // 单声道源格式。多声道 → 单声道不能交给 AVAudioConverter：
        // 实测 4ch(Quadraphonic) → 1ch 会返回帧数正确、内容全 0 的静音缓冲（RMS 0.0）。
        // 降噪开启时麦克风恰好是 4 声道，于是整场转录喂进去的都是数字静音。
        // 所以先按这个格式抽出第 0 声道，再做 1ch → 1ch 转换（这一步实测可靠）。
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: micFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            statusMessage = "❌ 无法构建单声道格式"
            return
        }

        // 5. 创建 analyzer
        let modules: [any SpeechModule] = transcribers
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer

        // 5b. 把术语表灌进去当自定义词表，赶在喂音频之前
        await applyContext(to: analyzer)

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: micFormat
        ) else {
            statusMessage = "❌ 麦克风格式不兼容"
            return
        }

        formatDescription = "麦克风 \(Self.describe(micFormat)) → 抽第0声道 \(Self.describe(monoFormat)) → analyzer \(Self.describe(targetFormat))"

        do {
            try await analyzer.prepareToAnalyze(in: targetFormat)
        } catch {
            statusMessage = "❌ 分析器初始化失败: \(error.localizedDescription)"
            return
        }

        // 6. 先挂结果监听，再喂音频
        for (transcriber, localeID) in zip(transcribers, usable) {
            consumeResults(from: transcriber, language: localeID)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        guard startMicrophone(
            engine: audioEngine,
            micFormat: micFormat,
            monoFormat: monoFormat,
            convertingTo: targetFormat,
            into: continuation
        ) else { return }

        // 7. 开跑
        do {
            try await analyzer.start(inputSequence: stream)
            isRunning = true
            let noise = voiceProcessingActive ? "降噪开" : "降噪关"
            // 增益档要报出来：它默认是开的，而「开着的」和「关着的」在
            // 转录结果上不一定当场分得出——用户改了这一档，得能确认它生效了
            statusMessage = "转录中 · \(usable.joined(separator: " + "))"
                + " · \(noise) · 增益 \(micGain.shortLabel)"
        } catch {
            statusMessage = "❌ 启动失败: \(error.localizedDescription)"
            stop()
        }
    }

    // MARK: - 麦克风采集

    private func startMicrophone(
        engine: AVAudioEngine,
        micFormat: AVAudioFormat,
        monoFormat: AVAudioFormat,
        convertingTo targetFormat: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> Bool {
        let input = engine.inputNode

        guard let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            statusMessage = "❌ 无法创建音频转换器"
            return false
        }

        // 录音存档。开不了就退回「只转录不落盘」，不影响转录本身
        let recorder = makeRecorder(sampleRate: monoFormat.sampleRate)
        self.recorder = recorder
        if recordsAudio && recorder == nil {
            statusMessage = "⚠️ 录音存档创建失败，本次只转录不落盘"
        }

        // 软件增益。**每段录音新建一个**，而不是让引擎长期持有一个：
        // AGC 的平滑状态是跟着这一路信号收敛出来的，跨录音复用会把上一段
        // 末尾的增益当成新一段的起点——上一段结尾要是正好在大声说话，
        // 新一段开头就会带着一个 4.5 倍的增益冲进去。
        let preamp = AudioPreamp(mode: micGain)
        preamp.reset()

        let tap = MicTap(
            sourceFormat: monoFormat,
            converter: converter,
            targetFormat: targetFormat,
            continuation: continuation,
            recorder: recorder,
            preamp: preamp
        ) { [weak self] level in
            // 电平表（仅 UI 用）：从音频线程跳回主 actor
            Task { @MainActor in self?.audioLevel = level }
        }

        Self.installTap(on: input, format: micFormat, tap: tap)
        micTap = tap

        engine.prepare()
        do {
            try engine.start()
        } catch {
            statusMessage = "❌ 麦克风启动失败: \(error.localizedDescription)"
            return false
        }

        return true
    }

    /// 建一个本次录音的存档文件。返回 nil 表示不存档，或创建失败。
    ///
    /// 失败不阻断转录：存档是附加能力，不能因为它开不了就录不了课。
    private func makeRecorder(sampleRate: Double) -> WAVRecorder? {
        guard recordsAudio else { return nil }
        let url = RecordingStorage.makeURL()
        guard let recorder = WAVRecorder(url: url, sampleRate: UInt32(sampleRate), channels: 1) else {
            return nil
        }
        recordingURL = url
        return recorder
    }

    /// 同理，构造 tap 闭包也必须在 nonisolated 上下文里。
    /// installTap 的 block 是非 Sendable 的 ObjC block，在主 actor 上构造会让它继承
    /// @MainActor 隔离，而它由音频线程调用 —— 一旦开启录音就会 trap。
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        tap: MicTap
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            tap.handle(buffer)
        }
    }

    /// 音频线程侧的处理体。
    ///
    /// 存在的理由：AVAudioConverter 不是 Sendable，没法被 @Sendable 闭包捕获。
    /// 把它封在这个显式承诺「只从音频线程访问」的类里，既过得了并发检查，
    /// 也让 tap 闭包得以彻底脱离主 actor。
    private final class MicTap: @unchecked Sendable {
        private let sourceFormat: AVAudioFormat
        private let converter: AVAudioConverter
        private let targetFormat: AVAudioFormat
        private let continuation: AsyncStream<AnalyzerInput>.Continuation
        private let onLevel: @Sendable (Float) -> Void
        /// 录音存档。为 nil 表示这次不落盘
        private let recorder: WAVRecorder?
        /// 软件增益（AGC / 固定倍数）。只作用在送进识别器的那一份上
        private let preamp: AudioPreamp

        /// 存档的低频清理截止频率。成年男声基频最低到 85Hz，再往上切会削元音，
        /// 所以卡在 80——理由写在 `HighPassFilter` 的文档里。
        private static let highPassCutoffHz = 80.0

        /// 存档用的低频清理，见 `HighPassFilter`。
        ///
        /// 只从音频线程访问，`MicTap` 已经是 `@unchecked Sendable`，
        /// 不再单独标注。构造不出来（采样率异常）时为 nil，整级跳过——
        /// 少一级滤波不影响功能，构造出一个错的才会。
        private let highPass: HighPassFilter?
        /// 和 `highPass` 同生共死，只为了让 UI 能说清这一级到底在不在
        private let highPassCutoff: Double?

        /// 抽声道用的复用缓冲。
        ///
        /// 原来这一块**每次回调都在实时音频线程上 new 一次**（约 12 次/秒）。
        /// 单次分配不大，但实时线程上的堆分配可能撞上优先级倒置或缺页，
        /// 而那一次卡顿就是采集丢帧。容量不够时（引擎改了回调块长）才重建。
        ///
        /// 只复用它、**不复用转换输出缓冲**：mono 缓冲的生命周期完全在这次
        /// 回调之内（高通 / 增益 / 存档 / 转换全是同步消费），而转换输出
        /// 被 yield 给 analyzer 后是异步读的，复用就是数据竞争。
        private var monoBuffer: AVAudioPCMBuffer?

        init(
            sourceFormat: AVAudioFormat,
            converter: AVAudioConverter,
            targetFormat: AVAudioFormat,
            continuation: AsyncStream<AnalyzerInput>.Continuation,
            recorder: WAVRecorder?,
            preamp: AudioPreamp,
            onLevel: @escaping @Sendable (Float) -> Void
        ) {
            self.sourceFormat = sourceFormat
            self.converter = converter
            self.targetFormat = targetFormat
            self.continuation = continuation
            self.recorder = recorder
            self.preamp = preamp
            let filter = HighPassFilter(
                sampleRate: sourceFormat.sampleRate,
                cutoff: Self.highPassCutoffHz
            )
            self.highPass = filter
            self.highPassCutoff = filter == nil ? nil : Self.highPassCutoffHz
            self.onLevel = onLevel
        }

        private let lock = NSLock()
        private var tappedCount = 0
        private var convertedCount = 0
        private var frameCount = 0
        private var silentConversionCount = 0
        private var gainSum: Double = 0
        private var gainSamples = 0

        /// 音频链路计数，自检 / 排障用
        var stats: (tapped: Int, converted: Int, frames: Int) {
            lock.lock(); defer { lock.unlock() }
            return (tappedCount, convertedCount, frameCount)
        }

        /// 本段录音里软件增益的平均值。读数是给界面用的：
        /// 只看输入电平，用户没法判断 AGC 到底在不在干活。
        var averageGain: Float? {
            lock.lock(); defer { lock.unlock() }
            guard gainSamples > 0 else { return nil }
            return Float(gainSum / Double(gainSamples))
        }

        func handle(_ buffer: AVAudioPCMBuffer) {
            // **永远拿一份自己拥有的缓冲**，不复用引擎的 buffer。
            //
            // 原来这里有一句 `buffer.format.isEqual(sourceFormat) ? buffer : ...`，
            // 省掉一次拷贝。但那意味着下面这级高通要原地改引擎的内存——
            // 引擎的缓冲我们只有读的权利，写它属于未定义行为。
            // `firstChannelAsMono` 在格式一致时做的正好就是「把第 0 声道拷出来」，
            // 内容和原缓冲逐样本相同，只是换成了我们的内存。
            let source = firstChannelAsMono(buffer, format: sourceFormat, reusing: &monoBuffer)

            // 高通在抽完声道之后做：多声道时先抽再滤，滤波器只需要维护一份状态。
            // 存档和识别走的是同一个 source，所以两边都过这一级——
            // 实测（dsp_lab 的 --hp）这条高通对转录结果没有可观察的影响，
            // 不存在「为了存档音质把识别搞坏」的取舍。
            if let source { highPass?.process(source) }

            // **存档必须排在软件增益之前。** 这三行的顺序是一条硬约束，
            // 和上面 stop() 里「先定稿再取消」是一类东西——调换之后不会
            // 报错，只会把结果悄悄改掉。
            //
            // 增益是给识别器的补偿：它是「这一帧有多小声」的一次性判断，
            // 下一帧可能完全不同。把它烧进存档，等于把当时那套 AGC 状态
            // 永久焊在文件里——事后拿这条录音重转、做 A/B、量动态范围，
            // 量到的都是加过工的信号，而原始电平已经不存在了，救不回来。
            // 界面上的「上传云端」传的就是这条存档，用户以为存的是课上
            // 实际发生的声音。
            //
            // 存档走抽好声道的单声道源，不走 converted：converted 是
            // analyzer 要的格式（可能 16kHz），存下来音质白丢一截
            if let source { recorder?.append(source) }

            // 增益只影响送进识别器的那一份（原地改 source，上面已经存过档了）
            var gain: Float = 1
            if let source { gain = preamp.process(source) }

            let converted = source.flatMap { convert($0, using: converter, to: targetFormat) }

            // 兜底：源有信号、转换后却是全零，说明又踩到「静音下混」那类坑了。
            // 静默失败的代价太大（整场转录全是空气），宁可显式报出来。
            let inputLevel = rms(of: buffer)
            let outputIsSilent = converted.map { rms(of: $0) == 0 } ?? false
            let suspicious = outputIsSilent && inputLevel > 0.001

            lock.lock()
            tappedCount += 1
            if let converted {
                convertedCount += 1
                frameCount += Int(converted.frameLength)
            }
            if suspicious { silentConversionCount += 1 }
            gainSum += Double(gain)
            gainSamples += 1
            lock.unlock()

            guard let converted else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
            reportLevel(inputLevel)
        }

        /// 电平表节流的最后发送记录（仅音频线程访问）
        private var lastReportedLevel: Float = -1
        private var lastReportTime: CFAbsoluteTime = 0

        /// 电平表更新。
        ///
        /// 直接每回调都 `onLevel` 的话，每次都要在音频线程上分配一个跳回
        /// 主 actor 的 Task（约 12 次/秒），而静音期电平几乎不动，这些跳转
        /// 全是浪费。所以变化小于阈值且距上次不足 100ms 就跳过——电平表
        /// 是个 10Hz 就够读的 UI，识别链路不缺这一下。
        private func reportLevel(_ level: Float) {
            let now = CFAbsoluteTimeGetCurrent()
            let settled = abs(level - lastReportedLevel) < 0.01
            let recent = now - lastReportTime < 0.1
            if settled && recent { return }
            lastReportedLevel = level
            lastReportTime = now
            onLevel(level)
        }

        var silentConversions: Int {
            lock.lock(); defer { lock.unlock() }
            return silentConversionCount
        }

        /// 存档那一级高通到底有没有生效。
        ///
        /// 报出来是因为「没生效」和「生效了」从波形和转录结果上都看不出来——
        /// 唯一能看出来的地方是频谱最底下那一条，而没人会为了一句
        /// 「低音干净了点」去翻频谱。构造失败（采样率异常）时这里是 nil，
        /// 不做的事就说不做，别让它静默地什么都不干。
        var activeHighPassCutoff: Double? { highPassCutoff }

        /// 本次录音的软件增益档
        var gainMode: MicGainMode { preamp.mode }
    }

    /// 音频链路计数，用于确认音频到底走到哪一步断了
    var micStats: String {
        guard let tap = micTap else { return "无 tap" }
        let s = tap.stats
        var line = "tap 回调 \(s.tapped) 次 · 转换成功 \(s.converted) 次 · 送入 analyzer \(s.frames) 帧"
        if let cutoff = tap.activeHighPassCutoff {
            line += " · 存档高通 \(Int(cutoff))Hz"
        } else {
            line += " · ⚠️ 存档高通未生效（采样率异常）"
        }
        let silent = tap.silentConversions
        if silent > 0 {
            line += " · ⚠️ \(silent) 次转换成了静音（源有信号但输出全零）"
        }
        // 增益报的是**平均值**：AGC 每帧的增益都在动，抽一帧出来看没有意义，
        // 而平均值正好回答「这一场里它到底放大了多少」
        line += " · 增益 \(tap.gainMode.label)"
        if let average = tap.averageGain, tap.gainMode == .auto {
            line += String(format: " 均 %.2f×", average)
        }
        return line
    }

    /// 链路读数的**结构化**版本。
    ///
    /// `micStats` 是拼成一整行的字符串，给终端看正合适；界面要的是
    /// 分开渲染的每一段数字，所以另出一份，不去拆那个字符串。
    struct CaptureStats {
        var hasTap = false
        var tapped = 0
        var converted = 0
        var frames = 0
        var silentConversions = 0
        /// 本次录音的软件增益档。没开始录时是 nil
        var gainMode: MicGainMode?
        /// AUTO 档下的平均增益。其余档位没有意义（是固定值）
        var averageGain: Float?

        /// 「转换成功」占「回调」的比例。中断在中间时这个数会明显小于 1
        var convertRatio: Double {
            tapped == 0 ? 0 : Double(converted) / Double(tapped)
        }
    }

    var captureStats: CaptureStats {
        guard let tap = micTap else { return CaptureStats() }
        let s = tap.stats
        return CaptureStats(
            hasTap: true,
            tapped: s.tapped,
            converted: s.converted,
            frames: s.frames,
            silentConversions: tap.silentConversions,
            gainMode: tap.gainMode,
            averageGain: tap.averageGain
        )
    }

    /// 一句话说明「现在卡在哪」，没有任何问题时返回 nil。
    ///
    /// 这几步是按音频实际流经的顺序排的，所以第一个命中的就是断点。
    /// 有过一次「看起来在录、其实一个字都没进来」的经历之后，把判断
    /// 交给用户自己去数那几个计数是不现实的——直接给结论。
    var captureDiagnosis: String? {
        let s = captureStats

        guard s.hasTap else { return "还没开始采集" }
        if s.tapped == 0 { return "麦克风零回调 —— 系统根本没有在采集" }
        if s.converted == 0 { return "收到了音频，但没有一帧转换成功" }
        if s.frames == 0 { return "转换成功却没有帧送进识别器" }
        if s.silentConversions > 0 && s.silentConversions == s.converted {
            return "转换输出全是静音 —— 源信号没真正进来"
        }
        // 电平判断只在上述结构性问题都排除后才做：底噪很低本身不是故障，
        // 但它会让识别器「安静地不吐字」，是最难自查的一种
        if isRunning, audioLevel > 0, audioLevel < 0.001 {
            return "音频在流，但电平极低（\(String(format: "%.4f", audioLevel))）—— 说话时若不上升就是没收到声音"
        }
        return nil
    }

    // MARK: - 结果消费

    private func consumeResults(from transcriber: SpeechTranscriber, language: String) {
        resultTasks.append(Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                    let startMillis = Int(result.range.start.seconds * 1000)
                    let endMillis = Int((result.range.start + result.range.duration).seconds * 1000)
                    // 逐字符置信度跟着结果一起走：`String(result.text.characters)`
                    // 会把 ConfidenceAttribute 整个丢掉，必须在这里就抽出来
                    let quality = TranscriptQualityAssessor.grade(
                        confidences: TranscriptQualityAssessor.confidences(from: result.text)
                    )

                    await self?.upsert(
                        text: text,
                        startMillis: startMillis,
                        endMillis: endMillis,
                        isFinal: result.isFinal,
                        language: language,
                        qualityGrade: quality
                    )
                }
            } catch {
                await self?.reportResultError(error, language: language)
            }
        })
    }

    private func upsert(
        text: String,
        startMillis: Int,
        endMillis: Int,
        isFinal: Bool,
        language: String,
        qualityGrade: TranscriptGrade?
    ) {
        // 同一个语言模型在同一时间点会反复吐 refine 后的结果，用 (起始时间, 语言) 去重
        let key = SegmentKey(startMillis: startMillis, language: language)

        if let existing = segmentIndex[key], existing < segments.count {
            let wasFinal = segments[existing].isFinal
            segments[existing].text = text
            segments[existing].endTimeMillis = endMillis
            segments[existing].isFinal = isFinal
            // 定稿的那一刻通知下游（事实核查），避免重复提交
            if isFinal && !wasFinal {
                segments[existing].qualityGrade = qualityGrade
                applyQuestionDetection(at: existing)
                onFinalSegment?(segments[existing])
            }
        } else {
            segmentIndex[key] = segments.count
            var created = TranscriptSegment(
                text: text,
                isFinal: isFinal,
                startTimeMillis: startMillis,
                endTimeMillis: endMillis,
                languages: [language]
            )
            if isFinal {
                created.qualityGrade = qualityGrade
            }
            segments.append(created)
            if isFinal {
                applyQuestionDetection(at: segments.count - 1)
                onFinalSegment?(segments[segments.count - 1])
            }
            // 流式结果几乎总是按时间顺序到达，追加本身不破坏有序性——
            // 这种时候全量 sort + 重建索引是纯浪费（一节课上千段就是 O(n²)）。
            // 只有真的来了「更早」的段（乱序）才付出这次代价。
            let count = segments.count
            let staysSorted = count < 2
                || segments[count - 2].startTimeMillis <= segments[count - 1].startTimeMillis
            if !staysSorted {
                segments.sort { $0.startTimeMillis < $1.startTimeMillis }
                // 排序后索引失效，重建
                segmentIndex = Dictionary(
                    uniqueKeysWithValues: segments.enumerated().compactMap { idx, seg in
                        guard let lang = seg.languages.first else { return nil }
                        return (SegmentKey(startMillis: seg.startTimeMillis, language: lang), idx)
                    }
                )
            }
        }
    }

    private func reportResultError(_ error: Error, language: String) {
        statusMessage = "⚠️ \(language) 转录中断: \(error.localizedDescription)"
    }

    /// 段落定稿时跑一次提问检测，命中则回写到 segment 上。
    ///
    /// 检测是纯规则的本地计算（微秒级），放在主 actor 上做没有问题；
    /// 放这里而不是视图里，是因为「这句是不是提问」是数据属性，不是呈现细节。
    private func applyQuestionDetection(at index: Int) {
        guard questionSensitivity != .off, segments.indices.contains(index) else { return }
        let detector = QuestionDetector(sensitivity: questionSensitivity)
        guard let hit = detector.detect(segments[index].text) else { return }
        segments[index].questionLevel = hit.level
        segments[index].coreQuestion = hit.coreQuestion
        onQuestion?(segments[index], hit)
    }

    // MARK: - 自定义词表

    /// 把 `contextualTerms` 注入 analyzer。
    ///
    /// 这个 App 一直有术语表，却从没告诉过识别器——等于每节课都让它从头猜
    /// 「gradient descent」是什么，猜错了再靠 LLM 事后校正。`AnalysisContext`
    /// 就是为这件事准备的：它抬高这些词被识别出来的先验。从源头少错一次，
    /// 比事后补救便宜得多，而且术语表是用户自己维护的，越用越准。
    ///
    /// 注入失败不阻断转录：词表只影响精度，不影响能不能用。
    private func applyContext(to analyzer: SpeechAnalyzer) async {
        guard !contextualTerms.isEmpty else {
            contextStatus = ""
            return
        }

        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualTerms

        do {
            try await analyzer.setContext(context)
            // 读回来核对，而不是「没抛错就算成功」：setContext 是跨 actor 的，
            // 中间隔着序列化，只有读回来的数才算数
            let applied = await analyzer.context.contextualStrings[.general]?.count ?? 0
            contextStatus = applied == contextualTerms.count
                ? "已注入 \(applied) 个术语"
                : "词表回读不符（送出 \(contextualTerms.count)，读到 \(applied)）"
        } catch {
            contextStatus = "术语注入失败（不影响转录）: \(error.localizedDescription)"
        }
    }

    // MARK: - 停止

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        micTap = nil
        // 关闭语音处理，把音频设备还给系统
        try? audioEngine?.inputNode.setVoiceProcessingEnabled(false)
        audioEngine?.stop()
        audioEngine = nil
        voiceProcessingActive = false

        // 必须等 tap 卸掉之后再收尾：否则最后一批缓冲还可能落进来，
        // 而文件头已经回填完了，那部分音频就落在文件长度之外，播放器会截断
        let recorder = self.recorder
        self.recorder = nil
        let recordedSeconds = Int(recorder?.durationSeconds ?? 0)
        recorder?.finish()
        if recordedSeconds <= 0 { recordingURL = nil }

        continuation?.finish()
        continuation = nil

        isRunning = false
        audioLevel = 0
        if !statusMessage.hasPrefix("❌") {
            statusMessage = "正在收尾…"
        }

        // 顺序很重要：必须先让 analyzer 定稿、等结果消费任务把最后几段吐出来，
        // 再取消它们。反过来写的话，定稿阶段才输出的内容会被整个丢掉
        // ——表现就是「录了半天，结果一段都没有」。
        let analyzer = self.analyzer
        let tasks = resultTasks
        self.analyzer = nil
        self.resultTasks.removeAll()
        transcribers.removeAll()

        Task { [weak self] in
            if let analyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            for task in tasks { task.cancel() }
            guard let self, !self.statusMessage.hasPrefix("❌") else { return }
            var message = "已停止 · 共 \(self.segments.count) 段"
            if let url = self.recordingURL {
                message += " · 已存档 \(url.lastPathComponent)"
            }
            self.statusMessage = message
        }
    }

    /// 等待 stop() 的收尾流程跑完（自检用；UI 不需要，状态自己会刷新）
    func waitUntilStopped() async {
        while statusMessage == "正在收尾…" {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func clear() {
        segments.removeAll()
        segmentIndex.removeAll()
        statusMessage = "就绪"
    }

    /// 用术语校正的结果回写转录文本。
    ///
    /// **只改 text，不动 id 和时间戳。** 核查结果是按 segmentID 关联的
    /// （见 FactCheckStore 的 index），换掉 id 会让已有的核查结果全部
    /// 变成孤儿——UI 上表现为核查列表突然清空。
    /// 按 id 匹配而不是按下标，是为了容忍校正期间又录进了新片段。
    func applyCorrections(_ corrected: [TranscriptSegment]) {
        let byID = Dictionary(
            corrected.map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )

        var changed = 0
        for index in segments.indices {
            guard let text = byID[segments[index].id], text != segments[index].text else { continue }
            segments[index].text = text
            // 校正后的文本和识别器的逐字符置信度对不上了（置信度标的是
            // 校正前那些字），但校正只修术语拼写，段落整体可信度仍由
            // 音频质量决定——保留原评分，不清空也不重算
            changed += 1
        }

        // segmentIndex 的键是 (起始时间, 语言)，只改文本不会让它失效，无需重建
        if changed > 0 {
            statusMessage = "已校正 \(changed) 段术语"
        }
    }

    // MARK: - 音频工具

    /// AVAudioConverter 是同步的、且不是线程安全的，转换在音频线程完成
    ///
    /// 输出缓冲**不复用、每次新分配**，这不是浪费：这块内存 yield 给
    /// SpeechAnalyzer 之后是被异步消费的，复用等于在 analyzer 还在读的时候
    /// 拿下一帧覆盖它——数据竞争，而且是「转录偶尔出乱码」这种没法归因的
    /// 故障。每帧一次的分配开销换确定性，值。
    private nonisolated static func convert(
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

    /// 诊断：验证「麦克风多声道 → analyzer 单声道」这一步会不会把内容吃掉。
    /// 用已知正弦信号，不依赖麦克风，结果可复现。
    nonisolated static func conversionProbe() -> [String] {
        var lines: [String] = []
        lines.append("源: Float32/48000Hz，目标: Int16/16000Hz（analyzer 实际要的格式）")
        lines.append("")

        for channels in [1, 2, 4] as [AVAudioChannelCount] {
            for sourceInterleaved in [false, true] {
                for targetInterleaved in [false, true] {
                    let label = "\(channels)ch/\(sourceInterleaved ? "交错" : "非交错")"
                        + " → 1ch/\(targetInterleaved ? "交错" : "非交错")"

                    guard let source = probeSource(channels: channels, interleaved: sourceInterleaved),
                          let target = AVAudioFormat(
                              commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                              channels: 1, interleaved: targetInterleaved
                          ) else {
                        lines.append("❌ \(label): 格式构建失败")
                        continue
                    }

                    guard let converter = AVAudioConverter(from: source, to: target) else {
                        lines.append("❌ \(label): 转换器建不出来")
                        continue
                    }

                    guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 48_000) else {
                        lines.append("❌ \(label): 缓冲区分配失败")
                        continue
                    }
                    fillWithTone(buffer)

                    guard let converted = convert(buffer, using: converter, to: target) else {
                        lines.append("❌ \(label): 转换返回 nil")
                        continue
                    }

                    let level = int16RMS(converted)
                    let verdict = level < 1 ? "⚠️ 输出静音，内容被吃掉" : "✅ 内容保留"
                    let frames = converted.frameLength
                    lines.append("\(label): \(frames) 帧, RMS \(String(format: "%.1f", level))/32767  \(verdict)")
                }
            }
        }

        lines.append("")
        lines.append("修复路径：4ch 先抽第 0 声道，再做 1ch → 1ch 转换")
        if let source = probeSource(channels: 4, interleaved: false),
           let mono = AVAudioFormat(
               commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
           ),
           let target = AVAudioFormat(
               commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
           ),
           let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 48_000),
           let converter = AVAudioConverter(from: mono, to: target) {
            fillWithTone(buffer)
            if let extracted = firstChannelAsMono(buffer, format: mono),
               let converted = convert(extracted, using: converter, to: target) {
                let level = int16RMS(converted)
                let verdict = level < 1 ? "⚠️ 仍然是静音" : "✅ 内容保留"
                let frames = converted.frameLength
                lines.append("4ch → 抽声道 → 1ch: \(frames) 帧, RMS \(String(format: "%.1f", level))/32767  \(verdict)")
            } else {
                lines.append("❌ 抽声道或转换失败")
            }
        } else {
            lines.append("❌ 无法构建修复路径所需的格式")
        }
        return lines
    }

    /// 诊断：把音频文件按**实时链路**的方式处理（抽第 0 声道 + 转换）后落盘。
    /// 用真实录到的多声道素材复现实时路径，不需要麦克风、不需要人说话。
    nonisolated static func convertFile(_ inputPath: String, to outputPath: String) -> [String] {
        var lines: [String] = []

        guard let inputFile = try? AVAudioFile(forReading: URL(fileURLWithPath: inputPath)) else {
            return ["❌ 打不开输入文件: \(inputPath)"]
        }
        let micFormat = inputFile.processingFormat
        lines.append("输入: \(describe(micFormat)) · \(inputFile.length) 帧")

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: micFormat.sampleRate,
            channels: 1, interleaved: false
        ), let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ), let converter = AVAudioConverter(from: monoFormat, to: target) else {
            return lines + ["❌ 无法构建格式或转换器"]
        }

        let chunk: AVAudioFrameCount = 4_096
        var readFrames = 0
        var writtenFrames = 0
        var silentBuffers = 0
        var peak: Double = 0
        var pcm = Data()

        while let buffer = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: chunk) {
            do {
                try inputFile.read(into: buffer, frameCount: chunk)
            } catch {
                lines.append("⚠️ 读取中断: \(error.localizedDescription)")
                break
            }
            guard buffer.frameLength > 0 else { break }
            readFrames += Int(buffer.frameLength)

            guard let extracted = firstChannelAsMono(buffer, format: monoFormat),
                  let converted = convert(extracted, using: converter, to: target) else {
                continue
            }
            writtenFrames += Int(converted.frameLength)
            let level = int16RMS(converted)
            if level == 0 { silentBuffers += 1 }
            peak = max(peak, level)

            // 不用 AVAudioFile 写：它的处理格式固定为 Float32，写 Int16 缓冲会断言崩溃
            if let channel = converted.int16ChannelData?[0] {
                let samples = Int(converted.frameLength) * (converted.format.isInterleaved
                    ? Int(converted.format.channelCount) : 1)
                pcm.append(Data(bytes: channel, count: samples * MemoryLayout<Int16>.size))
            }
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        writeWAV(pcm, sampleRate: 16_000, channels: 1, to: outputURL)

        lines.append("读出 \(readFrames) 帧 → 写出 \(writtenFrames) 帧")
        lines.append("静音缓冲 \(silentBuffers) 个 · 最大 RMS \(String(format: "%.1f", peak))/32767")
        lines.append("落盘: \(outputPath)")
        return lines
    }

    /// 手写 16-bit PCM WAV 头
    private nonisolated static func writeWAV(
        _ pcm: Data,
        sampleRate: UInt32,
        channels: UInt16,
        to url: URL
    ) {
        var data = Data()
        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF"); append32(UInt32(36 + pcm.count)); appendASCII("WAVE")
        appendASCII("fmt "); append32(16); append16(1); append16(channels)
        append32(sampleRate)
        append32(sampleRate * UInt32(channels) * 2)
        append16(channels * 2); append16(16)
        appendASCII("data"); append32(UInt32(pcm.count))
        data.append(pcm)

        try? data.write(to: url)
    }

    /// 抽第 0 声道成独立单声道缓冲。
    ///
    /// 存在的理由：AVAudioConverter 做多声道→单声道时会退化成全零静音
    /// （4ch Quadraphonic → 1ch，帧数正确、内容 RMS = 0.0）。自己抽声道绕开它。
    private nonisolated static func firstChannelAsMono(
        _ buffer: AVAudioPCMBuffer,
        format monoFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        var cache: AVAudioPCMBuffer?
        return firstChannelAsMono(buffer, format: monoFormat, reusing: &cache)
    }

    /// 带复用的版本：`cache` 容量够就直接写它，不为每帧回调各分配一块新缓冲。
    /// 容量不够（引擎改了回调块长）或格式变了才重建。调用方必须保证 cache
    /// 不被第二处同时读写——实时链路上只有音频线程会碰到它。
    private nonisolated static func firstChannelAsMono(
        _ buffer: AVAudioPCMBuffer,
        format monoFormat: AVAudioFormat,
        reusing cache: inout AVAudioPCMBuffer?
    ) -> AVAudioPCMBuffer? {
        if cache == nil || cache!.frameCapacity < buffer.frameLength
            || !cache!.format.isEqual(monoFormat) {
            cache = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)
        }
        guard let mono = cache,
              let destination = mono.floatChannelData?[0] else {
            return nil
        }
        mono.frameLength = buffer.frameLength

        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0 else { return mono }

        if let source = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let raw = source[0]
                for i in 0..<frames { destination[i] = raw[i * channels] }
            } else {
                let channel = source[0]
                for i in 0..<frames { destination[i] = channel[i] }
            }
            return mono
        }

        if let source = buffer.int16ChannelData {
            if buffer.format.isInterleaved {
                let raw = source[0]
                for i in 0..<frames { destination[i] = Float(raw[i * channels]) / 32_768 }
            } else {
                let channel = source[0]
                for i in 0..<frames { destination[i] = Float(channel[i]) / 32_768 }
            }
            return mono
        }

        return nil
    }

    /// 4 声道必须有 channel layout 才建得出来，设备给的格式自带布局
    private nonisolated static func probeSource(
        channels: AVAudioChannelCount,
        interleaved: Bool
    ) -> AVAudioFormat? {
        if channels == 4 {
            guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic) else {
                return nil
            }
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                interleaved: interleaved, channelLayout: layout
            )
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: channels, interleaved: interleaved
        )
    }

    /// 填一个 440Hz 正弦，幅值 0.5
    private nonisolated static func fillWithTone(_ buffer: AVAudioPCMBuffer) {
        buffer.frameLength = 48_000
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        for i in 0..<48_000 {
            let sample = Float(sin(2 * .pi * 440 * Double(i) / 48_000)) * 0.5
            for channel in 0..<channels {
                data[channel][i] = sample
            }
        }
    }

    private nonisolated static func int16RMS(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<Int(buffer.frameLength) {
            let v = Double(data[i])
            sum += v * v
        }
        return (sum / Double(buffer.frameLength)).squareRoot()
    }

    private nonisolated static func describe(_ format: AVAudioFormat) -> String {
        let layout = format.channelLayout.map { "布局tag=\($0.layoutTag)" } ?? "无布局"
        return "\(format.channelCount)ch/\(Int(format.sampleRate))Hz/\(format.commonFormat)"
            + "/\(format.isInterleaved ? "交错" : "非交错")/\(layout)"
    }

    /// 计算第 0 声道的 RMS（0…1 标度）。
    /// 必须同时处理 Float32 和 Int16：只看 floatChannelData 的话，
    /// Int16 缓冲会返回 nil，被误判成静音 —— 这个误判曾让我把正常链路当成故障。
    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        let channels = Int(buffer.format.channelCount)
        let isInterleaved = buffer.format.isInterleaved
        var sum = 0.0

        if let data = buffer.floatChannelData {
            let channel = data[0]
            for i in 0..<count {
                let v = Double(channel[isInterleaved ? i * channels : i])
                sum += v * v
            }
        } else if let data = buffer.int16ChannelData {
            let channel = data[0]
            for i in 0..<count {
                let v = Double(channel[isInterleaved ? i * channels : i]) / 32_768
                sum += v * v
            }
        } else {
            return 0
        }

        return Float(min(1, (sum / Double(count)).squareRoot() * 6))
    }
}
