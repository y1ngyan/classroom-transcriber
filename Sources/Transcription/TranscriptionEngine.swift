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

    /// 录音收尾完成、定稿内容吐完之后回调一次，把本次新增的内容交出去落盘。
    ///
    /// 引擎不认识 RecordingsStore（Transcription 层不依赖 Stores 层），
    /// 由 AppState 把 store.ingest 接上来。返回值是会话 id，引擎记进
    /// `sessionID`——「接着录」的下一次 stop 才知道该追加到哪条会话
    var onSessionComplete: (@MainActor (SessionDraft) -> UUID?)?

    /// 本次录制属于哪条会话。nil = 新会话；「接着录」时由调用方（下轮的
    /// UI / AppState）塞入已有会话的 id，stop 落盘时就会追加而不是新建。
    /// 每次落盘后会被回调的返回值刷新
    var sessionID: UUID?

    /// 本次 start() 时 segments 已有的条数。stop 落盘只存
    /// `segments[sessionSegmentBase...]`——同一场 App 运行里录第二次时，
    /// 内存里的 segments 是累加的，上一次录的内容已经落过盘，不能重存
    private var sessionSegmentBase = 0
    /// 本次开录的墙上时间（片段的 startedAt）
    private var partStartedAt: Date?

    // MARK: - 录制草稿（P9-1）

    /// 录制**途中**周期性交出快照，由 AppState 接到 `RecordingsStore.saveDraft`。
    ///
    /// 为什么由引擎推、而不是 Store 自己定时读：引擎才是 segments 和存档文件名
    /// 的持有者，Store 手上没有「本次录制从哪一段开始」这个边界
    /// （`sessionSegmentBase`），自己算就会把上一次录的内容重复写进草稿
    var onSessionDraft: (@MainActor (RecordingDraft) -> Void)?

    /// 收尾落盘成功后回调一次，通知「这份草稿已经多余了」。
    ///
    /// 和 `onSessionDraft` 分开而不是合成一个带 flag 的回调：这两件事的
    /// **失败后果不同**——草稿写失败只是少了一份保险，而草稿没删掉会让
    /// 重启后列表里冒出一条「未完成」，用户点恢复就得到重复的一份
    var onDraftObsolete: (@MainActor (UUID) -> Void)?

    /// 本次录制的草稿键。start() 时生成，stop() 用完即弃
    private var draftID: UUID?
    private var draftTask: Task<Void, Never>?

    /// 草稿落盘间隔。
    ///
    /// 30 秒是**对着代价定的**，不是拍的：一份两小时课的草稿约 1600 段 /
    /// 416 KB，每 30 秒重写一次全文 = 一场课合计 **49 MB**（P9-2 实测，
    /// `tools/probes/longrun_session_io.py --minutes 120`；这条注释原先写的是
    /// 「不到 10 MB」，量出来差 5 倍——草稿是**全文重写**，总量按份数平方长，
    /// 不是最后一份乘以份数）。49 MB 对 SSD 仍然可以忽略，所以 30 秒这个间隔
    /// 不用改；但这个数得是真的，免得下次有人拿它当依据去调）。
    /// 崩溃最多丢 30 秒的转录文本。**音频不受这个间隔影响**——它已经
    /// 流式落盘、崩溃时最多丢 1 秒（见 `WAVRecorder.headerRefreshBytes`）。
    /// 更密只是多花 I/O 换一点文本，更疏则开始丢得让用户心疼
    private static let draftInterval = Duration.seconds(30)

    /// 课堂提问检测灵敏度。只在段落**定稿**的那一刻跑一次——
    /// 未定稿的文本还会被反复改写，对半成品跑规则只会得到一会有一会没的假信号。
    var questionSensitivity: QuestionSensitivity = .normal

    /// 要挂载的语言模型。
    ///
    /// 实测结论（同 `CLAUDE.md` 第 4 条）：中文课堂挂单个 `zh-CN` 最优——它会把英文术语
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

    /// 实时转录走哪条链路。**默认 Apple**——理由见 `TranscriptionBackend`。
    ///
    /// 由 `AppState.startTranscription` 在起录那一刻写入（和 `micGain` 同一个
    /// 理由：起录时是什么就是什么），录音中途改它不生效。
    var backend: TranscriptionBackend = .apple

    /// Whisper 模型引擎（预热 + 持有 + 专属推理队列）。
    ///
    /// 放在引擎上而不是 AppState 上：它是「这条录音链路的一个部件」，
    /// 而界面要能读到它的状态（设置页显示「已就绪 / 不可用」）。
    /// 只读访问：`appState.transcription.whisper.statusLine`。
    let whisper = WhisperRuntime()

    // MARK: - 内部状态

    private var analyzer: SpeechAnalyzer?
    private var transcribers: [SpeechTranscriber] = []
    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTasks: [Task<Void, Never>] = []
    private var segmentIndex: [SegmentKey: Int] = [:]
    private var micTap: MicTap?
    private var recorder: WAVRecorder?

    // MARK: - Whisper 链路的内部状态

    /// 这一段录音实际用的后端。`backend` 是「设置」，这个是「这次真的走了哪条」
    /// ——stop() 要按它决定怎么收尾，而用户在录音中途改设置不该改变已经开始的
    /// 这一段怎么收尾
    /// 界面要读它——「本次录制走的是哪条链路」这句话只有这里答得出来。
    /// 读的是**这次真的走了哪条**，不是设置里的那一个：录音中途改设置时
    /// 两者会不一样，而已经开始的这一段按前者收尾
    private(set) var activeBackend: TranscriptionBackend?

    /// 起录被拦住时的**完整**文案（多行：模型路径 / 期望大小 / 下载入口）。
    ///
    /// 为什么不让界面直接读 `statusMessage`：那一行是单行状态条，塞不下三件事，
    /// 而这三件事恰恰是用户照着就能自己解决的全部信息。所以状态条只放第一行
    /// 摘要，全文放这里。
    private(set) var blockedDetail: String?
    private var whisperPipeline: WhisperWindowPipeline?
    private var whisperLoopTask: Task<Void, Never>?
    /// 因为上一轮超步长而跳过的轮数。不丢音频（下一窗整段覆盖），但界面上
    /// 出句子的间隔会变长，所以要能报出来
    private var whisperSkippedRounds = 0
    /// 每轮的墙钟耗时（含等在队列后面的时间）。纯转写耗时在 pipeline 里
    private var whisperRoundSeconds: [Double] = []

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
        // 落盘用的会话边界:从这一刻起新进的段才算「本次录制」的
        sessionSegmentBase = segments.count
        partStartedAt = Date()
        // 后端二选一。Whisper 那条路**不走**下面这一整套：它不需要 locale、
        // 不需要装系统语言模型、也没有 SpeechAnalyzer 可建（模型是它自己的
        // 文件）。两条路共用的只有最底下的采集段（音频引擎、tap、存档、增益）
        //
        // 裁决在起采集**之前**做，而且只做一次（`decide` 是纯函数，不在这里
        // 再探一次磁盘——探测和裁决分家的话，两处会各自漂移）
        let decision = TranscriptionBackend.decide(backend: backend)

        switch decision {
        case .blocked(let reason):
            // **绝不静默退回 Apple**：用户把后端设成 Whisper 就是在等 Whisper
            // 的结果，悄悄换回系统识别会让「今天怎么突然不准了」变成一个查不
            // 出来的谜。宁可这里停下、把原因和下载入口一起摆在界面上
            statusMessage = decision.summary ?? "❌ Whisper 不可用"
            blockedDetail = reason
            activeBackend = nil
            return
        case .apple, .whisper:
            break
        }

        activeBackend = backend
        blockedDetail = nil
        startDraftLoop()

        if case .whisper = decision {
            await startWhisper()
            return
        }

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

        // 单声道源格式。那条「不能交给 AVAudioConverter 下混」的硬约束见
        // `monoFormat(matching:)`——两条链路共用同一份构造，不许各写一份
        guard let monoFormat = Self.monoFormat(matching: micFormat) else {
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
            output: .analyzer(continuation)
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

    // MARK: - 启动（Whisper 后端）

    /// Whisper 后端的启动路径。
    ///
    /// 和 Apple 那条完全分开，只有最底下的采集段共用。三处刻意不共用：
    /// ① 不建 SpeechAnalyzer、不解析 locale、不装系统语言模型——Whisper 用自己
    /// 的模型文件，走那一套只会在没装过语言模型的机器上白等一次下载；
    /// ② 不碰系统语音处理——那是本项目的禁区（`setVoiceProcessingEnabled` 会在
    /// 约 20 秒后毁掉音频，见 `useVoiceProcessing`），这条链路连开关都不碰；
    /// ③ 采样目标固定 16kHz 单声道，而不是问 analyzer 要什么格式。
    private func startWhisper() async {
        guard await whisper.engineForRecording() != nil else {
            // **绝不静默退回 Apple**：用户把后端设成 Whisper 就是在等 Whisper
            // 的结果，悄悄换回系统识别会让「今天怎么突然不准了」变成一个查不
            // 出来的谜。宁可这里停下、把原因摆在界面上
            //
            // 这是**第二道网**：`start()` 已经在起采集前用 `decide` 拦过一次
            // （模型不在位）。能走到这里说明文件在、但 `whisper_init` 仍然失败
            // ——损坏的文件、架构不对的库、内存不够都归这一档。同样是拦住，
            // 同样不换后端。
            statusMessage = "❌ \(whisper.statusLine ?? "Whisper 引擎不可用")"
            blockedDetail = "❌ Whisper 引擎起不来：\(whisper.statusLine ?? "未知原因")\n"
                + "   模型位置：\(WhisperEngine.resolvedModelURL.path)\n"
                + "   去下载：\(ModelRequirement.downloadEntryDescription)"
            activeBackend = nil
            return
        }

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        // 这一条链路上系统语音处理是关的（默认就是关，这里显式记一笔：
        // 「没打开」和「忘了关」在排查时长得一样）
        voiceProcessingActive = false

        let input = audioEngine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            statusMessage = "❌ 未找到可用麦克风输入"
            return
        }
        guard let monoFormat = Self.monoFormat(matching: micFormat) else {
            statusMessage = "❌ 无法构建单声道格式"
            return
        }
        guard let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: WhisperWindowPipeline.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            statusMessage = "❌ 无法构建 16kHz 单声道格式"
            return
        }

        formatDescription = "麦克风 \(Self.describe(micFormat)) → 抽第0声道 \(Self.describe(monoFormat))"
            + " → Whisper \(Self.describe(whisperFormat))"

        // 已经在界面上的段要交给管线：合并器的输入就是「已显示的段 + 本窗结果」。
        // 传进去的是一份拷贝，之后以管线吐回来的整份为准（见 adoptWhisperSegments）
        let pipeline = WhisperWindowPipeline(segments: segments)
        whisperPipeline = pipeline
        whisperSkippedRounds = 0
        whisperRoundSeconds.removeAll()

        guard startMicrophone(
            engine: audioEngine,
            micFormat: micFormat,
            monoFormat: monoFormat,
            convertingTo: whisperFormat,
            output: .window(pipeline)
        ) else { return }

        isRunning = true
        // 首句延迟要写在状态里：Whisper 是批处理模型，头十秒界面上一个字都不会有。
        // 不说清的话，那十秒看起来就是「按了没反应」。
        //
        // 「约 12 秒」不是「窗口 10 秒」——实测（2026-09-22，40 秒真实录音）：
        // 第一次取窗在 t=3s，但缓冲只有 3 秒，取到的是个 3 秒的**残窗**，
        // 起点恒为 0；接下来 t=6s、t=9s 两次取窗起点还是 0，被「同一窗不重转」
        // 的守卫挡掉（那两轮的墙钟 ≈0，这也是「轮次墙钟均 1.81 秒」低于
        // 「单次转写均 2.15 秒」的原因）。真正第一窗落在 t=12s：缓冲 12 秒、
        // 窗宽 10 秒、起点 2 秒。所以界面上**先出现的是残窗那句**，
        // 攒满一窗的稳定节奏要到 12 秒
        statusMessage = "转录中 · Whisper 本地 · 降噪关 · 增益 \(micGain.shortLabel)"
            + " · 首句约 12 秒后出现（先攒满 10 秒窗口）"
        whisperLoopTask = Task { [weak self] in
            await self?.runWhisperLoop(pipeline: pipeline)
        }
    }

    // MARK: - Whisper 滑窗驱动循环

    /// 等一个步长 → 取窗转写 → 合并 → 更新界面。
    ///
    /// 循环本身在主 actor 上（界面状态只由主 actor 写），但**转写不在主线程**：
    /// `whisper.run` 把它放到专属推理队列上，主 actor 在 await 期间是自由的
    /// （电平表、按钮、切页面都不受影响）。
    private func runWhisperLoop(pipeline: WhisperWindowPipeline) async {
        let step = Duration.milliseconds(WhisperWindowPipeline.stepMillis)
        var scheduled = ContinuousClock.now.advanced(by: step)

        while !Task.isCancelled {
            do {
                try await Task.sleep(until: scheduled, clock: .continuous)
            } catch {
                return   // 被取消
            }
            guard !Task.isCancelled else { return }

            let roundStarted = ContinuousClock.now
            do {
                if let update = try await advanceWhisper(pipeline) {
                    adoptWhisperSegments(update.segments)
                }
            } catch {
                // 单窗失败不停链路：下一窗还会覆盖同一段音频（滑窗的好处），
                // 但要说出来——连续失败时用户能看见原因（比如模型被移走了）
                statusMessage = "⚠️ Whisper 单窗转写失败: \(error.localizedDescription)"
            }
            let roundElapsed = ContinuousClock.now - roundStarted
            whisperRoundSeconds.append(
                Double(roundElapsed.components.seconds)
                    + Double(roundElapsed.components.attoseconds) / 1e18
            )

            scheduled = scheduled.advanced(by: step)
            // **超步长就跳过下一轮，不排队。**
            // 排队看着更「不丢内容」，但滑窗取的是「最近 10 秒」，补跑一个已经
            // 过期的窗口收益是零——那 10 秒会被下一窗完整覆盖。而代价是延迟随
            // 录音时长线性增长（一节课一小时就是几百轮积压，越排越久）。
            // 跳过之后下一窗直接从「现在」起算，延迟有界
            let now = ContinuousClock.now
            if scheduled < now {
                whisperSkippedRounds += 1
                scheduled = now.advanced(by: step)
            }
        }
    }

    /// 把一轮「取窗 + 转写 + 合并」放到推理队列上跑。nil = 这一轮没攒够/没有新音频
    private func advanceWhisper(
        _ pipeline: WhisperWindowPipeline
    ) async throws -> WhisperWindowPipeline.Update? {
        try await whisper.run { engine in try pipeline.advance(engine: engine) }
    }

    /// 把合并器吐出的整份段列表接进引擎状态，并把「这一轮刚定稿」的段推给下游。
    ///
    /// 为什么定稿之后那两个动作（提问检测、通知核查）在这里做而不是在合并器里：
    /// 合并器是纯函数，它只判 `isFinal`；而这两件事需要引擎的状态
    /// （`questionSensitivity`、回调）。Apple 那条链路也是在 `applyUpdate` 里判
    /// false→true 之后做这两件事的——两条链路共用同一个出口，下游才不会出现
    /// 「只有 Apple 段有提问标记」这种一半有一半没有的状态。
    private func adoptWhisperSegments(_ updated: [TranscriptSegment]) {
        let wasFinal = Dictionary(
            segments.map { ($0.id, $0.isFinal) },
            uniquingKeysWith: { first, _ in first }
        )
        segments = updated
        restoreOrderIfNeeded()
        // 合并器是按候选顺序追加的，吐回来的顺序不保证与索引一致，必须重建
        rebuildSegmentIndex()

        for index in segments.indices
        where segments[index].isFinal && wasFinal[segments[index].id] != true {
            applyQuestionDetection(at: index)
            onFinalSegment?(segments[index])
        }
    }

    /// Whisper 链路的实测占用率。自检与排障用，界面上不显示
    var whisperStats: String? {
        guard let pipeline = whisperPipeline else { return nil }
        var line = pipeline.statsLine
        if !whisperRoundSeconds.isEmpty {
            let mean = whisperRoundSeconds.reduce(0, +) / Double(whisperRoundSeconds.count)
            line += String(format: " · 轮次墙钟均 %.2f 秒", mean)
        }
        if whisperSkippedRounds > 0 {
            line += " · ⚠️ 超步长跳过 \(whisperSkippedRounds) 轮"
        }
        return line
    }

    // MARK: - 麦克风采集

    /// 麦克风格的「单声道版」源格式。
    ///
    /// 多声道 → 单声道**不能交给 AVAudioConverter**：实测 4ch(Quadraphonic) → 1ch
    /// 会返回帧数完全正确、内容全 0 的静音缓冲（RMS 恰好 0.0），不报任何错，
    /// 表现就是「整场转录一个字都没有」。正确做法是按这个格式先抽出第 0 声道
    /// （`firstChannelAsMono`），再做 1ch → 1ch 转换。
    ///
    /// 两条链路（Apple / Whisper）都从这里取这个格式：这种东西「看着多余、
    /// 去掉就静默坏掉」，只该有一份。
    private static func monoFormat(matching micFormat: AVAudioFormat) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: micFormat.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    private func startMicrophone(
        engine: AVAudioEngine,
        micFormat: AVAudioFormat,
        monoFormat: AVAudioFormat,
        convertingTo targetFormat: AVAudioFormat,
        output: MicTap.Output
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
            output: output,
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

        /// 麦克风缓冲的去处。**同一时刻只有一个消费者**（接线那一包的硬约束）。
        ///
        /// 为什么不能两边都喂：Apple 的 analyzer 和 Whisper 滑窗各自维护自己的
        /// 时间轴和「这段音频归我」的状态，同时消费会让同一段话在两条链路里
        /// 各出一份、彼此还看不见对方的进度；而且两边要的格式本来就不同
        /// （analyzer 的格式由它自己定，Whisper 固定 16kHz），一份转换结果
        /// 喂不了两边。所以这是个二选一的枚举，不是数组、不是回调列表。
        enum Output {
            case analyzer(AsyncStream<AnalyzerInput>.Continuation)
            case window(WhisperWindowPipeline)
        }

        private let sourceFormat: AVAudioFormat
        private let converter: AVAudioConverter
        private let targetFormat: AVAudioFormat
        private let output: Output
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
            output: Output,
            recorder: WAVRecorder?,
            preamp: AudioPreamp,
            onLevel: @escaping @Sendable (Float) -> Void
        ) {
            self.sourceFormat = sourceFormat
            self.converter = converter
            self.targetFormat = targetFormat
            self.output = output
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
            switch output {
            case .analyzer(let continuation):
                continuation.yield(AnalyzerInput(buffer: converted))
            case .window(let pipeline):
                // 16kHz 单声道直接取样本进攒帧缓冲，不在这里做任何筛选或精简：
                // 滑窗每步自己取「最近 10 秒」，这里塞进去的都会被它按窗口取走
                if let samples = WhisperEngine.samples(from: converted) {
                    pipeline.append(samples)
                }
            }
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

    /// 「文本相似但不算同一句」时要求的时间窗口。实测 Apple 在 progressive
    /// 模式下会修正中间结果的 start：小幅修正 3000ms（课堂-20260920-141224.wav），
    /// 极端情况 12000ms（课堂-20260920-151734.wav：孤儿停在 start=0，
    /// 定稿落在 12 秒后）。窗口取 4000：盖住常见的小幅修正再留一秒余量；
    /// 极端漂移不由窗口兜——那种形态文本完全相同，走 textRelation 的
    /// 「same」分支，不需要时间窗（见 tolerantMatch）
    private static let startToleranceMillis = 4_000

    /// 用一条新结果刷新已有段。定稿（false→true）的那一刻通知下游（事实核查），
    /// 避免重复提交——核查挂在这个回调上，不是挂在视图对 segments 的 diff 上
    private func applyUpdate(at index: Int, text: String, endMillis: Int, isFinal: Bool, qualityGrade: TranscriptGrade?) {
        let wasFinal = segments[index].isFinal
        segments[index].text = text
        segments[index].endTimeMillis = endMillis
        segments[index].isFinal = isFinal
        if isFinal && !wasFinal {
            segments[index].qualityGrade = qualityGrade
            applyQuestionDetection(at: index)
            onFinalSegment?(segments[index])
        }
    }

    /// 找「start 漂移了但其实是同一段」的已有段。
    ///
    /// 为什么存在：Apple 在 progressive 模式下先吐一个 start 偏早的中间结果，
    /// 定稿时才把 start 修正到真实位置。实测修正量 3000~12000ms——漂移量
    /// 取决于它多久才定稿，不是一个小修正，**任何固定时间窗都框不住**。
    /// 精确键认不出这是同一段，于是留下一条永远停在未定稿的孤儿段 +
    /// 一条内容相同的定稿段。
    ///
    /// 所以匹配按文本确定度分两档（外加一条硬限制：只合**未定稿**的段，
    /// 双定稿同文是老师真的重复了一遍，合掉就把真实内容吞了）：
    /// 1. 归一化后完全相同/互含、且短者 ≥6 字：两个不同话语撞出这么长的
    ///    相同文本概率极低（撞上了也是双定稿，已被硬限制挡住），这就是
    ///    start 被修正的孤儿——**不看时间窗**，多远都认
    /// 2. 只是相似（编辑距离 ≤20%，有个别字差异）：必须同时 start 落在
    ///    4000ms 窗口内。课堂上「好的我们看一下上一页/下一页」这种句式
    ///    重复是常态，放了时间窗就会把两句真话吞成一段
    private func tolerantMatch(startMillis: Int, language: String, text: String) -> Int? {
        // 全表扫（一节课段数百量级，代价可忽略），从后往前、先命中最近的
        // ——多条孤儿撞文本时，近的那条才是这次漂移的另一半
        for index in segments.indices.reversed() {
            let seg = segments[index]
            guard seg.languages.first == language, !seg.isFinal else { continue }
            switch Self.textRelation(seg.text, text) {
            case .same(let shorter):
                guard shorter >= 6 else { continue }
                return index
            case .similar:
                guard abs(seg.startTimeMillis - startMillis) <= Self.startToleranceMillis else { continue }
                return index
            case .different:
                continue
            }
        }
        return nil
    }

    /// 两条文本的相似关系。minLength 是归一化后较短那条的长度，
    /// 给「same 也要够长才作数」用——「好的」这种两三个字到处出现
    enum TextRelation {
        /// 归一化后完全相同，或一个包含另一个（中间结果还没说完）
        case same(shorterLength: Int)
        /// 编辑距离 ≤ 较长者的 20%：同一句的个别字差异
        case similar
        case different
    }

    /// 判两条文本的相似关系。
    ///
    /// 比较前剥掉空白和标点：定稿时识别器可能补标点（「管理管理」→「管理，管理」），
    /// 带标点比会把同一句判成两句。
    ///
    /// 20% 的阈值**不给下限兜底**：短句里一个字的分量很重，「第一点」和
    /// 「第二点」只差 1 字但占比 33%，必须判成 different——这正是
    /// 「光有时间容差会误合并」要防的
    nonisolated static func textRelation(_ a: String, _ b: String) -> TextRelation {
        let na = normalizedForMatch(a), nb = normalizedForMatch(b)
        if na.isEmpty || nb.isEmpty { return .different }
        if na == nb || na.contains(nb) || nb.contains(na) {
            return .same(shorterLength: min(na.count, nb.count))
        }
        let distance = levenshtein(Array(na), Array(nb))
        return distance * 5 <= max(na.count, nb.count) ? .similar : .different
    }

    /// 「可能是同一句」的宽判：same 或 similar 都算。只用于自检和
    /// --dedup-file 的残留重复扫描，不参与合并决策（合并要看档位）
    private static func textsMatch(_ a: String, _ b: String) -> Bool {
        switch textRelation(a, b) {
        case .same, .similar: return true
        case .different: return false
        }
    }

    nonisolated static let matchIgnoredChars: Set<Character> = [
        " ", "\n", "\t", "。", "，", "、", "；", "：", "！", "？", "…",
        ".", ",", ";", ":", "!", "?",
    ]

    nonisolated static func normalizedForMatch(_ text: String) -> String {
        String(text.filter { !matchIgnoredChars.contains($0) })
    }

    /// 编辑距离。只服务 textsMatch，输入已归一化、课堂段很少超过几百字，
    /// O(n·m) 完全够用，不值得上更聪明的算法
    nonisolated static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for (i, ca) in a.enumerated() {
            curr[0] = i + 1
            for (j, cb) in b.enumerated() {
                curr[j + 1] = ca == cb
                    ? prev[j]
                    : min(prev[j], prev[j + 1], curr[j]) + 1
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    /// segments 必须按 startTimeMillis 有序——展示、追加优化都依赖它。
    /// 流式结果几乎总是按时间到达，有序时这个检查只是一次空转；真乱序
    /// （start 漂移合并、更早的段迟到）才付出 sort + 重建索引的代价
    /// （一节课上千段，全量重建是 O(n²)，不能每次做）
    private func restoreOrderIfNeeded() {
        let staysSorted = zip(segments, segments.dropFirst()).allSatisfy {
            $0.startTimeMillis <= $1.startTimeMillis
        }
        guard !staysSorted else { return }
        segments.sort { $0.startTimeMillis < $1.startTimeMillis }
        // 排序后索引失效，重建
        rebuildSegmentIndex()
    }

    /// 按 (起始时间, 语言) 重建去重索引。
    ///
    /// 用 `uniquingKeysWith` 而不是 `uniqueKeysWithValues`：后者撞上重复键会
    /// 直接 trap，而进程崩掉这一次录音就整段没了。Apple 那条链路上键不会重复
    /// （upsert 先按同一个键去重），但 Whisper 是整窗重识别、且合并器会把候选
    /// 直接追加进列表——同一个起始时间戳出现两段并非不可能。为一种「不该发生、
    /// 但真发生后果极大」的情况留条不崩的路，比事后解释为什么崩了便宜
    private func rebuildSegmentIndex() {
        segmentIndex = Dictionary(
            segments.enumerated().compactMap { idx, seg in
                guard let lang = seg.languages.first else { return nil }
                return (SegmentKey(startMillis: seg.startTimeMillis, language: lang), idx)
            },
            uniquingKeysWith: { first, _ in first }
        )
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
            applyUpdate(at: existing, text: text, endMillis: endMillis, isFinal: isFinal, qualityGrade: qualityGrade)
        } else if let near = tolerantMatch(startMillis: startMillis, language: language, text: text) {
            // start 漂移合并的字段取舍（想清楚了再改）：
            // · id 沿用旧段——核查结果、笔记引用、术语校正回写都按 segment id
            //   关联（见 applyCorrections），换 id 会让已有的下游数据变孤儿
            // · text / start / end 用新值——定稿是修正后的结果，更准
            // · timestamp 保留旧值——这段第一次出现的墙上时间不变
            // · qualityGrade / 提问标记：旧段是未定稿的孤儿，这两个字段只在
            //   定稿时写入，旧段上必然还是空的，走 applyUpdate 的定稿转换
            //   逻辑正常写入即可，不需要特殊处理
            let oldKey = SegmentKey(startMillis: segments[near].startTimeMillis, language: language)
            segments[near].startTimeMillis = startMillis
            applyUpdate(at: near, text: text, endMillis: endMillis, isFinal: isFinal, qualityGrade: qualityGrade)
            segmentIndex.removeValue(forKey: oldKey)
            segmentIndex[key] = near
            // start 改大可能打乱有序性
            restoreOrderIfNeeded()
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
            restoreOrderIfNeeded()
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

    // MARK: - 自检

    /// `--dedup-selftest`：容差去重的规则回归。纯内存驱动 upsert，
    /// 不需要麦克风和模型。
    ///
    /// 核心用例来自真实录音（课堂-20260920-141224.wav）：start=0 未定稿
    /// + start=3000 已定稿、文本完全相同——旧逻辑建出两段，新逻辑必须
    /// 合并成一段
    static func dedupSelfTest() -> [String] {
        var lines: [String] = ["重复段去重自检（纯内存驱动 upsert）"]
        var allPassed = true
        let lang = "zh-CN"

        func dump(_ engine: TranscriptionEngine) {
            for seg in engine.segments {
                lines.append(String(
                    format: "     start=%6d  %@  %@",
                    seg.startTimeMillis, seg.isFinal ? "定稿" : "中间", seg.text
                ))
            }
        }

        /// steps 依次喂给 upsert；verify 返回 nil 表示通过，否则返回失败理由
        func check(
            _ name: String,
            _ reason: String,
            _ steps: [(text: String, start: Int, end: Int, final: Bool)],
            verify: (TranscriptionEngine) -> String?
        ) {
            let engine = TranscriptionEngine()
            for step in steps {
                engine.upsert(
                    text: step.text, startMillis: step.start, endMillis: step.end,
                    isFinal: step.final, language: lang,
                    qualityGrade: step.final ? .good : nil
                )
            }
            if let problem = verify(engine) {
                allPassed = false
                lines.append("  ❌ \(name)：\(problem)")
            } else {
                lines.append("  ✅ \(name)：\(reason)")
            }
            dump(engine)
        }

        // 1. 核心用例（真实录音的形态）：start 漂移 3000ms、文本相同 →
        //    合并成一段，留下定稿的内容和时间，id 沿用旧段
        do {
            let engine = TranscriptionEngine()
            let text = "现在学校的管理管理育人的方方面面"
            engine.upsert(text: text, startMillis: 0, endMillis: 3500, isFinal: false, language: lang, qualityGrade: nil)
            let originalID = engine.segments[0].id
            engine.upsert(text: text, startMillis: 3000, endMillis: 6000, isFinal: true, language: lang, qualityGrade: .good)

            var problems: [String] = []
            if engine.segments.count != 1 {
                problems.append("段数 \(engine.segments.count) ≠ 1（孤儿段没合掉）")
            }
            if let seg = engine.segments.first {
                if !seg.isFinal { problems.append("留下的还是未定稿段") }
                if seg.startTimeMillis != 3000 || seg.endTimeMillis != 6000 {
                    problems.append("时间没用定稿的修正值")
                }
                if seg.id != originalID { problems.append("id 变了，下游引用会成孤儿") }
                if seg.qualityGrade != .good { problems.append("定稿时质量自评没写入") }
            }
            if problems.isEmpty {
                lines.append("  ✅ 真重复（start 漂移 3000ms、文本相同）：合并为一段，定稿优先，id 不变")
            } else {
                allPassed = false
                lines.append("  ❌ 真重复（start 漂移 3000ms、文本相同）：\(problems.joined(separator: "；"))")
            }
            dump(engine)
        }

        // 2. 真重复：start 只差 5ms、新文本是旧文本的延展（中间结果还没说完）
        check(
            "真重复（start 差 5ms、前缀关系）",
            "前缀视为同一句的续说，合并",
            [
                ("现在学校的管理", 1000, 2000, false),
                ("现在学校的管理管理育人的方方面面", 1005, 4000, true),
            ]
        ) { engine in
            guard engine.segments.count == 1 else { return "段数 \(engine.segments.count) ≠ 1" }
            guard engine.segments[0].text == "现在学校的管理管理育人的方方面面" else { return "文本没用新值" }
            return engine.segments[0].isFinal ? nil : "没转成定稿"
        }

        // 3. 假重复：start 差 400ms 但文本明显不同。短句差 1 字占比 33%，
        //    超过 20% 阈值——文本闸门必须拦住，时间再近也不许合
        check(
            "假重复（start 差 400ms、文本不同）",
            "文本闸门拦住，不合并",
            [
                ("第一点。", 0, 1500, false),
                ("第二点。", 400, 1900, true),
            ]
        ) { engine in
            engine.segments.count == 2 ? nil : "段数 \(engine.segments.count) ≠ 2（真话被吞了）"
        }

        // 4. 正常刷新：start 完全相同、文本变长 → 原地更新，不新建
        check(
            "正常刷新（start 相同、文本变长）",
            "精确键命中，原地更新",
            [
                ("今天我们讲", 5000, 6000, false),
                ("今天我们讲梯度下降", 5000, 7000, false),
            ]
        ) { engine in
            guard engine.segments.count == 1 else { return "段数 \(engine.segments.count) ≠ 1" }
            guard engine.segments[0].text == "今天我们讲梯度下降" else { return "文本没更新" }
            return engine.segments[0].isFinal ? "被误标定稿" : nil
        }

        // 5. 老师真的重复了一遍（强调）：两条都定稿、文本相同、start 在窗口内。
        //    孤儿段永远是未定稿的，所以只合未定稿——双定稿必须保留两条
        check(
            "真实重复（双定稿同文，强调）",
            "只合未定稿段，真实内容保留",
            [
                ("这个概念很重要。", 0, 2000, true),
                ("这个概念很重要。", 3000, 5000, true),
            ]
        ) { engine in
            engine.segments.count == 2 ? nil : "段数 \(engine.segments.count) ≠ 2（强调的重复被吞了）"
        }

        // 6. 大漂移（课堂-20260920-151734.wav 的形态）：孤儿停在 start=0，
        //    定稿落在 12 秒后、文本完全相同。任何固定时间窗都框不住它——
        //    完全相同且够长，放时间窗也要认
        check(
            "真重复（start 漂移 12000ms、文本相同）",
            "完全相同且 ≥6 字，不看时间窗，合并",
            [
                ("是有点别这草地加土那可显出了个物边和发亮", 0, 9000, false),
                ("是有点别这草地加土那可显出了个物边和发亮", 12000, 21000, true),
            ]
        ) { engine in
            guard engine.segments.count == 1 else { return "段数 \(engine.segments.count) ≠ 1（大漂移孤儿没合掉）" }
            return engine.segments[0].isFinal ? nil : "没转成定稿"
        }

        // 7. 句式重复：只是相似（上/下一个字，10% 差异）且 start 差 20 秒。
        //    放了时间窗就把「上一页/下一页」两句真话吞成一句
        check(
            "假重复（相似但超窗，句式重复）",
            "相似但没到相同，时间窗拦住，不合并",
            [
                ("好的我们看一下上一页", 0, 3000, false),
                ("好的我们看一下下一页", 20000, 23000, true),
            ]
        ) { engine in
            engine.segments.count == 2 ? nil : "段数 \(engine.segments.count) ≠ 2（句式重复被吞了）"
        }

        // 8. 短文本相同：「好的」这种两三个字到处出现，same 也要 ≥6 字才作数
        check(
            "假重复（短文本互含，不足 6 字）",
            "短文本撞车太常见，不合并",
            [
                ("好的", 0, 800, false),
                ("好的我们开始吧", 30000, 32000, true),
            ]
        ) { engine in
            engine.segments.count == 2 ? nil : "段数 \(engine.segments.count) ≠ 2（短文本被误合）"
        }

        lines.append(allPassed ? "全部通过 ✅" : "存在失败用例 ❌")
        return lines
    }

    /// `--dedup-file <wav>` 的实现：用实时同款预设（timeIndexedProgressive）
    /// 转文件，结果逐条喂给引擎的 upsert，同时用旧的「精确 start 键」逻辑
    /// 离线重放一遍作对照，最后报「旧逻辑段数 → 新逻辑段数」。
    ///
    /// --transcribe-file 走的是「只打印定稿结果」的路，不过 upsert，
    /// 复现不了重复段 bug；这个入口跑的是和线上一模一样的去重逻辑
    static func dedupFileRun(path: String) async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ 文件不存在: \(path)")
            return
        }

        do {
            let supported = await SpeechTranscriber.supportedLocales
            guard let locale = FileTranscription.resolve(["zh-CN"], against: supported).first else {
                print("❌ 没有可用的 zh-CN 模型")
                return
            }
            var preset = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription
            preset.attributeOptions.insert(.transcriptionConfidence)
            let transcriber = SpeechTranscriber(locale: locale, preset: preset)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                print("⬇️  正在下载语言模型…")
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                print("❌ 无法确定音频格式")
                return
            }
            try await analyzer.prepareToAnalyze(in: format)

            let engine = TranscriptionEngine()
            // Task 闭包是 @Sendable 的，直接抓 var 会被 Swift 6 警告;
            //  rows 只从这一个闭包访问,用盒子做显式承诺
            final class RowBox: @unchecked Sendable {
                var rows: [(start: Int, end: Int, final: Bool, text: String)] = []
            }
            let box = RowBox()

            let consumer = Task { @MainActor in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let startMillis = Int(result.range.start.seconds * 1000)
                        let endMillis = Int((result.range.start + result.range.duration).seconds * 1000)
                        box.rows.append((startMillis, endMillis, result.isFinal, text))
                        // 和 consumeResults 完全同款的喂法
                        let quality = TranscriptQualityAssessor.grade(
                            confidences: TranscriptQualityAssessor.confidences(from: result.text)
                        )
                        engine.upsert(
                            text: text, startMillis: startMillis, endMillis: endMillis,
                            isFinal: result.isFinal, language: locale.identifier,
                            qualityGrade: quality
                        )
                    }
                } catch {
                    print("⚠️ 结果流中断: \(error.localizedDescription)")
                }
            }

            let file = try AVAudioFile(forReading: url)
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            _ = await consumer.value

            // 旧逻辑（精确 start 键）离线重放，作改前对照
            var oldIndex: [Int: Int] = [:]
            var oldSegments: [(start: Int, final: Bool, text: String)] = []
            for row in box.rows {
                if let i = oldIndex[row.start] {
                    oldSegments[i] = (row.start, row.final, row.text)
                } else {
                    oldIndex[row.start] = oldSegments.count
                    oldSegments.append((row.start, row.final, row.text))
                }
            }

            print("📁 \(url.lastPathComponent)")
            print("结果总数 \(box.rows.count) → 旧逻辑（精确键）\(oldSegments.count) 段 / 新逻辑（容差+文本闸门）\(engine.segments.count) 段")
            print("\n─── 新逻辑建段 ───")
            for (i, seg) in engine.segments.enumerated() {
                print(String(
                    format: "  %2d. start=%6d  %@  %@",
                    i + 1, seg.startTimeMillis, seg.isFinal ? "定稿" : "中间",
                    String(seg.text.prefix(30))
                ))
            }
            // 收尾校验:新逻辑的结果里不该再有「相邻且文本撞车」的段
            var remaining = 0
            for pair in zip(engine.segments, engine.segments.dropFirst()) {
                if textsMatch(pair.0.text, pair.1.text) {
                    remaining += 1
                    print("  ⚠️ 仍有疑似重复: start=\(pair.0.startTimeMillis) / \(pair.1.startTimeMillis)")
                }
            }
            print(remaining == 0 ? "\n✅ 无残留重复" : "\n❌ 残留 \(remaining) 处疑似重复")
        } catch {
            print("❌ \(error.localizedDescription)")
        }
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
        // 先停草稿循环再卸 tap：反过来的话，一条已经排队的草稿推送可能在
        // 收尾落盘**之后**才落地，把一份过期的转录覆盖回去
        stopDraftLoop()
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

        // Whisper 链路的收尾和 Apple 那条同构，只是「定稿」换成了「补最后一窗
        // + 强制定稿」：
        //   取消循环 → **等它把正在跑的那一轮跑完** → 补最后一窗 → 定稿 → 落盘
        // 中间那一步不能省：whisper_full 一次两秒，循环里那一轮可能正跑到一半，
        // 而它跑完会返回一份「旧的」段列表（不含收尾那一窗的结果）。
        // 抢先收尾再让它回来覆盖，收尾那一窗就白转（等价于 Apple 那条
        // 「先定稿再取消」的坑：晚到的结果把已经定稿的内容改回去）
        if activeBackend == .whisper {
            let pipeline = whisperPipeline
            let loopTask = whisperLoopTask
            whisperLoopTask = nil
            activeBackend = nil
            Task { [weak self] in
                loopTask?.cancel()
                await loopTask?.value
                if let pipeline {
                    await self?.finishWhisper(pipeline)
                }
                await self?.completeSession(recordedSeconds: recordedSeconds)
            }
            return
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
            guard let self else { return }
            await self.completeSession(recordedSeconds: recordedSeconds)
        }
    }

    /// 收尾那一窗 + 强制定稿，然后把结果接进界面状态。
    private func finishWhisper(_ pipeline: WhisperWindowPipeline) async {
        do {
            let update = try await whisper.run { engine in try pipeline.finish(engine: engine) }
            adoptWhisperSegments(update.segments)
        } catch {
            // 收尾那一窗的音频救不回来是一回事，已经认出来的段落停在「未定稿」
            // 是另一回事：未定稿的段拿不到质量档位、不会送核查，而用户已经
            // 没法再录一遍来补上它们了。所以照样定稿，但把失败说出来
            statusMessage = "❌ Whisper 收尾转写失败：\(error.localizedDescription)（已按已有结果定稿）"
            adoptWhisperSegments(pipeline.finalizeWithoutTranscribing().segments)
        }
    }

    /// 录音收尾的公共后半段：会话落盘 + 状态文案。
    ///
    /// 两条链路都走这一份。落盘判据（有没有新段、有没有录音文件）只该有一处，
    /// 不然迟早出现「Apple 录的课能「接着录」、Whisper 录的不能」这种差别
    /// ——而那种差别从界面上看不出来，只会表现为「我上次录的呢」。
    private func completeSession(recordedSeconds: Int) async {
        // 会话落盘必须在这个位置:analyzer 定稿完 / 滑窗收尾完、最后
        // 几段已经落地之后——再早存下来的就是不完整的转录(顺序约束同上的注释)
        if let onSessionComplete {
            let base = min(sessionSegmentBase, segments.count)
            let newSegments = Array(segments[base...])
            // 没有新段也没有录音文件,这次录制什么都没留下,不落盘
            if !newSegments.isEmpty || recordingURL != nil {
                let draft = SessionDraft(
                    sessionID: sessionID,
                    recordingFileName: recordingURL?.lastPathComponent,
                    startedAt: partStartedAt ?? Date(),
                    // 存档时长为准;没开存档时用最后一段的结束时间兜底,
                    // 不然「接着录」的偏移会算出 0,两段的时间轴叠在一起
                    durationMillis: max(
                        recordedSeconds * 1000,
                        newSegments.map(\.endTimeMillis).max() ?? 0
                    ),
                    segments: newSegments
                )
                sessionID = onSessionComplete(draft) ?? sessionID
            }
        }

        // 落盘走完了，这次录制的草稿就没有意义了。**放在落盘之后**：
        // 万一 `ingest` 抛错/进程恰好在这一刻被杀，「草稿被删了、会话也没写成」
        // 是最坏的一种结局——保险要在主路径确认成功之后才烧掉
        if let draftID {
            onDraftObsolete?(draftID)
            self.draftID = nil
        }

        guard !statusMessage.hasPrefix("❌") else { return }
        var message = "已停止 · 共 \(segments.count) 段"
        if let url = recordingURL {
            message += " · 已存档 \(url.lastPathComponent)"
        }
        statusMessage = message
    }

    // MARK: - 录制草稿

    /// 起一条定时任务，定期把「这次录制到此为止」交出去落成草稿。
    ///
    /// **第一次推在 30 秒之后，不是立刻**：此刻 `recordingURL` 还没建出来
    /// （要等 `startMicrophone` 里 `makeRecorder`），立刻推的那一份会声称
    /// 「本次没有音频文件」——崩溃后用户就会看到一条「未完成（无音频）」
    /// **外加**一条「无会话的录音」，同一段录音被拆成两条报出来。
    /// 前 30 秒空窗里崩溃的话，音频由「无会话的录音」那条路兜住，不会漏
    private func startDraftLoop() {
        draftTask?.cancel()
        draftID = UUID()
        draftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.draftInterval)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                guard let snapshot = self.currentDraft() else { continue }
                self.onSessionDraft?(snapshot)
            }
        }
    }

    private func stopDraftLoop() {
        draftTask?.cancel()
        draftTask = nil
    }

    /// 把「本次录制到此为止」打成一份草稿。
    ///
    /// **段落的取法与 `completeSession` 逐字相同**（`segments[sessionSegmentBase...]`、
    /// 时长取「存档秒数 与 最后一段结束时间」的较大者）——不这么写，
    /// 恢复出来的会话会和正常录完的会话在边界上差一段：要么把上一次录的
    /// 内容重复算进来，要么把最后几秒丢掉
    private func currentDraft() -> RecordingDraft? {
        guard let draftID, let startedAt = partStartedAt else { return nil }
        let base = min(sessionSegmentBase, segments.count)
        let newSegments = Array(segments[base...])
        let recordedSeconds = Int(recorder?.durationSeconds ?? 0)
        return RecordingDraft(
            id: draftID,
            targetSessionID: sessionID,
            recordingFileName: recordingURL?.lastPathComponent,
            startedAt: startedAt,
            durationMillis: max(recordedSeconds * 1000, newSegments.map(\.endTimeMillis).max() ?? 0),
            segments: newSegments,
            savedAt: Date()
        )
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
        // Whisper 那段的状态跟着一起清：上一次录音的滑窗缓冲和统计留着，
        // 下一次录音的 statsLine 会把两次的数字混在一起报
        whisperPipeline = nil
        whisperSkippedRounds = 0
        whisperRoundSeconds.removeAll()
        // 清空 = 新的一课:会话归属一起断掉,否则下一段转录会
        // 追加进已经翻篇的会话里
        sessionID = nil
        sessionSegmentBase = 0
        partStartedAt = nil
        // 草稿一起断掉：`clear()` 的语义是「这一课翻篇了」，
        // 留着一个指向上一次的草稿键，下一次录制会把它当成自己的草稿覆盖掉
        stopDraftLoop()
        draftID = nil
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

        // 按「还剩多少」读，不按固定块长读。
        // `AVAudioFile.read(into:frameCount:)` 在 frameCount 超过剩余帧数时
        // 会抛错而不是安静地短读，固定块长会让文件末尾不足一块的那部分
        // 直接丢失——同 TranscriptionEngine 的 feedWithPreprocess，
        // 那一处实测丢过 13 秒
        let totalFrames = inputFile.length
        var consumed: AVAudioFramePosition = 0

        while consumed < totalFrames,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: micFormat,
                  frameCapacity: AVAudioFrameCount(min(AVAudioFramePosition(chunk), totalFrames - consumed))
              ) {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), totalFrames - consumed))
            do {
                try inputFile.read(into: buffer, frameCount: want)
            } catch {
                lines.append("⚠️ 读取中断（已读 \(consumed)/\(totalFrames) 帧）: \(error.localizedDescription)")
                break
            }
            guard buffer.frameLength > 0 else { break }
            readFrames += Int(buffer.frameLength)
            consumed += AVAudioFramePosition(buffer.frameLength)

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
