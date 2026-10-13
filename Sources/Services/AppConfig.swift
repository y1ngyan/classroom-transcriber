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
        /// 是否把术语表作为 whisper 的 `initial_prompt` 送进去（P12-1）。
        /// 缺省见 `AppConfig.glossaryPromptEnabled`——那里的注释写了为什么
        var glossaryPrompt: Bool?
    }

    private static let configURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("config.json")
    }()

    /// 配置的内存副本。
    ///
    /// 装在一个带锁的盒子里而不是直接用 `static var`：设置界面要在主线程
    /// 写它，而签名、上传那些路径是从后台线程读的，Swift 6 会（正确地）
    /// 拒绝一个裸的可变全局量。用 `static let` 持有盒子本身——不可变的
    /// 全局量是安全的，变化的部分关在锁里。
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Config

        init(_ value: Config) { self.value = value }

        var current: Config {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }

    private static let box = Box(loadFromDisk())

    private static func loadFromDisk() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return config
    }

    /// 文件里现在写的是什么。
    ///
    /// 刻意**不含**环境变量的覆盖：环境变量是只读的一层，用户在界面上
    /// 改不了，把它显示出来只会让人对着一个改不动的值发懵。
    static var current: Config { box.current }

    /// 从磁盘重读一份。
    ///
    /// 只有 `save()` 会更新内存副本，所以文件被**这个进程之外**的东西改过
    /// 之后（用户自己拿编辑器改、自检把文件还原回去），内存里那份就是过期的
    /// ——不重新读，界面会拿着旧值当真。自检的还原步骤就踩过这个：文件已经
    /// 还原了，最后打印出来却还是测试用的值。
    static func reload() {
        box.current = loadFromDisk()
    }

    /// 落盘并让后续读取立刻看到新值
    static func save(_ config: Config) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        // 不转义斜杠：URL 里全是 /，转义了就没法读也没法手工核对
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: configURL, options: .atomic)

        // 这文件里躺着 COS 密钥和 API key，同机器上的其他账户不该读得到。
        // 先建再 chmod：写的时候是原子替换，权限得在文件存在之后设
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )

        box.current = config
    }

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
        value(env: "DEEPSEEK_API_KEY", file: box.current.deepSeekAPIKey)
    }

    static var searchProvider: String {
        value(env: "SEARCH_PROVIDER", file: box.current.searchProvider)?
            .lowercased() ?? "tavily"
    }

    static var searchAPIKey: String? {
        value(env: "SEARCH_API_KEY", file: box.current.searchAPIKey)
    }

    // MARK: - 腾讯云 COS

    static var cosBucket: String? {
        value(env: "COS_BUCKET", file: box.current.cosBucket)
    }

    static var cosRegion: String? {
        value(env: "COS_REGION", file: box.current.cosRegion)
    }

    static var cosSTSURL: String? {
        value(env: "COS_STS_URL", file: box.current.cosSTSURL)
    }

    /// COS 端点。没显式配就用 `https://{bucket}.cos.{region}.myqcloud.com` 推导。
    static var cosEndpoint: String? {
        if let explicit = value(env: "COS_ENDPOINT", file: box.current.cosEndpoint) {
            return explicit
        }
        guard let bucket = cosBucket, let region = cosRegion else { return nil }
        return "https://\(bucket).cos.\(region).myqcloud.com"
    }

    static var cosKeyPrefix: String {
        value(env: "COS_KEY_PREFIX", file: box.current.cosKeyPrefix) ?? "recordings"
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
        value(env: "COS_SECRET_ID", file: box.current.cosSecretID)
    }

    static var cosSecretKey: String? {
        value(env: "COS_SECRET_KEY", file: box.current.cosSecretKey)
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
        MicGainMode.of(value(env: "MIC_GAIN", file: box.current.micGain))
    }

    /// 课堂提问检测灵敏度。认不出来的值回落 NORMAL（见 `QuestionSensitivity.of`）。
    static var questionSensitivity: QuestionSensitivity {
        QuestionSensitivity.of(value(env: "QUESTION_SENSITIVITY", file: box.current.questionSensitivity))
    }

    /// 段落定稿后是否自动联网核查。配置文件里没写这一项时判定为 false——
    /// 「没配过」和「明确关掉」在结果上是同一件事：不自动花钱。
    /// 环境变量只认这几个真值写法，其余（含 "0" / "false"）都是关。
    static var autoFactCheck: Bool {
        let raw = value(
            env: "AUTO_FACT_CHECK",
            file: box.current.autoFactCheck.map { $0 ? "true" : "false" }
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
        .of(value(env: "TRANSCRIBE_BACKEND", file: box.current.transcriptionBackend))
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
            fileValue: box.current.glossaryPrompt,
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
    /// 让用户下次打开 App 发现又空了，然后再填一遍。所以这里直接动真实的
    /// 配置文件：**先备份，结束时还原**，中途异常也走 defer。
    ///
    /// 输出里**不打印任何密钥值**，只说长度和前缀。
    static func selfTest() -> [String] {
        var lines: [String] = []
        let backup = configURL.appendingPathExtension("selftest-backup")
        let hadOriginal = FileManager.default.fileExists(atPath: configURL.path)

        if hadOriginal {
            try? FileManager.default.removeItem(at: backup)
            do {
                try FileManager.default.copyItem(at: configURL, to: backup)
                lines.append("  ✅ 已备份原配置 → \(backup.lastPathComponent)")
            } catch {
                return ["  ❌ 备份失败，为免弄丢你的密钥，自检中止：\(error.localizedDescription)"]
            }
        } else {
            lines.append("  ⚠️ 原配置不存在，自检结束后会删掉临时建的这份")
        }

        defer {
            try? FileManager.default.removeItem(at: configURL)
            if hadOriginal { try? FileManager.default.moveItem(at: backup, to: configURL) }
            // 还原完必须重读：不然内存里还留着测试写的值，
            // 自检最后那几行「还原后现状」就是在拿假数据骗人
            reload()
        }

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

        do {
            try save(seed)
            lines.append("  ✅ save() 未抛错")
        } catch {
            return lines + ["  ❌ save() 失败：\(error.localizedDescription)"]
        }

        // 2. 内存副本要立刻生效，不能等下次启动
        let inMemory = current
        lines.append("  \(inMemory.cosBucket == seed.cosBucket ? "✅" : "❌") 内存副本已更新（cosBucket）")
        lines.append("  \(AppConfig.isCOSConfigured ? "✅" : "❌") isCOSConfigured 立刻变 true（永久密钥那条路）")
        lines.append("  \(AppConfig.cosEndpoint == "https://sentinel-1300000000.cos.ap-shanghai.myqcloud.com" ? "✅" : "❌") 端点推导正确 → \(AppConfig.cosEndpoint ?? "nil")")

        // 3. 真的落盘了吗——重新从文件里读一遍，不信内存
        let onDisk: Config? = {
            guard let data = try? Data(contentsOf: configURL) else { return nil }
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
        let mode = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.posixPermissions] as? NSNumber
        lines.append("  \(mode?.intValue == 0o600 ? "✅" : "❌") 权限 600（实测 \(mode.map { String($0.intValue, radix: 8) } ?? "未知")）")

        // 5. 空白要折算成 nil，不能存进去一个空串——读配置那边用「非空」
        //    判断是否已配置，空串会被当成「配了但值是空的」
        var blanked = seed
        blanked.searchAPIKey = "   "
        do {
            try save(blanked)
            let round = current
            lines.append("  \(round.searchAPIKey == "   " ? "✅" : "❌") 原文原样保留（折算成 nil 由设置层负责，不是存储层）")
        } catch {
            lines.append("  ❌ 二次保存失败：\(error.localizedDescription)")
        }

        return lines
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
          "glossaryPrompt": true
        }
        """
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? template.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
