import Foundation

// MARK: - 策略

/// 环形文件的尺寸策略。**纯算术，不碰盘**——自检可以直接拿它做
/// 「写 2000 条之后封顶是多少」的推演，不用先写 2000 条
struct LogRingPolicy: Equatable {

    /// 单个文件的字节上限
    var maxFileBytes: Int
    /// 归档份数。加上活跃的那一份，一共 `maxArchives + 1` 个文件
    var maxArchives: Int

    /// 活跃文件 256 KB × 4 个文件 = **总共约 1 MB，到顶就不再长**
    static let `default` = LogRingPolicy(maxFileBytes: 256 * 1024, maxArchives: 3)

    var totalByteCap: Int { maxFileBytes * (maxArchives + 1) }
    var maxFileCount: Int { maxArchives + 1 }

    var activeName: String { "diagnostics.log" }
    /// 1 = 最近一份归档，`maxArchives` = 最老的一份
    func archiveName(_ index: Int) -> String { "diagnostics.\(index).log" }

    /// 现在这个大小再写 `incomingBytes` 字节，要不要先轮转。
    ///
    /// `currentBytes > 0` 那个条件是**必要的**，不是防御性写法：单条日志
    /// 比 `maxFileBytes` 还长时（消息里塞了一大坨），如果不加这一条，
    /// 空文件也会判定「该轮转了」，于是每写一条就轮转一次，把前面所有
    /// 归档全推走，日志目录里最后只剩那一条——**上限没破，但整份历史
    /// 都丢了**。加上之后，超长行会在一个空文件里老老实实写下去
    func shouldRotate(currentBytes: Int, incomingBytes: Int) -> Bool {
        currentBytes > 0 && currentBytes + incomingBytes > maxFileBytes
    }
}

// MARK: - 写入器

/// 固定上限的环形日志文件。
///
/// **它的全部意义是「崩溃后仍能读到崩溃前最后 N 条」**，所以有两件事
/// 不能妥协：
///
/// ① **不做用户态缓冲**。每 `append` 一次就 `write(2)` 一次、随即关掉句柄。
///    有人会想「开个常驻句柄、攒一批再写」——那正好把这个类存在的理由
///    抹掉：`kill -9` 时攒在内存里的那批就没了，而那批恰恰是最接近现场的。
///    **不调 `fsync`** 也是有意的：`write` 之后数据已经在内核页缓存里，
///    杀进程不会带走它（丢的是断电/内核崩溃那一种，那不在本包范围内），
///    而每行一次 fsync 会把这条路径拖到毫秒级。
///
/// ② **上限是硬的**。任何时刻磁盘占用 ≤ `policy.totalByteCap`，
///    与运行多久、出了多少次错无关。写入量只影响「能回溯多久」，不影响
///    「占多大」——这是「绝不无限增长」那句要求的具体形状。
final class LogRingWriter: @unchecked Sendable {

    private let lock = NSLock()
    private let directory: URL
    let policy: LogRingPolicy

    /// `@unchecked Sendable`：`FileManager` 是线程安全的，其余可变状态
    /// 全在 `lock` 里。承诺见 `DiagnosticLogSink` 那边的注释
    private let fm = FileManager.default

    init(directory: URL, policy: LogRingPolicy = .default) {
        self.directory = directory
        self.policy = policy
    }

    // MARK: 路径

    var activeURL: URL { directory.appendingPathComponent(policy.activeName) }
    func archiveURL(_ index: Int) -> URL {
        directory.appendingPathComponent(policy.archiveName(index))
    }

    /// 从最老到最新：`N, N-1, …, 1, active`。
    /// **顺序就是读回顺序**，所以只此一处，读和写都从这里取
    private var orderedURLs: [URL] {
        var urls: [URL] = []
        if policy.maxArchives >= 1 {
            for i in stride(from: policy.maxArchives, through: 1, by: -1) { urls.append(archiveURL(i)) }
        }
        urls.append(activeURL)
        return urls
    }

    // MARK: 写

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = Data((line + "\n").utf8)
        if policy.shouldRotate(currentBytes: size(of: activeURL), incomingBytes: data.count) {
            rotate()
        }
        appendData(data, to: activeURL)
    }

    /// 轮转：`active → 1 → 2 → … → N`，最老的 N 被删掉。
    ///
    /// **顺序是这个方法唯一的讲究**：先删最老的，再从老到新挪，最后才动
    /// 活跃文件。反过来的话（先把 active 改成 1），中途出错就会撞上
    /// 一个还占着位的 1——`moveItem` 会失败，而失败是 `try?` 吞掉的，
    /// 于是**活跃文件凭空消失、日志从这一刻起断掉**，且不报任何错
    private func rotate() {
        try? fm.removeItem(at: archiveURL(policy.maxArchives))
        if policy.maxArchives > 1 {
            for i in stride(from: policy.maxArchives - 1, through: 1, by: -1) {
                try? fm.moveItem(at: archiveURL(i), to: archiveURL(i + 1))
            }
        }
        try? fm.moveItem(at: activeURL, to: archiveURL(1))
        // 不在这里建新的活跃文件：下一次 `append` 会建。
        // 建了的话，「刚轮转完就崩」会留下一个 0 字节文件冒充一条日志
    }

    private func appendData(_ data: Data, to url: URL) {
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // MARK: 读

    /// 崩溃后回读：所有归档 + 活跃文件，按时间序的最后 `limit` 条。
    ///
    /// **末尾那条不完整也照样返回**：进程是在写它的中途被打死的，
    /// 半行本身就是现场的一部分（比如「写到一半的那条正是崩的那条」）
    func recent(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }

        var lines: [String] = []
        for url in orderedURLs {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            lines += text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return Array(lines.suffix(limit))
    }

    // MARK: 量

    /// 现存文件字节总和。**自检的上限判据就钉在它上面**
    var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return orderedURLs.reduce(0) { $0 + size(of: $1) }
    }

    var fileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return orderedURLs.filter { fm.fileExists(atPath: $0.path) }.count
    }

    private func size(of url: URL) -> Int {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 自检用：清空整个目录下的日志文件。**只清自己的，不删目录**——
    /// 目录可能是用户别的数据所在的父目录（自检传的是临时目录，
    /// 但这个方法本身不该假设这一点）
    func removeAllFiles() {
        lock.lock()
        defer { lock.unlock() }
        for url in orderedURLs { try? fm.removeItem(at: url) }
    }
}
