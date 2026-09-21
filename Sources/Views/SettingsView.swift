import SwiftUI

/// 设置页：填 API 密钥和 COS 凭证，并当场验证。
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showsSecretKey = false

    private var store: SettingsStore { appState.settings }

    var body: some View {
        ScrollView {
            // 区块之间靠 80 的留白分开，不放卡片框（规格要求）
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                header
                audioSection()
                deepSeekSection()
                searchSection()
                cosSection()
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
            subtitle: "送进识别器之前给麦克风信号做一级软件增益。老师离得远、说话偏小的时候，小声识别率会明显变好。"
                + "录音存档存的是未加增益的原始音频，不受这一级影响。",
        ) {
            VStack(alignment: .leading, spacing: 12) {
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

                note(
                    "检测的是「老师是不是在向全班提问」，命中的段落会在转录里标出来。"
                        + "纯本地规则判定，不联网、不调模型。"
                )
            }
        }
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

    /// 提示行。规格要求分组靠留白和小图标，不靠背景色块，
    /// 所以这里只剩一个图标 + 一段灰字。
    private func note(_ text: String) -> some View {
        StatusMark(kind: .neutral, text: text)
    }
}

// MARK: - 组件

/// 一个设置区块：标题、说明、「去哪儿拿」的步骤，然后是表单。
///
/// 没有外框。分组靠上面那条发丝分隔线和 80 的留白——这是规格要的
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
