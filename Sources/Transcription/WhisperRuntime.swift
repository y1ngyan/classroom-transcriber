import AppKit
import Foundation
import Observation

/// Whisper 引擎的预热与持有。
///
/// **为什么要有这一层**：`WhisperEngine` 的构造实测 **17.03 秒**（冷启动，
/// Metal kernel 编译）↔ **0.65 秒**（缓存命中），差 26 倍。这个代价绝不能
/// 落在「点开始录制」那一刻——用户点了按钮、App 十七秒不响，他会以为坏了，
/// 然后再点一次。所以构造提前在后台做，点录制时只是把已经造好的取出来。
///
/// **预热失败必须说出来，不许静默退回 Apple**：用户把后端设成 Whisper 就是
/// 在等 Whisper 的结果，悄悄换回系统识别会让「怎么突然变差/变好」变成一个
/// 查不出来的谜。所以不可用时界面上一句话写清楚原因和模型路径。
@MainActor
@Observable
final class WhisperRuntime {

    enum State: Equatable {
        case idle
        case preparing
        /// 已就绪。seconds 是这一次构造花的时间（冷启动十几秒、缓存不到一秒，
        /// 这个数字本身就能告诉用户「下次会不会还这么慢」）
        case ready(seconds: Double)
        /// 不可用。字符串是给人看的原因（含模型路径）
        case unavailable(reason: String)
    }

    private(set) var state: State = .idle

    /// 这次加载是什么时候开始的（界面要显示「已经等了多久」）
    private(set) var preparingStartedAt: Date?
    /// 就绪那一刻（界面据此把「已就绪」显示 2.5 秒再收起来）
    private(set) var readyAt: Date?

    /// 这次要加载的模型文件。界面直接显示它——「模型放哪儿」只能靠翻文档
    /// 回答的话，模型缺失这条路上用户就只剩「重装一遍」这一个动作
    let modelURL: URL

    private var engine: WhisperEngine?
    private var warmupTask: Task<Void, Never>?
    /// 已经放掉引擎（进程要退了）。放掉之后不许再预热——退出路径上再起一次
    /// 那就正好把要解决的问题又造一遍
    private var isShutDown = false

    private var terminationObserver: NSObjectProtocol?

    /// whisper_full 一次两秒左右的重计算，放这条专属队列上跑。
    /// 不用 `Task.detached`：那会占着协作线程池的一个线程两秒钟，
    /// 而协作池的线程数是有限的（别的 await 会跟着排队）
    private let inferenceQueue = DispatchQueue(
        label: "com.classroomtranscriber.whisper.inference",
        qos: .userInitiated
    )

    /// - Parameter modelURL: 缺省用**实时那档**（turbo 在位就 turbo）。
    ///   离线重转自己会显式传 large，不走这个默认值
    init(modelURL: URL = WhisperEngine.liveModelURL) {
        self.modelURL = modelURL

        // 正常退出（Cmd+Q）时把引擎放掉。理由见 `unload()`——不放的话进程
        // 以 abort 结束，用户看到的是「退出时崩溃」。
        // 这条只覆盖走 AppKit 终止流程的退出；自检入口是直接 exit(0) 的，
        // 那条路上得各自显式调一次（NotificationCenter 在那种退出里不发）
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 先走正规所有权：`unload()` 把引擎放掉，`deinit` 里 free context
                self?.unload()
                // 再兜一遍底：进程里可能还有本对象之外的 context（无头自检自己
                // 造的、或另一个 runtime）。只要漏一个，退出就是 abort——
                // 而 abort 发生在静态析构里，栈上看不出是谁没放
                GgmlTeardown.releaseAll()
            }
        }
    }

    // 刻意没有 deinit 去摘掉那个观察者：`deinit` 是 nonisolated，碰不到
    // 主 actor 隔离的 token；而观察者块只弱引用 self，且这个对象活到进程结束
    // （它挂在 AppState 上），没有需要拆的循环

    var isPreparing: Bool {
        if case .preparing = state { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// 界面上那一行状态文案。nil 表示没什么可说的（还没打算用 Whisper）
    var statusLine: String? {
        switch state {
        case .idle:
            return nil
        case .preparing:
            return "正在准备 Whisper 模型…（第一次要十几秒）"
        case .ready(let seconds):
            return String(format: "Whisper 已就绪（准备用时 %.1f 秒）· 模型 %@", seconds, modelURL.path)
        case .unavailable(let reason):
            return "❌ Whisper 不可用：\(reason)"
        }
    }

    /// 预热。幂等；已经在准备或已经就绪时什么都不做。
    ///
    /// **刻意不是 async**：调用方（启动时、改完设置时）不该等它——那十几秒里
    /// 界面要照常能用，用户可能正在翻设置、改别的选项。
    func warmUp() {
        guard !isShutDown else { return }
        guard warmupTask == nil, engine == nil else { return }

        // 文件不存在就别去碰 ggml 后端。顺序反过来的话，这条路上要白付一次
        // Metal kernel 编译（`WhisperEngine.init` 里的同类判断也是这个原因）
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            state = .unavailable(reason: "模型文件不存在 \(modelURL.path)")
            return
        }

        state = .preparing
        preparingStartedAt = Date()
        readyAt = nil
        let url = modelURL
        let queue = inferenceQueue
        warmupTask = Task { [weak self] in
            let started = ContinuousClock.now
            let result: Result<WhisperEngine, Error> = await withCheckedContinuation { cont in
                queue.async {
                    do {
                        cont.resume(returning: .success(try WhisperEngine(modelURL: url)))
                    } catch {
                        cont.resume(returning: .failure(error))
                    }
                }
            }

            guard let self, !self.isShutDown else { return }
            self.warmupTask = nil
            switch result {
            case .success(let engine):
                self.engine = engine
                // **预热解码**，不只是加载模型。
                //
                // 实测（2026-11-25）：录第一分钟时单窗解码 5→34 秒，后面同样
                // 的窗只要 3 秒——差的是 Metal kernel 的首次编译与首帧分配。
                // 冷着开录，前几窗就把积压堆到缓冲上限，用户看到的是「中间丢了
                // 两分钟」。这里空跑一小段（1 秒静音）把 kernel 编好，
                // 代价在后台，不在录音里
                _ = try? engine.transcribe([Float](repeating: 0, count: 16_000),
                                           audio: "预热解码（1 秒静音）")
                let elapsed = ContinuousClock.now - started
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                self.state = .ready(seconds: seconds)
                self.readyAt = Date()
                self.preparingStartedAt = nil
            case .failure(let error):
                self.state = .unavailable(reason: error.localizedDescription)
                self.preparingStartedAt = nil
            }
        }
    }

    /// 取引擎，必要时等这一次预热跑完。返回 nil = 不可用（原因在 `state` 里）。
    ///
    /// 正常路径（提前预热过）这里立即返回，一次 await 都不挂起。
    func engineForRecording() async -> WhisperEngine? {
        guard !isShutDown else { return nil }
        if let ready = engine { return ready }
        if warmupTask == nil, !isReady {
            // 模型可能是刚下好的、或者上次因为文件缺失放弃了——允许再试一次
            warmUp()
        }
        await warmupTask?.value
        return engine
    }

    /// 放掉引擎。进程退出前必须调一次。
    ///
    /// **为什么不能靠自动释放**：whisper 的 ggml Metal 后端在进程退出、
    /// 静态析构时断言 `[rsets->data count] == 0`。只要还有一个活着的
    /// context 拿着它分配过的 buffer，这个断言就挂——进程以 **abort** 结束
    /// （实测 exit=134，栈在 `__cxa_finalize_ranges` → `ggml_metal_device_free`）。
    /// 用户看到的是「点退出的时候崩了一下」。
    ///
    /// 反过来说，**释放必须发生在 exit 之前**：`whisper_free` 把 buffer 还给
    /// 后端，residency set 才空得下来。离线跑 `--whisper-window-file` 全程
    /// 不崩，正是因为它把引擎放在局部变量里、函数返回时就释放了。
    ///
    /// 放掉之后回到 `idle` 而不是 `unavailable`：模型没丢，只是不打算再用它。
    func unload() {
        isShutDown = true
        warmupTask?.cancel()
        warmupTask = nil
        engine = nil
        state = .idle
    }

    /// 跑一次重计算并等结果。只允许滑窗链路调用。
    ///
    /// 抽在这里而不是让引擎自己开队列：队列的所有权在这一层，
    /// 「重计算都在同一条串行队列上」这条前提才有唯一一个出处。
    func run<T>(_ work: @escaping @Sendable (WhisperEngine) throws -> T) async throws -> T {
        guard let ready = engine else { throw WhisperEngine.WhisperError.modelMissing }
        let queue = inferenceQueue
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try work(ready))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
