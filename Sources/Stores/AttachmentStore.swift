import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

/// 图片附件。选中的图片会**复制**到 App 自己的目录下——原 TS 版用
/// expo-file-system 的 copyAsync 也是这个思路，避免用户移动或删除
/// 原文件后附件失效。
@MainActor
@Observable
final class AttachmentStore {

    private(set) var attachments: [ImageAttachment] = []
    private(set) var errorMessage: String?

    /// 缩略图跟段落的匹配容差：段落起点在此范围内的图片算属于该段
    private let matchToleranceMillis = 20_000

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    func add(urls: [URL], atMillis: Int) {
        guard !urls.isEmpty else { return }
        errorMessage = nil

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            errorMessage = "无法创建附件目录: \(error.localizedDescription)"
            return
        }

        for source in urls {
            // 用户通过 open panel 选的文件，需要先取得访问权限
            let needsScope = source.startAccessingSecurityScopedResource()
            defer { if needsScope { source.stopAccessingSecurityScopedResource() } }

            let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
            let destination = directory
                .appendingPathComponent("img_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6)).\(ext)")

            do {
                try FileManager.default.copyItem(at: source, to: destination)
                attachments.append(
                    ImageAttachment(
                        url: destination,
                        originalName: source.lastPathComponent,
                        timestampMillis: atMillis
                    )
                )
            } catch {
                errorMessage = "复制 \(source.lastPathComponent) 失败: \(error.localizedDescription)"
            }
        }

        attachments.sort { $0.timestampMillis < $1.timestampMillis }
    }

    func remove(_ attachment: ImageAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        try? FileManager.default.removeItem(at: attachment.url)
    }

    func clear() {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.url)
        }
        attachments.removeAll()
    }

    /// 找出应该显示在某个转录段落旁边的图片
    func attachments(for segment: TranscriptSegment) -> [ImageAttachment] {
        attachments.filter { attachment in
            let delta = attachment.timestampMillis - segment.startTimeMillis
            return delta >= -matchToleranceMillis && delta < matchToleranceMillis
        }
    }

    /// 当前应该绑定的时间点：有转录就绑到最新一段，否则绑到 0
    func currentTimestampMillis(from segments: [TranscriptSegment]) -> Int {
        segments.last?.startTimeMillis ?? 0
    }
}
