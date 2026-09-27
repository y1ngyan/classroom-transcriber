import Foundation
import Observation

/// 设置页的状态。
///
/// 存在的理由：配置原本只能手改 `~/Library/Application Support/` 下的
/// 一个隐藏 JSON。那个路径从 Finder 要走「前往文件夹」才够得着，改错了
/// 也没有任何反馈——填完了到底通不通，只能回去录一节课碰运气。
/// 这里把它变成一个能粘贴、能当场验证的表单。
@MainActor
@Observable
final class SettingsStore {

    // MARK: - 表单字段

    var deepSeekAPIKey = ""
    var searchProvider = "tavily"
    var searchAPIKey = ""
    var cosBucket = ""
    var cosRegion = "ap-guangzhou"
    var cosSecretID = ""
    var cosSecretKey = ""
    var cosKeyPrefix = "recordings"

    /// 麦克风软件增益档。默认 AUTO——老师小声、坐得远是常态，
    /// 而这一档正是为那个场景准备的，还得带噪声门才不会连底噪一起放大。
    var micGain: MicGainMode = .auto

    /// 课堂提问检测灵敏度。默认 NORMAL：强疑问结构直接判，弱疑问词要旁证——
    /// 讲课陈述里全是「什么」「怎么」，没有这道门槛提问列表会被讲课淹没。
    var questionSensitivity: QuestionSensitivity = .normal

    /// 实时转录后端。**默认 APPLE**，见 `TranscriptionBackend`——
    /// 这不是「哪个更准」的取舍，是「默认状态下不许把课录丢」的取舍。
    var backend: TranscriptionBackend = .apple

    /// 段落定稿后是否自动联网核查。默认关闭：核查要联网、要花检索和 LLM
    /// 额度，这是用户自己的账。开着的时候每段定稿都会自动跑一次，一节课
    /// 下来是几十次请求——默认替他花掉不合适。关掉不影响手动核查。
    var autoFactCheck = false

    // MARK: - 状态

    private(set) var saveMessage = ""
    private(set) var isTestingCOS = false
    private(set) var isTestingSearch = false
    private(set) var cosTestResult: TestResult?
    private(set) var searchTestResult: TestResult?
    /// 「导出诊断日志」的结果。和另外两个分开：那个导出不是一次「测试」，
    /// 而是把文件写到桌面上——写没写成、写到哪儿，都得说得出来
    private(set) var diagnosticsExport: TestResult?

    /// 有过一次「看起来在跑、其实没生效」之后，测试结果就带上了颜色和图标
    struct TestResult {
        var ok: Bool
        var detail: String
    }

    init() { reload() }

    /// 从磁盘读回表单。每次进设置页都重来一遍：这一页显示的就该是
    /// 文件里真实的值，而不是上次编辑残留的草稿。
    /// 把诊断日志导出成一个文件。
    ///
    /// **落在桌面上**，不是落在 `logs/` 旁边：导出这件事的意义就是把它交给
    /// 别人（或换个时间自己看），而 Application Support 那个路径从 Finder
    /// 要走「前往文件夹」才够得着。路径原样显示在结果里，用户不用猜
    ///
    /// 条数给 5000：默认上限 1 MB、每条约 120 字节，那是**全部**的量级，
    /// 所以「导出」导出的是整份现场，不是最近一小段
    func exportDiagnostics() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "课堂转录-诊断日志-\(formatter.string(from: Date())).txt"
        let url = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)

        let exported = DiagnosticLog.exportText(directory: DiagnosticLog.defaultDirectory, limit: 5000)
        do {
            try exported.text.write(to: url, atomically: true, encoding: .utf8)
            diagnosticsExport = TestResult(
                ok: true,
                detail: "已导出 \(exported.count) 条（\(exported.fileCount) 个文件）到 \(url.path)")
        } catch {
            diagnosticsExport = TestResult(
                ok: false, detail: "导出失败：\(error.localizedDescription)")
        }
    }

    func reload() {
        // 先让 AppConfig 自己重读一遍文件。少了这一步，这里读到的是
        // 进程启动时那份内存副本——文件被外部改过（用户拿编辑器改、
        // 或者别的进程写的）就完全看不见，而这一页显示的正是「文件里
        // 是什么」，不是「启动时是什么」
        AppConfig.reload()
        let config = AppConfig.current
        deepSeekAPIKey = config.deepSeekAPIKey ?? ""
        searchProvider = config.searchProvider ?? "tavily"
        searchAPIKey = config.searchAPIKey ?? ""
        cosBucket = config.cosBucket ?? ""
        cosRegion = config.cosRegion ?? "ap-guangzhou"
        cosSecretID = config.cosSecretID ?? ""
        cosSecretKey = config.cosSecretKey ?? ""
        cosKeyPrefix = config.cosKeyPrefix ?? "recordings"
        micGain = MicGainMode.of(config.micGain)
        questionSensitivity = QuestionSensitivity.of(config.questionSensitivity)
        autoFactCheck = config.autoFactCheck ?? false
        backend = .of(config.transcriptionBackend)
    }

    var configFilePath: String { AppConfig.configFilePath }

    // MARK: - 保存

    func save() {
        var config = AppConfig.current

        // 空白一律折算成 nil 而不是空串：读配置那边用「非空」判断是否
        // 已配置，留一个 "" 进去会让它显示成「已配置但值是空的」
        config.deepSeekAPIKey = trimmed(deepSeekAPIKey)
        config.searchProvider = trimmed(searchProvider) ?? "tavily"
        config.searchAPIKey = trimmed(searchAPIKey)
        config.cosBucket = trimmed(cosBucket)
        config.cosRegion = trimmed(cosRegion)
        config.cosSecretID = trimmed(cosSecretID)
        config.cosSecretKey = trimmed(cosSecretKey)
        config.cosKeyPrefix = trimmed(cosKeyPrefix) ?? "recordings"
        // 档位一律写出显式值（含 auto），不靠「缺省即默认」——
        // 配置文件是给人看的，留空之后没人知道空代表哪一档
        config.micGain = micGain.rawValue
        config.questionSensitivity = questionSensitivity.rawValue
        config.autoFactCheck = autoFactCheck
        config.transcriptionBackend = backend.rawValue

        do {
            try AppConfig.save(config)
            saveMessage = "✅ 已保存并生效"
            // 换了凭证就得重新测，旧的结论已经不作数了
            cosTestResult = nil
            searchTestResult = nil
        } catch {
            saveMessage = "❌ 保存失败：\(error.localizedDescription)"
        }
    }

    private func trimmed(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    var hasUnsavedChanges: Bool {
        let config = AppConfig.current
        // 档位按解析后的值比，不按字符串比：文件里是 nil 和文件里写着 "auto"
        // 是同一个档，用字符串比会把一个没改过的设置报成「有未保存的改动」
        return micGain != MicGainMode.of(config.micGain)
            || questionSensitivity != QuestionSensitivity.of(config.questionSensitivity)
            || backend != .of(config.transcriptionBackend)
            || trimmed(deepSeekAPIKey) != config.deepSeekAPIKey
            || trimmed(searchAPIKey) != config.searchAPIKey
            || trimmed(cosBucket) != config.cosBucket
            || trimmed(cosRegion) != config.cosRegion
            || trimmed(cosSecretID) != config.cosSecretID
            || trimmed(cosSecretKey) != config.cosSecretKey
            || trimmed(cosKeyPrefix) != config.cosKeyPrefix
    }

    func clearMessages() {
        saveMessage = ""
    }

    // MARK: - 测试

    /// 真查一次。只验证「密钥格式像不像」没有意义——格式对但额度用光、
    /// 或者权限不够，都要到用户第一次核查时才炸出来。
    func testSearch() async {
        guard !isTestingSearch else { return }
        isTestingSearch = true
        defer { isTestingSearch = false }

        // 测试跑的是表单里当前的值，不是存盘的值：用户改完不点保存就点
        // 测试，想验的显然是眼前这串字符
        save()

        do {
            let hits = try await SearchService.search(query: "梯度下降", maxResults: 2)
            if hits.isEmpty {
                searchTestResult = TestResult(ok: false, detail: "连通了，但一条结果都没有（额度或权限问题？）")
            } else {
                searchTestResult = TestResult(
                    ok: true,
                    detail: "连通，返回 \(hits.count) 条。示例：\(hits[0].title)"
                )
            }
        } catch {
            searchTestResult = TestResult(ok: false, detail: error.localizedDescription)
        }
    }

    /// 真往桶里传一个小文件。
    ///
    /// 只调 `fetchCredentials` 是不够的——那只证明密钥拿得到，证明不了
    /// 它对**这个桶**有写权限，也证明不了签名能被 COS 接受。签名的错法
    /// 五花八门，唯一可靠的验证就是让服务端真的收一次。
    func testCOS() async {
        guard !isTestingCOS else { return }
        isTestingCOS = true
        defer { isTestingCOS = false }

        save()

        guard AppConfig.isCOSConfigured else {
            cosTestResult = TestResult(ok: false, detail: "还缺东西：\(cosMissingHint)")
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString.prefix(8)).txt")
        do {
            try "classroom-transcriber 配置自检\n\(stamp)\n".data(using: .utf8)?.write(to: probe)
        } catch {
            cosTestResult = TestResult(ok: false, detail: "建临时文件失败：\(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: probe) }

        do {
            let credentials = try await COSService.fetchCredentials()
            let key = "selftest/probe-\(stamp).txt"
            let state = try await COSService.upload(
                fileURL: probe,
                key: key,
                credentials: credentials,
                // 就一个几百字节的文件，没有值得显示进度的过程
                onStateChange: { _ in }
            )
            cosTestResult = TestResult(
                ok: true,
                detail: "上传成功（\(ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file))）。"
                    + "对象键 \(key) —— 验证完可以在控制台删掉这个 selftest/ 目录"
            )
        } catch {
            cosTestResult = TestResult(ok: false, detail: error.localizedDescription)
        }
    }

    /// 缺哪一项，直接说出来。让用户自己去比对一串字段名是最不友好的做法
    var cosMissingHint: String {
        var missing: [String] = []
        if trimmed(cosBucket) == nil { missing.append("存储桶名") }
        if trimmed(cosRegion) == nil { missing.append("地域") }
        if trimmed(cosSecretID) == nil || trimmed(cosSecretKey) == nil {
            missing.append("SecretId / SecretKey")
        }
        return missing.isEmpty ? "无" : "缺 " + missing.joined(separator: "、")
    }
}
