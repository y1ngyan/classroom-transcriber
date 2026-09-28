import SwiftUI

struct TranscriptionView: View {
    @Environment(AppState.self) private var appState
    @State private var courseName = "未命名课程"
    @State private var isImporting = false
    @State private var attachmentImportError: String?
    @State private var isShowingQuestions = false

    private var engine: TranscriptionEngine { appState.transcription }

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
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                header
                transcript
            }

            // 底部悬浮胶囊按钮
            recordButton
                .padding(.bottom, Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("课堂转录")
                .textStyle(Theme.Text.largeTitle)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                Text(currentDate)
                Text("·")
                Text(courseName)
                if engine.isRunning {
                    Text("·")
                    Text("转录中").foregroundStyle(Theme.accent)
                }
            }
            .textStyle(Theme.Text.caption)
            .foregroundStyle(Theme.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Text(engine.statusMessage)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)

                Spacer()

                PillButton(
                    title: "上传云端",
                    systemImage: "icloud.and.arrow.up",
                    style: .quiet,
                    isEnabled: engine.recordingURL != nil && appState.upload.isConfigured
                ) {
                    if let url = engine.recordingURL {
                        appState.upload.enqueue(fileURL: url)
                    }
                }
                .help(engine.recordingURL == nil
                    ? "录完一段后才有音频可上传"
                    : (appState.upload.isConfigured
                        ? "上传 \(engine.recordingURL?.lastPathComponent ?? "")"
                        : "COS 缺凭证：去「设置」填 cosSecretID + cosSecretKey（或填 cosSTSURL）"))

                PillButton(
                    title: "添加图片",
                    systemImage: "photo.badge.plus",
                    style: .quiet,
                    isEnabled: !engine.isRunning && !engine.segments.isEmpty
                ) {
                    isImporting = true
                }
            }
            .padding(.top, Theme.Spacing.xs)

            // 区块之间用 80 的留白拉开，而不是加个卡片框（设计规范要求）
            CaptureDiagnostics()
                .padding(.top, Theme.Spacing.md)

            // 提问汇总入口：次要操作，按设计规范退化成文字链接而不是按钮
            if !questionSegments.isEmpty {
                Button {
                    isShowingQuestions = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "questionmark.bubble")
                            .font(.system(size: 11))
                        Text("本节课提问 \(questionSegments.count) 条")
                            .textStyle(Theme.Text.caption)
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Spacing.sm)
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
                .padding(.top, Theme.Spacing.sm)
            }

            if !appState.upload.items.isEmpty {
                UploadQueuePanel()
                    .padding(.top, Theme.Spacing.lg)
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
        .sheet(isPresented: $isShowingQuestions) {
            QuestionListView(questions: questionSegments)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
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
                LazyVStack(alignment: .leading, spacing: Theme.segmentSpacing) {
                    if engine.segments.isEmpty {
                        Text(engine.isRunning ? "正在聆听…" : "点击下方按钮开始录制")
                            .textStyle(Theme.Text.body)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 120)
                    }

                    ForEach(engine.segments) { segment in
                        TranscriptLine(
                            segment: segment,
                            attachments: appState.attachments.attachments(for: segment),
                            onRemoveAttachment: { appState.attachments.remove($0) },
                            checkState: appState.factCheck.state(for: segment.id),
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
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, Theme.Spacing.sm)
                // 给悬浮按钮留出空间，避免遮住最后一段
                .padding(.bottom, 120)
            }
            .onChange(of: engine.segments.count) {
                guard let last = engine.segments.last else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - 录制按钮

    /// 设计规范要求不使用阴影。这个按钮原本靠阴影从滚动的文字上"浮"起来，
    /// 去掉之后改用实心填充 + 留白来拉开层次——它下面那 120pt 的留白
    /// 就是干这个的。
    private var recordButton: some View {
        PillButton(
            title: engine.isRunning ? "停止录制" : "开始录制",
            dotColor: engine.isRunning ? .white : Theme.error,
            style: .filled
        ) {
            Task {
                if engine.isRunning {
                    engine.stop()
                } else {
                    await appState.startTranscription()
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: engine.isRunning)
    }
}

// MARK: - 提问汇总

/// 一节课里所有被判为提问的段落，按时间列出来。
///
/// 存在的理由：提问标记散在整场转录里，课上想「回看一下老师都问了什么」
/// 不可能回去翻几千字。这里列的是剥过口头禅的核心问题，原句留给需要
/// 核对上下文的人展开看。
private struct QuestionListView: View {
    let questions: [TranscriptSegment]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("本节课提问")
                    .textStyle(Theme.Text.title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .textStyle(Theme.Text.body)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.bottom, Theme.Spacing.lg)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(questions) { segment in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                                Text(segment.formattedTimestamp)
                                    .textStyle(Theme.Text.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.textTertiary)
                                if segment.questionLevel < 2 {
                                    Text("点名")
                                        .textStyle(Theme.Text.caption)
                                        .foregroundStyle(Theme.warning)
                                }
                            }
                            Text(segment.coreQuestion ?? segment.text)
                                .textStyle(Theme.Text.body)
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                            // 核心问题是剥出来的，和原句可能差很远——
                            // 剥错了的时候，没有对照就不知道是检测错了还是记错了
                            if let core = segment.coreQuestion, core != segment.text {
                                Text(segment.text)
                                    .textStyle(Theme.Text.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.md)

                        if segment.id != questions.last?.id {
                            Separator()
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(minWidth: 480, minHeight: 360)
        .background(Theme.background)
    }
}
