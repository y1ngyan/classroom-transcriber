import AVFoundation
import Foundation

/// 坏掉的 wav 头：诊断 + 修复。
///
/// **默认只报不改。** 修复要调用方显式触发（`--wav-repair --apply` 或界面上的
/// 确认按钮），且每一处都打印「原值是什么、改成什么」。理由和 `IntegrityScan`
/// 不给自动修复是同一条：改用户数据出错一次就没有第二次机会，而「查出来什么」
/// 和「该怎么处置」是两个决定。
///
/// **三类，处置完全不同**（实测依据见 `tools/probes/recovery-notes.md`）：
///
/// - `.staleSizes` —— 头是合法的，只有两个长度字段比真实文件短。这是
///   `WAVRecorder` 每秒回填一次头留下的**崩溃窗口**（`headerRefreshBytes`
///   = 96000 字节 = 1 秒）。格式就在文件自己的 `fmt ` 块里，**只重写两个
///   长度字段**，不含任何假设。
/// - `.zeroHeader` —— 前 44 字节全零。这是旧版 `WAVRecorder` 的零占位遗留
///   （见那边 `init` 里的注释）。PCM 一个字节没丢，但**采样率根本不在文件里**，
///   所以这一类的修复**含一个假设**：按本 App 唯一的录音格式补
///   （48kHz / 单声道 / 16-bit）。假设必须被打印出来，不能装作是读出来的。
/// - `.foreign` —— 既不是 RIFF、头也不是全零（实测库里有一个是 UTF-8 文本
///   被存成了 .wav）。**一律拒绝**：给它补一个音频头等于把文本文件改成噪声，
///   那是破坏不是修复。
enum WAVHeaderRepair {

    /// 标准 PCM 头的长度，也是零占位遗留里被写坏的那一段
    static let headerSize = 44

    /// `.zeroHeader` 那一类不得不假设的格式。
    ///
    /// 依据不是猜的：`TranscriptionEngine.makeRecorder` 只按一个格式建录音器
    /// （`monoFormat.sampleRate` + 单声道，见 `WAVRecorder.append` 只取第 0
    /// 声道），而库里同期正常的 wav `afinfo` 报 `bit rate: 768000` = 48000×16。
    /// 但它在这些文件里**确实不存在**，所以 `apply` 会把它打进输出
    static let assumedSampleRate: UInt32 = 48_000
    static let assumedChannels: UInt16 = 1
    static let assumedBitsPerSample: UInt16 = 16

    // MARK: - 诊断

    enum Defect: Equatable {
        /// 头合法，但长度字段比真实文件短。`declared` 是**原值**
        case staleSizes(declaredDataBytes: Int, actualDataBytes: Int)
        /// 前 44 字节全零（旧版零占位），**而且后面真的有 PCM**
        case zeroHeader(actualDataBytes: Int)
        /// 前 44 字节全零，**而且一个字节的 PCM 都没有**（文件总共 44 字节）。
        ///
        /// 单独一档的理由：给它补一个合法的 0 秒头**不是恢复任何东西**——
        /// 它本来就没有内容可恢复。混在 `.zeroHeader` 里会让「可修 N 个」
        /// 这个数字对用户**过度承诺**；反过来把它藏掉也不行，用户有权看见
        /// 「这里有一条空录音」再自己决定删不删。所以：**可见，但不算可修**
        case emptyRecording(actualDataBytes: Int)
        /// 拒绝修复
        case foreign(reason: String)

        /// **三个生产调用点决定「给不给用户修」用的就是这一个属性**
        /// （`RecordingsStore.recover` 的两处 guard、`--wav-repair` 的
        /// 「可修 N 个」、`RecoveryScan` 的恢复前提示），所以它自己必须
        /// 有判据钉死，不能只靠 `apply` 里那道会抛错的闸兜底——
        /// 那道闸抛的错在调用点会被 `try?` 吞掉，计数照样对（P9-1b 的由来）
        var isRepairable: Bool {
            switch self {
            case .staleSizes, .zeroHeader: true
            case .emptyRecording, .foreign: false
            }
        }

        /// 给人看的一行。**放在 `Defect` 上而不是各调用点各写一份**：
        /// 三处（列表、修复报告、恢复前提示）说的必须是同一件事
        var userNote: String {
            switch self {
            case .staleSizes:
                "恢复时会一并修复音频头（崩溃留下的，长度字段比真实文件短）"
            case .zeroHeader:
                "恢复时会一并修复音频头（旧版零占位遗留，采样率按本 App 唯一的录音格式补）"
            case .emptyRecording:
                "空录音：没有音频内容，修不了、也不需要修"
            case .foreign:
                "音频头坏了，而且这一类**修不了**（这个文件不是音频）"
            }
        }

        /// 修复报告里「不动的那几个」按什么名目列出来
        var refusedLabel: String {
            switch self {
            case .staleSizes, .zeroHeader: "（会被修）"
            case .emptyRecording: "空录音（没有音频内容，不需要修）"
            case .foreign(let reason): "非音频（拒绝修复：\(reason)）"
            }
        }
    }

    struct Inspection: Equatable {
        let url: URL
        let fileBytes: Int
        let defect: Defect

        var fileName: String { url.lastPathComponent }

        /// 给人看的一行。**原值一定在里面**——「修了什么」说不清「原来是什么」
        /// 就等于没记账
        var summary: String {
            switch defect {
            case let .staleSizes(declared, actual):
                let lost = Double(actual - declared) / 96_000
                return "长度字段过期：头声明 \(declared) 字节，实际 \(actual) 字节"
                    + "（少报 \(actual - declared) 字节 ≈ \(String(format: "%.2f", lost)) 秒）"
            case let .zeroHeader(actual):
                return "头全零（旧版零占位遗留）：\(fileBytes) 字节里前 44 字节是零，"
                    + "其后 \(actual) 字节是 PCM"
            case .emptyRecording(let actual):
                return "空录音（旧版零占位遗留）：\(fileBytes) 字节里前 44 字节是零，"
                    + "其后 \(actual) 字节是 PCM —— **没有可恢复的内容**"
            case let .foreign(reason):
                return "拒绝修复：\(reason)"
            }
        }
    }

    // MARK: - 扫描（只读）

    /// 只看一个文件。**只读**：只是 `FileHandle(forReadingFrom:)` 读头，
    /// 不写、不 seek 到尾部、不解码
    static func inspect(_ url: URL) -> Inspection? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let total = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        guard let head = try? handle.read(upToCount: headerSize), head.count == headerSize else {
            return Inspection(url: url, fileBytes: total,
                              defect: .foreign(reason: "文件不足 \(headerSize) 字节，连头都不完整"))
        }
        let actual = max(0, total - headerSize)

        if head.prefix(4) == Data("RIFF".utf8) {
            // 只认本 App 写出来的那种规范头：`fmt ` 在 12、`data` 在 36。
            // 带额外 chunk 的文件（LIST/bext…）长度字段的位置不同，**不猜**——
            // 猜错就是把真实音频截掉一段
            guard head[12..<16] == Data("fmt ".utf8), head[36..<40] == Data("data".utf8) else {
                return Inspection(url: url, fileBytes: total,
                                  defect: .foreign(reason: "RIFF 头但布局不是本 App 的规范头（`fmt `/`data` 不在预期偏移）"))
            }
            let declared = Int(readU32(head, at: 40))
            let riff = Int(readU32(head, at: 4))
            // RIFF 长度字段比 data 字段多 36（它管的是「data 之后还剩多少」）。
            // 两个字段**都要**对，只对上一个是另一种坏法，不在这里修
            guard riff == declared + 36 else {
                return Inspection(url: url, fileBytes: total,
                                  defect: .foreign(reason: "RIFF 长度字段（\(riff)）与 data 长度字段（\(declared)）不自洽"))
            }
            if declared == actual { return nil }   // 好的，一个字都不动
            return Inspection(url: url, fileBytes: total,
                              defect: .staleSizes(declaredDataBytes: declared, actualDataBytes: actual))
        }

        // 不是 RIFF。**只认「前 44 字节全零」这一种签名**——它是旧版零占位的
        // 指纹，可复现、可解释。别的（文本、随便什么二进制）一律拒绝：
        // 判据越窄，误伤越少
        if head.allSatisfy({ $0 == 0 }) {
            // 零 PCM = 空录音。「修」它是给它编一个 0 秒的头，那不是恢复内容，
            // 却会让「可修 N 个」对用户过度承诺，所以单独一档（见 `Defect`）
            return Inspection(url: url, fileBytes: total, defect: actual == 0
                ? .emptyRecording(actualDataBytes: actual)
                : .zeroHeader(actualDataBytes: actual))
        }
        return Inspection(url: url, fileBytes: total,
                          defect: .foreign(reason: "开头既不是 RIFF 也不是全零（前 4 字节 \(head.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))）"))
    }

    /// 扫一个目录。**只报坏的**，好的文件不出现在结果里
    static func scan(directory: URL) -> [Inspection] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { inspect($0) }
    }

    // MARK: - 修复（显式触发）

    struct Outcome: Equatable {
        let fileName: String
        let lines: [String]
    }

    enum RepairError: Error, CustomStringConvertible {
        case notRepairable(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case let .notRepairable(reason): reason
            case let .writeFailed(reason): "写入失败：\(reason)"
            }
        }
    }

    /// **原地只改头，不动一个字节的音频。**
    ///
    /// 不重写整个文件：`.zeroHeader` 那一类动辄 37MB，而真正要改的只有开头
    /// 44 字节。seek 过去写、不 truncate——文件长度不变
    @discardableResult
    static func apply(_ inspection: Inspection) throws -> Outcome {
        var lines: [String] = []
        let url = inspection.url

        switch inspection.defect {
        case let .foreign(reason):
            throw RepairError.notRepairable(reason)

        case .emptyRecording:
            throw RepairError.notRepairable("空录音：一个字节的 PCM 都没有，没有东西可以恢复")

        case let .staleSizes(declared, actual):
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: littleEndianU32(UInt32(36 + actual)))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: littleEndianU32(UInt32(actual)))
            try handle.synchronize()
            lines.append("  \(inspection.fileName)")
            lines.append("    RIFF 长度    \(declared + 36) → \(actual + 36)")
            lines.append("    data 长度    \(declared) → \(actual)")
            lines.append("    音频字节    未改动（只重写了头里的两个长度字段）")

        case let .zeroHeader(actual):
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.canonicalHeader(
                dataBytes: actual,
                sampleRate: assumedSampleRate,
                channels: assumedChannels,
                bitsPerSample: assumedBitsPerSample
            ))
            try handle.synchronize()
            lines.append("  \(inspection.fileName)")
            lines.append("    头格式       全零 → RIFF/WAVE（\(assumedSampleRate)Hz · "
                         + "\(assumedChannels) 声道 · \(assumedBitsPerSample)-bit）")
            lines.append("    RIFF 长度    0 → \(actual + 36)")
            lines.append("    data 长度    0 → \(actual)")
            lines.append("    ⚠️ 假设       采样率 \(assumedSampleRate)Hz · \(assumedChannels) 声道"
                         + " · \(assumedBitsPerSample)-bit —— **这个值不在文件里**，"
                         + "是按本 App 唯一的录音格式补的")
            lines.append("    音频字节     未改动（只重写了前 44 字节）")
        }

        // 写完立刻用系统读取器验一遍。**不验的修复等于没修**——
        // 上面那些字节偏移只要错一个，文件依然是打不开的，而日志会说「已修复」
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            lines.append("    验证         AVAudioFile 读到了 · \(String(format: "%.3f", seconds)) 秒"
                         + " · \(Int(file.processingFormat.sampleRate))Hz")
        } else {
            throw RepairError.writeFailed("写完之后 AVAudioFile 依然打不开，头没修对")
        }

        return Outcome(fileName: inspection.fileName, lines: lines)
    }

    // MARK: - 字节

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func littleEndianU32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// 规范头。**和 `WAVRecorder.header` 是同一套布局**——两处必须一致，
    /// 否则修过的文件会被自己的写入器当成坏文件（自检里对着 `WAVRecorder`
    /// 写出来的文件跑一遍，就是钉这件事）
    static func canonicalHeader(
        dataBytes: Int, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16
    ) -> Data {
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        let blockAlign = channels * bitsPerSample / 8
        ascii("RIFF"); u32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * UInt32(blockAlign)); u16(blockAlign); u16(bitsPerSample)
        ascii("data"); u32(UInt32(dataBytes))
        return data
    }
}
