import Foundation
import Observation

/// 全局状态。转录引擎和核查存储在这里汇总，
/// 转录段定稿后自动推给核查队列。
@MainActor
@Observable
final class AppState {
    let transcription = TranscriptionEngine()
    let factCheck = FactCheckStore()
    let notes = NotesStore()
    /// 课后学习笔记（6a）。和 `notes` 是两回事：那个是转录页那份
    /// 「核心知识点大纲」，活在内存里；这个是按会话落盘的课后产出
    let studyNotes = StudyNotesStore()
    let attachments = AttachmentStore()
    let glossary = GlossaryStore()
    /// 用户自建的课程词库（联网生成后存下来的那些）。和 `glossary` 分开：
    /// 前者是「备着以后用的」，后者是「这节课要用的」
    let presets = CoursePresetStore()
    let punctuation = PunctuationStore()
    let upload = UploadStore()
    let recordings = RecordingsStore()
    /// 放在这里而不是设置页的 `@State` 里：切走标签页再回来，视图会被
    /// 重建，`@State` 跟着归零——用户填了一半的密钥就没了
    let settings = SettingsStore()

    init() {
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
