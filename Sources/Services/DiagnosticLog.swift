import Foundation
import os

// MARK: - 级别

/// 日志级别。**顺序有意义**：`Comparable` 按 `order` 比，门槛过滤就是
/// `level >= minimum`——写成字符串比较的话 "error" < "info" 会成立（字典序），
/// 而那正好把过滤方向反过来，且不会报任何错
enum LogLevel: String, CaseIterable, Comparable {
    case debug, info, warn, error

    var order: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    /// 定宽 5 字符。**为了 `grep '\[WARN \]'` 能对齐**：不定宽的话
    /// `[WARN]` 和 `[ERROR]` 之后的列会错开，肉眼扫一屏排不上号
    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warn: return "WARN "
        case .error: return "ERROR"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .default
        case .error: return .error
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.order < rhs.order }
}

// MARK: - 类别

/// 日志类别。**刻意是个闭集**：自由字符串的话，同一个子系统会被写成
/// `diarize` / `diarization` / `Diarization` 三种，按类别过滤就废了。
/// 加一条新类别是一次显式的改动，这正是这里想要的
enum LogCategory: String, CaseIterable {
    /// 进程生命周期：启动、退出
    case app
    /// 转录链路：开始/结束、段数、时长
    case transcription
    /// 录音存档落盘
    case recording
    /// 会话 JSON 的读写（`RecordingsStore`）
    case storage
    /// 说话人识别
    case diarization
    /// 课后笔记、笔记导出
    case notes
    /// 联网调用：核查、词库生成、COS
    case network
    /// 脏数据告警（反向段那类）
    case data
}

// MARK: - 出口

/// 一个日志出口：级别过滤 → 脱敏 → os_log + 环形文件。
///
/// **为什么是实例而不是一堆 `static func`**：自检必须能指向临时目录。
/// 如果出口是全局单例，`--log-selftest` 就会往用户真实的 `logs/` 里灌
/// 测试串（`StudyNotesStore` 那边为同一件事另开了一个临时 store——
/// 规则是一样的：**自检一个字都不该写进用户目录**）。
///
/// `@unchecked Sendable` 的理由：`FileHandle` 和 `ISO8601DateFormatter` 都
/// 不是 `Sendable`，而它们只在 `lock` 里被碰。**这是显式承诺，不是忽略**——
/// 任何一处绕过 `lock` 的访问都是 bug，而不是「编译器太严」
final class DiagnosticLogSink: @unchecked Sendable {

    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter
    private let mirrorToOSLog: Bool

    /// 环形文件的目录。`nil` = 只走 os_log（自检里验「级别过滤不该落盘」时用）
    private let writer: LogRingWriter?
    private var _minimumLevel: LogLevel

    init(
        directory: URL?,
        policy: LogRingPolicy = .default,
        minimumLevel: LogLevel = .info,
        mirrorToOSLog: Bool = true
    ) {
        self.writer = directory.map { LogRingWriter(directory: $0, policy: policy) }
        self._minimumLevel = minimumLevel
        self.mirrorToOSLog = mirrorToOSLog

        // 带毫秒 + 带时区偏移。**不写 UTC**：这份日志是给人看的，
        // 「下午三点出的事」比「07:00Z」直接；偏移量同时在，换算也不丢信息
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        self.formatter = f
    }

    var minimumLevel: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _minimumLevel }
        set { lock.lock(); defer { lock.unlock() }; _minimumLevel = newValue }
    }

    func log(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: String,
        fields: [DiagnosticLog.Field] = [],
        at date: Date = Date()
    ) {
        lock.lock()
        let floor = _minimumLevel
        let stamp = formatter.string(from: date)
        lock.unlock()

        guard level >= floor else { return }

        let raw = DiagnosticLog.format(level: level, category: category, message: message,
                                      fields: fields, timestamp: stamp)
        // **每一个字节都从这里过**。放在格式化之后、写盘之前，而不是在
        // 每个字段上各做一次——「所有出口都记得脱敏」是靠不住的，
        // 而这一行只要在，就没有第二条通向磁盘的路
        let line = DiagnosticLog.redact(raw)

        if mirrorToOSLog {
            let logger = Logger(subsystem: DiagnosticLog.subsystem, category: category.rawValue)
            // `.public`：这行已经脱敏过了，再打上 `<private>` 会让 Console.app
            // 里只剩一串占位符，等于白接。**前提是上面那行 `redact` 还在**——
            // 谁把它去掉，谁就把脱敏一起废了
            logger.log(level: level.osLogType, "\(line, privacy: .public)")
        }
        writer?.append(line)
    }

    /// 崩溃后回读：所有归档 + 活跃文件，按时间序的最后 `limit` 条
    func recent(limit: Int) -> [String] {
        writer?.recent(limit: limit) ?? []
    }

    var totalBytes: Int { writer?.totalBytes ?? 0 }
    var fileCount: Int { writer?.fileCount ?? 0 }
}

// MARK: - 对外门面

/// 本地诊断日志。全项目的日志都从这里走。
///
/// **为什么要有它**（派单书 §「为什么做这个」）：之前全项目的 `os_log` /
/// `NSLog` 调用数是 0，而 C-4 那个反向段 bug 的现场是 **SIGTRAP / exit 133 /
/// 一个字都不打印**——那类问题没有日志就查不出第二次。
///
/// **接线点清单**（刻意不是「全项目无脑撒」。选点规则：**用户看不到、
/// 但出事一定想查**的那些地方——它们的共同形状是「只变成界面上的一句
/// `errors[id] = …` 就没了」）：
///   · 启动 / 退出 —— `AppState.init`（`app`）
///   · 转录开始 / 结束（时长、段数）—— `AppState.startTranscription` /
///     `onSessionComplete`（`transcription`）
///   · 录音落盘 —— 同上那条 `onSessionComplete`（`recording`）
///   · 会话写盘失败 —— `RecordingsStore.save` / `persistIndex`（`storage`）
///   · 脏数据告警 —— `RecordingsStore.save`（反向段计数，`data`）
///   · 说话人识别的每一条失败 —— `SpeakerDiarizationService.evaluate` 的
///     `failing()`，**那条路是 helper 退出码 → 原因的唯一落点**（`diarization`）
///   · 课后笔记生成 / 导出失败 —— `StudyNotesStore`（`notes`）
///   · 核查失败 —— `FactCheckStore`（`network`）
///   · COS 上传失败 —— `UploadStore`（`network`）
///
/// **不接 HTTP 请求体、不接转录正文、不接笔记正文**——那三样都是用户内容，
/// 见 `redact` 上面那段
enum DiagnosticLog {

    /// 系统统一日志里的 subsystem。**和 bundle id 同一个串**：
    /// Console.app 里按 `com.asuka.classroomtranscriber` 过滤就能看到全部。
    /// 无头入口跑的时候 `Bundle.main.bundleIdentifier` 是 nil（裸二进制），
    /// 所以这里写死一个常量而不是去问 Bundle
    static let subsystem = "com.asuka.classroomtranscriber"

    /// `~/Library/Application Support/ClassroomTranscriber/logs/`
    /// ——与 `models/`、`study-notes/`、`recordings/` 同级（派单书要求），
    /// **不在仓库里**，`.gitignore` 也不用管它（`build/` 和 `.build/` 才是
    /// 仓库内的生成物，这份在用户目录）
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    static var directoryPath: String { defaultDirectory.path }

    /// 全局出口。`static let` = 第一次用到才建（不 log 的进程不会凭空
    /// 造出一个 logs/ 目录），且 Swift 保证只初始化一次。
    ///
    /// **无头入口拿到的是一个丢弃出口**（不落盘、不打 os_log）。
    ///
    /// 为什么：无头入口里有的是**会走到生产失败路径的自检**——比如
    /// `--diarize-ui-selftest` 会真的调 `DiarizationStore.run`，那条路
    /// 失败时要记日志。如果全局出口在无头模式下照样落盘，跑一次自检就往
    /// 用户真实的环形文件里灌一批假现场（「helper 模型不在」之类），
    /// **把昨晚那节课的真现场挤掉**——环形只有 1 MB，挤掉就是永久丢掉。
    ///
    /// 靠「每个自检记得传一个空出口」是靠不住的：那是 N 处纪律，而这是
    /// 一处结构。**无头入口的现场本来就在 stdout 上**，不在环形文件里，
    /// 所以在这里丢掉不损失任何东西
    static let shared: DiagnosticLogSink = {
        if HeadlessEntry.isActive {
            return DiagnosticLogSink(directory: nil, mirrorToOSLog: false)
        }
        return DiagnosticLogSink(directory: defaultDirectory)
    }()

    // MARK: 便捷方法

    static func debug(_ c: LogCategory, _ m: String, fields: [Field] = []) { shared.log(.debug, c, m, fields: fields) }
    static func info(_ c: LogCategory, _ m: String, fields: [Field] = []) { shared.log(.info, c, m, fields: fields) }
    static func warn(_ c: LogCategory, _ m: String, fields: [Field] = []) { shared.log(.warn, c, m, fields: fields) }
    static func error(_ c: LogCategory, _ m: String, fields: [Field] = []) { shared.log(.error, c, m, fields: fields) }

    static func recent(limit: Int = 200) -> [String] { shared.recent(limit: limit) }

    /// 导出正文：一个头 + 最后 `limit` 条。
    ///
    /// **无头入口 `--log-export` 和设置页那个按钮共用这一份**。两处各拼一次
    /// 头的话，头里那句「上限是多少、文件几个」早晚会跟 `LogRingPolicy`
    /// 的真实值漂开——而导出文件的头正是接手者判断「这份日志是不是完整的」
    /// 的唯一依据，漂了比没有更糟
    static func exportText(directory: URL, limit: Int) -> (text: String, count: Int, fileCount: Int, bytes: Int) {
        let writer = LogRingWriter(directory: directory)
        let lines = writer.recent(limit: limit)
        let header = [
            "课堂转录 · 诊断日志导出",
            "目录：\(directory.path)",
            "文件：\(writer.fileCount) 个 · 共 \(writer.totalBytes) 字节"
                + "（上限 \(writer.policy.totalByteCap)，超了自动丢最老的）",
            "本次取出：\(lines.count) 条（最多最后 \(limit) 条）",
            "────────",
        ].joined(separator: "\n")
        return (header + "\n" + lines.joined(separator: "\n") + "\n",
                lines.count, writer.fileCount, writer.totalBytes)
    }

    // MARK: - 键值

    /// 一条结构化字段。
    ///
    /// **有几种构造器不是装饰**：`Int` / `Double` / `UUID` 进去之后就不再是
    /// 自由文本了，`Field("段数", 42)` 不可能带出用户正文。想塞正文只有
    /// `Field(String, String)` 一条路，而那条路的值会在 `format` 里先看键名
    /// （`sensitiveKeys`），再在 `redact` 里过一遍
    struct Field: Equatable {
        var key: String
        var value: String

        init(_ key: String, _ value: String) { self.key = key; self.value = value }
        init(_ key: String, _ value: Int) { self.init(key, String(value)) }
        init(_ key: String, _ value: Int32) { self.init(key, String(value)) }
        init(_ key: String, _ value: UInt64) { self.init(key, String(value)) }
        init(_ key: String, _ value: UUID) { self.init(key, value.uuidString) }

        /// 秒，保留一位。**别用 `String(describing:)`**：`Double` 的默认描述
        /// 会打出 `8.410000000000001` 这种噪声，一屏日志全是假精度
        init(seconds key: String, _ value: Double) { self.init(key, String(format: "%.1fs", value)) }
    }

    /// **键名在这一组里，值一律不写盘。**
    ///
    /// 这是「绝不许出现用户正文」那条硬要求的落点：正则认不出「正文」，
    /// 但认得出「这个键装的是正文」。所以堵在这里——**凡是装用户内容的键，
    /// 一律连值带键换掉**，而不是指望写日志的人自己记得别写。
    ///
    /// `key` / `secret` / `token` 那几个是第二道：密钥也可能被塞进一个
    /// 自由键名里（`Field("deepseekKey", …)`），它们在 `redact` 里还有一道，
    /// 两道的形状不同，所以都留着
    static let sensitiveKeys: Set<String> = [
        "text", "transcript", "transcripttext", "segment", "segments",
        "content", "body", "prompt", "answer", "reply", "response",
        "note", "notes", "summary", "query", "q", "term", "terms",
        "title", "filename", "path",
        "key", "apikey", "secret", "secretkey", "secretid", "token",
        "password", "credential", "authorization",
    ]

    /// 换上去的标记。**全部规则共用一个串**——给每条规则各起一个名字
    /// （`「已脱敏:长令牌」`）看着更"有信息"，实际代价是「只要看见标记就
    /// 知道这里被换过」这条不变量没了：判据得挨个去认是哪条规则命中，
    /// 漏一个就是一条静默的假绿。**是哪个键被换掉了，周围的文字写着**
    /// （`token=「已脱敏」`），标记本身不必再背这个信息
    static let redactedMarker = "「已脱敏」"

    // MARK: - 格式化（纯函数）

    /// 一行 = 一条。**行内不许有换行**——有了的话 `tail -n 20` 数出来的
    /// 「最后 20 条」就不是 20 条，而且谁能往消息里塞 `\n` 谁就能伪造一条
    /// 看起来像别人写的日志（日志注入）。所以先摊平，再拼
    static func format(
        level: LogLevel,
        category: LogCategory,
        message: String,
        fields: [Field],
        timestamp: String
    ) -> String {
        var line = "\(timestamp) [\(level.tag)] \(category.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) | \(flatten(message))"
        for field in fields {
            let key = flatten(field.key)
            if sensitiveKeys.contains(key.lowercased()) {
                line += " \(key)=\(redactedMarker)"
            } else {
                line += " \(key)=\(quoteIfNeeded(flatten(field.value)))"
            }
        }
        return line
    }

    /// 把 CR/LF/Tab 摊成空格。Tab 也摊：一行里混着制表符的话，
    /// 贴进报告/工单会错列，而它的诊断价值是零
    static func flatten(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// 只在会读不出来的时候加引号。**默认不加**：`exitCode=5`
    /// 这样才 grep 得动，而 grep 是这份日志最主要的用法
    static func quoteIfNeeded(_ v: String) -> String {
        if v.isEmpty || v.contains(" ") || v.contains("\"") || v.contains("=") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "'") + "\""
        }
        return v
    }

    // MARK: - 脱敏（纯函数）

    /// 规则表（**具名的 7 条**，第 ⑤ 条安全网见 `longTokenRegex`）。
    ///
    /// **顺序有意义**：具名前缀（`sk-`/`tvly-`/`AKID`）先吃掉整段，
    /// 后面那条「32 字符以上的长令牌」才不至于把它切碎。
    /// 所以 `redact` 里安全网排在最后跑。
    ///
    /// **这 7 条一条都不许放宽**（P6-3 明确要求）：它们是「密钥」的**具名形状**，
    /// 误伤的代价再大也不能拿它们去换——可用性那一侧收窄的是**安全网**
    /// （它本来就是「不确定，先抹了」的那一条，代价与收益要重新算）
    private static let redactionRules: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // ① 具名前缀的密钥。**分成两条不是啰嗦**：`sk-`/`tvly-` 那一族
            //    前缀后必带分隔符，而腾讯云的 SecretId 是 `AKID` 直接接
            //    32 位字母数字、**中间没有分隔符**——写成一条的话，
            //    `AKIDxxxx…` 既过不了带分隔符的这条，也够不着下面那条
            //    32 字符的安全网（`AKID` + 8 位只有 12 个字符）
            (#"(?i)\b(?:sk|tvly|ghp|gho|xox[baprs]|hf)[-_][A-Za-z0-9_\-]{8,}"#, redactedMarker),
            (#"\bAKID[A-Za-z0-9]{8,}"#, redactedMarker),
            // ② 赋值形态：apiKey = xxx / "secretKey": "xxx" / token=xxx
            (#"(?i)"?\b(api[_-]?key|secret[_-]?(?:id|key)?|access[_-]?(?:key|token)|auth[_-]?token|token|password|passwd|credential)\b"?\s*[:=]\s*"?([^\s",;}\]]{4,})"?"#,
             "$1=" + redactedMarker),
            // ③ Authorization 头
            (#"(?i)\bbearer\s+[A-Za-z0-9._\-+/=]{8,}"#, "Bearer " + redactedMarker),
            // ④ URL 查询串里的凭证（腾讯云预签名 URL 的 q-ak 就是 SecretId）
            (#"(?i)([?&](?:key|token|secret|signature|sig|q-ak|q-signature|q-key-time|q-sign-time|access_token|api_key)=)([^&\s"'<>]+)"#,
             "$1" + redactedMarker),
        ]
        return specs.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
    }()

    /// 第 ⑤ 条：32 字符以上的长令牌安全网。
    ///
    /// **它不跟上面那 7 条一起放进表里**，因为它是唯一一条需要**逐命中**
    /// 判断的规则：同一个正则命中的串，有的要抹有的要留（路径要留），
    /// 而 `stringByReplacingMatches` + 模板表达不了「这条留、那条抹」。
    /// 放进表里就得靠一条巨型负向先行断言去表达路径形状，那种正则没人敢改
    ///
    /// **要放过 UUID**：`sessionId=<uuid>` 是这份日志里最常用也最有用的一列，
    /// 36 个十六进制加连字符整好落进这一条。
    ///
    /// 只写 `(?!uuid)` 不够——那个负向断言只在匹配**起点**成立。
    /// UUID 有 36 个字符，从第 2 个字符起再数 35 个，仍是一段 32 字符以上的
    /// 合法匹配，于是「放过 UUID」会在第二个字符位置失效、把后 35 位吃掉。
    /// 所以再加一条负向后顾：**前面一个字符是十六进制或连字符的，一律不是
    /// 新令牌的起点**。UUID 的每一个后续位置前面都是十六进制字符，整条就被挡掉了
    ///
    /// 代价：紧跟在十六进制字符后面的真令牌会漏（`abc123<32位密钥>` 这种连写）。
    /// 实际写法（`token=`、空格、中文冒号之后）不受影响
    private static let longTokenRegex = try? NSRegularExpression(
        pattern: #"(?<![0-9a-fA-F-])(?![0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})[A-Za-z0-9+/_\-]{32,}={0,2}\b"#
    )

    /// 路径组件长度的上限。**为什么是 24**：本 App 会写进日志的最长路径组件是
    /// `ClassroomTranscriber`（20 字符），24 留了余量；而一个真正的不透明令牌
    /// 即使偶然含 `/`，段也会长得多
    static let maxPathComponent = 24

    /// 「这一个长令牌是路径，不是密钥吗」。
    ///
    /// **判据：含 `/`，而且被 `/` 切出来的每一段都不超过 `maxPathComponent`。**
    /// 路径的形状是「一串短组件」，密钥不是。
    ///
    /// 为什么必须收窄（P6-3 的由来，实测）：真实日志里这一行——
    ///
    ///     [INFO ] app | 启动 后端=whisper 增益=x3 日志目录="「已脱敏」 「已脱敏」"
    ///
    /// 路径里的空格（`Application Support`）把它切成两段，各自够 32 字符
    /// （`/Users/you/Library/Application` 32、`Support/ClassroomTranscriber/recordings/`
    /// 40），两段都命中了安全网。而**录音落盘和脏数据告警的消息里都带文件名**，
    /// 那些行会一起变成「已脱敏」——「查到日志却看不出是哪条录音」，
    /// 可诊断性直接打折，而这份日志存在的全部理由就是「出事能查」。
    ///
    /// **已知代价**：一个 ≥32 字符、含 `/`、且每段都 ≤24 的不透明令牌会被放行。
    /// 这个洞比不收窄时那个（**每一个带绝对路径的文件名都被吃掉**）小得多。
    /// 自检里用真值表把它钉住，免得将来有人以为「含 `/` 就一定安全」
    static func looksLikePath(_ token: String) -> Bool {
        guard token.contains("/") else { return false }
        // 保留空段：`/Users/…` 头尾的空段长度为 0，天然 ≤ 上限
        return token.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { $0.count <= maxPathComponent }
    }

    /// 走一遍安全网：命中的长令牌**逐个**判是不是路径，不是才抹。
    ///
    /// 找不到任何命中时原样返回——绝大多数行都走这条路
    private static func redactLongTokens(_ text: String) -> String {
        guard let regex = longTokenRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard let r = Range(match.range, in: text) else { continue }
            out += text[cursor..<r.lowerBound]
            let token = String(text[r])
            out += looksLikePath(token) ? token : redactedMarker
            cursor = r.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// 把够像密钥的串换掉。**纯函数**（无 IO、不看时钟），所以自检能直接喂
    /// 构造好的串。
    ///
    /// 它**不是**万能的：正则认不出「用户正文」（那正是 `sensitiveKeys`
    /// 存在的理由），也认不出自定义格式的密钥。这条防线的定位是
    /// **挡住手滑，不是挡住恶意**——真正的保证来自「写日志的 API 里
    /// 根本没有『把正文传进来』这个动作」
    static func redact(_ text: String) -> String {
        var out = text
        for (regex, replacement) in redactionRules {
            // 每条规则都重新取 range：上一条替换完串长变了，
            // 沿用旧 range 会越界或者漏掉尾巴
            out = regex.stringByReplacingMatches(
                in: out, options: [], range: NSRange(out.startIndex..., in: out),
                withTemplate: replacement)
        }
        // 安全网**最后**跑（见 `redactionRules` 上面那段），而且逐命中判断
        return redactLongTokens(out)
    }

    /// 某段文本里还残留着密钥形状吗。给自检用——**判据要能在文件上断言，
    /// 而不是在内存里**，所以自检真正说的是「读回来的文件里 grep 不到」
    static func containsSecretShape(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        for (regex, _) in redactionRules where regex.firstMatch(in: text, options: [], range: r) != nil {
            return true
        }
        // 安全网必须按**和 `redact` 逐字相同的那条判据**算。不共用的话，
        // 两边会对同一段文本各说各话：「自检说这里还有密钥」而「redact 放行了它」
        // ——判据与实现漂开正是这个项目最怕的那种失败
        guard let regex = longTokenRegex else { return false }
        return regex.matches(in: text, options: [], range: r).contains { match in
            guard let range = Range(match.range, in: text) else { return false }
            return !looksLikePath(String(text[range]))
        }
    }
}
