import Foundation

/// API 密钥与配置。
///
/// 读取顺序：环境变量 → `~/Library/Application Support/ClassroomTranscriber/config.json`
/// （从 Finder 启动的 App 拿不到 shell 环境变量，所以需要配置文件兜底）
enum AppConfig {

    struct Config: Codable {
        var deepSeekAPIKey: String?
        var searchProvider: String?
        var searchAPIKey: String?
        var cosBucket: String?
        var cosRegion: String?
        /// 签发临时密钥的后端地址（腾讯云 SCF 或自建）。
        var cosSTSURL: String?
        /// 完整端点地址。留空则由 bucket + region 推导。
        /// 本地 mock 服务要填这个才连得上。
        var cosEndpoint: String?
        /// 对象键前缀，便于在同一个桶里区分不同来源
        var cosKeyPrefix: String?
        /// 永久密钥。只填 cosSecretID + cosSecretKey 也能跑，见下方注释。
        var cosSecretID: String?
        var cosSecretKey: String?

        // ---- 偏好设置 ----
        //
        // 不是密钥，但和密钥住在同一个文件里。给两个下拉框单开一个
        // 偏好文件，只会让「我的设置到底存在哪」这个问题多一个答案，
        // 而那个答案对用户没有任何用。
        /// 麦克风软件增益档（auto / off / x2 / x3 / x5）
        var micGain: String?
        /// 课堂提问检测灵敏度（high / normal / low / off）
        var questionSensitivity: String?
        /// 段落定稿后是否自动联网核查。**缺省关闭**——核查要联网、
        /// 要花检索和 LLM 额度，这是用户的账，不该由我们默认替他花掉。
        /// 关掉只是不自动触发，手动点某一段照样能核查
        var autoFactCheck: Bool?
        /// 实时转录的后端（apple / whisper）。**缺省 apple**，见 `TranscriptionBackend`
        var transcriptionBackend: String?
        /// 悬浮字幕（灵动岛样式）。缺省关：它是一条浮在全屏视频上的窗，
        /// 用户没要就不该出现
        var subtitleOverlay: Bool?
        /// 音源：mic / system。缺省 mic（与改造前一致）。
        /// system = 采系统正在播放的声音（网课/会议），需要「屏幕录制」权限
        var audioSource: String?
        /// 转录语言（auto / zh / en / ja / ko / de / fr / es / ru）。缺省 zh，
        /// 与改造前一致；非法值由 `LanguagePreference.normalize` 回落 zh
        var transcriptionLanguage: String?
        /// Obsidian vault 目录。选过一次就记住，之后「导出到 Obsidian」不再弹选择框
        var obsidianVaultPath: String?
        /// 是否把术语表作为 whisper 的 `initial_prompt` 送进去（P12-1）。
        /// 缺省见 `AppConfig.glossaryPromptEnabled`——那里的注释写了为什么
        var glossaryPrompt: Bool?
        /// 静音窗跳过（P12-3）。**缺省开**，见 `AppConfig.speechGatePolicy`。
        ///
        /// 老配置里没有这一项时解出来是 nil —— 那是「从没配过」，必须走缺省（开），
        /// 不能因为字段缺失就默默关掉：门控挡的是已实测四次的静音幻觉，
        /// 关掉之后静音窗会重新送进模型，长出像真话的句子
        var speechGate: Bool?
    }

    private static let configURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("config.json")
    }()

    /// 一份配置的落身之处：**哪个文件** + 它的内存副本。
    ///
    /// 内存副本装在一个带锁的盒子里而不是直接用 `static var`：设置界面要在
    /// 主线程写它，而签名、上传那些路径是从后台线程读的，Swift 6 会（正确地）
    /// 拒绝一个裸的可变全局量。用 `static let` 持有盒子本身——不可变的
    /// 全局量是安全的，变化的部分关在锁里。
    ///
    /// **为什么文件地址是构造参数，而不是写死那一条路径**：`selfTest()` 要做
    /// 落盘往返，而往返必须发生在**临时目录**里。之前的写法是直接动用户真实的
    /// `config.json`——先备份成 `.selftest-backup`、写完测试值再搬回来。那条路上
    /// 任何一次中途退出（崩溃、被 kill、断电）都会让用户的密钥停在「真文件已删、
    /// 备份还在旁边」的状态，而那份文件里是 COS / DeepSeek / Tavily 的真钥匙，
    /// 没有第二份。所以「读写哪个文件」变成了参数：自检拿一个临时路径走
    /// **同一条**编解码 + chmod 路径，真文件一个字节都不碰。
    final class Store: @unchecked Sendable {
        let url: URL
        private let lock = NSLock()
        private var value: Config

        init(url: URL) {
            self.url = url
            self.value = Store.read(url)
        }

        /// 读不出 / 解不开 → 空配置。**不抛**：没有配置文件是正常状态
        /// （第一次启动就是这个），把它变成一个要调用方处理的错误，
        /// 只会让每个读取点都多一段「读不到就当作空」的样板
        static func read(_ url: URL) -> Config {
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(Config.self, from: data)
            else {
                return Config()
            }
            return config
        }

        var current: Config {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }

        /// 从磁盘重读一份，并让后续读取看到它
        /// 写要走 `current` 的 setter，**不能直接给 `value` 赋值**：读取方
        /// （`COSService.fetchCredentials` 在通用执行器上）与主线程的
        /// `save()` 可以并发，绕过锁就是一个 `Config` 结构体的无锁读写。
        /// 独立核验者在 P12-2 抓到过这一处——重构搬字段时把带锁的 setter 漏了
        func reload() { current = Store.read(url) }

        /// 落盘并让后续读取立刻看到新值
        func save(_ config: Config) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            // 不转义斜杠：URL 里全是 /，转义了就没法读也没法手工核对
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(config).write(to: url, options: .atomic)

            // 这文件里躺着 COS 密钥和 API key，同机器上的其他账户不该读得到。
            // 先建再 chmod：写的时候是原子替换，权限得在文件存在之后设
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )

            current = config
        }
    }

    private static let store = Store(url: configURL)

    /// 文件里现在写的是什么。
    ///
    /// 刻意**不含**环境变量的覆盖：环境变量是只读的一层，用户在界面上
    /// 改不了，把它显示出来只会让人对着一个改不动的值发懵。
    static var current: Config { store.current }

    /// 从磁盘重读一份。
    ///
    /// 只有 `save()` 会更新内存副本，所以文件被**这个进程之外**的东西改过
    /// 之后（用户自己拿编辑器改），内存里那份就是过期的——不重新读，界面
    /// 会拿着旧值当真。
    static func reload() { store.reload() }

    /// 落盘并让后续读取立刻看到新值
    static func save(_ config: Config) throws { try store.save(config) }

    private static func value(env: String, file: String?) -> String? {
        if let raw = ProcessInfo.processInfo.environment[env],
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return raw
        }
        if let file, !file.trimmingCharacters(in: .whitespaces).isEmpty {
            return file
        }
        return nil
    }

    static var deepSeekAPIKey: String? {
        value(env: "DEEPSEEK_API_KEY", file: store.current.deepSeekAPIKey)
    }

    /// 音源。`CLASSROOM_AUDIO_SOURCE=system` 可强制覆盖（探针用）
    static var audioSource: String {
        let raw = value(env: "CLASSROOM_AUDIO_SOURCE", file: store.current.audioSource)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "system" ? "system" : "mic"
    }

    static var usesSystemAudio: Bool { audioSource == "system" }

    /// 悬浮字幕开关（`CLASSROOM_SUBTITLE_OVERLAY=1` 可强制打开，探针/演示用）
    static var subtitleOverlayEnabled: Bool {
        if let raw = value(env: "CLASSROOM_SUBTITLE_OVERLAY", file: nil) {
            return ["1", "on", "true", "yes"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return store.current.subtitleOverlay ?? false
    }

    /// 转录语言。环境变量 `CLASSROOM_LANGUAGE` 可覆盖（探针要能指定语言跑同一段音频）
    static var transcriptionLanguage: String {
        LanguagePreference.normalize(value(env: "CLASSROOM_LANGUAGE", file: store.current.transcriptionLanguage))
    }

    static var searchProvider: String {
        value(env: "SEARCH_PROVIDER", file: store.current.searchProvider)?
            .lowercased() ?? "tavily"
    }

    /// Obsidian vault 目录。没有就是没选过，界面会弹一次选择框
    static var obsidianVaultPath: String? {
        value(env: "OBSIDIAN_VAULT", file: store.current.obsidianVaultPath)
    }

    /// 记住 vault 目录。写盘失败就**静默算了**：这只影响「下次要不要再问一次」，
    /// 不该因为存不下偏好就让导出失败——用户这一刻要的是笔记落进 vault
    static func setObsidianVaultPath(_ path: String) {
        var config = store.current
        config.obsidianVaultPath = path
        try? save(config)
    }

    static var searchAPIKey: String? {
        value(env: "SEARCH_API_KEY", file: store.current.searchAPIKey)
    }

    // MARK: - 腾讯云 COS

    static var cosBucket: String? {
        value(env: "COS_BUCKET", file: store.current.cosBucket)
    }

    static var cosRegion: String? {
        value(env: "COS_REGION", file: store.current.cosRegion)
    }

    static var cosSTSURL: String? {
        value(env: "COS_STS_URL", file: store.current.cosSTSURL)
    }

    /// COS 端点。没显式配就用 `https://{bucket}.cos.{region}.myqcloud.com` 推导。
    static var cosEndpoint: String? {
        endpoint(
            explicit: value(env: "COS_ENDPOINT", file: store.current.cosEndpoint),
            bucket: cosBucket,
            region: cosRegion
        )
    }

    /// 端点的推导规则，抽成一个**纯函数**。
    ///
    /// 抽出来的理由只有一个：推导规则要能被断言，而全局那个
    /// `cosEndpoint` 读的是全局 store——想在自检里喂它一组值，就得先把
    /// 那组值写进**用户真实的 config.json**（上一版的 `--config-selftest`
    /// 正是这么干的）。规则本身与「值从哪来」无关，分开之后自检就能在
    /// 临时目录里把它验干净（见 `selfTest()`）
    static func endpoint(explicit: String?, bucket: String?, region: String?) -> String? {
        if let explicit, !explicit.trimmingCharacters(in: .whitespaces).isEmpty {
            return explicit
        }
        guard let bucket, let region,
              !bucket.trimmingCharacters(in: .whitespaces).isEmpty,
              !region.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return "https://\(bucket).cos.\(region).myqcloud.com"
    }

    static var cosKeyPrefix: String {
        value(env: "COS_KEY_PREFIX", file: store.current.cosKeyPrefix) ?? "recordings"
    }

    /// 永久密钥。填了这两个就不必再配 `cosSTSURL`。
    ///
    /// 正规做法是让后端用 STS 签发临时密钥、客户端永不持有永久密钥。
    /// 但那要求先部署一个 SCF 函数——对「只在自己电脑上用」的场景，
    /// 这道门槛比它挡住的风险还高，于是留这条直填的路。
    ///
    /// **代价要说清楚**：密钥以明文躺在 config.json 里。只适合本机自用，
    /// 别把这份文件拷到别的机器、也别提交进任何仓库。真要上云分发，
    /// 还是回去走 `cosSTSURL`。
    static var cosSecretID: String? {
        value(env: "COS_SECRET_ID", file: store.current.cosSecretID)
    }

    static var cosSecretKey: String? {
        value(env: "COS_SECRET_KEY", file: store.current.cosSecretKey)
    }

    /// 是否走「直填永久密钥」这条路（决定界面上的提示文案）
    static var usesCOSDirectKeys: Bool {
        cosSecretID != nil && cosSecretKey != nil
    }

    /// 凭证来源：要么有个签发后端，要么直填了永久密钥。两者有其一即可。
    static var isCOSConfigured: Bool {
        cosEndpoint != nil && (cosSTSURL != nil || usesCOSDirectKeys)
    }

    /// 麦克风软件增益档。认不出来的值回落 AUTO（见 `MicGainMode.of`）。
    ///
    /// 允许环境变量覆盖，是为了无头自检能指定档位跑——
    /// 例如 `MIC_GAIN=off ClassroomTranscriber --mic-selftest`。
    static var micGain: MicGainMode {
        MicGainMode.of(value(env: "MIC_GAIN", file: store.current.micGain))
    }

    /// 课堂提问检测灵敏度。认不出来的值回落 NORMAL（见 `QuestionSensitivity.of`）。
    static var questionSensitivity: QuestionSensitivity {
        QuestionSensitivity.of(value(env: "QUESTION_SENSITIVITY", file: store.current.questionSensitivity))
    }

    /// 段落定稿后是否自动联网核查。配置文件里没写这一项时判定为 false——
    /// 「没配过」和「明确关掉」在结果上是同一件事：不自动花钱。
    /// 环境变量只认这几个真值写法，其余（含 "0" / "false"）都是关。
    static var autoFactCheck: Bool {
        let raw = value(
            env: "AUTO_FACT_CHECK",
            file: store.current.autoFactCheck.map { $0 ? "true" : "false" }
        )
        guard let raw else { return false }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    /// 实时转录后端。认不出来的值回落 `.apple`（见 `TranscriptionBackend.of`）。
    ///
    /// 允许环境变量覆盖，是为了无头自检能指定后端跑——
    /// 例如 `TRANSCRIBE_BACKEND=whisper ClassroomTranscriber --mic-selftest`。
    /// 这条覆盖**只能选后端，不能改默认值**：文件里没写这一项时仍然是 apple。
    static var transcriptionBackend: TranscriptionBackend {
        .of(value(env: "TRANSCRIBE_BACKEND", file: store.current.transcriptionBackend))
    }

    /// 术语表前移（作为 whisper 的 `initial_prompt`）的开关。**缺省关**。
    ///
    /// **为什么缺省关 —— 这是实测改的，不是一开始就这么写的。**
    /// 原先缺省开，理由是「它什么都不花」（不联网、不调模型，只多塞一个字符串
    /// 参数），代价则是「可能诱发幻觉」。2026-10-13 拿真录音跑了 A/B
    /// （`tools/probes/glossary_prompt.sh`，课堂-20260923 第 3000 秒起 60 秒、
    /// 18 窗、medium，同一段音频同一个模型，唯一变量是这个开关），**代价是实的、
    /// 好处没测到**：
    ///
    ///   项                   关            开（198 token 词表）
    ///   段数                 13            4
    ///   总字数               141           72
    ///   词表命中             0/105         0/105
    ///   逐字符置信度 均/中位 0.775/0.928   0.729/0.876   ← 框架原生置信度，§10
    ///   p10 / <0.5 占比      0.324/21.5%   0.182/25.2%
    ///   质量档位 可信        3             1
    ///
    /// **不是「段数少但更准」——置信度是全面下降的。** 而且有个配对观察：同一段
    /// 音频的同一时刻（00:50），关臂吐的是「(听不懂)」，开臂吐的是
    /// 「这也是正确的方法去看,就是叫做Fractive data analysis。」（标「可信」）。
    /// 这正是注释里担心的那件事的形状。
    ///
    /// **这一趟量不出「词表对得上时有没有好处」**：磁盘上那份内置词表是
    /// 机器学习/线代混合词（machine learning、eigenvalue…），而这节课是另一门课，
    /// 两臂命中都是 0/105。所以这一趟只测到了**危害方向**。
    ///
    /// 而危害方向恰恰是**缺省状态**：一个从没配过术语表的新用户，词表就是那份
    /// 内置的机器学习词，他的课多半不是机器学习。缺省开 = 给每一堂课都注入一段
    /// 无关的英文术语。所以缺省改成关——**要翻回开，需要先有一份「与所录课程
    /// 匹配」的词表上的实测**（[[glossary-course-presets]]：词表必须先于录音）。
    ///
    /// 环境变量 `GLOSSARY_PROMPT`（1/true/yes/on 为开）只给无头 A/B 用。
    static var glossaryPromptEnabled: Bool {
        glossaryPromptEnabled(
            fileValue: store.current.glossaryPrompt,
            envValue: ProcessInfo.processInfo.environment["GLOSSARY_PROMPT"]
        )
    }

    /// 上面那条的**纯函数**形式，两个入参都是显式喂进来的。
    ///
    /// 抽出来是「判据必须能红」的要求：自检要断言「文件里没这一项 → 关」，
    /// 而真实的 accessor 读的是本进程的配置和环境变量——测试进程里那两样
    /// 都不是缺省状态。拿 accessor 断言缺省值，只能在「碰巧是缺省」的时候绿，
    /// 那不是判据，是撞运气。缺省值由 `--glossary-prompt-selftest` 的第八节钉住。
    static func glossaryPromptEnabled(fileValue: Bool?, envValue: String?) -> Bool {
        if let raw = envValue, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return ["1", "true", "yes", "on"].contains(raw.lowercased())
        }
        // 文件里没写这一项 = 从没配过。这不是「用户关掉了」——
        // 两种情形在结果上不同：没配过要走缺省（关，理由见上），配成 true 才是开
        guard let fileValue else { return false }
        return fileValue
    }

    // MARK: - 静音窗跳过（P12-3）

    /// 静音门控的开关，**两步裁决**：环境变量设了 → 按它（探针/开发的强制覆盖）；
    /// 没设 → 设置页那一项；文件里也没有这一项 → **开**。
    ///
    /// **为什么环境变量优先**：它是探针的强制覆盖。A/B 要拿同一份二进制、
    /// 同一条录音、只换这一个变量跑两臂，让「设置页里存的是什么」参与进来
    /// 就让两臂不再只差一个变量了。所以探针设了它就必须盖过生产设置；
    /// 没设时才轮到用户在界面上选的那个值。两者不打架的判据在
    /// `AppConfig.selfTest()` 与 `SpeechGate.selfTest()` 里各钉了一组边界值。
    ///
    /// **为什么缺省开**：门控挡的是**已经实测过四次**的静音幻觉（见 `SpeechGate`
    /// 类型注释）；它省的是算力，而算力是用户自己的。缺省关会让「录一节课、
    /// 回来看转录」在没人说话的地方多出一堆像真话的句子——那是内容层面的坏，
    /// 比多花几秒算力严重得多。但判据在这条录音上只有 0.4 dB 的 p90 余量，
    /// 「人离麦很远、说话很小声」那个边界没标定过（`SpeechGate` 末尾的 ⚠️），
    /// 所以**必须给用户一个关得掉的开关**——这就是 P12-3 的存在理由。
    static var speechGatePolicy: SpeechGatePolicy {
        SpeechGatePolicy.resolve(
            fileValue: store.current.speechGate,
            envValue: ProcessInfo.processInfo.environment[SpeechGatePolicy.environmentKey]
        )
    }

    /// 上面那条的**纯函数**形式（布尔）。
    ///
    /// 抽出来的理由和 `glossaryPromptEnabled(fileValue:envValue:)` 一样：自检要断言
    /// 「文件里没这一项 → 开」，而真实 accessor 读的是本进程的配置和环境变量——
    /// 拿它断言缺省值只能撞运气。设置页的 `reload()` 也走这一条，两处用的是同一个
    /// 纯函数，不会出现「界面缺省」和「无头缺省」各写一个 `?? true` 然后分家
    static func speechGateEnabled(fileValue: Bool?, envValue: String?) -> Bool {
        SpeechGatePolicy.resolve(fileValue: fileValue, envValue: envValue) == .on
    }

    static var configFilePath: String { configURL.path }

    /// 供 UI 提示用：哪些能力当前可用
    static var statusLines: [String] {
        var lines: [String] = []
        lines.append(deepSeekAPIKey == nil ? "❌ DeepSeek 密钥未配置" : "✅ DeepSeek 密钥已配置")
        lines.append(searchAPIKey == nil
            ? "❌ 搜索密钥未配置（\(searchProvider)）"
            : "✅ 搜索密钥已配置（\(searchProvider)）")
        if cosEndpoint == nil {
            lines.append("❌ COS 未配置：先填 cosBucket 与 cosRegion")
        } else if usesCOSDirectKeys {
            lines.append("✅ COS 已配置（永久密钥）→ \(cosEndpoint ?? "")")
        } else if cosSTSURL != nil {
            lines.append("✅ COS 已配置（STS 后端）→ \(cosEndpoint ?? "")")
        } else {
            lines.append("❌ COS 缺凭证：填 cosSecretID + cosSecretKey，或填 cosSTSURL")
        }
        lines.append("   配置文件: \(configFilePath)")
        return lines
    }

    /// 配置存取的往返自检。
    ///
    /// 要防的是「填了、点了保存、其实没生效」——这类 bug 不报错，只是
    /// 让用户下次打开 App 发现又空了，然后再填一遍。
    ///
    /// **往返在临时目录里做，真实配置文件一个字节都不碰。** 上一版是直接动
    /// 用户那份 `config.json`（先备份成 `.selftest-backup`、写完测试值再搬回
    /// 来）——那条路上任何一次中途退出（崩溃、被 kill、断电）都会让用户的密钥
    /// 停在「真文件已删、备份还在旁边」的状态，而那份文件里是 COS / DeepSeek /
    /// Tavily 的真钥匙，没有第二份。所以现在：走的是**同一条**编解码 + chmod
    /// 路径（同一个 `Store` 类型、同一个 `save`），只是文件的地址换成了临时目录，
    /// 而「真文件没被动过」本身是这一节最后一条判据（指纹前后一致）。
    ///
    /// 输出里**不打印任何密钥值**，只说长度和前缀。
    static func selfTest() -> [String] {
        var lines: [String] = []

        // 真实配置的指纹（存在与否 / 大小 / 修改时间 / inode）。**只取元数据，
        // 不读内容**——这一节从头到尾都不该打开那个文件
        let realBefore = fingerprint(of: configURL)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-config-selftest-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: tmpDir.appendingPathComponent("config.json"))
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        lines.append("  ✅ 往返在临时目录里做 → \(store.url.path)")

        // 1. 写入一份每个字段都有值的配置
        var seed = Config()
        seed.deepSeekAPIKey = "sk-SENTINEL-deepseek"
        seed.searchProvider = "tavily"
        seed.searchAPIKey = "tvly-SENTINEL-search"
        seed.cosBucket = "sentinel-1300000000"
        seed.cosRegion = "ap-shanghai"
        seed.cosSecretID = "AKIDSENTINEL"
        seed.cosSecretKey = "sentinel-secret-key"
        seed.cosKeyPrefix = "sentinel-prefix"
        // 偏好也要一起验：它和密钥走的是同一条落盘路径，
        // 「填了、点了保存、下次打开又回到默认」在这两个字段上一样致命
        seed.micGain = "x3"
        seed.questionSensitivity = "low"
        seed.autoFactCheck = true
        seed.transcriptionBackend = "whisper"
        // 这一项**写的是 true，不是它的缺省值（false）**：这条自检验的是
        // 「落盘往返」，写一个和缺省相同的值就分不出「存进去了」和
        // 「没存、读的时候回落到了缺省」——那正是这条自检要抓的 bug
        seed.glossaryPrompt = true
        // 同理：静音窗跳过的缺省是 true，这里写 false。写 true 的话
        // 「没存进去」和「存对了」读出来一模一样
        seed.speechGate = false

        do {
            try store.save(seed)
            lines.append("  ✅ save() 未抛错")
        } catch {
            return lines + ["  ❌ save() 失败：\(error.localizedDescription)"]
        }

        // 2. 内存副本要立刻生效，不能等下次启动。
        //    这里问的是**这份 store** 的内存副本（上一版问的是全局那个，
        //    因为那时测试值就写在全局那份文件里；性质没变，主语变了）
        let inMemory = store.current
        lines.append("  \(inMemory.cosBucket == seed.cosBucket ? "✅" : "❌") 内存副本已更新（cosBucket）")
        // 已配置与端点推导都走纯函数问同一组值——不再依赖「先把值写进真文件」
        let configured = endpoint(explicit: nil, bucket: inMemory.cosBucket, region: inMemory.cosRegion) != nil
            && inMemory.cosSecretID != nil && inMemory.cosSecretKey != nil
        lines.append("  \(configured ? "✅" : "❌") 只要字段齐就是「已配置」（永久密钥那条路，纯函数判定）")
        let derived = endpoint(explicit: nil, bucket: inMemory.cosBucket, region: inMemory.cosRegion)
        lines.append("  \(derived == "https://sentinel-1300000000.cos.ap-shanghai.myqcloud.com" ? "✅" : "❌") 端点推导正确 → \(derived ?? "nil")")
        // 显式配的端点优先于推导；缺 bucket / region 时给 nil 而不是半截 URL
        let explicitWins = endpoint(explicit: "https://explicit.example.com", bucket: "b", region: "r")
            == "https://explicit.example.com"
        let blankIsNotExplicit = endpoint(explicit: "   ", bucket: nil, region: nil) == nil
        let halfConfigIsNil = endpoint(explicit: nil, bucket: "b", region: nil) == nil
        lines.append("  \(explicitWins && blankIsNotExplicit && halfConfigIsNil ? "✅" : "❌") 端点规则：显式优先、空白不算显式、缺 bucket/region 给 nil")

        // 静音窗跳过（P12-3）：持久化与优先级。**三条各自钉一个真实失效形态**：
        //
        //   ① 缺省：老配置里没有 `speechGate` 这一项 → 必须读成**开**。
        //      不能因为升级后字段缺失就默默关掉（那等于把静音幻觉放回来）。
        //      老配置必须是一份**真的能解出来的**旧 JSON：随手写一个坏文件
        //      也能得到 nil → 也读成开，那样这条判据就是跟着被测缺省走的空转
        //      （所以同时断言旧配置里的其它字段读出来了）。
        //   ② 落盘往返：写 false 重读得 false、写 true 重读得 true。
        //      两次都用一个**新建的 Store** 从磁盘读，而不是复用内存副本——
        //      复用内存的话「只改内存没写盘」照样绿。
        //   ③ 优先级：环境变量设了就按它，没设才看文件；空白视同没设。
        //
        // **这一段放在「3. 真的落盘了吗」之前**：那一节在文件读不回来时直接
        // `return`。放它后面的话，把写盘那一行去掉（变异②）会让整节提前返回，
        // 这三条根本轮不到打印——「红」变成了「没有这一行」，而不是「这一行是 ❌」。
        let legacyURL = tmpDir.appendingPathComponent("legacy-config.json")
        let legacyJSON = #"{"deepSeekAPIKey": "sk-legacy-sentinel", "autoFactCheck": true}"#
        let legacyWrote = (try? legacyJSON.write(to: legacyURL, atomically: true, encoding: .utf8)) != nil
        let legacyConfig = Store(url: legacyURL).current
        let legacyDecoded = legacyWrote && legacyConfig.deepSeekAPIKey == "sk-legacy-sentinel"
        let legacyDefault = SpeechGatePolicy.resolve(fileValue: legacyConfig.speechGate, envValue: nil)
        lines.append("  \(legacyDecoded && legacyDefault == .on ? "✅" : "❌") 静音窗跳过·老配置没有该字段 → 读出来是\(legacyDefault.label)（\(legacyDecoded ? "旧 JSON 正常解出，其它字段在" : "旧 JSON 没解出来，这条不成立")）")

        let gateURL = tmpDir.appendingPathComponent("speech-gate.json")
        var gateSeed = Config()
        gateSeed.speechGate = false
        let wroteOff = (try? Store(url: gateURL).save(gateSeed)) != nil
        let rereadOff = Store(url: gateURL).current.speechGate
        gateSeed.speechGate = true
        let wroteOn = (try? Store(url: gateURL).save(gateSeed)) != nil
        let rereadOn = Store(url: gateURL).current.speechGate
        lines.append("  \(wroteOff && rereadOff == false && wroteOn && rereadOn == true ? "✅" : "❌") 静音窗跳过·落盘往返：写 false → 重读 \(rereadOff.map { $0 ? "true" : "false" } ?? "nil")，写 true → 重读 \(rereadOn.map { $0 ? "true" : "false" } ?? "nil")")

        let envOffWins = SpeechGatePolicy.resolve(fileValue: true, envValue: "off")
        let envOnWins = SpeechGatePolicy.resolve(fileValue: false, envValue: "1")
        let blankIsUnset = SpeechGatePolicy.resolve(fileValue: false, envValue: "   ")
        lines.append("  \(envOffWins == .off && envOnWins == .on && blankIsUnset == .off ? "✅" : "❌") 静音窗跳过·优先级：环境变量 off 盖过文件 true → \(envOffWins.label)，环境变量 1 盖过文件 false → \(envOnWins.label)，空白视同没设 → 按文件 \(blankIsUnset.label)")

        // 3. 真的落盘了吗——重新从文件里读一遍，不信内存
        let onDisk: Config? = {
            guard let data = try? Data(contentsOf: store.url) else { return nil }
            return try? JSONDecoder().decode(Config.self, from: data)
        }()
        guard let onDisk else {
            return lines + ["  ❌ 文件读不回来"]
        }

        let fields: [(String, Bool)] = [
            ("deepSeekAPIKey", onDisk.deepSeekAPIKey == seed.deepSeekAPIKey),
            ("searchAPIKey", onDisk.searchAPIKey == seed.searchAPIKey),
            ("cosBucket", onDisk.cosBucket == seed.cosBucket),
            ("cosRegion", onDisk.cosRegion == seed.cosRegion),
            ("cosSecretID", onDisk.cosSecretID == seed.cosSecretID),
            ("cosSecretKey", onDisk.cosSecretKey == seed.cosSecretKey),
            ("cosKeyPrefix", onDisk.cosKeyPrefix == seed.cosKeyPrefix),
            ("micGain", onDisk.micGain == seed.micGain),
            ("questionSensitivity", onDisk.questionSensitivity == seed.questionSensitivity),
            ("autoFactCheck", onDisk.autoFactCheck == seed.autoFactCheck),
            ("transcriptionBackend", onDisk.transcriptionBackend == seed.transcriptionBackend),
            ("glossaryPrompt", onDisk.glossaryPrompt == seed.glossaryPrompt),
            ("speechGate", onDisk.speechGate == seed.speechGate),
        ]
        let lost = fields.filter { !$0.1 }.map(\.0)
        lines.append("  \(lost.isEmpty ? "✅" : "❌") \(fields.count) 个字段全部落盘（漏掉：\(lost.isEmpty ? "无" : lost.joined(separator: ", "))）")

        // 档位名认不出来时必须回落 AUTO，而不是变成一个「没有增益」的默认值
        lines.append("  \(MicGainMode.of("x3") == .x3 && MicGainMode.of("笔误") == .auto && MicGainMode.of(nil) == .auto ? "✅" : "❌") 增益档解析：x3 → x3，无效值 / 缺省 → auto")

        // 这一条守的是接线那一包的硬约束：**默认后端必须是 Apple**。
        // 翻默认值必须是有人显式改这一行、并且在这里看见红——不是某次
        // 顺手重构把它带过去的（那会让「明天照常录课」变成一句空话）
        lines.append("  \(TranscriptionBackend.of("whisper") == .whisper && TranscriptionBackend.of("APPLE") == .apple && TranscriptionBackend.of("笔误") == .apple && TranscriptionBackend.of(nil) == .apple ? "✅" : "❌") 后端解析：whisper → whisper；APPLE / 无效值 / 缺省 → apple（默认值）")

        // 术语表前移的缺省值。**单独钉一条**的理由和后端那条一样：
        // 它决定「明天照常录课」时 whisper 收到的参数是什么，翻默认值
        // 必须是一次看得见红的显式改动，不是某次重构顺手带过去的。
        // 这一条喂的是**纯函数**的边界值，不是「读一次真实配置看看」：
        //   文件里没写 + 没环境变量   → 关（缺省；2026-10-13 由 A/B 从「开」翻过来）
        //   文件里写了 false          → 关（用户显式关掉）
        //   文件里写了 true           → 开（用户显式打开，不许被缺省盖过）
        //   文件写了 false + 环境变量 1 → 开（环境变量只给无头 A/B 用，优先级更高）
        let dflt = AppConfig.glossaryPromptEnabled(fileValue: nil, envValue: nil)
        let offByFile = AppConfig.glossaryPromptEnabled(fileValue: false, envValue: nil)
        let onByFile = AppConfig.glossaryPromptEnabled(fileValue: true, envValue: nil)
        let envWins = AppConfig.glossaryPromptEnabled(fileValue: false, envValue: "1")
        lines.append("  \(!dflt && !offByFile && onByFile && envWins ? "✅" : "❌") 术语表前移开关：缺省 \(dflt ? "开" : "关")、文件写 false → \(offByFile ? "开" : "关")、文件写 true → \(onByFile ? "开" : "关")、环境变量 1 覆盖 → \(envWins ? "开" : "关")")

        // 4. 权限：这文件里有密钥，同机其他账户不该读得到
        let mode = (try? FileManager.default.attributesOfItem(atPath: store.url.path))?[.posixPermissions] as? NSNumber
        lines.append("  \(mode?.intValue == 0o600 ? "✅" : "❌") 权限 600（实测 \(mode.map { String($0.intValue, radix: 8) } ?? "未知")）")

        // 5. 空白要折算成 nil，不能存进去一个空串——读配置那边用「非空」
        //    判断是否已配置，空串会被当成「配了但值是空的」
        var blanked = seed
        blanked.searchAPIKey = "   "
        do {
            try store.save(blanked)
            let round = store.current
            lines.append("  \(round.searchAPIKey == "   " ? "✅" : "❌") 原文原样保留（折算成 nil 由设置层负责，不是存储层）")
        } catch {
            lines.append("  ❌ 二次保存失败：\(error.localizedDescription)")
        }

        // 6. **本节的底线判据**：用户的真实配置文件从头到尾没被碰过。
        //
        //    这一条是整节的存在理由——前面每一条都在验「往返对不对」，
        //    只有这一条在验「你的钥匙还在不在原处」。指纹比的是元数据
        //    （存在与否 / 大小 / 修改时间 / inode）：内容变了这几项必变，
        //    而元数据不泄密。
        //
        //    它**能红**（2026-10-15 实测）：把上面那行 `Store(url: tmpDir…)`
        //    改成 `Store(url: configURL)`（让这一节重新去动真文件），同一份
        //    输出的末条立刻变成「❌ 真实配置全程未被触碰（指纹变了：不存在，
        //    现在 存在 · 432 字节 · mtime … · inode …）」。注意这一条红了
        //    **进程退出码还是 0**——自检是打印式的，判它在那个 ✅/❌ 字样上，
        //    不在退出码上（`exit_codes.sh` 里也是这么断言的）。
        //
        //    ⚠️ 那次注入必须配 `CFFIXED_USER_HOME=$(mktemp -d)`，**`HOME=` 不管用**：
        //    macOS 上 Foundation 的 `.applicationSupportDirectory`（和
        //    `NSHomeDirectory()`）根本不看 `$HOME`，看的是 `CFFIXED_USER_HOME`。
        //    实测：`HOME=/tmp/x` 之后 `NSHomeDirectory()` 仍是 `/Users/you`；
        //    `CFFIXED_USER_HOME=/tmp/x` 才变成 `/tmp/x`。**按 `HOME=` 写等于没隔离**，
        //    那一下就是拿用户那份装着 COS / DeepSeek / Tavily 真钥匙的
        //    `config.json` 去写 `sentinel-` 那组值——真文件、无第二份。
        //    注入跑完回头比一次真文件的 sha256 确认没被碰（实测一致）。
        let realAfter = fingerprint(of: configURL)
        lines.append("  \(realAfter == realBefore ? "✅" : "❌") 真实配置全程未被触碰（\(realAfter == realBefore ? "指纹一致" : "指纹变了")：\(realBefore)，现在 \(realAfter)）")

        return lines
    }

    /// 文件指纹：存在与否 / 大小 / 修改时间 / inode。**不读内容**。
    ///
    /// 用途只有一个：证明某个文件在这段代码前后**没被动过**。
    /// 拿内容哈希也行，但那意味着要把一份装着明文的密钥文件读进内存——
    /// 为了证明「我没碰它」而去读它，方向反了。
    static func fingerprint(of url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "不存在"
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? -1
        return String(format: "存在 · %lld 字节 · mtime %.3f · inode %d", size, mtime, inode)
    }

    /// 生成模板配置文件，方便用户填
    static func writeTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        // 一律留空，**不要写占位说明文字**：JSON 没有注释，那些文字会被
        // 当成真的值读进去——`cosBucket` 里躺着一句中文提示，端点就会被
        // 拼成 `https://填你的存储桶名....cos.ap-guangzhou.myqcloud.com`。
        // 「去哪儿拿这些值」由设置页负责讲，那才是它该待的地方。
        let template = """
        {
          "deepSeekAPIKey": "",
          "searchProvider": "tavily",
          "searchAPIKey": "",
          "cosBucket": "",
          "cosRegion": "ap-guangzhou",
          "cosSecretID": "",
          "cosSecretKey": "",
          "cosSTSURL": "",
          "cosEndpoint": "",
          "cosKeyPrefix": "recordings",
          "micGain": "auto",
          "questionSensitivity": "normal",
          "autoFactCheck": false,
          "transcriptionBackend": "apple",
          "glossaryPrompt": true,
          "speechGate": true
        }
        """
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? template.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
