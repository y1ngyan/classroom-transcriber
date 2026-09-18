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

    func export() {
        guard hasNotes else { return }

        let panel = NSSavePanel()
        panel.title = "导出 Markdown 笔记"
        panel.nameFieldStringValue = exportFileName
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "导出失败: \(error.localizedDescription)"
        }
    }

    private var exportFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = generatedAt.map { formatter.string(from: $0) } ?? formatter.string(from: Date())
        return "课堂笔记-\(stamp).md"
    }
}
