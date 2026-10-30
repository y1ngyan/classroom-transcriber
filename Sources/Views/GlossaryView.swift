import SwiftUI

struct GlossaryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GlossaryContent(
            store: appState.glossary,
            presets: appState.presets,
            punctuation: appState.punctuation,
            engine: appState.transcription
        )
    }
}

private struct GlossaryContent: View {
    @Bindable var store: GlossaryStore
    let presets: CoursePresetStore
    let punctuation: PunctuationStore
    let engine: TranscriptionEngine

    /// 联网生成词表的输入（课程名）。放视图状态就够：它是一次性输入，
    /// 不需要跨标签页保留——要留下的是生成结果，那个进了词表/自建词库。
    /// 顺带它也是「存为我的词库」那一包的**名字来源**，所以按钮上会把
    /// 这个名字显示出来，用户看得见自己会存成什么名字。
    @State private var courseInput = ""

    var body: some View {
        ScrollView {
            // 区块之间靠 80 的留白和发丝分隔线分组，不放卡片框（设计规范要求）
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                header
                coursePreset
                punctuationSection
                if !store.candidates.isEmpty { candidatePanel }
                if store.hasPending { diffPanel }
                correctionList
                editor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.RecordingLayout.pagePadding)
            .padding(.top, Theme.RecordingLayout.pagePadding)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        // 术语表是直接改数组的，改完在这里统一落盘
        .onChange(of: store.entries) { store.persist() }
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // 44pt 工具栏：主操作「新增术语」在右上角（P14-4）
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Text("术语表")
                    .textStyle(Theme.Text.largeTitle)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: Theme.Spacing.md)

                ToolbarActionButton(title: "新增术语", systemImage: "plus") {
                    store.addEntry()
                }
            }
            .frame(height: Theme.RecordingLayout.toolbarHeight)

            HStack(spacing: Theme.Spacing.s6) {
                Text("\(store.entries.count) 个术语")
                Text("·")
                Text("\(engine.segments.count) 段转录")
                if !store.corrections.isEmpty {
                    Text("·")
                    Text("\(store.corrections.count) 处待确认")
                        .foregroundStyle(Theme.accent)
                }
            }
            .textStyle(Theme.Text.meta)
            .foregroundStyle(Theme.textSupporting)

            if !store.isConfigured {
                StatusMark(kind: .warning, text: "未配置 DeepSeek 密钥，校正功能不可用")
            }

            HStack(spacing: Theme.Spacing.md) {
                // 这一行只留一个胶囊（主操作已经进了工具栏）；「恢复默认」
                // 是三级操作，退化成文字链
                PillButton(
                    title: store.isRunning ? "校正中…" : "术语校正",
                    systemImage: "text.badge.checkmark",
                    isLoading: store.isRunning,
                    isEnabled: store.isConfigured && !engine.segments.isEmpty
                ) {
                    Task { await store.run(segments: engine.segments) }
                }

                Button("恢复默认") { store.resetToDefaults() }
                    .buttonStyle(.plain)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textTertiary)

                Spacer()
            }

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(Theme.Text.meta.font.monospaced())
                    .foregroundStyle(store.statusMessage.hasPrefix("❌")
                        ? Theme.error : Theme.textSupporting)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 课程预设

    private var coursePreset: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Separator()

            let courseExplanation = "术语表是喂给识别器的先验，只能在开录之前定下来——"
                + "录完再改，对已经录好的那场没有任何影响。所以上课前先选一包对得上的词。"
                + "第一节课拿不准就随便挑一个，下课用下面的「从转录提取」把这场课真正的术语捞出来，"
                + "下次上课前就有对得上的词表了。"

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("按课程选词表")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.textPrimary)
                    // 完整说明放进问号气泡：这段是「课前怎么准备」的长解释，
                    // 页面上留三行提示，剩下的按需看（P14-4）
                    InfoBubble(text: courseExplanation)
                }

                // 注意：这里不能用 `**加粗**`。SwiftUI 只在字符串**字面量**上
                // 解析 Markdown，拼接出来的 String 走的是另一个 init，星号会原样显示。
                Text(courseExplanation)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Spacing.sm) {
                // 一次只放一个胶囊：选词表是这一段的主动作
                PillMenu(title: "载入课程预设", systemImage: "books.vertical") {
                    ForEach(CoursePresets.all) { preset in
                        Button("\(preset.name)（\(preset.entries.count) 词）") {
                            store.apply(preset)
                        }
                    }
                    // 用户自建的词库（联网生成之后存下来的）。
                    // 删除单独列一段：放在载入项上做长按/右键都不好发现
                    if !presets.custom.isEmpty {
                        Divider()
                        ForEach(presets.custom) { preset in
                            Button("我的 · \(preset.name)（\(preset.entries.count) 词）") {
                                store.apply(preset)
                            }
                        }
                        Divider()
                        ForEach(presets.custom) { preset in
                            Button("删除「\(preset.name)」", role: .destructive) {
                                presets.remove(id: preset.id)
                            }
                        }
                    }
                }

                // 次要动作退化成一个文字链，不再多一个胶囊
                Button("从转录提取术语") {
                    Task { await store.extract(segments: engine.segments) }
                }
                .buttonStyle(.plain)
                .textStyle(Theme.Text.meta)
                .foregroundStyle(engine.segments.isEmpty ? Theme.textTertiary : Theme.accent)
                .disabled(engine.segments.isEmpty || !store.isConfigured || store.isExtracting)

                if store.isExtracting {
                    ProgressView().controlSize(.small)
                }

                Spacer()
            }

            // 内置预设对不上这门课时，用联网生成一包。
            //
            // 这一段的语义是「课前备课」，所以在文案上必须和上面那句
            // 「术语表是喂给识别器的先验」连起来——用户最容易的误解就是
            // 以为录到一半点一下能让识别变准。
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("没有对得上的预设？填课程名，联网生成一包")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textTertiary)

                HStack(spacing: Theme.Spacing.sm) {
                    TextField("课程名（例如：生物化学）", text: $courseInput)
                        .textFieldStyle(.plain)
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: 220)
                        .onSubmit { generateFromWeb() }

                    // 这一行的主动作，只放这一个胶囊
                    PillButton(
                        title: "联网生成词表",
                        systemImage: "globe",
                        isLoading: store.isSuggesting,
                        isEnabled: !GlossarySuggestionService.cleanCourseName(courseInput).isEmpty
                    ) {
                        generateFromWeb()
                    }

                    // 次要动作是文字链，不再多一个胶囊
                    if !store.entries.isEmpty {
                        Button("存为我的词库「\(GlossarySuggestionService.cleanCourseName(courseInput))」") {
                            presets.save(
                                name: GlossarySuggestionService.cleanCourseName(courseInput),
                                entries: store.entries
                            )
                        }
                        .buttonStyle(.plain)
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(GlossarySuggestionService.cleanCourseName(courseInput).isEmpty
                            ? Theme.textTertiary : Theme.accent)
                        .disabled(GlossarySuggestionService.cleanCourseName(courseInput).isEmpty)
                    }

                    Spacer()
                }

                // 实际用了哪些检索式。结果不对时，用户第一眼看的就是这一行
                if store.candidateSource == .web, !store.lastQueries.isEmpty {
                    Text("检索式：" + store.lastQueries.joined(separator: " / "))
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !presets.statusMessage.isEmpty {
                    Text(presets.statusMessage)
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(presets.statusMessage.hasPrefix("❌")
                            ? Theme.error : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 联网生成。逻辑全在 store 里，这里只负责把输入递过去。
    private func generateFromWeb() {
        let course = GlossarySuggestionService.cleanCourseName(courseInput)
        guard !course.isEmpty else { return }
        Task { await store.suggestFromWeb(course: course) }
    }

    // MARK: - LLM 补标点

    private var punctuationSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Separator()

            let punctuationExplanation = "识别引擎原生不产出标点，长段转录是一整坨无标点文字。"
                + "这一步把整场转录发给 DeepSeek 补标点，每段返回都要过校验——剥掉标点后必须和原文"
                + "逐字一致才落地，不一致的段保持原文。要联网，只在你点按钮时跑；"
                + "补过标点的段落，展示时会严格按标点断句。"

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("LLM 补标点")
                        .textStyle(Theme.Text.meta)
                        .foregroundStyle(Theme.textPrimary)
                    InfoBubble(text: punctuationExplanation)
                }

                Text(punctuationExplanation)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Spacing.sm) {
                PillButton(
                    title: punctuation.isRunning ? "补标点中…" : "补标点",
                    systemImage: "text.quote",
                    isLoading: punctuation.isRunning,
                    isEnabled: punctuation.isConfigured && !engine.segments.isEmpty
                ) {
                    Task { await punctuation.run(on: engine) }
                }

                Spacer()
            }

            if !punctuation.statusMessage.isEmpty {
                Text(punctuation.statusMessage)
                    .font(Theme.Text.meta.font.monospaced())
                    .foregroundStyle(punctuation.statusMessage.hasPrefix("❌")
                        ? Theme.error : Theme.textSupporting)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 提取出来的候选

    private var candidatePanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            StatusMark(
                kind: .neutral,
                text: store.candidateSource == .web
                    ? "联网生成 \(store.candidates.count) 个候选术语，采纳后才进词表"
                    : "从这场课里提出 \(store.candidates.count) 个术语，采纳后才进词表"
            )

            // 两种来源的**含义完全不同**，文案不能共用：
            // 提取拿的是「这场课真的讲过什么」（有实测价值），
            // 联网拿的是「这门课一般会讲什么」（只有先验价值，可能一个都不在
            // 这堂课里出现）。而且提取只能救下一场，联网生成必须赶在开录前。
            Text(store.candidateSource == .web
                 ? "这些词来自网上检索到的术语表，是这门课的通用术语，不一定出现在老师这堂课里。"
                   + "现在采纳，效力在还没录的课——术语表是识别器的先验，录完的那场已经改不了了。"
                   + "模型从资料里挑的词不一定对，逐条看一眼再采纳。"
                 : "提取发生在录完之后，所以改不了已经录好的这场——它救的是下一场同类课，"
                   + "以及马上要跑的术语校正。模型猜的词不一定对，逐条看一眼再采纳。")
                .textStyle(Theme.Text.meta)
                .foregroundStyle(Theme.textSupporting)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(store.candidates) { candidate in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text(candidate.term)
                            .font(Theme.Text.meta.font.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)

                        if let alias = candidate.aliases.first {
                            Text("← \(alias)")
                                .textStyle(Theme.Text.meta)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if !candidate.note.isEmpty {
                            Text(candidate.note)
                                .textStyle(Theme.Text.meta)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("采纳") { store.accept(candidate) }
                            .buttonStyle(.plain)
                            .textStyle(Theme.Text.meta)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                PillButton(title: "全部采纳") { store.acceptAllCandidates() }
                PillButton(title: "忽略", style: .quiet) { store.dismissCandidates() }
            }
        }
        .padding(.leading, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 和 diffPanel 一样用左侧竖线标注「这是待你处理的一批东西」
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.separator).frame(width: 2)
        }
    }

    // MARK: - 待确认的改动

    private var diffPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            StatusMark(
                kind: .warning,
                text: "校正预览：\(store.corrections.count) 处改动待确认"
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(store.corrections) { correction in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(correction.timestamp)
                            .font(Theme.Text.footnote.font.monospaced())
                            .foregroundStyle(Theme.textTertiary)

                        Text(correction.before)
                            .textStyle(Theme.Text.meta)
                            .foregroundStyle(Theme.textSecondary)
                            .strikethrough(color: Theme.error.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(correction.after)
                            .textStyle(Theme.Text.meta)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                PillButton(title: "应用到转录", isEnabled: !engine.segments.isEmpty) {
                    store.apply(to: engine)
                }
                PillButton(title: "放弃", style: .quiet) { store.discard() }
            }
        }
        .padding(.leading, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 待确认的改动用左侧一条 accent 竖线标出来，而不是整块底色——
        // 设计规范里的「状态用小图标 + 颜色表达」
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.accent).frame(width: 2)
        }
    }

    /// 已应用过的改动记录（没有 pending 时也留个痕）
    @ViewBuilder
    private var correctionList: some View {
        if !store.hasPending && !store.corrections.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Separator()
                Text("上次校正的改动")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textPrimary)

                ForEach(store.corrections) { correction in
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        Text(correction.timestamp)
                            .font(Theme.Text.footnote.font.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                        Text(correction.after)
                            .textStyle(Theme.Text.meta)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 术语编辑

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Separator()
                Text("术语（正确写法 / 实测误转写）")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textPrimary)

                Text("误转写留空也能用——模型会自己判断，填了更准。中文说法不要填进来，"
                     + "否则模型会把转录里本来正确的中文改写成英文。")
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 每条术语一张 elevation 1 的卡片：它和录音列表的行是同一种
            // 「一条」单位，P14-4 定死的卡片规则（亮色带阴影）就该照抄。
            // 曾经写成 0——亮色下白卡压在 #F1F1F4 上只剩一条约 0.94 的
            // 描边，和页面底（0.946）几乎同亮，自检「亮色卡片有描边」直接红
            VStack(spacing: Theme.Spacing.sm) {
                ForEach($store.entries) { $entry in
                    GlossaryEntryRow(entry: $entry, source: sourceLabel(for: entry)) {
                        store.remove(entry)
                    }
                    .cardStyle(elevation: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 词条的「来源」。条目本身没有来源字段（不改数据结构），这里从
    /// 「它和哪一包预设里的词条同名」反推：自建词库优先，其次是内置预设，
    /// 都对不上就是手动加的。改过词条名之后会显示「手动添加」——这是实话，
    /// 它确实不再来自任何预设
    private func sourceLabel(for entry: GlossaryEntry) -> String {
        if let custom = presets.custom.first(where: { preset in
            preset.entries.contains { $0.term == entry.term }
        }) {
            return "我的 · \(custom.name)"
        }
        if let builtin = CoursePresets.all.first(where: { preset in
            preset.entries.contains { $0.term == entry.term }
        }) {
            return builtin.name
        }
        return "手动添加"
    }
}

// MARK: - 单行术语

private struct GlossaryEntryRow: View {
    @Binding var entry: GlossaryEntry
    /// 来源文案（11pt 显示在右上角）
    let source: String
    let onDelete: () -> Void

    /// 误转写这一栏在编辑期用本地字符串，避免每敲一个分隔符就被切分重组、
    /// 导致刚打出的「、」立刻消失。失焦或回车时才提交成数组。
    @State private var aliasesText = ""
    @FocusState private var aliasesFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                TextField("正确写法", text: $entry.term)
                    .textFieldStyle(.plain)
                    .textStyle(Theme.Text.bodyEmphasized)

                TextField("误转写，用「、」分隔（可留空）", text: $aliasesText)
                    .textFieldStyle(.plain)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
                    .focused($aliasesFocused)
                    .onSubmit { commitAliases() }
                    .onChange(of: aliasesFocused) { _, focused in
                        if !focused { commitAliases() }
                    }

                TextField("说明（可选）", text: $entry.note)
                    .textFieldStyle(.plain)
                    .textStyle(Theme.Text.meta)
                    .foregroundStyle(Theme.textSupporting)
            }
            // 输入区吃掉剩余宽度；来源那一列只占自己的固有宽度
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                Text("来源 · \(source)")
                    .textStyle(Theme.Text.footnote)
                    .foregroundStyle(Theme.textSupporting)
                    .lineLimit(1)

                if isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: Theme.Text.meta.size))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.textSecondary, Theme.separator)
                    }
                    .buttonStyle(.plain)
                    .help("删除这个术语")
                }
            }
        }
        .onHover { isHovering = $0 }
        .onAppear { aliasesText = entry.aliases.joined(separator: "、") }
        // 恢复默认会整批换掉条目（含 id），本地镜像要跟着重置
        .onChange(of: entry.id) { aliasesText = entry.aliases.joined(separator: "、") }
    }

    private func commitAliases() {
        let parsed = aliasesText
            .split(whereSeparator: { "、,，;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parsed != entry.aliases else { return }
        entry.aliases = parsed
    }
}
