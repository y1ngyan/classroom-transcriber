import SwiftUI

struct GlossaryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GlossaryContent(store: appState.glossary, engine: appState.transcription)
    }
}

private struct GlossaryContent: View {
    @Bindable var store: GlossaryStore
    let engine: TranscriptionEngine

    var body: some View {
        ScrollView {
            // 区块之间靠 80 的留白和发丝分隔线分组，不放卡片框（规格要求）
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                header
                coursePreset
                if !store.candidates.isEmpty { candidatePanel }
                if store.hasPending { diffPanel }
                correctionList
                editor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        // 术语表是直接改数组的，改完在这里统一落盘
        .onChange(of: store.entries) { store.persist() }
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("术语表")
                .textStyle(Theme.Text.largeTitle)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                Text("\(store.entries.count) 个术语")
                Text("·")
                Text("\(engine.segments.count) 段转录")
                if !store.corrections.isEmpty {
                    Text("·")
                    Text("\(store.corrections.count) 处待确认")
                        .foregroundStyle(Theme.accent)
                }
            }
            .textStyle(Theme.Text.caption)
            .foregroundStyle(Theme.textSecondary)

            if !store.isConfigured {
                StatusMark(kind: .warning, text: "未配置 DeepSeek 密钥，校正功能不可用")
            }

            HStack(spacing: Theme.Spacing.sm) {
                PillButton(
                    title: store.isRunning ? "校正中…" : "术语校正",
                    systemImage: "text.badge.checkmark",
                    isLoading: store.isRunning,
                    isEnabled: store.isConfigured && !engine.segments.isEmpty
                ) {
                    Task { await store.run(segments: engine.segments) }
                }

                PillButton(title: "添加术语", systemImage: "plus", style: .quiet) {
                    store.addEntry()
                }

                // 三级操作用文字链，不再多一个胶囊——一排三个胶囊按钮
                // 等于这一行没有主次
                Button("恢复默认") { store.resetToDefaults() }
                    .buttonStyle(.plain)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)

                Spacer()
            }
            .padding(.top, Theme.Spacing.xs)

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.system(size: Theme.Text.caption.size, design: .monospaced))
                    .foregroundStyle(store.statusMessage.hasPrefix("❌")
                        ? Theme.error : Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 课程预设

    private var coursePreset: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Separator()

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("按课程选词表")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textPrimary)

                // 注意：这里不能用 `**加粗**`。SwiftUI 只在字符串**字面量**上
                // 解析 Markdown，拼接出来的 String 走的是另一个 init，星号会原样显示。
                Text("术语表是喂给识别器的先验，只能在开录之前定下来——"
                     + "录完再改，对已经录好的那场没有任何影响。所以上课前先选一包对得上的词。"
                     + "第一节课拿不准就随便挑一个，下课用下面的「从转录提取」把这场课真正的术语捞出来，"
                     + "下次上课前就有对得上的词表了。")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
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
                }

                // 次要动作退化成一个文字链，不再多一个胶囊
                Button("从转录提取术语") {
                    Task { await store.extract(segments: engine.segments) }
                }
                .buttonStyle(.plain)
                .textStyle(Theme.Text.caption)
                .foregroundStyle(engine.segments.isEmpty ? Theme.textTertiary : Theme.accent)
                .disabled(engine.segments.isEmpty || !store.isConfigured || store.isExtracting)

                if store.isExtracting {
                    ProgressView().controlSize(.small)
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 提取出来的候选

    private var candidatePanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            StatusMark(
                kind: .neutral,
                text: "从这场课里提出 \(store.candidates.count) 个术语，采纳后才进词表"
            )

            Text("提取发生在录完之后，所以改不了已经录好的这场——它救的是下一场同类课，"
                 + "以及马上要跑的术语校正。模型猜的词不一定对，逐条看一眼再采纳。")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(store.candidates) { candidate in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text(candidate.term)
                            .font(.system(size: Theme.Text.caption.size, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)

                        if let alias = candidate.aliases.first {
                            Text("← \(alias)")
                                .textStyle(Theme.Text.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if !candidate.note.isEmpty {
                            Text(candidate.note)
                                .textStyle(Theme.Text.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("采纳") { store.accept(candidate) }
                            .buttonStyle(.plain)
                            .textStyle(Theme.Text.caption)
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
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)

                        Text(correction.before)
                            .textStyle(Theme.Text.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .strikethrough(color: Theme.error.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(correction.after)
                            .textStyle(Theme.Text.caption)
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
        // 规格里的「状态用小图标 + 颜色表达」
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
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textPrimary)

                ForEach(store.corrections) { correction in
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        Text(correction.timestamp)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        Text(correction.after)
                            .textStyle(Theme.Text.caption)
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
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textPrimary)

                Text("误转写留空也能用——模型会自己判断，填了更准。中文说法不要填进来，"
                     + "否则模型会把转录里本来正确的中文改写成英文。")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach($store.entries) { $entry in
                    GlossaryEntryRow(entry: $entry) {
                        store.remove(entry)
                    }
                    Separator()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 单行术语

private struct GlossaryEntryRow: View {
    @Binding var entry: GlossaryEntry
    let onDelete: () -> Void

    /// 误转写这一栏在编辑期用本地字符串，避免每敲一个分隔符就被切分重组、
    /// 导致刚打出的「、」立刻消失。失焦或回车时才提交成数组。
    @State private var aliasesText = ""
    @FocusState private var aliasesFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                TextField("正确写法", text: $entry.term)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.Text.caption.size, weight: .medium))

                TextField("误转写，用「、」分隔（可留空）", text: $aliasesText)
                    .textFieldStyle(.plain)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .focused($aliasesFocused)
                    .onSubmit { commitAliases() }
                    .onChange(of: aliasesFocused) { _, focused in
                        if !focused { commitAliases() }
                    }

                TextField("说明（可选）", text: $entry.note)
                    .textFieldStyle(.plain)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.textSecondary, Theme.separator)
                }
                .buttonStyle(.plain)
                .help("删除这个术语")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
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
