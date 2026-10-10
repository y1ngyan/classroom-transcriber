import Foundation
import Observation

/// 下载模型这件事的**界面状态**。搬字节的活在 `ModelDownloader` 里，
/// 这里只负责：把进度摆出来、把「正在第几次重试」说出来、让用户能按停。
///
/// 一节课 45 分钟，模型 514MB——校园网下这是「点一下然后去干别的」的量级。
/// 所以这个类要回答的问题只有三个：**下了多少 / 还剩多久 / 现在到底在干什么**。
/// 尤其是第三个：自动重试如果不显示，界面看上去就只是「卡住了」。
@MainActor
@Observable
final class ModelDownloadCenter {

    enum Phase: Equatable {
        case idle
        case running
        case done(bytes: Int64)
        case cancelled
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .running: return true
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: DownloadProgress?
    /// 源给出的诚实提示（「此源不支持续传，将从 0 开始」这类）。
    /// **原样显示**，不加工——加工就等于替源撒谎
    private(set) var notices: [String] = []
    /// 正在第几次自动重试、为什么。nil = 没在重试
    private(set) var retryNote: String?
    private(set) var lastReport: DownloadReport?
    /// 模型目录的占用报告。**未完成的下载单独列在这里**，用户能看见它、
    /// 也知道清掉能释放多少
    private(set) var cache: ModelCacheReport?
    /// 清理残留之后给用户看的一句话
    private(set) var cleanupNote: String?

    private var task: Task<Void, Never>?
    private let downloader = ModelDownloader()

    /// **这次在下的那一份**（清单里钉的文件名）。默认是实时链路那份 medium；
    /// 课后重转要的 large 走的是**同一套**下载器、同一份进度、同一个取消，
    /// 只有「下哪一份」这一个参数不同——所以它是这里的一个字段，
    /// 而不是第二套并行的下载状态（两套状态迟早会各说各话）
    private(set) var activeFile: String = ModelDownloadCenter.defaultPinFile

    /// 默认那一份的名字。**从 `WhisperEngine` 取，不在这里重写一遍**：
    /// 写两遍就会出现「界面说在下 A，其实在下 B」
    static var defaultPinFile: String { WhisperEngine.modelPath.lastPathComponent }

    static var defaultDestination: URL { WhisperEngine.modelPath }
    static var defaultPartURL: URL { ModelDownloader.partURL(for: defaultDestination) }

    var destination: URL {
        WhisperEngine.modelDirectory.appendingPathComponent(activeFile)
    }

    /// 清单里钉住的那一版。见 `ModelManifest.bundledDefaultPin`
    static var bundledPin: ModelPin? { ModelManifest.bundledDefaultPin }

    /// 重扫模型目录。切换进设置页、下载结束、清理之后各调一次
    func refreshCache() {
        cache = ModelCacheReport.scan(directory: WhisperEngine.modelDirectory,
                                      manifest: try? ModelManifest.loadBundled())
    }

    var freeablePlan: ModelCachePlan? {
        guard let cache, !cache.freeable.isEmpty else { return nil }
        return cache.plan
    }

    /// 设置页那一行要不要出现。**有残留、或者刚清完（有话要说）时才显示**——
    /// 没有残留是常态，不该常驻一行「0 项」占着地方
    var shouldShowCacheRow: Bool {
        freeablePlan != nil || cleanupNote != nil
    }

    /// 清掉未完成的下载。**只删 `.part` 和它的版本记录**——正式模型文件
    /// 一根手指都不碰，哪怕它没通过校验（那是用户的文件）
    func cleanIncomplete() {
        guard let plan = freeablePlan else { return }
        do {
            let freed = try cache?.clean() ?? 0
            cleanupNote = "已清理 \(plan.items.count) 项残留，释放 \(ModelCache.byteText(freed))"
        } catch {
            cleanupNote = "清理失败：\(error.localizedDescription)"
        }
        refreshCache()
    }

    /// 已下载 / 总量 / 速度 / 预计剩余——**四个都要**，界面才有话可说
    var progressLine: String {
        guard let p = progress else { return "准备中…" }
        let mb = Double(p.written) / 1_000_000
        guard let total = p.total else {
            // 源没给长度就**不编百分比**：分母是编的，百分比就是假的
            return String(format: "已下载 %.1f MB（此源未提供总长度）", mb)
        }
        let totalMB = Double(total) / 1_000_000
        let percent = totalMB > 0 ? mb / totalMB * 100 : 0
        var line = String(format: "%.1f / %.1f MB（%.0f%%）", mb, totalMB, percent)
        if p.bytesPerSecond > 1 {
            line += String(format: " · %.1f MB/s", p.bytesPerSecond / 1_000_000)
        }
        if let remaining = p.remainingSeconds {
            line += " · 剩余约 \(Self.durationText(remaining))"
        }
        return line
    }

    static func durationText(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f 秒", seconds) }
        if seconds < 3600 { return String(format: "%.0f 分钟", seconds / 60) }
        return String(format: "%.1f 小时", seconds / 3600)
    }

    /// 开下。已经在跑就什么都不做（不会开出第二条并发下载）
    ///
    /// 地址**不再由这里拼**，而是从清单里那一版推出来（见 `ModelPin.url`）。
    /// 原来那个 `URL(string: WhisperEngine.modelURL)!` 有两个问题：它指向的是
    /// `resolve/main` 这个移动目标，而且那句强制解包一旦失败就是启动即崩
    ///
    /// - Parameter file: 要下清单里的哪一份。nil = 默认那一份（medium，实时链路用）。
    ///   课后重转要的 large-v3 就从这儿指名要——**不多一套下载状态**，
    ///   下面每一条闸、每一句进度、取消/续传的语义对两档完全一样
    func start(file: String? = nil, minimumBytes: Int64 = WhisperEngine.expectedModelBytes) {
        guard !phase.isBusy else { return }
        cleanupNote = nil

        let manifest: ModelManifest
        do {
            manifest = try ModelManifest.loadBundled()
        } catch {
            // 清单读不出来就**不下**，并把原因原样摆出来。这里要是「那就
            // 不校验了、照下」——用户会拿到一个没人验证过的 539MB 文件，
            // 而且界面上一切正常
            phase = .failed((error as? ModelManifest.LoadError)?.localizedDescription
                            ?? error.localizedDescription)
            return
        }
        let wantedPin = file == nil ? manifest.defaultPin : manifest.pin(forFile: file!)
        guard let pin = wantedPin else {
            phase = .failed(file == nil
                ? "模型清单里没有可用条目（\(ModelManifest.resourceName).json）"
                : "模型清单里没有 \(file!) 这一条（\(ModelManifest.resourceName).json）")
            return
        }
        // 下哪一份由清单说，destination 跟着它走——不能让调用方指定一个
        // 和清单对不上的目标：那样下下来的字节没有任何判据能校验
        activeFile = pin.file

        phase = .running
        progress = nil
        notices = []
        retryNote = nil
        lastReport = nil

        let partURL = ModelDownloader.partURL(for: destination)
        let throttle = ProgressThrottle()
        let target = destination

        task = Task { [downloader] in
            do {
                let report = try await downloader.download(
                    from: pin.url,
                    to: target,
                    partURL: partURL,
                    minimumBytes: minimumBytes,
                    pin: pin,
                    onProgress: { p in
                        // 每个网络回包都回调一次，直接往主线程扔会淹掉 UI。
                        // 节流放在这里而不是 `ModelDownloader` 里：下载器
                        // 不该知道「界面多久刷新一次」这件事
                        guard throttle.shouldEmit(written: p.written) else { return }
                        Task { @MainActor [weak self] in self?.progress = p }
                    },
                    onRetry: { next, max, reason in
                        Task { @MainActor [weak self] in
                            self?.retryNote = "正在自动重试（第 \(next)/\(max) 次）· 上次失败：\(reason)"
                            self?.notices.append("自动重试 \(next - 1) 次失败，第 \(next) 次开始")
                        }
                    }
                )
                await MainActor.run {
                    self.phase = .done(bytes: report.bytesWritten)
                    self.lastReport = report
                    self.retryNote = nil
                    self.notices.append(contentsOf: report.notices)
                    self.refreshCache()
                }
            } catch is CancellationError {
                await MainActor.run {
                    // **取消不是失败**：`.part` 留着，下次从这儿续
                    self.phase = .cancelled
                    self.retryNote = nil
                    self.notices.append("已取消。已下载的部分保留在 \(self.activeFile).part，下次从这里接着下")
                    self.refreshCache()
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(error.localizedDescription)
                    self.retryNote = nil
                    self.refreshCache()
                }
            }
        }
    }

    /// 按停。**只停下载，不删 `.part`**——删了就等于把用户已经花掉的
    /// 流量和时间一起扔掉
    func cancel() {
        task?.cancel()
        task = nil
    }

    var canRetry: Bool {
        if case .failed = phase { return true }
        if case .cancelled = phase { return true }
        return false
    }

    var canStart: Bool { !phase.isBusy }
}

/// 给进度回调用的节流器。
///
/// `@unchecked Sendable` 的依据：`written` 只在 `lock` 里读写，
/// `lastEmit` 同理。回调确实来自 session 的后台队列——这是必须的，
/// 因为**不能**在那里碰 `@MainActor` 的状态。
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmit = Date.distantPast
    private var lastWritten: Int64 = 0

    /// 至少间隔 0.15 秒，或者涨了 1MB，才放行一次
    func shouldEmit(written: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEmit)
        guard elapsed >= 0.15 || written - lastWritten >= 1_000_000 else { return false }
        lastEmit = now
        lastWritten = written
        return true
    }
}
