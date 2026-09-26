import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class NotesStore {

    private(set) var markdown = ""
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    private(set) var generatedAt: Date?
    private(set) var lastSegmentCount = 0

    var hasNotes: Bool { !markdown.isEmpty }

    /// 转录段发生变化后，笔记就过期了
    var isStale: Bool { hasNotes && lastSegmentCount != 0 }

    func generate(from segments: [TranscriptSegment]) async {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil

        do {
            markdown = try await NotesService.generate(from: segments)
            generatedAt = Date()
            lastSegmentCount = segments.count
        } catch {
            errorMessage = error.localizedDescription
        }

        isGenerating = false
    }

    func clear() {
        markdown = ""
        errorMessage = nil
        generatedAt = nil
        lastSegmentCount = 0
    }

    // MARK: - 导出

    /// 导出这一路自己的结果，**不并进上面那个 `errorMessage`**：
    /// 那个显示在页面顶部（生成笔记的旁边），而用户点导出时人是在页面底部、
    /// 眼睛在按钮上。把「导出失败」写到屏幕另一端，等于没说
    private(set) var exportMessage: String?
    private(set) var exportFailed = false

    /// 导出按钮现在为什么不能点。**`nil` = 能点**。
    ///
    /// 原来这里是 `guard hasNotes else { return }` 一句静默返回，配上按钮的
    /// `isEnabled: hasNotes`——没笔记时按钮灰着、点不动、**一个字都不说**。
    /// 用户 2026-09-24 报的「点导出没反应」就是这个形状：他以为按钮能点。
    /// 而且 `markdown` 只活在内存里（没有任何落盘路径），**重启 App 之后必然是空的**，
    /// 也就是「打开笔记页 → 导出按钮必然点不动」。
    /// 禁用可以，但必须说出为什么
    var exportDisabledReason: String? {
        if !hasNotes { return "先点上面的「生成笔记」，有笔记内容才能导出" }
        return nil
    }

    func export() {
        exportMessage = nil
        exportFailed = false

        // 界面上按钮已经禁用了，但 store 是公开 API，别的地方也能调——
        // 这一条守的是「调用方绕过界面直接调」，不是给按钮兜底
        guard hasNotes else {
            exportFailed = true
            exportMessage = NotesExportError.emptyNotes.errorDescription
            return
        }

        // 面板弹出前先把 App 带到前台。macOS 上 App 不是最前的时候，
        // `runModal()` 出来的保存面板可能落到别的窗口后面——用户看到的同样是
        // 「点了没反应」，和上面那条长得一模一样。
        // 全仓库只有这一处弹面板，没有别处可以对照，所以这条只能是防御性的
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.title = "导出 Markdown 笔记"
        panel.nameFieldStringValue = NotesExporter.defaultFileName(for: generatedAt ?? Date())
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        panel.canCreateDirectories = true

        // 用户取消不是失败，不报红——按了取消再被红字骂一句是更差的体验
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try NotesExporter.write(markdown, to: url)
            // 路径就在这句话里。**不要再存一个 exportedURL 字段**——存了就得有读者，
            // 没读者就是死字段，而它的注释还会骗下一个读代码的人以为界面读它
            exportMessage = "已导出到 \(url.path)"
        } catch {
            exportFailed = true
            exportMessage = error.localizedDescription
        }
    }
}
