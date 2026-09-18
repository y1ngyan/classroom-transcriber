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

    // MARK: - 状态

    private(set) var saveMessage = ""
    private(set) var isTestingCOS = false
    private(set) var isTestingSearch = false
    private(set) var cosTestResult: TestResult?
    private(set) var searchTestResult: TestResult?

    /// 有过一次「看起来在跑、其实没生效」之后，测试结果就带上了颜色和图标
    struct TestResult {
        var ok: Bool
        var detail: String
    }

    init() { reload() }

    /// 从磁盘读回表单。每次进设置页都重来一遍：这一页显示的就该是
    /// 文件里真实的值，而不是上次编辑残留的草稿。
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
        return trimmed(deepSeekAPIKey) != config.deepSeekAPIKey
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
