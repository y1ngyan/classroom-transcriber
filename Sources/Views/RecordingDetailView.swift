import SwiftUI
import AppKit

/// 快照专用的交互态预览（P17）。
///
/// 离屏 `NSHostingView` 拍不到 hover / 点击 / 播放这类交互态（见 `UISnapshot`
/// 的说明），而「编辑中」「播放中」恰恰是 P17 要验的两个样子。这里把状态
/// 显式摆出来，生产代码永远传 nil——**不是为了给 App 加一个「预览模式」**，
/// 是让快照能拍到一个真实存在的状态，而不是另画一套假界面
struct TranscriptInteractionPreview: Equatable {
    var playingSegmentID: UUID?
    var editingSegmentID: UUID?
}

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
    /// 快照用；nil = 正常交互。见 `TranscriptInteractionPreview`
    var preview: TranscriptInteractionPreview? = nil

    @State private var isRenaming = false
    @State private var isSettingCourse = false
    @State private var isConfirmingRetranscribe = false
    @State private var isExporting = false
    /// 复制/导出的一句话结果。空 = 什么都不显示
    @State private var exportNotice = ""
    @State private var exportNoticeFailed = false
    @State private var draftTitle = ""
    @State private var draftCourse = ""

    // P17：行内改错 + 播放跟随
    @State private var editingSegmentID: UUID?
    @State private var draftText = ""
    /// 用户手动滚过列表就不再跟着播放位置滚——**别抢用户的滚动条**。
    /// 点句子 / 空格 / 方向键都会重新打开跟随（那是用户主动要定位）
    @State private var isFollowingPlayback = true
    @FocusState private var isTranscriptFocused: Bool
    @FocusState private var isEditorFocused: Bool

    /// 显式 init 只为了快照预览：编辑态要**在第一次布局前**就成立。
    /// `onAppear` 在离屏 `NSHostingView` 里不保证先于 `cacheDisplay` 跑，
    /// 靠它设状态会让编辑态在快照里时有时无
    init(session: RecordingSession,
         onBack: @escaping () -> Void,
         preview: TranscriptInteractionPreview? = nil) {
        self.session = session
        self.onBack = onBack
        self.preview = preview
        let editingText = preview?.editingSegmentID.flatMap { id in
            session.parts.flatMap(\.segments).first { $0.id == id }?.text
        } ?? ""
        _editingSegmentID = State(initialValue: preview?.editingSegmentID)
        _draftText = State(initialValue: editingText)
    }

    private var store: RecordingsStore { appState.recordings }
    private var player: TranscriptPlayer { appState.transcriptPlayer }

    /// 快照预览里「正在播放」这一档。生产路径看播放器真实状态
    private var isShowingPlayingState: Bool {
        if let preview { return preview.playingSegmentID != nil }
        return player.isPlaying
    }

    private var playbackHint: String {
        if isShowingPlayingState {
            return "空格 播放/暂停 · ←/→ 前后一句 · 双击改错"
        }
        return session.parts.contains { $0.fileName != nil }
            ? "点击句子跳转播放 · 空格 播放/暂停 · ←/→ 前后一句 · 双击改错"
            : "双击句子可以改错 · 这条录音没有存档音频"
    }

    /// 当前播放位置落在哪一句。按**会话时间轴**（绝对毫秒）找，和
    /// `TranscriptLine` 显示的时间戳同一套口径
    private var playingSegmentID: UUID? {
        if let preview { return preview.playingSegmentID }
        let millis = player.currentTimeMillis
        guard player.isPlaying || millis > 0 else { return nil }
        let ordered = orderedSegments
        return ordered.last { $0.startTimeMillis <= millis && millis < $0.endTimeMillis }?.id
            ?? ordered.last { $0.startTimeMillis <= millis }?.id
    }

    /// 跨片段的连续顺序。`parts` 之间本来就按时间排，这里再排一次
    /// 是因为「前后一句」的判据必须只有一处
    private var orderedSegments: [TranscriptSegment] {
        session.parts
            .flatMap { part in part.segments.map { $0.absoluteCopy(in: part) } }
            .sorted { $0.startTimeMillis < $1.startTimeMillis }
    }

    private var exportSource: TranscriptExportSource { .session(session) }

    /// 有没有可导出的段。**判据是规整后的段数**（空段、纯空白段不算），
    /// 和界面上的「N 段转录」不是同一个数——那里数的是原始段
    private var exportableSegmentCount: Int { exportSource.preparedSegments.count }

    /// 「本节课提问 N 条」里的 N。和 `SessionSummary.questionCount` 同一套
    /// 口径：回填过的会话数问题条目（去重后），旧会话回落到段落计数——
    /// 否则 B 包上线前录的课在这一行会显示 0，而转录里明明有提问
    private var questionEntryCount: Int {
        session.questionSchemaVersion >= LessonQuestionSchema.current
            ? session.questions.count
            : session.questionCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            transcript
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        // 键盘（P17）：空格播放/暂停，←/→ 前后一句。
        // 编辑时 TextField 会拿走焦点，这里三个 handler 再看一眼
        // `editingSegmentID`，回车打字不会被抢走
        .focusable()
        .focused($isTranscriptFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) { handleSpace() }
        .onKeyPress(.leftArrow) { jumpSegment(by: -1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { jumpSegment(by: 1) ? .handled : .ignored }
        // 音频装载放在 `.task` 而不是 init：`AVAudioPlayer` 只在真的要
        // 播的时候才建，进详情页不碰磁盘也不碰输出设备
        .task(id: session.id) {
            player.load(session: session, audioDirectory: store.audioDirectory)
        }
        .onAppear(perform: applyPreviewState)
        // 离开只暂停、不 stop：从详情页返回列表再点回来，位置还在。
        // 停止由「换会话」的 `load` 负责。
        // 顺带把「听到哪」落盘（断点续听）：下次打开这节课从这里接着放
        .onDisappear {
            player.pause()
            store.updatePlayedPosition(sessionID: session.id, millis: player.currentTimeMillis)
        }
        .sheet(isPresented: $isRenaming) { renameSheet }
        .sheet(isPresented: $isSettingCourse) { courseSheet }
        .sheet(isPresented: $isExporting) {
            TranscriptExportSheet(source: exportSource)
        }
        .confirmationDialog(
            "重新转录这条录音？",
            isPresented: $isConfirmingRetranscribe,
            titleVisibility: .visible
        ) {
            Button("重新转录", role: .destructive) {
                store.retranscribe(sessionID: session.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            // 三句话，各有各的用处（P11-1 目标 3、5）：
            //   · 第一句说清这是覆盖式操作、不可撤销；
            //   · 第二句是**派生数据的失效提醒**——说话人标签和课后笔记锚点
            //     都挂在段 id 上，重转把段整个换掉，那些东西就对不上了。
            //     按既有语义处理（`RecordingsStore.retranscribe` 不动这两样），
            //     所以这里只负责**在点下去之前说出来**；
            //   · 第三句是代价：large 只有 0.49× 实时，一节课要跑一节课的时间，
            //     不先说清楚，用户会以为它卡死了
            Text("会用新的识别结果替换现有的 \(session.segmentCount) 段转录内容。这个过程不可撤销。\n"
                 + "重转会让已生成的笔记和说话人标签失效，需要重跑。\n"
                 + store.retranscribeEstimate(for: session))
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

                // 撤销上一步人工改错（P17）。只在这一条会话刚被改过时出现：
                // 常驻一根灰着的「撤销」等于给每个用户一个永远点不亮的控件
                if store.lastSegmentEdit?.sessionID == session.id {
                    Button { store.undoLastSegmentEdit() } label: {
                        Text("撤销上次修改").textStyle(Theme.Text.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                // 重转：覆盖式操作，先确认再跑
                Button { isConfirmingRetranscribe = true } label: {
                    Text("重新转录").textStyle(Theme.Text.caption)
                        .foregroundStyle(store.isRetranscribing ? Theme.textTertiary : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(store.isRetranscribing || session.parts.allSatisfy { $0.fileName == nil })

                // 课后复习的主入口（B 包 §3.1）：切到独立的「提问查答案」页。
                // 数量为 0 时不显示——没有提问不是一种状态
                if questionEntryCount > 0 {
                    Button {
                        appState.openQuestions(scope: .session(session.id))
                    } label: {
                        Text("本节课提问 \(questionEntryCount) 条")
                            .textStyle(Theme.Text.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            // 导出/复制/分享单独一行。**不塞进上面那一行**：上面那排是
            // 「这条录音本身」（显示、改名、课程、重转），这一排是「把内容带出去」，
            // 两件事挤一起，七个文字链接排成一条，谁也扫不到
            exportRow

            // 重转进行中：一条几十分钟的录音要跑很久，不给状态用户会
            // 以为卡死了，进而去点别的地方把界面搞乱。
            // 「取消」是文字链接（一行只放一个 PillButton，上面那个位置
            // 是「在访达中显示」的）——它必须在这儿，因为这是唯一一个
            // 「跑错档了想停下」的时刻
            if store.isRetranscribing {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(store.retranscribeProgress)
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Button { store.cancelRetranscribe() } label: {
                        Text("取消").textStyle(Theme.Text.caption).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 上一次重转的结果 / 被打回来的理由。**这一条以前不存在**，
            // 于是「缺 large 模型」那种拦截就只写进了 statusMessage 而没有任何
            // 地方显示——用户看到的是「点了重转，什么都没发生」
            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.system(size: Theme.Text.caption.size, design: .monospaced))
                    .foregroundStyle(store.statusMessage.hasPrefix("❌")
                        ? Theme.error : Theme.textSecondary)
                    .textSelection(.enabled)
            }

            // 操作说明（P17）。这几件事没有可见按钮，不写出来用户不会知道；
            // 「正在播放」跟着它走，免得播放时屏幕上没有任何状态反馈
            HStack(spacing: Theme.Spacing.sm) {
                if isShowingPlayingState {
                    Text("正在播放")
                        .font(Theme.Text.caption.font.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                }
                Text(playbackHint)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
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

    /// 导出 / 复制全文 / 分享。三个都是「把内容带出去」，所以同一行。
    ///
    /// 分享用 `ShareLink` 而不是自绘菜单：它接的是系统的分享面板
    /// （隔空投送、备忘录、信息…），自己拼一份等于把系统能力实现得差一点。
    /// 传的是**复制用的那份 Markdown**（不带时间戳），与剪贴板一致——
    /// 「分享出去的」和「复制走的」该是同一份文本
    private var exportRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.lg) {
                Button { isExporting = true } label: {
                    Text("导出转录")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(exportableSegmentCount > 0 ? Theme.accent : Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(exportableSegmentCount == 0)
                .help(exportableSegmentCount == 0
                    ? "这条录音还没有转录内容"
                    : "导出为 SRT / VTT / Markdown / JSON")

                Button { copyTranscript() } label: {
                    Text("复制全文")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(exportableSegmentCount > 0 ? Theme.accent : Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(exportableSegmentCount == 0)
                .help("把分段正文复制到剪贴板（不带时间戳）")

                // 分享：没有内容时整颗不出现（灰着的分享按钮点了没反应，
                // 和「没有提问就不显示提问入口」是同一条规矩）
                if exportableSegmentCount > 0 {
                    ShareLink(item: exportSource.copyText()) {
                        Text("分享")
                            .textStyle(Theme.Text.caption)
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("用系统分享面板把转录发出去")
                }

                Spacer(minLength: 0)
            }

            // 结果必须落在界面上一句话：复制成功/失败是**看不见的**，
            // 不说就成了「点了一下，不知道有没有成」
            if !exportNotice.isEmpty {
                Text(exportNotice)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(exportNoticeFailed ? Theme.error : Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func copyTranscript() {
        let result = TranscriptExportAction.copyToPasteboard(exportSource)
        exportNotice = result.message
        exportNoticeFailed = result.failed
    }

    // MARK: - 转录正文
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                // 课后笔记在转录**上面**（拍板 6a）：用户进这条录音，
                // 先要的是「这堂课讲了什么」，全文往后翻才有用。
                // 与转录之间隔着 `Theme.Spacing.xxl`（80）——分组靠留白，
                // 不靠容器（设计规范：不要卡片/阴影/边框）
                StudyNotesPanelView(session: session)
                // 说话人识别面板紧跟着课后笔记。两个面板各是一个区块：
                // 各自的标题 + 一行动作，靠 `xxl` 留白和发丝线分组——
                // **不是把两个按钮并排塞进同一行**（派单书：「别叠成一堆」）。
                // 顺序是「先读产出、再做加工」：笔记是录完自动就有的，
                // 说话人标签要用户点了才有，所以它在下
                DiarizationPanelView(session: session)
                ForEach(Array(session.parts.enumerated()), id: \.element.id) { index, part in
                    partSection(index: index, part: part)
                }
            }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxl)
            }
            // 用户一上手滚，就交出跟随权（P17 派单：不要强制滚到打断
            // 手动浏览的位置）。只认 `.interacting`：程序自己触发的滚动
            // 是 `.animating`，不能把它当成用户操作，否则跟随只生效一次
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { isFollowingPlayback = false }
            }
            .onChange(of: playingSegmentID) { _, id in
                guard let id, isFollowingPlayback, editingSegmentID == nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
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

            // 这段转录是哪个模型产出的（P11-1 目标 4）。**没有就不显示**——
            // 不写「模型未知」那种占位：老存档本来就没这个字段，一句
            // 没有信息量的话只会把这一段挤高
            if let provenance = part.transcriptionProvenance {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "cpu").font(.system(size: 10))
                    Text("转录模型 \(provenance.summary)")
                        .textStyle(Theme.Text.caption)
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.textTertiary)
            }

            if part.segments.isEmpty {
                Text("这段录音没有转录内容")
                    .textStyle(Theme.Text.body)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: Theme.segmentSpacing) {
                    ForEach(part.segments) { segment in
                        if editingSegmentID == segment.id {
                            segmentEditor(segment: segment, part: part)
                                .id(segment.id)
                        } else {
                            // 复用转录页的展示组件：质量标记、提问标记、
                            // 语义切分、时间戳的样式全都一致。
                            // 时间戳传的是**会话时间轴**上的绝对位置——
                            // 多片段拼接时不能显示片段内的相对时间
                            TranscriptLine(
                                segment: segment.absoluteCopy(in: part),
                                attachments: [],
                                // 说话人字段在 `absoluteCopy` 里原样带过来
                                // （它是 `var copy = self`），所以这里直接用原段取
                                speakerLabel: SpeakerLabel.text(for: segment),
                                isPlaying: playingSegmentID == segment.id,
                                // 详情页关掉拖选：见 `allowsTextSelection`
                                allowsTextSelection: false
                            )
                            .id(segment.id)
                            .contentShape(Rectangle())
                            // 双击改错，单击跳播。`exclusively` 让双击优先：
                            // 两个独立的 onTapGesture(count:) 叠在一起时，
                            // 双击的第一下会先触发单击（于是用户每次想改错
                            // 都会先播放一遍）
                            .gesture(
                                TapGesture(count: 2)
                                    .onEnded { beginEditing(segment) }
                                    .exclusively(
                                        before: TapGesture(count: 1)
                                            .onEnded { play(segmentID: segment.id) }
                                    )
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 行内改错（P17）

    private func segmentEditor(segment: TranscriptSegment, part: RecordingPart) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s6) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(segment.absoluteCopy(in: part).formattedTimestamp)
                    .font(Theme.Text.meta.font.monospacedDigit())
                    .foregroundStyle(Theme.textSupporting)
                Text("编辑中 · 回车保存 · Esc 取消")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }

            // 单行 TextField 而不是 TextEditor：回车必须是「保存」，
            // 多行输入会把回车吃掉变成换行，用户就永远不知道该怎么提交。
            // 长句横向滚动，好在课堂转录单段很少长到放不下
            TextField("", text: $draftText)
                .textFieldStyle(.plain)
                .font(Theme.Text.summary.font)
                .foregroundStyle(Theme.textPrimary)
                .padding(Theme.Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Spacing.sm)
                        .fill(Theme.backgroundSecondary)
                }
                .overlay {
                    // 编辑框的描边是**功能**不是装饰：离屏快照里系统焦点环
                    // 和插入光标都可能画不出来，这根 1.5pt accent 边是
                    // 「正在编辑」唯一可靠的视觉信号
                    RoundedRectangle(cornerRadius: Theme.Spacing.sm)
                        .stroke(Theme.accent, lineWidth: 1.5)
                }
                .focused($isEditorFocused)
                .onSubmit(commitEdit)
                .onExitCommand(perform: cancelEdit)
        }
        .onAppear { isEditorFocused = true }
    }

    private func beginEditing(_ segment: TranscriptSegment) {
        // 改的时候不播：高亮每几秒跳一次，编辑框跟着晃，两个都在抢注意力
        player.pause()
        draftText = segment.text
        editingSegmentID = segment.id
        isTranscriptFocused = false
    }

    private func commitEdit() {
        guard let id = editingSegmentID, let part = part(containingSegment: id) else {
            cancelEdit()
            return
        }
        // 文本没变 / 被清空时 store 返回 false 并不落盘；界面上仍然退出编辑
        // ——「我看了看没改」不该把人卡在编辑框里
        store.updateSegmentText(
            sessionID: session.id, partID: part.id, segmentID: id, text: draftText
        )
        editingSegmentID = nil
        isEditorFocused = false
        isTranscriptFocused = true
    }

    private func cancelEdit() {
        editingSegmentID = nil
        draftText = ""
        isEditorFocused = false
        isTranscriptFocused = true
    }

    /// 找到段所在的片段：编辑和播放都要拿片段（一个取 partID，
    /// 一个取 `offsetMillis` 换算绝对时间）
    private func part(containingSegment id: UUID) -> RecordingPart? {
        session.parts.first { part in part.segments.contains { $0.id == id } }
    }

    // MARK: - 播放（P17）

    private func play(segmentID: UUID) {
        guard player.hasAudio,
              let part = part(containingSegment: segmentID),
              let segment = part.segments.first(where: { $0.id == segmentID })
        else { return }
        isFollowingPlayback = true
        isTranscriptFocused = true
        player.seek(
            toMillis: segment.absoluteCopy(in: part).startTimeMillis,
            play: true
        )
    }

    /// ←/→。返回是否处理——没有音频时把按键放回系统（否则方向键
    /// 会被吞掉，用户以为键盘坏了）
    private func jumpSegment(by offset: Int) -> Bool {
        guard editingSegmentID == nil, player.hasAudio else { return false }
        let ordered = orderedSegments
        guard !ordered.isEmpty else { return false }

        let currentIndex = ordered.lastIndex {
            $0.startTimeMillis <= player.currentTimeMillis
        }
        // 当前时间在第一句之前时，前后两个方向都从第一句起（夹取会处理）
        let targetIndex = (currentIndex ?? -1) + offset
        let target = ordered[min(max(targetIndex, 0), ordered.count - 1)]

        isFollowingPlayback = true
        isTranscriptFocused = true
        player.seek(toMillis: target.startTimeMillis, play: true)
        return true
    }

    private func handleSpace() -> KeyPress.Result {
        guard editingSegmentID == nil, player.hasAudio else { return .ignored }
        isFollowingPlayback = true
        isTranscriptFocused = true
        player.togglePlayPause()
        return .handled
    }

    /// 快照预览：编辑态已由 `init` 摆好，这里只负责让真实页面拿到键盘焦点
    private func applyPreviewState() {
        guard preview == nil else { return }
        isTranscriptFocused = true
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
