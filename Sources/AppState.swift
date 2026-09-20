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
    let attachments = AttachmentStore()
    let glossary = GlossaryStore()
    let upload = UploadStore()
    /// 放在这里而不是设置页的 `@State` 里：切走标签页再回来，视图会被
    /// 重建，`@State` 跟着归零——用户填了一半的密钥就没了
    let settings = SettingsStore()

    init() {
        AppConfig.writeTemplateIfMissing()

        transcription.onFinalSegment = { [weak self] segment in
            self?.factCheck.submit(segment: segment)
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
