import SwiftUI
import AppKit

/// 单条录音的详情：转录全文 + 对这条录音的操作。
///
/// 转录按「片段」分组展示——「接着录」会把多次录制拼进同一条会话，
/// 每个片段的 segments 存的是相对本片段 0 点的毫秒数，所以必须先按
/// 片段分段，再用 `RecordingSession.absoluteRange` 算成会话时间轴上的
/// 绝对时间。直接把所有 segments 拍平会丢掉这个边界。
struct RecordingDetailView: View {
    @Environment(AppState.self) private var appState
    let session: RecordingSession
    let onBack: () -> Void

    @State private var isRenaming = false
    @State private var isSettingCourse = false
    @State private var isConfirmingRetranscribe = false
    @State private var draftTitle = ""
    @State private var draftCourse = ""

    private var store: RecordingsStore { appState.recordings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            transcript
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $isRenaming) { renameSheet }
        .sheet(isPresented: $isSettingCourse) { courseSheet }
        .confirmationDialog(
            "重新转录这条录音？",
            isPresented: $isConfirmingRetranscribe,
            titleVisibility: .visible
        ) {
            Button("重新转录", role: .destructive) {
                for part in session.parts {
                    Task {
                        await store.retranscribe(sessionID: session.id, partID: part.id)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会用新的识别结果替换现有的 \(session.segmentCount) 段转录内容。这个过程不可撤销，耗时较长。")
        }
    }

    // MARK: - 改名 / 课程弹窗

    private var renameSheet: some View {
        EditSheet(
            title: "重命名",
            hint: "留空则恢复显示日期",
            placeholder: "这条录音叫什么",
            text: $draftTitle
        ) {
            store.rename(id: session.id, to: draftTitle)
            isRenaming = false
        } onCancel: { isRenaming = false }
        .onAppear { draftTitle = session.title }
    }

    private var courseSheet: some View {
        EditSheet(
            title: "设置课程",
            hint: "同课程的录音会归到一组；留空为未分类",
            placeholder: "课程名",
            text: $draftCourse,
            suggestions: store.knownCourses
        ) {
            store.setCourse(id: session.id, to: draftCourse)
            isSettingCourse = false
        } onCancel: { isSettingCourse = false }
        .onAppear { draftCourse = session.course }
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // 返回是文字链接而不是按钮——设计规范规定「一行只放一个
            // PillButton」，返回不该和下面的操作抢那个位置
            Button(action: onBack) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "chevron.left").font(.system(size: 11))
                    Text("录音列表").textStyle(Theme.Text.caption)
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(session.formattedDate)
                .textStyle(Theme.Text.largeTitle)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                Text(session.formattedDuration)
                    .monospacedDigit()
                Text("·")
                Text("\(session.segmentCount) 段转录")
                if session.parts.count > 1 {
                    Text("·")
                    Text("\(session.parts.count) 段录音")
                }
                if session.poorCount > 0 {
                    Text("·")
                    StatusMark(kind: .error, text: "\(session.poorCount) 段不可信")
                }
                if session.fairCount > 0 {
                    Text("·")
                    StatusMark(kind: .warning, text: "\(session.fairCount) 段存疑")
                }
            }
            .textStyle(Theme.Text.caption)
            .foregroundStyle(Theme.textSecondary)

            actionRow
                .padding(.top, Theme.Spacing.xs)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.md)
        .overlay(alignment: .bottom) { Separator() }
    }

    /// 操作行：一个 PillButton（主操作）+ 文字链接（次要操作）。
    /// 设计规范要求一行只放一个 PillButton，所以改名和课程退化成文字链接
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.lg) {
                PillButton(title: "在访达中显示", action: revealAudio)
                    .disabled(session.audioFileURL == nil)

                Button { isRenaming = true } label: {
                    Text("重命名").textStyle(Theme.Text.caption).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Button { isSettingCourse = true } label: {
                    Text("设置课程").textStyle(Theme.Text.caption).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                // 重转：覆盖式操作，先确认再跑
                Button { isConfirmingRetranscribe = true } label: {
                    Text("重新转录").textStyle(Theme.Text.caption)
                        .foregroundStyle(store.isRetranscribing ? Theme.textTertiary : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(store.isRetranscribing || session.parts.allSatisfy { $0.fileName == nil })

                Spacer()
            }

            // 重转进行中：一条几十分钟的录音要跑很久，不给状态用户会
            // 以为卡死了，进而去点别的地方把界面搞乱
            if store.isRetranscribing {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("\(store.retranscribeProgress)请勿关闭窗口")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if !session.course.isEmpty {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text(session.course).textStyle(Theme.Text.caption)
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - 转录正文

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                ForEach(Array(session.parts.enumerated()), id: \.element.id) { index, part in
                    partSection(index: index, part: part)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    private func partSection(index: Int, part: RecordingPart) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // 只有多片段会话才标片段头。单片段时那个头就是废话
            if session.parts.count > 1 {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("第 \(index + 1) 段录音")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(part.formattedTime) · \(part.formattedDuration)")
                        .textStyle(Theme.Text.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if part.segments.isEmpty {
                Text("这段录音没有转录内容")
                    .textStyle(Theme.Text.body)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: Theme.segmentSpacing) {
                    ForEach(part.segments) { segment in
                        // 复用转录页的展示组件：质量标记、提问标记、
                        // 语义切分、时间戳的样式全都一致。
                        // 时间戳传的是**会话时间轴**上的绝对位置——
                        // 多片段拼接时不能显示片段内的相对时间
                        TranscriptLine(
                            segment: segment.absoluteCopy(in: part),
                            attachments: []
                        )
                    }
                }
            }
        }
    }

    private func revealAudio() {
        guard let url = session.audioFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - 会话的显示格式

extension RecordingSession {
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: startedAt)
    }

    var formattedDuration: String {
        let total = max(0, durationMillis) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// 第一个片段的音频文件。多片段时只返回第一段——「在访达中显示」
    /// 定位到其中任意一段就够了，把整个目录打开反而更乱
    var audioFileURL: URL? {
        guard let name = parts.first?.fileName else { return nil }
        return RecordingStorage.directory.appendingPathComponent(name)
    }
}

extension RecordingPart {
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: startedAt)
    }

    var formattedDuration: String {
        let total = max(0, durationMillis) / 1000
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - 时间轴的绝对化

extension TranscriptSegment {
    /// 把片段内的相对时间换成会话时间轴上的绝对时间。
    ///
    /// 为什么需要：segments 存的是相对各自片段 0 点的毫秒数（这样
    /// 追加录音时不用改写历史数据）。但详情页是**跨片段连续**展示的，
    /// 用户看到的「第 3 段录音 12:30」必须是这条会话里的位置，
    /// 不是「这段录音开始后 30 秒」。换算只有 offsetMillis 这一处
    func absoluteCopy(in part: RecordingPart) -> TranscriptSegment {
        var copy = self
        copy.startTimeMillis = part.offsetMillis + startTimeMillis
        copy.endTimeMillis = part.offsetMillis + endTimeMillis
        return copy
    }
}
