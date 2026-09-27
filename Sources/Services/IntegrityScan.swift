import AVFoundation
import Foundation

/// 全库脏数据体检。
///
/// **这个类型是只读的**：它 `contentsOfDirectory` / `Data(contentsOf:)` /
/// `AVAudioFile(forReading:)`，没有一处 `write` / `removeItem` / `moveItem`。
/// 这不是「我们记得别写」——自检里有一条判据把扫描前后每个文件的 sha256
/// 对一遍，多写一个字节就红。
///
/// **也不给自动修复**。删用户数据这件事，出错一次就没有第二次机会；而
/// 「扫出什么」和「该拿它怎么办」是两个决定，后者要人看着具体那几条来定。
/// 所以报告只点名，不动手。
enum IntegrityScan {

    // MARK: - 类别

    /// 会报的几类。`rawValue` 是稳定机器键（报告里打在行首，便于 grep），
    /// `label` 是给人看的
    enum Kind: String, CaseIterable {
        case reversedSegment = "reversed-segment"
        case zeroLengthSegment = "zero-length-segment"
        case emptyTextSegment = "empty-text-segment"
        case missingAudio = "missing-audio"
        case orphanAudio = "orphan-audio"
        case emptySession = "empty-session"
        case truncatedWav = "truncated-wav"

        var label: String {
            switch self {
            case .reversedSegment: "反向段"
            case .zeroLengthSegment: "零长段"
            case .emptyTextSegment: "空文本段"
            case .missingAudio: "音频文件缺失的会话"
            case .orphanAudio: "孤儿音频（有音频没会话）"
            case .emptySession: "孤儿会话（有会话没音频）"
            case .truncatedWav: "半截 wav"
            }
        }
    }

    /// 一条脏数据。**必须能指到具体是哪条会话的哪一段**——
    /// 只说「有 12 个反向段」的报告没法行动，说了是哪条会话才能去看
    struct Finding: Equatable {
        let kind: Kind
        /// 孤儿音频没有会话，为 nil
        let sessionID: UUID?
        let fileName: String?
        let detail: String
    }

    struct Report: Equatable {
        var findings: [Finding] = []
        var sessionCount = 0
        var audioFileCount = 0

        func findings(of kind: Kind) -> [Finding] { findings.filter { $0.kind == kind } }
        var isClean: Bool { findings.isEmpty }

        /// 按类别汇总的行。扫完先看这个，要看具体哪几条再看明细
        var summaryLines: [String] {
            Kind.allCases.map { kind in
                let n = findings(of: kind).count
                return "  \(n == 0 ? "✅" : "⚠️") \(kind.label)　\(n) 条"
            }
        }
    }

    // MARK: - 阈值

    /// 「wav 时长与会话声明明显不符」里的「明显」。
    ///
    /// 两个都要超才算：绝对差 2 秒**且**相对差 5%。单用绝对差的话，一条
    /// 3 秒的短录音差 1.5 秒（50%）不算异常；单用相对差的话，一条 45 分钟
    /// 的课差 60 秒（2%）会漏。取两者的大者当门槛。
    ///
    /// 这两个数是**对着真实库定**的，不是拍的：先拿库里 6 条被引用的 wav
    /// 量了一遍差值，全部是「wav 略长于声明」（录音器比引擎的时钟多写一点点），
    /// 量到 **最大 +700ms / 相对 0.069%，中位 58ms**。门槛取 max(2000ms, 5%)
    /// ——绝对上比实测最大差还宽 3 倍，相对上宽 70 倍。真有一条被截断的录音
    /// 不会只差 2 秒，而这个余量足以保证正常会话一条都不被冤枉
    static let wavDurationToleranceMillis = 2_000
    static let wavDurationToleranceRatio = 0.05

    // MARK: - 扫描

    static func scan(sessionsDirectory: URL, recordingsDirectory: URL) -> Report {
        var report = Report()

        let sessions = loadSessions(in: sessionsDirectory)
        report.sessionCount = sessions.count

        let audioFiles = listAudioFiles(in: recordingsDirectory)
        report.audioFileCount = audioFiles.count

        // 被任何一条会话引用过的文件名。孤儿音频 = 不在这个集合里的
        var referenced: Set<String> = []

        for (url, session) in sessions {
            scanSession(session, file: url.lastPathComponent,
                        recordingsDirectory: recordingsDirectory,
                        referenced: &referenced, into: &report)
        }

        for file in audioFiles where !referenced.contains(file) {
            report.findings.append(Finding(
                kind: .orphanAudio, sessionID: nil, fileName: file,
                // **必须点名到文件**：只报「有 41 个孤儿音频」是没法行动的，
                // 而 41 行一模一样的说明看着像渲染坏了。第一次跑真实库就是
                // 40 行「有这个文件」——没有一行说得清是哪个文件
                detail: "recordings/\(file) 没有任何会话的片段引用它"
            ))
        }
        return report
    }

    /// 一条会话的逐项检查。`file` 是它自己的 json 文件名——会话连读都读不出来时
    /// 报告要指得到文件，指 UUID 是没用的（UUID 就在那个文件名里）
    private static func scanSession(
        _ session: RecordingSession,
        file: String,
        recordingsDirectory: URL,
        referenced: inout Set<String>,
        into report: inout Report
    ) {
        // 「有会话没音频」：一条片段都没有的会话。**只有这一种**算——
        // `recordsAudio` 关着时片段合法地没有 fileName，那不是脏数据，
        // 把它们也算进来就是误报
        if session.parts.isEmpty {
            report.findings.append(Finding(
                kind: .emptySession, sessionID: session.id, fileName: file,
                detail: "会话一个片段都没有"
            ))
        }

        for (partIndex, part) in session.parts.enumerated() {
            for (segIndex, segment) in part.segments.enumerated() {
                let where_ = "第 \(partIndex + 1) 段 · 第 \(segIndex + 1) 句"

                // 复用 C-4 的纯判定，不另写一遍 `end < start`——两处写法
                // 一旦漂移，体检和运行时告警说的就不是一回事了
                if RecordingSession.isReversed(segment) {
                    report.findings.append(Finding(
                        kind: .reversedSegment, sessionID: session.id, fileName: file,
                        detail: "\(where_) · \(segment.startTimeMillis)→\(segment.endTimeMillis)ms"
                    ))
                } else if segment.startTimeMillis == segment.endTimeMillis {
                    report.findings.append(Finding(
                        kind: .zeroLengthSegment, sessionID: session.id, fileName: file,
                        detail: "\(where_) · 起止都是 \(segment.startTimeMillis)ms"
                    ))
                }
                if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    report.findings.append(Finding(
                        kind: .emptyTextSegment, sessionID: session.id, fileName: file,
                        detail: "\(where_) · \(segment.startTimeMillis)→\(segment.endTimeMillis)ms 的正文是空白"
                    ))
                }
            }

            guard let name = part.fileName else { continue }
            referenced.insert(name)
            let url = recordingsDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                report.findings.append(Finding(
                    kind: .missingAudio, sessionID: session.id, fileName: name,
                    detail: "第 \(partIndex + 1) 段声明了 \(name)，但 recordings/ 里没有这个文件"
                ))
                continue
            }
            scanWavDuration(url, part: part, partIndex: partIndex,
                            session: session, into: &report)
        }
    }

    /// wav 实际时长 vs 会话声明的时长。
    ///
    /// 读时长走 `AVAudioFile` 而不是 `afinfo`：同一件事（只读文件头，
    /// 不解码、不播放），但不用起子进程、不用解析它的输出格式
    private static func scanWavDuration(
        _ url: URL,
        part: RecordingPart,
        partIndex: Int,
        session: RecordingSession,
        into report: inout Report
    ) {
        guard let file = try? AVAudioFile(forReading: url) else {
            report.findings.append(Finding(
                kind: .truncatedWav, sessionID: session.id, fileName: url.lastPathComponent,
                detail: "第 \(partIndex + 1) 段的 wav 打不开（文件头坏了或不是音频）"
            ))
            return
        }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return }
        let actualMillis = Int(Double(file.length) / rate * 1000)
        let declared = part.durationMillis
        let delta = actualMillis - declared
        let threshold = max(wavDurationToleranceMillis,
                            Int(Double(declared) * wavDurationToleranceRatio))
        guard abs(delta) > threshold else { return }
        report.findings.append(Finding(
            kind: .truncatedWav, sessionID: session.id, fileName: url.lastPathComponent,
            detail: "第 \(partIndex + 1) 段：wav 实际 \(actualMillis)ms，会话声明 \(declared)ms，"
                + "差 \(delta > 0 ? "+" : "")\(delta)ms（门槛 \(threshold)ms）"
        ))
    }

    // MARK: - 读盘（只读）

    /// 读会话目录下所有 `<uuid>.json`。`index.json` 跳过——它是派生的摘要，
    /// 不是会话正文。解不出来的文件**不算脏数据**：这里只管数据的内容，
    /// 「文件坏了读不出来」是另一类（本包不去猜它的语义）
    static func loadSessions(in directory: URL) -> [(URL, RecordingSession)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let session = try? decoder.decode(RecordingSession.self, from: data)
                else { return nil }
                return (url, session)
            }
    }

    static func listAudioFiles(in directory: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .map(\.lastPathComponent)
            .sorted()
    }
}
