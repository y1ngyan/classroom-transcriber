import Foundation
import Observation

/// COS 上传队列：入队、执行、暂停/继续/取消，以及跨重启的持久化。
@MainActor
@Observable
final class UploadStore {

    private(set) var items: [UploadItem] = []
    private(set) var statusMessage = ""

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 每个任务的身份号。暂停后立刻继续时，旧任务还在取消的路上，
    /// 它的收尾逻辑会晚一步跑回来——没有这个号，它就会把新任务的状态盖掉
    /// （表现为「点了继续，进度条却跳回暂停」）。每次启动任务都换号，
    /// 收尾前先核对号码，不是当前的就直接丢弃。
    private var generation: [UUID: Int] = [:]

    /// 临时密钥有有效期，缓存一份重复用，别每片都去签发
    private var cachedCredentials: COSCredentials?

    var isConfigured: Bool { AppConfig.isCOSConfigured }

    var activeCount: Int {
        items.filter { $0.status == .uploading }.count
    }

    var hasUnfinished: Bool {
        items.contains { !$0.status.isTerminal }
    }

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("uploads.json")
    }()

    static var storeFilePath: String { storeURL.path }

    init() {
        load()
    }

    // MARK: - 队列操作

    /// 把本地音频加入上传队列并立即开始。
    @discardableResult
    func enqueue(fileURL: URL) -> UploadItem? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            statusMessage = "❌ 文件不存在: \(fileURL.lastPathComponent)"
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let item = UploadItem(
            filePath: fileURL.path,
            fileName: fileURL.lastPathComponent,
            key: UploadKey.make(for: fileURL),
            totalBytes: size
        )

        items.append(item)
        persist()
        start(item.id)
        return item
    }

    func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        guard isConfigured else {
            items[index].status = .failed
            items[index].message = "COS 未配置"
            statusMessage = "❌ COS 缺凭证：填 cosSecretID + cosSecretKey，或填 cosSTSURL"
            persist()
            return
        }

        // 顶掉可能还在跑的旧任务，并换号作废旧任务的一切后续写入
        tasks[id]?.cancel()
        let gen = (generation[id] ?? 0) + 1
        generation[id] = gen

        items[index].status = .uploading
        items[index].message = ""
        persist()

        let fileURL = URL(fileURLWithPath: items[index].filePath)
        let key = items[index].key
        let state = items[index].uploadState

        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let credentials = try await self.credentials()
                let result = try await COSService.upload(
                    fileURL: fileURL,
                    key: key,
                    state: state,
                    credentials: credentials,
                    onStateChange: { [weak self] newState in
                        Task { @MainActor in
                            guard let self, self.generation[id] == gen else { return }
                            self.applyState(id: id, newState)
                        }
                    },
                    onProgress: { [weak self] sent, total in
                        Task { @MainActor in
                            guard let self, self.generation[id] == gen else { return }
                            self.applyProgress(id: id, sent: sent, total: total)
                        }
                    }
                )
                guard self.isCurrent(id, gen) else { return }
                self.finish(id: id, with: result)
            } catch is CancellationError {
                guard self.isCurrent(id, gen) else { return }
                self.markPaused(id: id)
            } catch {
                guard self.isCurrent(id, gen) else { return }
                // 密钥可能已过期，丢掉缓存让下次重签
                self.cachedCredentials = nil
                self.fail(id: id, message: error.localizedDescription)
                // COS 上传失败。**不记签名 URL、不记密钥**——那些都在
                // `error` 的描述里可能出现（服务端会把它回显出来），
                // 而 `DiagnosticLog.redact` 会在写盘前把密钥形状的东西换掉。
                // 这里只加一个「是哪条上传」的锚点
                DiagnosticLog.error(.network, "COS 上传失败", fields: [
                    .init("uploadId", id),
                    .init("原因", error.localizedDescription),
                ])
            }

            if self.isCurrent(id, gen) { self.tasks[id] = nil }
        }
    }

    func pause(_ id: UUID) {
        // 先换号再取消：这样被取消的任务收尾时已经不是「当前任务」，
        // 不会再把状态从「已暂停」改回别的
        generation[id] = (generation[id] ?? 0) + 1
        tasks[id]?.cancel()
        tasks[id] = nil
        markPaused(id: id)
    }

    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !items[index].status.isTerminal
        else { return }
        start(id)
    }

    func cancel(_ id: UUID) {
        generation[id] = (generation[id] ?? 0) + 1
        tasks[id]?.cancel()
        tasks[id] = nil
        items.removeAll { $0.id == id }
        generation[id] = nil
        persist()
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // 重试要清掉续传状态：失败的原因可能就是 uploadId 在服务端已失效，
        // 留着它去续传只会一直失败
        items[index].uploadID = nil
        items[index].completedParts.removeAll()
        items[index].uploadedBytes = 0
        items[index].message = ""
        items[index].status = .queued
        start(id)
    }

    func removeCompleted() {
        items.removeAll { $0.status.isTerminal }
        persist()
    }

    func clearStatus() { statusMessage = "" }

    // MARK: - 状态更新

    /// 这个任务还是不是当前任务。暂停/重试都会换号，旧任务的收尾据此作废。
    private func isCurrent(_ id: UUID, _ generation: Int) -> Bool {
        self.generation[id] == generation
    }

    private func credentials() async throws -> COSCredentials {
        if let cached = cachedCredentials, !cached.isExpired { return cached }
        let fresh = try await COSService.fetchCredentials()
        cachedCredentials = fresh
        return fresh
    }

    private func applyState(id: UUID, _ state: COSService.UploadState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].uploadState = state
        persist()
    }

    private func applyProgress(id: UUID, sent: Int64, total: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].uploadedBytes = max(items[index].uploadedBytes, sent)
        if total > 0 { items[index].totalBytes = total }
    }

    private func finish(id: UUID, with state: COSService.UploadState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].uploadedBytes = state.totalBytes
        items[index].totalBytes = max(items[index].totalBytes, state.totalBytes)
        items[index].uploadID = nil
        items[index].completedParts.removeAll()
        items[index].status = .completed
        items[index].message = "已完成"
        statusMessage = "✅ \(items[index].fileName) 上传完成"
        persist()
    }

    private func markPaused(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .uploading
        else { return }
        items[index].status = .paused
        items[index].message = "已暂停 · 已完成 \(Int(items[index].progress * 100))%"
        statusMessage = "已暂停 \(items[index].fileName)（继续时不会重传已传部分）"
        persist()
    }

    private func fail(id: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .failed
        items[index].message = message
        statusMessage = "❌ \(items[index].fileName): \(message)"
        persist()
    }

    // MARK: - 持久化

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: Self.storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: Self.storeURL, options: .atomic)
        } catch {
            statusMessage = "❌ 上传队列保存失败: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([UploadItem].self, from: data)
        else { return }

        // 上次退出时正在传的，重启后一律回到「已暂停」：
        // 进程没了，那个 Task 也不在了，标成「上传中」是自欺欺人。
        // 续传状态（uploadId + 已传分片）还在，点「继续」就能接着传。
        items = decoded.map { item in
            var item = item
            if item.status == .uploading {
                item.status = .paused
                item.message = "上次退出时中断 · 已完成 \(Int(item.progress * 100))%"
            }
            return item
        }

        let resumable = items.filter { $0.status == .paused && $0.uploadID != nil }.count
        if resumable > 0 {
            statusMessage = "已恢复 \(resumable) 个可续传的任务"
        }
    }
}
