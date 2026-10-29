import AppKit
import Foundation
import Observation

/// 全局状态。转录引擎和核查存储在这里汇总，
/// 转录段定稿后自动推给核查队列。
@MainActor
@Observable
final class AppState {
    let transcription: TranscriptionEngine
    let factCheck: FactCheckStore
    let notes = NotesStore()
    /// 课后学习笔记（6a）。和 `notes` 是两回事：那个是转录页那份
    /// 「核心知识点大纲」，活在内存里；这个是按会话落盘的课后产出
    let studyNotes = StudyNotesStore()
    let attachments = AttachmentStore()
    let glossary: GlossaryStore
    /// 用户自建的课程词库（联网生成后存下来的那些）。和 `glossary` 分开：
    /// 前者是「备着以后用的」，后者是「这节课要用的」
    let presets = CoursePresetStore()
    let punctuation = PunctuationStore()
    let upload = UploadStore()
    let recordings: RecordingsStore
    /// 说话人识别（C-3-2）。首跑就位、找 helper、落盘都在它里面；
    /// **它不自己写文件**，落盘走 `recordings.save`（`.atomic`，见那边的注释）
    let diarization: DiarizationStore
    /// 放在这里而不是设置页的 `@State` 里：切走标签页再回来，视图会被
    /// 重建，`@State` 跟着归零——用户填了一半的密钥就没了
    let settings = SettingsStore()

    /// 模型下载（P7-1）。和 `settings` 同样的理由放在这里：514MB 下到一半
    /// 切走设置页再回来，进度不该归零——那不只是显示问题，`@State` 一归零
    /// 那个 `Task` 就没人持有了，用户以为还在下，其实已经断了
    let modelDownload = ModelDownloadCenter()

    /// 当前标签页。放在 AppState 而不是 `RootView` 的 `@State`：
    /// 录音空状态里的「去转录页录制」要能从 RecordingsView 切走标签页，
    /// 而那个视图拿不到 RootView 的局部状态
    var selectedTab: RootView.Tab = .transcription

    /// - Parameter sessionsDirectory: 录音库（`sessions/`）落在哪。默认 nil =
    ///   用户真实那个目录，**行为一个字节没变**。存在的理由是 `--ui-snapshot`：
    ///   无头快照要拿固定夹具渲列表，而夹具绝不能写进用户真实的库
    /// - Parameter audioDirectory: `recordings/`（wav）落在哪，同上
    /// - Parameter transcription/factCheck/glossary: 预置好数据的 store。
    ///   默认值就是正常构造，**生产路径的取值一个字节没变**；存在的理由是
    ///   `--ui-snapshot` 要给转录/核查/术语表三屏喂固定假数据，而三个 store
    ///   的产出字段都是 `private(set)`，不给入口就只能拍空页
    init(sessionsDirectory: URL? = nil,
         audioDirectory: URL? = nil,
         transcription: TranscriptionEngine = TranscriptionEngine(),
         factCheck: FactCheckStore = FactCheckStore(),
         glossary: GlossaryStore = GlossaryStore()) {
        self.transcription = transcription
        self.factCheck = factCheck
        self.glossary = glossary
        // `recordings` 从「带默认值的存储属性」改成在 init 里建：说话人识别的
        // 落盘要用**这一个** store 实例（它带内存缓存和 index 同步），
        // 而默认值表达式里引用不到 `self`。两个 store 必须是指向同一份
        // sessions/ 的同一个对象——各自建一个的话，识别写完盘列表页也不刷新，
        // 而且两次 `loadIndex` 会互相覆盖
        //
        // audioDirectory 也要能指向夹具：`RecordingsStore.init` 里的
        // `refreshRecovery()` 会扫这个目录找「无会话的录音」，用真实目录的话
        // 快照会被用户库里的残留污染，而快照必须可复现
        let recordings = RecordingsStore(
            directory: sessionsDirectory,
            recordingsDirectory: audioDirectory ?? RecordingStorage.directory
        )
        self.recordings = recordings
        self.diarization = DiarizationStore(save: { recordings.save($0) })

        AppConfig.writeTemplateIfMissing()

        transcription.onFinalSegment = { [weak self] segment in
            // 自动核查是**用户开着的**才跑。默认关闭：核查要联网、要花检索和
            // LLM 额度，每段定稿都自动触发的话一节课几十次请求，用户未必
            // 想让 App 替他花这笔钱。关掉不是砍掉功能——核查页选中某段
            // 手动点「核查」照样走同一条链路。
            guard let self, self.settings.autoFactCheck else { return }
            self.factCheck.submit(segment: segment)
        }

        // 录音收尾完成后自动落盘。引擎用 SessionDraft 交接、拿会话 id
        // 回去——「接着录」的下一次 stop 才知道该追加到哪条会话
        transcription.onSessionComplete = { [weak self] draft in
            guard let self else { return UUID() }
            let session = self.recordings.ingest(draft)

            // 转录结束与录音落盘分开记：它们是两件事（一份音频可以转录失败
            // 但仍然存档，反过来也一样），判据要能分开数
            DiagnosticLog.info(.transcription, "转录结束", fields: [
                .init("sessionId", session.id),
                .init("本次段数", draft.segments.count),
                .init("累计段数", session.segmentCount),
                .init(seconds: "本次时长", Double(draft.durationMillis) / 1000),
            ])
            DiagnosticLog.info(.recording, "录音落盘", fields: [
                .init("sessionId", session.id),
                .init("片段", session.parts.count),
                .init(seconds: "累计时长", Double(session.durationMillis) / 1000),
            ])

            // 录完自动跑一次课后笔记（拍板 2c）。**只在这条会话还没有笔记时**
            // 才跑——判断在 `autoGenerateIfNeeded` 里，它同时把「已存在」
            // 「没配密钥」「已经在跑」三种情况挡掉了。
            //
            // 放在收尾路径上是因为这里正好是「这堂课结束了」这个事实唯一的
            // 落点。它内部起的是 Task，**不阻塞落盘**；失败也只记进 store，
            // 不弹窗、不打断——用户此刻多半已经合上电脑走了
            self.studyNotes.autoGenerateIfNeeded(
                session: session, glossary: self.glossary.entries
            )
            return session.id
        }

        // 录制途中的周期性草稿（P9-1）。引擎每 30 秒推一份，
        // 崩溃后它是唯一还记得「这堂课讲了什么」的东西
        transcription.onSessionDraft = { [weak self] draft in
            self?.recordings.saveDraft(draft)
        }

        // 收尾落盘成功 → 草稿多余了。**这一步不能省**：留着的话重启后
        // 列表里会冒出一条「未完成」，用户点恢复就得到重复的一份会话
        transcription.onDraftObsolete = { [weak self] id in
            self?.recordings.removeDraft(id: id, reason: "录制正常收尾，已落盘")
        }

        // Whisper 引擎在启动时就预热。
        //
        // 为什么在这里：引擎构造冷启动实测 17.03 秒（Metal kernel 编译），
        // 那笔钱绝不能落在「点开始录制」那一刻。放在启动时，用户翻设置、
        // 选课的这点时间里它就准备完了（缓存命中时 0.65 秒）。
        // **只在后端真的是 Whisper 时才预热**——默认是 Apple，那条路上
        // 一次 Metal 编译都不该发生，否则等于给所有人加一笔用不上的开销。
        //
        // **无头入口不预热**：那些入口自己在 `App.init` 里构造了引擎，这里再预热
        // 一份就是「同一个进程里两个 ggml context 并发初始化」——133（SIGTRAP）
        // 的根因。而 `AppState` 是 `App` 的 `@State` 属性、默认值先于 `init()` 体
        // 求值，所以这个判断**必须在预热这一侧**做，放在无头开关那一侧来不及
        // （详见 `HeadlessEntry`）。判据也在那边，一处就够
        if AppConfig.transcriptionBackend == .whisper, !HeadlessEntry.isActive {
            transcription.whisper.warmUp()
        }

        // 诊断日志（P6-1）：进程的开头和结尾各记一条。
        //
        // **无头入口不记**：那些入口是这个仓库一天跑几十次的东西，
        // 每次都往用户真实的 `logs/` 里塞一条「启动」，环形那 1 MB
        // 会被自检挤掉——真正要留的现场（昨晚那节课的失败）反而没了。
        // 判据和预热那边共用一条 `HeadlessEntry.isActive`，一处就够
        if !HeadlessEntry.isActive {
            DiagnosticLog.info(.app, "启动", fields: [
                .init("后端", AppConfig.transcriptionBackend.rawValue),
                .init("增益", AppConfig.micGain.rawValue),
                .init("日志目录", DiagnosticLog.directoryPath),
                // 采集设备（P0-1 ②）。**只读 CoreAudio 表**——不碰 AVAudioEngine、
                // 不开设备、不触发授权（`InputDeviceCatalog` 就是为这条约束写的）。
                //
                // 这一条说的是**进程起来时**系统默认是哪只；「这节录音是哪个麦」
                // 是每次开始录制另记的一行（`TranscriptionEngine.beginCaptureTracking`），
                // 两者可以不同，别拿这一条去归属某一节课
                .init("默认输入", Self.defaultInputSummary()),
            ])

            // 退出的写法是通知，不是 `deinit`：`AppState` 是 `App` 的
            // `@State` 属性，进程结束时**不保证被释放**——`deinit` 里写的
            // 日志多半根本不会执行，而那种失败是静默的（少一条日志，
            // 谁也不看得出来）。`willTerminateNotification` 是确定会到的
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                DiagnosticLog.info(.app, "退出")
            }
        }
    }

    /// 启动日志里那格「默认输入」。
    ///
    /// 读不到就给一句实话，**不编一个设备名**——那行日志的全部价值在于事后
    /// 能回答「当时到底是哪只麦」，写一只猜出来的比留空更糟
    private static func defaultInputSummary() -> String {
        let id = InputDeviceCatalog.defaultInputDeviceID()
        guard let info = InputDeviceCatalog.info(of: id) else { return "（读不到，ID \(id)）" }
        return "\(info.name) [\(info.uid) · \(info.channels)ch · \(Int(info.sampleRate))Hz]"
    }

    /// 开始转录。术语表在这里灌给识别器。
    ///
    /// 这个连线放在 AppState 而不是视图里：识别器该知道哪些词是数据层面的
    /// 约束，不是某一屏的呈现细节；将来从别处（菜单、快捷键、定时）起录，
    /// 也不该漏掉这一步。
    func startTranscription() async {
        transcription.contextualTerms = glossary.contextualTerms
        // 增益档在起录这一刻定下来：引擎按它建一个前级，整段录音用同一个。
        // 放在这里而不是让引擎直接读配置，是为了「起录时是什么档」这件事
        // 只有一个来源——设置页改了没保存、保存了没起录，都不会串
        transcription.micGain = settings.micGain
        transcription.questionSensitivity = settings.questionSensitivity
        // 后端同理在起录这一刻定下来。**中途换后端不生效**：换后端要重建
        // 整条采集链路（analyzer 或滑窗），两边的段语义也不同，中途换会让
        // 同一份转录里混着两条链路的输出。要换后端就停下再开始
        transcription.backend = settings.backend
        // 「起录那一刻定下来的那几个档」正是这个函数上面刚写的几行，
        // 所以它们就是这条日志该记的内容——出事之后要回答的是
        // 「当时用的是哪个后端、哪个增益档」，而不是「现在的设置页填的是什么」
        DiagnosticLog.info(.transcription, "转录开始", fields: [
            .init("后端", settings.backend.rawValue),
            .init("增益", settings.micGain.rawValue),
            .init("术语", glossary.contextualTerms.count),
        ])
        await transcription.requestPermissions()
        await transcription.start()
    }

    /// 核查卡片悬停预览用：取该段前后各一段原文。
    ///
    /// 浮窗如果只是把卡片内容原样再显示一遍就没有意义了——它应该给出
    /// 卡片上没有的东西。原句前后说了什么，正是判断这句结论可不可信
    /// 最需要的上下文。
    func context(around segmentID: UUID, radius: Int = 1) -> [TranscriptSegment] {
        let segments = transcription.segments
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return [] }
        let lower = max(0, index - radius)
        let upper = min(segments.count - 1, index + radius)
        return Array(segments[lower...upper])
    }
}
