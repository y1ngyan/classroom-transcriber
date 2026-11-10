import SwiftUI

struct TranscriptionView: View {
    @Environment(AppState.self) private var appState
    @State private var courseName = "未命名课程"
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportNotice = ""
    @State private var exportNoticeFailed = false
    @State private var attachmentImportError: String?

    private var engine: TranscriptionEngine { appState.transcription }

    /// 导出源：转录页用的是**内存里的段**（单条流，offset 恒 0）。
    /// 和详情页走同一个渲染器，出来的文件才长得一样
    private var exportSource: TranscriptExportSource {
        .live(segments: engine.segments, startedAt: Date(), title: "")
    }

    private var exportableSegmentCount: Int { exportSource.preparedSegments.count }

    /// 本次转录里被判为课堂提问的段落（含 L1 点名预警），按时间顺序
    private var questionSegments: [TranscriptSegment] {
        engine.segments.filter(\.isQuestion)
    }

    /// 质量自评的汇总计数。只数已定稿且评过分的段
    private var qualitySummary: (poor: Int, fair: Int) {
        var poor = 0, fair = 0
        for segment in engine.segments {
            switch segment.qualityGrade {
            case .poor: poor += 1
            case .fair: fair += 1
            default: break
            }
        }
        return (poor, fair)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            transcript
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $isExporting) {
            TranscriptExportSheet(source: exportSource)
        }
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // 44pt 工具栏（P14-4）：主操作收进右上角，底部那枚悬浮胶囊
            // 去掉。悬浮按钮在整屏文字上压着最后一段，而「开始录制」是
            // 页面级主操作，本来就该在页头
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Text("课堂转录")
                    .textStyle(Theme.Text.largeTitle)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: Theme.Spacing.md)

                ToolbarActionButton(
                    title: engine.isRunning ? "停止录制" : "开始录制",
                    systemImage: engine.isRunning ? "stop.fill" : "record.circle"
                ) {
                    toggleRecording()
                }
                .animation(.easeInOut(duration: 0.18), value: engine.isRunning)
            }
            .frame(height: Theme.RecordingLayout.toolbarHeight)

            HStack(spacing: Theme.Spacing.s6) {
                Text(currentDate)
                Text("·")
                Text(courseName)
                if engine.isRunning {
                    Text("·")
                    Text("转录中").foregroundStyle(Theme.accent)
                }
            }
            .textStyle(Theme.Text.meta)
            .foregroundStyle(Theme.textSupporting)

            // 采集读数收成一张细条卡片（一行 13pt 中点分隔）。
            // `statusMessage`（还没开始采集 / 正在聆听…）也挪进这一行：
            // 它和那些计数是同一类东西——「现在采集链走到哪了」
            CaptureDiagnostics()

            // 后端提示紧跟着采集读数：「这次会用哪个后端、为什么」这个问题
            // 是在按下开始录制的那一刻问的，放到别处等于让人先切走再回来
            backendIndicator

            // 次要操作退化成文字链接（P14-4）：工具条已经有一个主操作，
            // 这一行再放两枚胶囊按钮，整页就没有主次了
            HStack(spacing: Theme.Spacing.s20) {
                Button {
                    if let url = engine.recordingURL {
                        appState.upload.enqueue(fileURL: url)
                    }
                } label: {
                    Text("上传云端")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(canUpload ? Theme.accent : Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canUpload)
                .help(engine.recordingURL == nil
                    ? "录完一段后才有音频可上传"
                    : (appState.upload.isConfigured
                        ? "上传 \(engine.recordingURL?.lastPathComponent ?? "")"
                        : "COS 缺凭证：去「设置」填 cosSecretID + cosSecretKey（或填 cosSTSURL）"))

                Button {
                    isImporting = true
                } label: {
                    Text("添加图片")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(canAddImage ? Theme.accent : Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canAddImage)

                // 导出/复制/分享：和详情页同一套（同一份渲染器）。
                // 直播页的段还在内存里，没有落盘的会话——「录完之前就想把
                // 现有内容贴出去」是最常见的用法，不该逼用户先存完再切页
                Button { isExporting = true } label: {
                    Text("导出转录")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(exportableSegmentCount > 0 ? Theme.accent : Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(exportableSegmentCount == 0)
                .help(exportableSegmentCount == 0
                    ? "还没有转录内容"
                    : "导出为 SRT / VTT / Markdown / JSON")

                Button { copyTranscript() } label: {
                    Text("复制全文")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(exportableSegmentCount > 0 ? Theme.accent : Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(exportableSegmentCount == 0)

                if exportableSegmentCount > 0 {
                    ShareLink(item: exportSource.copyText()) {
                        Text("分享")
                            .textStyle(Theme.Text.meta)
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }

            if !exportNotice.isEmpty {
                Text(exportNotice)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(exportNoticeFailed ? Theme.error : Theme.textSecondary)
            }

            // 提问汇总入口：次要操作，退化成文字链接而不是按钮。
            // B 包起它不再弹一张只读列表，而是切到独立的「提问查答案」页
            // ——那里才有「查答案」这个动作（拍板第 2 条）
            if !questionSegments.isEmpty {
                Button {
                    appState.openQuestions(scope: .live)
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "questionmark.bubble")
                            .font(.system(size: Theme.Text.footnote.size))
                        Text("本节课提问 \(questionSegments.count) 条")
                            .textStyle(Theme.Text.meta)
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            // 质量汇总：整场转录可不可信，用户不该靠逐段翻标记去数。
            // 全 good 时不显示——没有可疑段才是常态，不该为它占一行
            let quality = qualitySummary
            if quality.poor > 0 || quality.fair > 0 {
                StatusMark(
                    kind: quality.poor > 0 ? .warning : .neutral,
                    text: quality.poor > 0
                        ? "本次转录 \(quality.poor) 段不可信、\(quality.fair) 段存疑（共 \(engine.segments.count) 段）"
                        : "本次转录 \(quality.fair) 段存疑（共 \(engine.segments.count) 段）"
                )
            }

            if !appState.upload.items.isEmpty {
                UploadQueuePanel()
                    .padding(.top, Theme.Spacing.sm)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                appState.attachments.add(
                    urls: urls,
                    atMillis: appState.attachments.currentTimestampMillis(from: engine.segments)
                )
            case .failure(let error):
                attachmentImportError = error.localizedDescription
            }
        }
        .alert(
            "添加图片失败",
            isPresented: Binding(
                get: { attachmentImportError != nil },
                set: { if !$0 { attachmentImportError = nil } }
            )
        ) {
            Button("好", role: .cancel) { attachmentImportError = nil }
        } message: {
            Text(attachmentImportError ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.RecordingLayout.pagePadding)
        .padding(.top, Theme.RecordingLayout.pagePadding)
        .padding(.bottom, Theme.Spacing.md)
    }

    private var canUpload: Bool {
        engine.recordingURL != nil && appState.upload.isConfigured
    }

    private var canAddImage: Bool {
        !engine.isRunning && !engine.segments.isEmpty
    }

    /// 复制全部文本。结果写回界面（复制成功与否是看不见的）
    private func copyTranscript() {
        let result = TranscriptExportAction.copyToPasteboard(exportSource)
        exportNotice = result.message
        exportNoticeFailed = result.failed
    }

    private func toggleRecording() {
        Task {
            if engine.isRunning {
                engine.stop()
            } else {
                await appState.startTranscription()
            }
        }
    }

    private var currentDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月 d 日 EEEE"
        return formatter.string(from: Date())
    }

    // MARK: - 转录列表

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // P15-3：卡片的间距不再由 LazyVStack 给，改由每一行自己的
                // 底部 padding 给（12，最后一行 0）——时间轴的竖线要贯穿
                // 行与行之间的空隙，`spacing` 是不画线的一段真空
                LazyVStack(alignment: .leading, spacing: 0) {
                    if engine.segments.isEmpty {
                        Text(engine.isRunning ? "正在聆听…" : "点击右上角「开始录制」")
                            .textStyle(Theme.Text.summary)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 120)
                    }

                    ForEach(Array(engine.segments.enumerated()), id: \.element.id) { index, segment in
                        let checkState = appState.factCheck.state(for: segment.id)
                        // 最后一段还没定稿 = 模型正在写它
                        let isActive = index == engine.segments.count - 1 && !segment.isFinal
                        TranscriptTimelineRow(
                            segment: segment,
                            status: TimelineNodeStatus.resolve(segment: segment,
                                                               checkState: checkState,
                                                               isActive: isActive),
                            isFirst: index == 0,
                            isLast: index == engine.segments.count - 1,
                            attachments: appState.attachments.attachments(for: segment),
                            checkState: checkState,
                            onRemoveAttachment: { appState.attachments.remove($0) },
                            // 手动核查无视全局 autoFactCheck 开关——那一条
                            // 管的是「自动跑不跑」，这里管的是「我现在想查
                            // 这一段」。定稿后才能查：未定稿的文字还在被
                            // 模型改写，拿去核查既浪费请求又会得到错结论
                            onCheck: { appState.factCheck.submit(segment: segment) }
                        )
                        .id(segment.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.RecordingLayout.pagePadding)
                .padding(.top, Theme.Spacing.sm)
                // P14-4：底部悬浮栏连同 `safeAreaInset` 一起去掉，
                // 列表末尾只留一级留白，不再为「压在上面的按钮」预留高度
                .padding(.bottom, Theme.Spacing.s32)
            }
            .onChange(of: engine.segments.count) {
                guard let last = engine.segments.last else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 「这一条录音走的是哪条链路」。
    ///
    /// 为什么要常驻一句话：两条链路的产出**在屏幕上长得一模一样**——都是
    /// 一段段文字。用户唯一能分辨它们的地方就是这个标签。没有它，一次
    /// 静默的后端切换（哪怕只是设想）会表现成「今天怎么突然不准了」，
    /// 而那是个查不出来的谜。
    ///
    /// 录音中读 `activeBackend`（这次真的走了哪条），不在录音中读设置
    /// （下次会走哪条）——这两件事在录音中途改设置时**会不一样**，
    /// 混成一个的话标签就在撒谎。
    @ViewBuilder
    private var backendIndicator: some View {
        if engine.isRunning, let active = engine.activeBackend {
            StatusMark(kind: .live, text: "本次录制：\(active.label)")
        } else {
            switch TranscriptionBackend.decide(backend: appState.settings.backend) {
            case .apple:
                StatusMark(kind: .neutral, text: "下次录制：\(TranscriptionBackend.apple.label)")
            case .whisper:
                StatusMark(kind: .neutral,
                           text: "下次录制：\(TranscriptionBackend.whisper.label) · 模型已就位")
            case .blocked(let reason):
                // 缺模型时**提前**把话说清楚：按下去才发现录不了，
                // 损失的是一整节课的信任
                StatusMark(kind: .error, text: reason)
            }
        }
    }
}
