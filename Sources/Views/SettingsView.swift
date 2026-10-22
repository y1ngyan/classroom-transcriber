import SwiftUI

/// 设置页：填 API 密钥和 COS 凭证，并当场验证。
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showsSecretKey = false
    /// 「清理未完成的下载」的确认框。清的是磁盘上不可逆的东西，所以要有这一步
    @State private var isConfirmingCleanup = false

    private var store: SettingsStore { appState.settings }

    var body: some View {
        ScrollView {
            // 区块之间靠 80 的留白分开，不放卡片框（设计规范要求）
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                header
                audioSection()
                deepSeekSection()
                searchSection()
                cosSection()
                diagnosticsSection()
                fileFooter
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.pageBackground)
        // 每次进来重读磁盘——但要先让过没保存的草稿，否则一进来就把
        // 用户刚粘进去还没存的东西冲掉了
        .onAppear {
            if !store.hasUnsavedChanges { store.reload() }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("设置")
                    .textStyle(Theme.Text.largeTitle)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                if store.hasUnsavedChanges {
                    Text("有未保存的改动")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.warning)
                }

                PillButton(title: "保存", isEnabled: store.hasUnsavedChanges) {
                    store.save()
                    // 刚把后端保存成 Whisper：立刻开始预热模型。用户接下来多半
                    // 就是切到转录页点开始录制，十几秒的准备时间正好花在
                    // 「切页面、摆设备」这段里，而不是花在他盯着按钮的时候
                    if store.backend == .whisper {
                        appState.transcription.whisper.warmUp()
                    }
                }
            }

            Text("填完点「保存」，再点各部分里的「测试」当场验证。密钥只存在本机的配置文件里，不会上传到任何地方。")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !store.saveMessage.isEmpty {
                Text(store.saveMessage)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(store.saveMessage.hasPrefix("✅") ? Theme.success : Theme.error)
            }
        }
    }

    // MARK: - 录音与识别

    /// 这一节和页面其他部分不同：它不需要配置任何东西，默认就是可用的。
    /// 放在最前面是因为它是唯一一个直接决定「录下来能不能认出来」的开关，
    /// 而其余几节配不配只影响附加能力。
    private func audioSection() -> some View {
        @Bindable var store = appState.settings
        return SettingsSection(
            title: "录音与识别",
            subtitle: "决定「录下来的声音怎么变成文字」。识别后端和增益都从下一段录音开始生效；"
                + "录音存档存的始终是未加增益的原始音频，不受这里影响。",
        ) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(label: "识别后端") {
                    Picker("", selection: $store.backend) {
                        ForEach(TranscriptionBackend.allCases) { backend in
                            Text(backend.label).tag(backend)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                }

                Text(store.backend.hint)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                note(
                    "Whisper 后端跑的是本地模型：不联网、不上传，但要在「开始录制」之前先把模型读进内存。"
                        + "第一次准备要十几秒（之后走缓存，不到一秒），准备没成功时会明确报出来，不会悄悄换回系统识别。"
                )

                // 模型这一段只在选了 Whisper 时出现。默认（Apple）走的是系统
                // 识别，模型在不在和这次录音无关——把一条无关的信息摆在
                // 默认路径上，只会让真正的错误更难被看见
                if store.backend == .whisper {
                    modelRow()
                }

                // 课后重转要的 large-v3。**和后端选择无关**（P11-1 目标 2）：
                // 重转是对已经录好的音频做事，走的是自己那条路，用户哪怕
                // 选了 Apple 也照样能重转——把它藏在 `backend == .whisper`
                // 后面，就会出现「提示我去下 large，可设置里没有这一行」
                retranscribeModelRow()

                // 未完成的下载残留。**和后端选择无关**：用户下一半切回 Apple，
                // 那几百 MB 的 `.part` 照样占着盘。它只在自己存在时出现——
                // 没有残留时不占一行，这是常态
                if appState.modelDownload.shouldShowCacheRow {
                    cacheRow()
                }

                // 预热结果只在这一节里显示：模型路径、准备用时、「不可用」的原因
                // 都只对「选了 Whisper 的人」有意义，默认（Apple）时这一行不出现
                if let line = appState.transcription.whisper.statusLine {
                    Text(line)
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(line.hasPrefix("❌") ? Theme.error : Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledField(label: "麦克风增益") {
                    Picker("", selection: $store.micGain) {
                        ForEach(MicGainMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                }

                // 选中的那一档到底做什么，写在下面而不是让用户去猜档位名。
                // 「自动」和「5 倍」听上去都像「会放大」，区别全在噪声门上，
                // 而那个区别从名字上一点也看不出来
                Text(store.micGain.hint)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)

                note(
                    "改动从下一段录音开始生效。增益档决定的是整段录音的处理方式，"
                        + "中途换档会让同一段录音的前后两截用上不同的增益曲线。"
                )

                LabeledField(label: "提问检测") {
                    Picker("", selection: $store.questionSensitivity) {
                        ForEach(QuestionSensitivity.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                }

                Text(store.questionSensitivity.hint)
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)

                LabeledField(label: "自动核查") {
                    Toggle("", isOn: $store.autoFactCheck)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .frame(width: 360, alignment: .leading)
                }

                Text("开启后每段转录定稿会自动联网核查（消耗检索与模型额度）；关闭时可在核查页手动核查")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)

                // 只对 whisper 后端有效。**不把这一项藏在「后端 = whisper」后面**：
                // 那一栏是可以随时改的，而这一项一藏，用户切到 whisper 之后
                // 会以为这一页里根本没有这个词表开关
                LabeledField(label: "术语前移") {
                    Toggle("", isOn: $store.glossaryPrompt)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .frame(width: 360, alignment: .leading)
                }

                Text("开启后把术语表作为先验送进 whisper（不联网、不调模型）；顶部是 Apple 后端时不生效")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)

                // 静音窗跳过（P12-3）。**不藏在「后端 = whisper」后面**：这条只看
                // 转录走没走 whisper，和「录不录」无关；藏起来会让默认的后端用户
                // 以为设置页里根本没有这个开关。措辞必须写出代价——「关掉」是
                // 一次显式选择，不是免费的：静音窗会重新送进模型，而那正是
                // 幻觉句的来源
                LabeledField(label: "静音窗跳过（省算力）") {
                    Toggle("", isOn: $store.skipSilentWindows)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .frame(width: 360, alignment: .leading)
                }

                Text("开启后整窗都判为静音（没人说话）的窗口不进模型，省算力；"
                        + "关闭后静音窗也会送进模型，可能重新长出「像真话的幻觉句」，"
                        + "但不会因为门控判错而漏掉小声说话")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)

                note(
                    "检测的是「老师是不是向全班提问」，命中的段落会在转录里标出来。"
                        + "纯本地规则判定，不联网、不调模型。"
                )
            }
        }
        // 进设置页扫一次模型目录。**挂在这里而不是写在 `body` 的求值路径上**：
        // 扫盘是副作用，而 `body` 一次渲染会被走好几遍。残留那一行只在自己
        // 存在时出现，所以扫出来是空的时候界面上什么都不会多
        .onAppear { appState.modelDownload.refreshCache() }
    }

    // MARK: - DeepSeek

    // 下面三段都用函数而不是计算属性：`$store.field` 这样的绑定需要一个
    // `@Bindable` 包装，而它得在函数体里作为局部变量取一份
    private func deepSeekSection() -> some View {
        @Bindable var store = appState.settings
        return SettingsSection(
            title: "DeepSeek",
            subtitle: "术语校正、生成笔记、事实核查的判定都靠它。没有它，这三个功能都用不了。",
            steps: [
                "打开 platform.deepseek.com 注册并登录",
                "左侧「API keys」→「创建 API key」",
                "复制出来的那串（sk- 开头），粘到下面",
            ]
        ) {
            LabeledField(label: "API 密钥", hint: "sk- 开头") {
                SecureField("sk-…", text: $store.deepSeekAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    // MARK: - 联网搜索

    private func searchSection() -> some View {
        @Bindable var store = appState.settings
        return SettingsSection(
            title: "联网搜索",
            subtitle: "事实核查要用它去查资料。没有它，核查就退化成「模型凭记忆表个态」，那不是核查。",
            steps: [
                "打开 tavily.com 注册（免费额度每月 1000 次，够用）",
                "登录后在 Dashboard 里找到 API Key",
                "复制那串（tvly- 开头），粘到下面",
            ]
        ) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(label: "服务商") {
                    Picker("", selection: $store.searchProvider) {
                        Text("Tavily（推荐）").tag("tavily")
                        Text("Serper").tag("serper")
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                LabeledField(
                    label: "API 密钥",
                    hint: store.searchProvider == "tavily" ? "tvly- 开头" : "Serper 的 key"
                ) {
                    SecureField("tvly-…", text: $store.searchAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                TestRow(
                    title: "测试搜索",
                    isTesting: store.isTestingSearch,
                    result: store.searchTestResult,
                    action: { Task { await store.testSearch() } }
                )
            }
        }
    }

    // MARK: - COS

    private func cosSection() -> some View {
        @Bindable var store = appState.settings
        return SettingsSection(
            title: "腾讯云 COS",
            subtitle: "「上传云端」把录音存到这里。不配也能用，只是录音只留在本机。",
            steps: [
                "打开 console.cloud.tencent.com，注册并实名",
                "搜「对象存储」→ 创建存储桶。地域选离你近的（如广州 ap-guangzhou）",
                "建好后桶名形如 classroom-1300000000，它和地域一起填到下面",
                "再搜「访问管理」→「API 密钥管理」→ 新建密钥，得到 SecretId 和 SecretKey",
            ]
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    LabeledField(label: "存储桶名", hint: "含 APPID 后缀") {
                        TextField("classroom-1300000000", text: $store.cosBucket)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    LabeledField(label: "地域", hint: "如 ap-guangzhou") {
                        TextField("ap-guangzhou", text: $store.cosRegion)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 180)
                    }
                }

                LabeledField(label: "SecretId", hint: "AKID 开头") {
                    TextField("AKID…", text: $store.cosSecretID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                LabeledField(label: "SecretKey", hint: "新建密钥时只显示一次") {
                    HStack(spacing: 6) {
                        if showsSecretKey {
                            TextField("", text: $store.cosSecretKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        } else {
                            SecureField("", text: $store.cosSecretKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        Button {
                            showsSecretKey.toggle()
                        } label: {
                            Image(systemName: showsSecretKey ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }

                note(
                    "这个密钥等于账号的钥匙，权限很大。想要更稳妥，去「访问管理 → 用户 → 新建子用户」，"
                        + "只给它 COS 的读写权限，用子用户的密钥填在这里。"
                )

                TestRow(
                    title: "测试上传",
                    isTesting: store.isTestingCOS,
                    result: store.cosTestResult,
                    action: { Task { await store.testCOS() } }
                )
            }
        }
    }

    // MARK: - 诊断日志（P6-1）

    /// 这一节不配置任何东西，只提供「把现场取出来」这一个动作。
    ///
    /// 它是 `SettingsSection` 的另一种用法——没有步骤、只有一个按钮
    /// 和一条说明，和「录音与识别」那一节同一种做法。分组靠留白和发丝线，
    /// 没有框也不该有
    private func diagnosticsSection() -> some View {
        SettingsSection(
            title: "诊断日志",
            subtitle: "出问题时留下的现场。日志只记「发生了什么」——级别、类别、时长、"
                + "退出码、段数；密钥和你的转录正文都不会写进去。"
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.lg) {
                    PillButton(
                        title: "导出诊断日志",
                        systemImage: "square.and.arrow.up",
                        style: .quiet
                    ) {
                        store.exportDiagnostics()
                    }
                    Spacer()
                }

                if let result = store.diagnosticsExport {
                    StatusMark(kind: result.ok ? .ok : .error, text: result.detail)
                }

                // 说清它会自己封顶——不然「日志」两个字让人担心它哪天把盘写满
                // 不写 `**强调**`：这里的文案是以 `String` 变量喂进 `Text` 的，
                // 不走 markdown 解析，星号会原样显示出来
                note("日志目录：\(DiagnosticLog.directoryPath)。最多 4 个文件、约 1 MB，"
                     + "写满之后自动丢掉最老的，不会一直长大。")
            }
        }
    }

    // MARK: - 页脚

    private var fileFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Separator()
            Text("配置文件位置")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(store.configFilePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
            Text("权限已设为 600（仅本人可读）。这个文件里有密钥，别拷贝到别的机器，也别提交进任何仓库。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 8)
    }

    /// 提示行。设计规范要求分组靠留白和小图标，不靠背景色块，
    /// 所以这里只剩一个图标 + 一段灰字。
    private func note(_ text: String) -> some View {
        StatusMark(kind: .neutral, text: text)
    }

    /// 「模型」这一行：现在有没有、在下多少、按哪里下/按哪里停。
    ///
    /// 一条规则：**状态永远是「小图标 + 一句话」，不是一个色块**（设计规范）。
    /// 进度条也不画——字节数、百分比、速度、剩余时间这四样已经是全部信息，
    /// 再加一根条只是把同样的东西画第二遍。
    @ViewBuilder
    private func modelRow() -> some View {
        let center = appState.modelDownload
        // 每次重算时现探一次磁盘。下载完成后 `phase` 会变，视图跟着重画，
        // 这一行也就跟着翻到「已就位」
        let decision = TranscriptionBackend.decide(backend: .whisper)

        VStack(alignment: .leading, spacing: 8) {
            if center.phase.isBusy {
                StatusMark(kind: .live, text: center.progressLine)
                if let retry = center.retryNote {
                    // 自动重试**必须看得见**：不显示的话，界面看上去就只是
                    // 「卡住了」，用户既不知道出了什么事，也没有停下来的理由
                    StatusMark(kind: .warning, text: retry)
                }
            } else if case .done(let bytes) = center.phase {
                StatusMark(kind: .ok, text: "模型已就位 · \(ModelCache.byteText(bytes))")
            } else {
                switch decision {
                case .whisper:
                    StatusMark(kind: .ok, text: "模型已就位")
                case .apple:
                    EmptyView()
                case .blocked(let reason):
                    // **拦住的地方就要说全**：路径、期望大小、去哪儿下。
                    // 这三件事是用户照着就能自己解决的全部信息
                    StatusMark(kind: .error, text: reason)
                }
            }

            if case .failed(let message) = center.phase {
                StatusMark(kind: .error, text: message)
            }

            Text("模型位置：\(center.destination.path)")
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // 源给出的诚实提示原样显示（例如「此源不支持续传，将从 0 开始」）。
            // **不加工**——加工就等于替源撒谎
            ForEach(center.notices, id: \.self) { notice in
                StatusMark(kind: .neutral, text: notice)
            }

            // 一次只放一个 PillButton：进行中就是「取消下载」，其余是「下载模型」。
            // 取消之后按钮回到「下载模型」——下一次会从 `.part` 接着下，
            // 所以文案不写「重新下载」（那会让人以为前面的白下了）
            if center.phase.isBusy {
                PillButton(title: "取消下载", style: .quiet) { center.cancel() }
            } else {
                PillButton(title: center.canRetry ? "重试下载" : "下载模型",
                           isLoading: false) {
                    center.start()
                }
            }
        }
    }

    /// 「课后重转模型」这一行（P11-1 目标 2）。
    ///
    /// 什么时候出现，只有两条：
    ///   · **large-v3 缺着或不全**（裁决 `.blocked`）——这是它存在的主要理由。
    ///     拦截文案本身就写全了「缺哪个文件 / 路径 / 期望多大 / 去哪儿下」，
    ///     这里再加一个按钮，用户照着就能自己解决；
    ///   · 正在下这一份 / 刚下完这一份——下完了要看见「已就位」，
    ///     否则界面上下完和没下一样，用户会再点一次。
    ///
    /// 齐全且没在动 = 常态，**不占一行**（和 `cacheRow` 同一条规矩）。
    ///
    /// 它**不挂在 `backend == .whisper` 后面**：重转是对已经录好的音频做事，
    /// 走自己那条路，用户选了 Apple 后端也照样能重转。
    @ViewBuilder
    private func retranscribeModelRow() -> some View {
        let center = appState.modelDownload
        let engine = RetranscribeEngine.large
        let decision = RetranscribeRequirement.resolve(engine: engine)
        let activeHere = center.activeFile == engine.fileName
        let busyHere = center.phase.isBusy && activeHere

        VStack(alignment: .leading, spacing: 8) {
            if busyHere {
                StatusMark(kind: .live, text: "正在下载重转模型 · \(center.progressLine)")
                if let retry = center.retryNote {
                    StatusMark(kind: .warning, text: retry)
                }
                // 同 modelRow：一次只放一个 PillButton，下完之前那一个位置是取消
                PillButton(title: "取消下载", style: .quiet) { center.cancel() }
                Text("模型位置：\(center.destination.path)")
                    .textStyle(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                switch decision {
                case .ready:
                    if case .done(let bytes) = center.phase, activeHere {
                        StatusMark(kind: .ok, text: "重转模型已就位 · \(ModelCache.byteText(bytes))")
                    }
                case .blocked(let reason):
                    // 文案里带着路径和一个下载地址，**原样显示**：它是照着做的全部信息
                    StatusMark(kind: .error, text: reason)
                    if case .failed(let message) = center.phase, activeHere {
                        StatusMark(kind: .error, text: message)
                    } else if case .cancelled = center.phase, activeHere {
                        StatusMark(kind: .warning,
                                   text: "下载已取消。已下的部分留着，下次从这里接着下")
                    }
                    PillButton(title: "下载重转模型（large-v3）") {
                        center.start(file: engine.fileName)
                    }
                }
            }
        }
    }

    /// 「未完成的下载」这一行：列出来、说清占了多少、能一键清掉。
    ///
    /// 存在的理由：`.part` 是**默认看不见的**——它不叫模型文件的名字，Finder
    /// 里也不会提示它。用户唯一能察觉它的地方是「磁盘怎么少了 500MB」。
    /// 而清理必须**先说要释放多少再动手**：删东西这件事，确认框上那个数字
    /// 是用户唯一的依据
    @ViewBuilder
    private func cacheRow() -> some View {
        let center = appState.modelDownload
        VStack(alignment: .leading, spacing: 8) {
            if let plan = center.freeablePlan {
                StatusMark(kind: .warning,
                           text: "未完成的下载 \(plan.items.count) 项 · 占用 \(ModelCache.byteText(plan.totalBytes))")
                ForEach(plan.items) { item in
                    Text("· \(item.url.lastPathComponent) · \(ModelCache.byteText(item.bytes))")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PillButton(title: "清理未完成的下载", style: .quiet) {
                    isConfirmingCleanup = true
                }
                .confirmationDialog(
                    "清理未完成的下载？",
                    isPresented: $isConfirmingCleanup
                ) {
                    // 按钮上写的就是将要释放的字节数——确认框上那个数字是
                    // 用户唯一的依据，不能含糊成「确定吗？」
                    Button("删除 \(plan.items.count) 项（释放 \(ModelCache.byteText(plan.totalBytes))）",
                           role: .destructive) {
                        center.cleanIncomplete()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除：\n" + plan.itemLines.joined(separator: "\n")
                         + "\n\n已经下好的模型文件不在此列。")
                }
            }
            if let note = center.cleanupNote {
                StatusMark(kind: .neutral, text: note)
            }
        }
    }
}

// MARK: - 组件

/// 一个设置区块：标题、说明、「去哪儿拿」的步骤，然后是表单。
///
/// 没有外框。分组靠上面那条发丝分隔线和 80 的留白——这是设计规范要的
/// 苹果产品页那种做法，框和阴影都不要。
///
/// 步骤直接印在界面上而不是只写在文档里：用户卡住的那一刻他人就在
/// 这个页面，不会去翻 README。
private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    /// 「去哪儿拿这个值」的步骤。需要用户先去别的网站申请东西的区块才有，
    /// 空数组表示这一节没什么前置动作好讲（默认就是空的）
    var steps: [String] = []
    @ViewBuilder var content: Content

    @State private var showsSteps = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Separator()

            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .textStyle(Theme.Text.title)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                // 没有步骤就不给这个开关：一个点开之后什么都没有的「显示步骤」，
                // 比没有它更让人怀疑自己点错了地方
                if !steps.isEmpty {
                    Button(showsSteps ? "隐藏步骤" : "显示步骤") { showsSteps.toggle() }
                        .buttonStyle(.plain)
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Text(subtitle)
                .textStyle(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsSteps && !steps.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Text("\(index + 1).")
                                .textStyle(Theme.Text.caption)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textTertiary)
                            Text(step)
                                .textStyle(Theme.Text.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                // 靠缩进区分层级，不靠底色：底色就是「卡片」的另一种形态
                .padding(.leading, Theme.Spacing.md)
            }

            content
                .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                if let hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            content
        }
    }
}

/// 「测试」按钮 + 结果。
///
/// 结果里刻意带上服务端返回的实际内容（对象键、命中的标题），而不是
/// 只说「成功」——一句不带细节的「成功」，和一个勾号一样，都没法让人
/// 判断它到底验了什么。
private struct TestRow: View {
    let title: String
    let isTesting: Bool
    let result: SettingsStore.TestResult?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if isTesting {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("测试中…")
                        .textStyle(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                PillButton(title: title, systemImage: "bolt.horizontal", style: .quiet) {
                    action()
                }
            }

            if let result {
                StatusMark(
                    kind: result.ok ? .ok : .error,
                    text: result.detail
                )
            }
        }
    }
}
