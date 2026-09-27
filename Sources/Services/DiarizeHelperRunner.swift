import Foundation
import Darwin

// MARK: - 超时

/// 超时公式，与 helper 侧同名实现**逐字相同**（`C-helper/Sources/DiarizeHelper/TimeoutPolicy.swift`）。
///
/// `max(300s, 90s + audioSeconds/5)`。依据：C-1 实测最慢 98.6× 实时（45 min → 约 27s
/// 纯计算），模型加载/编译首见 66.4s；除以 5 已含约 4× 余量。
///
/// 为什么在 App 侧再写一份而不是「让 helper 自己超时」：超时是**给失控的子进程兜底**的，
/// 一个卡住的进程没有能力给自己发信号。App 是唯一能杀它的那一方，所以判据必须在 App 这边。
/// 两边公式相同不是巧合，是为了「同样的音频得到同样的超时」——改一处就要改另一处
enum DiarizeTimeoutPolicy {
    static let floorSeconds: Double = 300
    static let baseSeconds: Double = 90
    static let realtimeDivisor: Double = 5
    /// SIGTERM 之后宽限多久再 SIGKILL
    static let killGraceSeconds: Double = 5

    static func timeoutSeconds(audioSeconds: Double) -> Double {
        max(floorSeconds, baseSeconds + audioSeconds / realtimeDivisor)
    }
}

// MARK: - 进程终止状态

/// 子进程结束后能拿到的两个量（`Process.terminationReason` + `terminationStatus`）。
/// 形状对齐 helper 侧的 `ProcessTermination`——两边说的是同一件事，名字一样便于对照
struct DiarizeProcessTermination: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case exit
        case uncaughtSignal
    }

    var reason: Reason
    var status: Int32
}

// MARK: - 一次调用的入参 / 出参

struct DiarizeHelperInput: Equatable, Sendable {
    /// 绝对路径（wav 存档）
    var path: String
    /// 该片段在**会话时间轴**上的起点，直接来自 `RecordingPart.offsetMillis`
    var offsetMillis: Int
}

struct DiarizeHelperInvocation {
    var executable: URL
    var inputs: [DiarizeHelperInput]
    /// **App 自有的 models 根目录**（不是 `speaker-diarization` 本身）。
    /// helper 自己会在它下面找 `speaker-diarization/`——这个层级关系是 helper 的
    /// `ModelPresence` 定的（`Repo.diarizer.folderName`），App 这边不重复实现它
    var modelsDir: URL
    /// helper 把 JSON 信封写到这里（绝对路径）
    var output: URL
    var timeoutSeconds: Double
}

struct DiarizeHelperRun: Sendable {
    /// nil = 进程根本没起来（launch 失败）
    var termination: DiarizeProcessTermination?
    var envelopeData: Data?
    var stderrTail: String
    var wallSeconds: Double
    /// 看门狗真的开了枪（而不是「进程自己退得慢了一点」）
    var timedOut: Bool
    /// 连 `Process.run()` 都没成功（helper 不在、不可执行、bundle 坏了）
    var launchError: String?
}

// MARK: - 看门狗

/// 看门狗与 `waitUntilExit()` 在不同线程上，要共享一个可变的「开没开枪」标记。
/// `Process` 本身不是 `Sendable`，这里显式承诺「只通过这把锁访问它」
private final class WatchdogBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var fired = false

    init(_ process: Process) { self.process = process }

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }

    /// 到期先 SIGTERM，宽限期后再 SIGKILL。
    ///
    /// `isRunning` 那一问是**必须的**：进程可能正好在这一刻自己退干净了，
    /// 此时 `terminate()` 是无害的，但把 `fired` 记成 true 会把一次正常退出
    /// 判成超时——那是「把成功说成失败」，比漏判更糟
    func fire(grace: Double) {
        lock.lock()
        guard process.isRunning else { lock.unlock(); return }
        fired = true
        lock.unlock()

        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            lock.lock()
            let stillRunning = process.isRunning
            lock.unlock()
            if stillRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// 收 stderr 的尾巴（诊断用）。
///
/// 不读完会**死锁**：管道的缓冲区只有 64 KB，写满之后子进程会阻塞在 write 上，
/// 而父进程如果这时正在 `waitUntilExit()`，两边就永远等下去。所以必须一边跑一边收。
/// 上限 8 KB：界面只给一句短原因，栈刷给学生既没用又吓人（设计稿 §2.7）
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap = 8 * 1024

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard data.count < cap else { return }
        data.append(chunk.prefix(cap - data.count))
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 跑一次 helper

enum DiarizeHelperRunner {

    /// 拼参数。**单列成函数是为了可断言**：参数错了的表现是「helper 说用法错误」
    /// （退出码 2），而那时人已经在怀疑模型/音频了
    static func arguments(for invocation: DiarizeHelperInvocation) -> [String] {
        var args = ["diarize"]
        for input in invocation.inputs {
            args += ["--input", input.path, "--offset-ms", String(input.offsetMillis)]
        }
        args += ["--models-dir", invocation.modelsDir.path]
        args += ["--output", invocation.output.path]
        // 生产恒开。helper 只有在不带这个开关时才可能联网下模型，而下载必须是
        // 用户显式触发的动作（拍板第 7 条把模型放 App 自有目录，前提就是它不会
        // 自己偷偷去别处拉一份）
        args.append("--no-network")
        return args
    }

    /// 异步外壳：`runSync` 会阻塞一个线程到子进程结束（分钟级），
    /// 不能占着协作线程池。丢到 GCD 的全局队列上是这里唯一合适的做法
    static func run(_ invocation: DiarizeHelperInvocation) async -> DiarizeHelperRun {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(invocation))
            }
        }
    }

    static func runSync(_ invocation: DiarizeHelperInvocation) -> DiarizeHelperRun {
        let startedAt = Date()

        func fail(_ message: String, termination: DiarizeProcessTermination? = nil,
                  stderr: String = "") -> DiarizeHelperRun {
            DiarizeHelperRun(
                termination: termination, envelopeData: nil, stderrTail: stderr,
                wallSeconds: Date().timeIntervalSince(startedAt), timedOut: false,
                launchError: message
            )
        }

        // 先把上一轮的信封删掉：留着的话「这一轮没产出」会被上一次的文件冒充成成功。
        // helper 失败时**不写**输出文件，所以「文件不存在」是它失败的一种正常形状
        try? FileManager.default.removeItem(at: invocation.output)

        guard FileManager.default.isExecutableFile(atPath: invocation.executable.path) else {
            return fail("helper 不在或不可执行：\(invocation.executable.path)")
        }

        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = arguments(for: invocation)
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        let collector = StderrCollector()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collector.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            return fail("helper 起不来：\(error.localizedDescription)")
        }

        let box = WatchdogBox(process)
        let watchdog = DispatchWorkItem {
            box.fire(grace: DiarizeTimeoutPolicy.killGraceSeconds)
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + max(1, invocation.timeoutSeconds), execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        errPipe.fileHandleForReading.readabilityHandler = nil

        let termination: DiarizeProcessTermination?
        switch process.terminationReason {
        case .exit:
            termination = DiarizeProcessTermination(reason: .exit, status: process.terminationStatus)
        case .uncaughtSignal:
            termination = DiarizeProcessTermination(
                reason: .uncaughtSignal, status: process.terminationStatus)
        @unknown default:
            termination = nil
        }

        return DiarizeHelperRun(
            termination: termination,
            envelopeData: try? Data(contentsOf: invocation.output),
            stderrTail: collector.text,
            wallSeconds: Date().timeIntervalSince(startedAt),
            timedOut: box.didFire,
            launchError: nil
        )
    }
}

// MARK: - helper 在哪

/// 从 **app bundle** 里找 helper（派单书点名：不许硬编码 spike 目录）。
///
/// 放 `Contents/MacOS/` 的理由：那里是 `Bundle.main.url(forAuxiliaryExecutable:)`
/// 按定义要找的地方，也是主可执行文件所在处——两者同目录时 rpath 的解析
/// 与「这个二进制属于这个 bundle」的直觉都最省事。C-1 已 `otool -L` 核过：
/// 这个二进制的动态依赖只有系统框架，不需要一起搬别的 dylib
enum DiarizeHelperLocator {
    static let executableName = "diarize-helper"

    /// 允许 `CLASSROOM_DIARIZE_HELPER` 指到别处，与 `CLASSROOM_WHISPER_MODEL`
    /// 同一个理由：模型/二进制放哪不该只能靠翻文档回答，而自检也要能指到一个桩上
    static var environmentOverride: URL? {
        guard let raw = ProcessInfo.processInfo.environment["CLASSROOM_DIARIZE_HELPER"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// 依次尝试：环境变量 → `Bundle.main` 的辅助可执行 → 主可执行同目录 → `Contents/MacOS/`。
    /// 多试几处是因为无头入口下 `Bundle.main` 的解析与 `open` 起来的 App 不完全一样，
    /// 而「找不到 helper」在界面上和「helper 坏了」是两件事，值得多找一下
    static func locate(bundle: Bundle = .main) -> URL? {
        if let override = environmentOverride { return override }
        var candidates: [URL] = []
        if let aux = bundle.url(forAuxiliaryExecutable: executableName) { candidates.append(aux) }
        if let executable = bundle.executableURL {
            candidates.append(executable.deletingLastPathComponent()
                .appendingPathComponent(executableName))
        }
        candidates.append(bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - 模型放哪 + 首跑就位

/// 说话人模型的位置与首跑就位（拍板第 7 条）。
///
/// 位置与 whisper 模型**同一层**：`models/` 是「这个 App 的模型」的唯一目录，
/// 说话人模型在它下面单独一个 `speaker-diarization/`。helper 的 `--models-dir`
/// 收的就是这个 `models/`，它自己再拼 `speaker-diarization/`——**层级关系只有
/// helper 那边一份实现**，App 不复制（复制就是两处实现同一个概念，两边一旦
/// 不一致，表现是「模型明明在，却说不存在」）
enum SpeakerModelStore {

    /// 该 App 的模型根目录。**复用 `WhisperEngine.modelDirectory`** 而不是在这里
    /// 再拼一次 Application Support 路径：那是「模型放哪」这件事在仓库里的唯一定义
    static var modelsDirectory: URL { WhisperEngine.modelDirectory }

    /// 说话人模型实际落的目录（诊断与报错信息里要显示它）
    static var repositoryDirectory: URL {
        modelsDirectory.appendingPathComponent("speaker-diarization", isDirectory: true)
    }

    /// FluidAudio 自己的默认缓存位置。C-1 之前助手都是往这儿下的，
    /// 首跑就从这里搬——**搬而不是下载**：这是一台已经训练/验证过的机器上的既有 21 MB，
    /// 重新下一次要联网、要等，而且拿到的不保证是同一份
    static var legacyRepositoryDirectory: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("speaker-diarization", isDirectory: true)
    }

    enum Provision: Equatable {
        /// 已经在 App 自有目录里（不管里面全不全——**全不全由 helper 的 probe 说了算**，
        /// App 不自己判一遍：判定逻辑只能有一份，见 `ModelPresence` 的注释）
        case inPlace
        /// 从 FluidAudio 的旧位置搬过来了。`bytes` / `seconds` 是实测数字，
        /// 拍板第 7 条把它们列成了待测项
        case moved(bytes: Int64, seconds: Double)
        /// 没得搬，也没现成的。**这不是「静默用别处的模型」的许可**：调用方要把它
        /// 变成一条用户可见的错误
        case unavailable(reason: String)
    }

    /// 目录里有多少字节（用于报「搬了多少」这个实测数字）
    static func byteSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// 首跑就位。
    ///
    /// 判定顺序刻意是「先看目标位置有没有东西」：**已经有就一个字都不动**。
    /// 反过来的话，每跑一次都要去碰一次用户的模型目录，而那个动作（搬移）
    /// 是有破坏性的，不该在稳态下发生
    static func provision(
        fileManager: FileManager = .default,
        destination: URL? = nil,
        legacySource: URL? = nil
    ) -> Provision {
        let destination = destination ?? repositoryDirectory
        let legacySource = legacySource ?? legacyRepositoryDirectory

        let destinationExists = fileManager.fileExists(atPath: destination.path)
        if destinationExists {
            let contents = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
            if !contents.isEmpty { return .inPlace }
        }

        guard let legacySource, fileManager.fileExists(atPath: legacySource.path) else {
            return .unavailable(
                reason: "没有现成的说话人模型（\(destination.path) 是空的）。"
                    + "先跑一次 `diarize-helper download --models-dir \(modelsDirectory.path)` 把模型下下来")
        }

        let startedAt = Date()
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 目标位置可能已经存在但是个空目录：`moveItem` 会拒绝覆盖，
            // 先把它挪开（它里面什么都没有，挪走不丢数据）
            if destinationExists { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: legacySource, to: destination)
        } catch {
            // **响亮失败**：不「换个地方找一份凑合用」。静默降级到别处的模型，
            // 表现是「模型更新了但 App 用着旧的」，而这完全看不出来
            return .unavailable(
                reason: "说话人模型搬移失败：\(error.localizedDescription)"
                    + "（从 \(legacySource.path) 到 \(destination.path)）")
        }

        return .moved(
            bytes: byteSize(of: destination),
            seconds: Date().timeIntervalSince(startedAt)
        )
    }
}
