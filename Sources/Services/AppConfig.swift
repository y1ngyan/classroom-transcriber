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
        ]
        let lost = fields.filter { !$0.1 }.map(\.0)
        lines.append("  \(lost.isEmpty ? "✅" : "❌") \(fields.count) 个字段全部落盘（漏掉：\(lost.isEmpty ? "无" : lost.joined(separator: ", "))）")

        // 档位名认不出来时必须回落 AUTO，而不是变成一个「没有增益」的默认值
        lines.append("  \(MicGainMode.of("x3") == .x3 && MicGainMode.of("笔误") == .auto && MicGainMode.of(nil) == .auto ? "✅" : "❌") 增益档解析：x3 → x3，无效值 / 缺省 → auto")

        // 这一条守的是接线那一包的硬约束：**默认后端必须是 Apple**。
        // 翻默认值必须是有人显式改这一行、并且在这里看见红——不是某次
        // 顺手重构把它带过去的（那会让「明天照常录课」变成一句空话）
        lines.append("  \(TranscriptionBackend.of("whisper") == .whisper && TranscriptionBackend.of("APPLE") == .apple && TranscriptionBackend.of("笔误") == .apple && TranscriptionBackend.of(nil) == .apple ? "✅" : "❌") 后端解析：whisper → whisper；APPLE / 无效值 / 缺省 → apple（默认值）")

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
          "transcriptionBackend": "apple"
        }
        """
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? template.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
