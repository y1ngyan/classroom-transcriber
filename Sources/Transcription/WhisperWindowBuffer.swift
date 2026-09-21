import Foundation

/// 为 Whisper 滑窗准实时转录攒音频的 ring buffer。
///
/// 采集线程把 16kHz 单声道 Float32 样本 append 进来；后台推理 Task
/// 每 3 秒取一次最近 10 秒的窗口。容量比最大窗口稍长，给合并策略留余量。
///
/// 线程安全：采集线程和推理 Task 不是同一个队列，用 NSLock 保护内部
/// 状态。`@unchecked Sendable` 是因为 `[Float]` 本身不是 Sendable，
/// 但锁保证了不会并发访问。
final class WhisperWindowBuffer: @unchecked Sendable {

    private let lock = NSLock()
    private var buffer: [Float]
    private var totalAppended: Int = 0
    private let capacity: Int

    /// - Parameters:
    ///   - capacitySeconds: ring buffer 最大保留时长。默认 15 秒，
    ///     大于 10 秒窗口 + 3 秒步长，防止边界处需要多读一点时拿不到。
    ///   - sampleRate: 固定 16kHz（Whisper 的输入格式）。
    init(capacitySeconds: Double = 15, sampleRate: Double = 16_000) {
        self.capacity = Int(capacitySeconds * sampleRate)
        self.buffer = []
        self.buffer.reserveCapacity(self.capacity)
    }

    /// 追加样本。采集线程每回调一次 append 一次。
    func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(contentsOf: samples)
        totalAppended += samples.count
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    /// 取最后 `durationSeconds` 的样本。
    ///
    /// - Returns: 样本数组；`nil` 表示累积量还不够一个完整窗口。
    func window(durationSeconds: Double, sampleRate: Double = 16_000) -> [Float]? {
        let needed = Int(durationSeconds * sampleRate)
        lock.lock(); defer { lock.unlock() }
        guard buffer.count >= needed else { return nil }
        return Array(buffer.suffix(needed))
    }

    /// 从启动至今累计追加的样本数（包含已经被挤出 ring buffer 的）。
    /// 用于把样本索引换算成全局时间戳。
    var totalSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return totalAppended
    }
}

// MARK: - 无头自检

extension WhisperWindowBuffer {

    /// `--whisper-buffer-selftest`：攒帧缓冲的回归。
    ///
    /// 纯内存、不碰音频设备（App 可能正在录音，不能抢麦克风）。
    /// 采样率取 100Hz 是为了让用例小到看不出来，判据全是比例关系，与真实
    /// 16kHz 无关。
    static func selfTest() -> [String] {
        var lines: [String] = ["Whisper 滑窗攒帧自检（纯内存 · 不碰麦克风 · 无模型）"]
        var allPassed = true

        func check(_ name: String, _ condition: Bool, _ detail: String) {
            allPassed = allPassed && condition
            lines.append("  \(condition ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        let rate: Double = 100          // 100Hz：15 秒容量 = 1500 样本
        let capacity = 15.0
        let windowSeconds = 10.0
        let windowSamples = Int(windowSeconds * rate)   // 1000

        // MARK: 用例 1：攒不够一窗返回 nil，刚好够就非 nil
        do {
            let buf = WhisperWindowBuffer(capacitySeconds: capacity, sampleRate: rate)
            buf.append([Float](repeating: 0, count: windowSamples - 1))
            let justShort = buf.window(durationSeconds: windowSeconds, sampleRate: rate)
            buf.append([Float](repeating: 0, count: 1))
            let exactly = buf.window(durationSeconds: windowSeconds, sampleRate: rate)

            check("差 1 个样本时拿不到窗口", justShort == nil, "\(justShort?.count ?? -1)")
            check("刚好够一窗时能拿到，且长度正确",
                  exactly?.count == windowSamples, "\(exactly?.count ?? -1)（期望 \(windowSamples)）")
        }

        // MARK: 用例 2：取的是「最后 N 个」而不是最先的
        do {
            let buf = WhisperWindowBuffer(capacitySeconds: capacity, sampleRate: rate)
            let total = windowSamples + 300
            buf.append((0..<total).map { Float($0) })
            let w = buf.window(durationSeconds: windowSeconds, sampleRate: rate)
            // 期望：样本 total-windowSamples ... total-1，按序
            let expectedFirst = Float(total - windowSamples)
            let expectedLast = Float(total - 1)
            check("窗口是最新的那一段（收尾对齐）",
                  w?.first == expectedFirst && w?.last == expectedLast,
                  "首=\(w?.first ?? -1)（期望 \(expectedFirst)）尾=\(w?.last ?? -1)（期望 \(expectedLast)）")
        }

        // MARK: 用例 3：超过容量只留最后 capacity 个，但累计计数不丢
        do {
            let buf = WhisperWindowBuffer(capacitySeconds: capacity, sampleRate: rate)
            let cap = Int(capacity * rate)
            buf.append((0..<(cap * 3)).map { Float($0) })   // 灌三倍容量
            let w = buf.window(durationSeconds: capacity, sampleRate: rate)
            check("缓冲长度被裁到容量上限",
                  w?.count == cap, "\(w?.count ?? -1)（期望 \(cap)）")
            check("留下的确实是最后一段（最老的被挤出去）",
                  w?.last == Float(cap * 3 - 1), "尾=\(w?.last ?? -1)（期望 \(Float(cap * 3 - 1))）")
            check("totalSampleCount 仍记全部（全局时间戳换算靠它）",
                  buf.totalSampleCount == cap * 3, "\(buf.totalSampleCount)（期望 \(cap * 3)）")
        }

        // MARK: 用例 4：分块 append 与一次大块等价（采集线程是按回调分块来的）
        do {
            let chunked = WhisperWindowBuffer(capacitySeconds: capacity, sampleRate: rate)
            let whole = WhisperWindowBuffer(capacitySeconds: capacity, sampleRate: rate)
            let samples = (0..<windowSamples).map { Float($0) }
            var idx = 0
            while idx < samples.count {                       // 每块 137：不整除，逼出边界
                let end = min(idx + 137, samples.count)
                chunked.append(Array(samples[idx..<end]))
                idx = end
            }
            whole.append(samples)
            // 逐样本比，不是比长度——长度对而上例出现过「内容全 0」的教训
            let a = chunked.window(durationSeconds: windowSeconds, sampleRate: rate)
            let b = whole.window(durationSeconds: windowSeconds, sampleRate: rate)
            check("分块攒帧与一次灌入逐样本一致", a == b && a?.count == windowSamples,
                  "块大小 137 · 块数 \((samples.count + 136) / 137)")
        }

        // MARK: 用例 5：多线程并发 append 不丢样本（采集线程和推理 Task 不同队列）
        do {
            let buf = WhisperWindowBuffer(capacitySeconds: capacity, sampleRate: rate)
            let threads = 8, perThread = 200, perCall = 97
            DispatchQueue.concurrentPerform(iterations: threads) { _ in
                let chunk = [Float](repeating: 0.5, count: perCall)
                for _ in 0..<perThread { buf.append(chunk) }
            }
            let expected = threads * perThread * perCall
            check("并发 append 后累计计数不多不少",
                  buf.totalSampleCount == expected,
                  "\(buf.totalSampleCount)（期望 \(expected)，\(threads) 线程 × \(perThread) 次 × \(perCall) 样本）")
            check("并发之后仍能正常取窗", buf.window(durationSeconds: windowSeconds, sampleRate: rate)?.count == windowSamples,
                  "")
        }

        lines.append(allPassed ? "✅ Whisper 滑窗攒帧自检通过" : "❌ Whisper 滑窗攒帧自检未通过")
        return lines
    }
}
