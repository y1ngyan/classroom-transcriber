import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 导出转录的弹窗：选格式（+ Markdown 可选带不带时间戳）→ 保存面板落盘。
///
/// 为什么是弹窗而不是一行按钮直接导：格式是四选一，且 Markdown 还带一个开关，
/// 直接在页面上摊开会让详情页的操作行变成一张表单。弹窗里还能放**预览**
/// ——导出前先看一眼「导出来长什么样」，比选完再发现不对要省事得多。
///
/// 面板（`NSSavePanel`）只在这里弹，渲染/落盘全在 `TranscriptExporter`。
/// 那条分界和 `NotesExporter` / `NotesStore.export()` 是同一把尺子：
/// **能被无头自检的那半边不许有 AppKit**，否则「导出到底对不对」又只能靠肉眼看
struct TranscriptExportSheet: View {
    let source: TranscriptExportSource

    @Environment(\.dismiss) private var dismiss

    @State private var format: TranscriptExportFormat = .srt
    /// Markdown 的默认是**不带**时间戳：导成纯文本是为了贴进别处，
    /// 一串 `[00:00:08]` 只会让人手删。要时间轴就选 SRT/VTT
    @State private var includeTimestamps = false
    @State private var message = ""
    @State private var failed = false
    @State private var isSaving = false

    private var segmentCount: Int { source.preparedSegments.count }

    /// 不能导出时的那句原因。**禁用了就必须说清为什么**（同
    /// `DiarizationPanelState.runDisabledReason`）：灰着一颗按钮、一个字不说，
    /// 正是用户报过的「点了没反应」的形状
    private var disabledReason: String? {
        segmentCount == 0 ? "这条录音还没有转录内容，先录一段或把录音转出来" : nil
    }

    /// 前 1200 字符的预览。截断是为了让弹窗高度不随课程长度爆炸——
    /// 预览的作用是「确认格式对不对」，不是通读全文（通读请用导出的文件）
    private var preview: String {
        let text = (try? source.render(format, includeTimestamps: includeTimestamps)) ?? ""
        return text.count > 1_200 ? String(text.prefix(1_200)) + "\n…" : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("导出转录")
                .textStyle(Theme.Text.title)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: Theme.Spacing.s6) {
                Text("\(segmentCount) 段")
                Text("·")
                Text(source.defaultFileName(for: format))
            }
            .textStyle(Theme.Text.caption)
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()

            // 四选一用分段控件：选项少、互斥、要一眼看全
            Picker("格式", selection: $format) {
                ForEach(TranscriptExportFormat.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("包含时间戳", isOn: $includeTimestamps)
                .toggleStyle(.checkbox)
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textPrimary)
                // 只有 Markdown 需要这个开关（见 `supportsTimestampToggle`）
                .disabled(!format.supportsTimestampToggle)

            Text(format.supportsTimestampToggle
                ? "关掉之后是干净的分段正文，适合贴进笔记；打开则是逐句带 [时:分:秒] 的逐字稿"
                : "\(format.label) 的时间轴就是格式本身，不能去掉")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)

            // 预览：等宽字体，保留换行。`textSelection` 开着，方便只挑一段出来比对
            ScrollView {
                Text(preview.isEmpty ? "没有内容" : preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.sm)
            }
            .frame(height: 180)
            .background(Theme.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: Theme.Text.caption.size, design: .monospaced))
                    .foregroundStyle(failed ? Theme.error : Theme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            HStack(spacing: Theme.Spacing.lg) {
                // 只有主操作用 PillButton，取消退化成文字链接（设计规范）
                PillButton(
                    title: isSaving ? "保存中…" : "保存…",
                    style: .filled,
                    isLoading: isSaving,
                    isEnabled: disabledReason == nil,
                    disabledStyle: .neutral
                ) {
                    save()
                }

                Button { dismiss() } label: {
                    Text("取消")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if let reason = disabledReason {
                    Text(reason)
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSupporting)
                }
            }
        }
        .padding(Theme.pagePadding)
        .frame(width: 560)
        .background(Theme.background)
    }

    private func save() {
        // 先看能不能导。**这里不 return 到保存流程里去**：写成一个 if + return，
        // 读代码的人一眼能看到「不能导就到此为止」
        if let reason = disabledReason {
            failed = true
            message = reason
            return
        }
        runSave()
    }

    private func runSave() {
        let text: String
        do {
            text = try source.render(format, includeTimestamps: includeTimestamps)
        } catch {
            failed = true
            message = error.localizedDescription
            return
        }

        // 面板弹出前把 App 带到前台：App 不在最前时 `runModal()` 出来的保存面板
        // 可能落到别的窗口后面，用户看到的是「点了没反应」（同 `NotesStore.export`）
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.title = "导出转录（\(format.label)）"
        panel.nameFieldStringValue = source.defaultFileName(for: format)
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true

        // 用户取消不是失败，不报红
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isSaving = true
        defer { isSaving = false }
        do {
            try TranscriptExporter.write(text, to: url)
            failed = false
            message = "已导出到 \(url.path)"
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}

// MARK: - 剪贴板与分享

/// 复制/分享这两件事在详情页和转录页都要有，抽出来共用。
///
/// 复制走**渲染器**而不是「把段拼起来」：否则复制出去的和导出出去的
/// 会是两份不同的文本（少说话人、多时间戳），而用户以为它们是同一件事。
enum TranscriptExportAction {

    /// 复制全部文本（Markdown，不带时间戳）。返回给界面显示的一句话。
    ///
    /// **写回后再读一遍**：`setString` 返回 Bool 是真的，但 NSPasteboard 被
    /// 别的进程抢走时内容会变。读回来对不上就直说没复制成，不要报「已复制」
    static func copyToPasteboard(_ source: TranscriptExportSource) -> (message: String, failed: Bool) {
        let text = source.copyText()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("这条录音还没有转录内容，没有可复制的文本", true)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return ("复制失败：剪贴板写不进去", true)
        }
        let readBack = pasteboard.string(forType: .string) ?? ""
        guard readBack == text else {
            return ("复制未生效：剪贴板里读回来的内容对不上", true)
        }
        return ("已复制 \(source.preparedSegments.count) 段到剪贴板", false)
    }
}
