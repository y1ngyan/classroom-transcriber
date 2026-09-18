import SwiftUI

/// 上传队列面板。
///
/// 只在队列非空时被父视图放进层级里，所以这里不做空态处理。
struct UploadQueuePanel: View {
    @Environment(AppState.self) private var appState
    private var store: UploadStore { appState.upload }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("云端上传")
                    .font(.system(size: Theme.Text.caption.size, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if store.activeCount > 0 {
                    Text("· \(store.activeCount) 个进行中")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                if store.items.contains(where: { $0.status.isTerminal }) {
                    Button("清除已完成") { store.removeCompleted() }
                        .buttonStyle(.plain)
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            // 无外框：行与行之间用发丝分隔线，队列本身就是一组同类项，
            // 再套个框只是多一层装饰
            VStack(spacing: 0) {
                Separator()
                ForEach(store.items) { item in
                    UploadRow(item: item)
                    Separator()
                }
            }

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(store.statusMessage.hasPrefix("❌")
                        ? Theme.error : Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 单条任务

private struct UploadRow: View {
    @Environment(AppState.self) private var appState
    let item: UploadItem

    private var store: UploadStore { appState.upload }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                    .frame(width: 14)

                Text(item.fileName)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(item.status.label)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(color)
            }

            progressBar

            HStack(spacing: Theme.Spacing.sm) {
                Text("\(Int(item.progress * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                Text("\(ByteCountFormatter.string(fromByteCount: item.uploadedBytes, countStyle: .file)) / \(item.formattedSize)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                Text(item.key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("COS 对象键：\(item.key)")

                Spacer()

                actions
            }

            if !item.message.isEmpty, item.status == .failed || item.status == .paused {
                StatusMark(
                    kind: item.status == .failed ? .error : .warning,
                    text: item.message
                )
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.separator)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geometry.size.width * item.progress))
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Theme.Spacing.md) {
            switch item.status {
            case .uploading:
                smallButton("暂停", prominent: true) { store.pause(item.id) }
                smallButton("取消") { store.cancel(item.id) }

            case .paused:
                smallButton("继续", prominent: true) { store.resume(item.id) }
                smallButton("取消") { store.cancel(item.id) }

            case .failed:
                smallButton("重试", prominent: true) { store.retry(item.id) }
                smallButton("移除") { store.cancel(item.id) }

            case .queued:
                smallButton("取消") { store.cancel(item.id) }

            case .completed:
                smallButton("移除") { store.cancel(item.id) }
            }
        }
    }

    /// 行内操作都用文字链，不套胶囊：一排三四个小胶囊按钮会把
    /// 「这一行到底是什么状态」淹没掉。取消类是灰色，推进类是强调色。
    private func smallButton(
        _ title: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .textStyle(Theme.Text.caption)
            .foregroundStyle(prominent ? Theme.accent : Theme.textSecondary)
    }

    private var icon: String {
        switch item.status {
        case .queued: return "clock"
        case .uploading: return "arrow.up.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .completed: return Theme.success
        case .failed: return Theme.error
        case .paused: return Theme.warning
        case .uploading: return Theme.accent
        case .queued: return Theme.textTertiary
        }
    }
}
