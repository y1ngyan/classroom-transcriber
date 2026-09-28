import Foundation
import Darwin

// MARK: - 失败原因（可枚举）

/// 说话人识别失败的原因。**枚举而不是一句「识别失败」**——沿用
/// `StudyItemRejection` / `DiarizationValidationFailure` 立的范式：
/// 自检要能断言「是因为哪一条失败的」，验收报告里的原因分布也要按它分组。
/// 糊成一句话，这两件事都做不了
enum DiarizationFailureReason: String, Equatable, CaseIterable {
    /// 会话里没有任何片段带 wav 存档（`RecordingPart.fileName == nil`），或压根没有片段。
    /// 拍板第 1 条要求**一次吃整节课**，所以只要有一段没存档，整节课就喂不进去
    case noAudio
    /// app bundle 里找不到 helper，或者它不可执行
    case helperMissing
    /// 模型不在（helper 退出码 5）
    case modelMissing
    /// 模型加载/编译失败（退出码 6）
    case modelLoadFailed
    /// 输入文件不存在/不可读（退出码 3）
    case audioUnreadable
    /// 音频格式不支持/解码失败（退出码 4）
    case audioUnsupported
    /// 推理失败（退出码 7）
    case inferenceFailed
    /// 输出写失败（退出码 8）
    case outputWriteFailed
    /// 用法错误（退出码 2）。参数是 App 自己拼的，出现这条说明拼接逻辑坏了
    case badInvocation
    /// 超时被看门狗终止（退出码 9，或被 SIGTERM）
    case timeout
    /// 崩溃：被别的信号杀死、没有退出状态、或退出码不在 helper 的分类里
    case crashed
    /// 第 2 条校验：没有信封 / 解不开 / schemaVersion 不对 / status 不是 ok / result 缺失
    case envelopeInvalid
    /// 第 3 条校验：`audioSeconds` 与会话时长差超容差（拿错文件 / 半截结果）
    case audioSecondsMismatch
    /// 第 4 条校验：某个 segment 越界或零长
    case segmentOutOfRange
    /// 第 5 条校验：有 ≥1 秒的转录段却说 0 个说话人（前后矛盾）
    case speakerCountContradiction

    /// helper 的分类退出码 → 原因（设计稿 §2.5）。**别的码一律算崩溃**：
    /// 「没见过的退出码」被当成某个已知失败，会让真正的崩溃看起来像正常失败
    init(helperExitCode: Int32) {
        switch helperExitCode {
        case 2: self = .badInvocation
        case 3: self = .audioUnreadable
        case 4: self = .audioUnsupported
        case 5: self = .modelMissing
        case 6: self = .modelLoadFailed
        case 7: self = .inferenceFailed
        case 8: self = .outputWriteFailed
        case 9: self = .timeout
        default: self = .crashed
        }
    }

    /// 报告里分组用的短标签（原因分布按它统计）
    var label: String {
        switch self {
        case .noAudio: return "没有可用的录音存档"
        case .helperMissing: return "找不到 diarize-helper"
        case .modelMissing: return "说话人模型不在"
        case .modelLoadFailed: return "模型加载失败"
        case .audioUnreadable: return "音频读不出来"
        case .audioUnsupported: return "音频格式不支持"
        case .inferenceFailed: return "推理失败"
        case .outputWriteFailed: return "helper 写输出失败"
        case .badInvocation: return "helper 用法错误"
        case .timeout: return "超时"
        case .crashed: return "helper 异常退出"
        case .envelopeInvalid: return "helper 的输出信封不合法"
        case .audioSecondsMismatch: return "音频时长对不上"
        case .segmentOutOfRange: return "说话人段越界"
        case .speakerCountContradiction: return "有转写却说没语音"
        }
    }

    /// 给用户看的一句话：**说清下一步**，不是只说一句「失败」（同 `StudyNotesPanelState.missingKeyReason`）
    var userMessage: String {
        switch self {
        case .noAudio:
            return "这条录音没有音频存档，识别不了说话人（录音时「保存音频」没开）"
        case .helperMissing:
            return "App 里缺 diarize-helper，说话人识别不可用。重新跑一次 ./build.sh（它会构建并放进 App 包）"
        case .modelMissing:
            return "说话人模型不在 App 的模型目录里。跑一次 diarize-helper download 把它下下来"
        case .modelLoadFailed:
            return "说话人模型加载失败，可能是模型文件损坏。删掉模型目录后重新 download"
        case .audioUnreadable:
            return "录音文件读不出来（可能被移走或删了）"
        case .audioUnsupported:
            return "这段录音的格式解不开，识别不了说话人"
        case .inferenceFailed:
            return "说话人识别推理失败"
        case .outputWriteFailed:
            return "说话人识别写不出结果文件（磁盘满或没有权限）"
        case .badInvocation:
            return "启动说话人识别时参数拼错了（这是 App 的缺陷，请反馈）"
        case .timeout:
            return "说话人识别超时了（录音太长或机器太忙），可以重试"
        case .crashed:
            return "说话人识别进程异常退出"
        case .envelopeInvalid:
            return "说话人识别返回的结果不完整，已丢弃"
        case .audioSecondsMismatch:
            return "说话人识别返回的音频时长和这条录音对不上，结果已丢弃"
        case .segmentOutOfRange:
            return "说话人识别返回的段落越界，结果已丢弃"
        case .speakerCountContradiction:
            return "有转写文字却报告没检测到语音，前后矛盾，结果已丢弃"
        }
    }
}

struct DiarizationFailure: Equatable {
    var reason: DiarizationFailureReason
    /// 具体细节（helper 的 stderr 尾巴 / 哪个 segment 越界）。
    /// **只进日志和验收报告，不进界面**——界面只给 `reason.userMessage` 那一句
    var detail: String
}

// MARK: - 统计（验收报告要的量）

struct DiarizationStats: Equatable {
    var transcriptSegments = 0
    var labeled = 0
    /// 未标注且判为「这里没语音」：`Σ重叠 < 200ms`，或**零长转录段**（`b ≤ a`）。
    ///
    /// 这条分桶是**从 `SpeakerAssignment` 的公开取值推出来的**，不是重算了一遍
    /// 阈值：`overlapRatio == 0 && !isMixed`。两种真实情形会落进同一桶
    /// （真没重叠 / 有重叠但赢家占比低到第二人也不足 25%），所以报告里的
    /// 桶名说的是「mapper 这么判的」，不是「我另算了一遍」
    var unlabeledNoOverlap = 0
    /// 未标注但**确实有两人在说**（`isMixed == true`）：无多数派
    var unlabeledNoMajority = 0
    var mixed = 0
    var speakerCount = 0
    /// 转录里**时间反向**的段数（`end < start`）。正常恒为 0。
    ///
    /// 单独计数而不是让它混进 `unlabeledNoOverlap`：那一桶的含义是「这里没人
    /// 说话」（一段正常的判读），反向段的含义是「这条数据本身坏了」——两件事
    /// 合成一个数字，就再也分不出「这节课安静」和「这条会话是坏的」。
    /// 底层（`RecordingSession.absoluteRange`）对反向段的行为是「当零长处理」，
    /// 所以它**不会崩**，但也**不会自己喊**——喊的工作在这一格
    var reversedTranscriptSegments = 0
    var spanCount = 0
    var audioSeconds: Double = 0
    var helperWallSeconds: Double = 0

    /// 标注率 = 带标签的转录段 / 转录段总数
    var annotationRate: Double {
        transcriptSegments == 0 ? 0 : Double(labeled) / Double(transcriptSegments)
    }
}

// MARK: - 结果

struct DiarizationEvaluation {
    /// **要落盘的会话**：成功时带上物化好的三个字段；失败时三个字段全清空
    var session: RecordingSession
    /// 原始结果（真相来源）。失败时为 nil
    var diarization: SpeakerDiarization?
    var failure: DiarizationFailure?
    var stats: DiarizationStats

    var isOK: Bool { failure == nil }

    func report() -> [String] {
        var lines: [String] = []
        if let failure {
            lines.append("❌ 说话人识别失败：\(failure.reason.rawValue) · \(failure.reason.label)")
            lines.append("   \(failure.reason.userMessage)")
            if !failure.detail.isEmpty { lines.append("   细节：\(failure.detail)") }
            lines.append("   回退：diarization = nil，所有段的 speakerId = nil（**不是全员 S1**）")
            return lines
        }
        lines.append(String(format: "✅ 说话人识别通过 5 条校验"))
        // `audioSeconds` 那一格**必须走 `String(format:)`**：直接写在字符串里的话
        // `%.1f` 会原样打出来（2026-09-27 真实端到端第一次跑就撞上了，
        // 自检里断言的是 `stats.audioSeconds` 本身，所以没拦住这一行）
        lines.append(String(format: "   音频 %.1f 秒 · 说话人 %d 人 · diar 段 %d 个 · helper 墙钟 %.2f 秒",
                            stats.audioSeconds, stats.speakerCount, stats.spanCount,
                            stats.helperWallSeconds))
        lines.append("   转录段 \(stats.transcriptSegments) 个：已标注 \(stats.labeled)"
            + "（\(String(format: "%.1f", stats.annotationRate * 100))%）"
            + " · 含多人 \(stats.mixed)"
            + " · 未标注·无有效重叠 \(stats.unlabeledNoOverlap)"
            + " · 未标注·无多数派 \(stats.unlabeledNoMajority)"
            // 只在**真的出现**时才多打这一格：正常会话（反向段 0 条）的报告行
            // 一个字节都不变，C-3-1 已核验的那几行格式不受影响
            //（`~/ClassroomTranscriber-design/C-3-1核验记录.md` §三 逐项对过那张表）
            + (stats.reversedTranscriptSegments == 0
                ? ""
                : " · ⚠️ 反向转录段 \(stats.reversedTranscriptSegments)（数据异常，按零长处理）"))
        return lines
    }
}

// MARK: - 编号归一（纯函数）

/// 课内编号（C3a）：把 helper 给的原始 label 按「首次出现时间」重编成 `S1…Sn`。
///
/// **为什么必须归一而不是直接用 helper 的 label**：helper 的 label 来自 FluidAudio 的
/// 全局聚类，编号顺序由聚类决定，**不保证 `S1` 就是最先开口的那个人**。一节课里
/// 「S1 是个只在第 40 分钟插了一句的学生」这种编号，学生读起来就是错的。
/// 归一之后，`S2` 一定意味着「第 2 个开口的人」。
///
/// 纯函数：同输入两次调用必然同输出（并列时按原始 label 字典序决胜）
enum SpeakerNumbering {

    /// 原始 label 按首次出现时间升序
    static func order(of spans: [SpeakerSpan]) -> [String] {
        var firstSeen: [String: Int] = [:]
        for span in spans {
            let current = firstSeen[span.speakerId]
            firstSeen[span.speakerId] = current.map { min($0, span.startMillis) } ?? span.startMillis
        }
        return firstSeen.keys.sorted { lhs, rhs in
            let l = firstSeen[lhs] ?? 0
            let r = firstSeen[rhs] ?? 0
            if l != r { return l < r }
            return lhs < rhs
        }
    }

    /// 原始 label → `S1`/`S2`…
    static func normalized(_ spans: [SpeakerSpan]) -> [String: String] {
        var map: [String: String] = [:]
        for (index, raw) in order(of: spans).enumerated() {
            map[raw] = "S\(index + 1)"
        }
        return map
    }
}

// MARK: - 信封（helper 的输出，App 侧只解自己用得到的部分）

/// helper 的 JSON 信封（`schemaVersion 1`，见设计稿 §2.4）。
///
/// App 侧**只解自己消费的字段**，`timings` / `inputs` / `mode` 不进结构体：
/// 声明了却不用的字段，下一个人会以为它在参与判断。
/// `schemaVersion` 与 `status` 必须解——它们是权威成功信号
struct DiarizationEnvelope: Decodable {
    struct Segment: Decodable {
        var speakerId: String
        var startMillis: Int
        var endMillis: Int
        var qualityScore: Double
    }

    struct Result: Decodable {
        var audioSeconds: Double
        var speakerCount: Int
        var segments: [Segment]
    }

    struct Failure: Decodable {
        var code: String
        var message: String
    }

    var schemaVersion: Int
    var status: String
    var helperBuild: String?
    var result: Result?
    var error: Failure?

    static let currentSchemaVersion = 1
}

// MARK: - 服务

/// 说话人识别：调 helper → 校验 → 映射 → 把三个字段物化到 `TranscriptSegment`。
///
/// 三件事的次序是刻意的，也是这个类型存在的全部理由：
///   1. **5 条校验全过才允许标注**，任何一条不过 → `diarization = nil` 且所有
///      `speakerId = nil`。**回退的目标是 nil，不是某个说话人**——「失败就全员 S1」
///      是本项目最忌讳的失败形状（拍板原话），它让一次失败看起来像一次成功；
///   2. `speakerCount == 1` 是**阳性结果**（单人讲授就该标 S1），区分靠「校验过没过」，
///      不是「说话人数多少」；
///   3. 编号按**首次出现时间**归一（`SpeakerNumbering`），保证 `S2` = 第 2 个开口的人。
///
/// 这一层**不落盘**：它返回改好的 `RecordingSession`，写盘由调用方决定
/// （无头入口写临时副本；详情页那条路是 C-3-2，用户点了才写真实会话）
enum SpeakerDiarizationService {

    // MARK: - 输入音频

    /// 整节课的输入。**一次调用喂完所有片段**（拍板第 1 条）：
    /// 分片段跑的话 S1/S2 只在片段内一致，同一个老师在一节课里会换名字。
    ///
    /// 任何一段没有 wav 存档 → `nil`：整节课喂不进去，只能不做。
    /// 这里**不检查文件是否真的存在**——「读不出来」由 helper 判（退出码 3），
    /// 那是它的职责，App 再判一遍就是第二份实现
    static func inputs(of session: RecordingSession) -> [DiarizeHelperInput]? {
        guard !session.parts.isEmpty else { return nil }
        var inputs: [DiarizeHelperInput] = []
        for part in session.parts {
            guard let fileName = part.fileName else { return nil }
            inputs.append(DiarizeHelperInput(
                path: RecordingStorage.directory.appendingPathComponent(fileName).path,
                offsetMillis: part.offsetMillis
            ))
        }
        return inputs
    }

    /// 会话里有没有「够长」的转录段（≥1 秒）。第 5 条校验用它判前后矛盾
    static func hasLongTranscriptSegment(_ session: RecordingSession) -> Bool {
        session.parts.contains { part in
            part.segments.contains { $0.durationMillis >= 1_000 }
        }
    }

    // MARK: - 判定（纯函数，可离线断言）

    /// 从 helper 的一次运行结果算出该落盘的会话。**无 IO、不看时钟以外的环境**
    /// （`ranAt` 由调用方给），所以自检可以直接喂构造好的 `DiarizeHelperRun`。
    static func evaluate(
        session: RecordingSession,
        run: DiarizeHelperRun,
        ranAt: Date = Date()
    ) -> DiarizationEvaluation {

        /// 失败一律走这里。**清空所有 speakerId 是它唯一的落点**——
        /// 失败路径有好几条，每一条各自记得清空是不可能的
        func failing(_ reason: DiarizationFailureReason, _ detail: String) -> DiarizationEvaluation {
            var cleared = session
            for partIndex in cleared.parts.indices {
                for segmentIndex in cleared.parts[partIndex].segments.indices {
                    cleared.parts[partIndex].segments[segmentIndex].speakerId = nil
                    cleared.parts[partIndex].segments[segmentIndex].speakerOverlapRatio = nil
                    cleared.parts[partIndex].segments[segmentIndex].speakerMixed = false
                }
            }
            return DiarizationEvaluation(
                session: cleared, diarization: nil,
                failure: DiarizationFailure(reason: reason, detail: detail),
                stats: DiarizationStats(helperWallSeconds: run.wallSeconds)
            )
        }

        let stderrTail = run.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        func withStderr(_ message: String) -> String {
            stderrTail.isEmpty ? message : "\(message)；helper stderr：\(stderrTail)"
        }

        // ⓪ 音频输入。拍板第 1 条的前提，放在最前面：没有可喂的音频，
        //    后面任何一步都没有意义，也不该去启动一个必然会失败的进程
        guard inputs(of: session) != nil else {
            return failing(.noAudio, "会话里没有带 wav 存档的片段")
        }

        // ① 第 1 条校验：干净退出。超时单列——它是「我们杀了它」，
        //    和「它自己崩了」对用户是两件事（一个可以重试，一个要查）
        if run.timedOut {
            return failing(.timeout, String(format: "helper 超过 %.0f 秒被终止", run.wallSeconds))
        }
        if let launchError = run.launchError {
            return failing(.helperMissing, launchError)
        }
        guard let termination = run.termination else {
            return failing(.crashed, "没有拿到 helper 的退出状态")
        }
        if termination.reason == .uncaughtSignal {
            return failing(
                termination.status == SIGTERM ? .timeout : .crashed,
                "helper 被信号 \(termination.status) 杀死")
        }
        guard termination.status == 0 else {
            return failing(
                DiarizationFailureReason(helperExitCode: termination.status),
                withStderr("helper 退出码 \(termination.status)"))
        }

        // ② 第 2 条校验：信封存在、能解、schemaVersion/status 对、有 result
        guard let data = run.envelopeData,
              let envelope = try? JSONDecoder().decode(DiarizationEnvelope.self, from: data)
        else {
            return failing(.envelopeInvalid, withStderr("退出码 0，但没有可解析的输出信封"))
        }
        guard envelope.schemaVersion == DiarizationEnvelope.currentSchemaVersion else {
            return failing(.envelopeInvalid, "信封 schemaVersion = \(envelope.schemaVersion)（期望 1）")
        }
        guard envelope.status == "ok" else {
            return failing(.envelopeInvalid, "退出码 0 但信封 status = \(envelope.status)")
        }
        guard let result = envelope.result else {
            return failing(.envelopeInvalid, "信封里没有 result")
        }
        // helper 自己的附加一致性（不在 5 条里，但不一致的信封一律拒收）：
        // `speakerCount` 与 segments 里真实出现的说话人数对不上，说明这份结果本身是坏的
        let distinctSpeakers = Set(result.segments.map(\.speakerId)).count
        guard result.speakerCount == distinctSpeakers else {
            return failing(
                .envelopeInvalid,
                "speakerCount = \(result.speakerCount)，但 segments 里只出现 \(distinctSpeakers) 个说话人")
        }

        // ③ 第 3 条校验：`audioSeconds` 与会话时长对得上（防止拿错文件/半截结果）。
        //    容差 `max(2s, 1%)`——多片段摆放有 <1s/段的差（设计稿 §8 第 9 条），
        //    卡死了会把正常结果判成失败
        let sessionAudioSeconds = Double(session.durationMillis) / 1000
        let tolerance = max(2.0, sessionAudioSeconds * 0.01)
        let delta = abs(result.audioSeconds - sessionAudioSeconds)
        guard delta <= tolerance else {
            return failing(
                .audioSecondsMismatch,
                String(format: "helper 报 %.3f 秒，会话是 %.3f 秒（差 %.3f，容差 %.3f）",
                       result.audioSeconds, sessionAudioSeconds, delta, tolerance))
        }

        // ④ 第 4 条校验：每个段 `0 ≤ start < end ≤ audioSeconds*1000 + 1000`
        let upperBound = result.audioSeconds * 1000 + 1000
        for segment in result.segments {
            guard segment.startMillis >= 0,
                  segment.endMillis > segment.startMillis,
                  Double(segment.endMillis) <= upperBound
            else {
                return failing(
                    .segmentOutOfRange,
                    "段 \(segment.speakerId) [\(segment.startMillis), \(segment.endMillis)) 越界（上界 \(Int(upperBound))）")
            }
        }

        // ⑤ 第 5 条校验：有 ≥1 秒的转录段却说 0 个说话人 = 前后矛盾。
        //    **反过来不成立**：转录段都很短时的 0 个说话人是正常结果（近静音），
        //    所以这里判的是「矛盾」，不是「0 就是坏」
        if hasLongTranscriptSegment(session) && result.speakerCount < 1 {
            return failing(
                .speakerCountContradiction,
                "有 ≥1 秒的转录段，但 helper 报 speakerCount = 0")
        }

        // ── 全过 ──
        let spans = result.segments.map {
            SpeakerSpan(speakerId: $0.speakerId, startMillis: $0.startMillis,
                        endMillis: $0.endMillis, qualityScore: $0.qualityScore)
        }
        let order = SpeakerNumbering.order(of: spans)
        let diarization = SpeakerDiarization(
            schemaVersion: envelope.schemaVersion,
            helperBuild: envelope.helperBuild ?? "unknown",
            ranAt: ranAt,
            audioSeconds: result.audioSeconds,
            speakerCount: result.speakerCount,
            speakerOrder: order,
            segments: spans,
            partFingerprint: fingerprint(of: session)
        )

        let (materialized, stats) = materialize(
            session: session, diarization: diarization, helperWallSeconds: run.wallSeconds)
        return DiarizationEvaluation(
            session: materialized, diarization: diarization, failure: nil, stats: stats)
    }

    /// 音频指纹：回答「这份结果还算不算数」（设计稿 §4.1）。
    /// 重新转录不动音频 → 指纹不变；追加了一段录音 → 指纹变
    static func fingerprint(of session: RecordingSession) -> String {
        let joined = session.parts
            .map { "\($0.fileName ?? "-")|\($0.offsetMillis)|\($0.durationMillis)" }
            .joined(separator: ";")
        // 这里不引 CryptoKit：指纹只用来「比一比一样不一样」，不是安全边界。
        // 用字符串自身的哈希，跨进程稳定（不是 `hashValue`——那个每次进程启动都变，
        // 存进磁盘的指纹下次读回来必然不等）
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in joined.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// 把 diar 段贴到转录段上。**用 C-2 的映射纯函数**（`SpeakerMapper.assign`），
    /// 这里只做两件它不做的事：把原始 label 换成课内编号、把结果装进统计桶
    static func materialize(
        session: RecordingSession,
        diarization: SpeakerDiarization,
        helperWallSeconds: Double = 0
    ) -> (RecordingSession, DiarizationStats) {
        var updated = session
        let numberMap = SpeakerNumbering.normalized(diarization.segments)
        var stats = DiarizationStats(
            speakerCount: diarization.speakerCount,
            spanCount: diarization.segments.count,
            audioSeconds: diarization.audioSeconds,
            helperWallSeconds: helperWallSeconds
        )

        for partIndex in updated.parts.indices {
            let part = updated.parts[partIndex]
            // 反向段**照原样交给 `assign`**，这里不再预先滤掉。
            //
            // C-3-1 曾在这里滤一道（`filter { end >= start }`），因为那时底层
            // `RecordingSession.absoluteRange` 拿 `..<` 拼 `9000..<1000` 会
            // SIGTRAP（exit 133，release 下不打印任何东西），而 `assign` 里那句
            // 「反向/零长不标」的 guard 因此**永远到不了**。C-4 把底层改成了
            // 反向返回空区间，guard 就此可达，滤这一道反而把它重新盖回死代码——
            // 留着就是「看着有防御、其实没人走」的那种骗人的代码
            stats.reversedTranscriptSegments += part.segments.filter(RecordingSession.isReversed).count
            let assignments = SpeakerMapper.assign(
                transcript: part.segments,
                part: part,
                diarization: diarization,
                // **会话**音频总长（不是本片段的）：传小了会把合法的 diar 段
                // 夹成零长、判成「这里没人说话」，而且不报错。
                //（同一个坑的另一面见 `~/ClassroomTranscriber-design/C-1裁决2.md`
                // §三 红 2——那里的用例是自己声明了比 span 还短的音频总长）
                sessionAudioMillis: session.durationMillis
            )
            for segmentIndex in updated.parts[partIndex].segments.indices {
                let assignment = assignments[updated.parts[partIndex].segments[segmentIndex].id]
                    ?? .unlabeled
                if let raw = assignment.speakerId {
                    // 归一表里没有的 label 原样保留：宁可显示一个没归一的编号，
                    // 也不要把它变成 nil——那会把「标了」说成「没标」
                    updated.parts[partIndex].segments[segmentIndex].speakerId =
                        numberMap[raw] ?? raw
                    updated.parts[partIndex].segments[segmentIndex].speakerOverlapRatio =
                        assignment.overlapRatio
                } else {
                    updated.parts[partIndex].segments[segmentIndex].speakerId = nil
                    // 没标时 `speakerOverlapRatio` 必须是 nil，不是 0：
                    // 0 是一个合法的覆盖率读数，拿它兼职「没有值」就分不开了
                    updated.parts[partIndex].segments[segmentIndex].speakerOverlapRatio = nil
                }
                updated.parts[partIndex].segments[segmentIndex].speakerMixed = assignment.isMixed

                stats.transcriptSegments += 1
                if assignment.isLabeled {
                    stats.labeled += 1
                } else if assignment.isMixed {
                    // 有两人在说、但赢家不到一半 → 无多数派（拍板第 6 条：这种不显示说话人）
                    stats.unlabeledNoMajority += 1
                } else {
                    stats.unlabeledNoOverlap += 1
                }
                if assignment.isMixed { stats.mixed += 1 }
            }
        }

        return (updated, stats)
    }

    // MARK: - 跑一次（有 IO）

    struct RunReport {
        var helper: URL
        var run: DiarizeHelperRun
        var evaluation: DiarizationEvaluation
        var timeoutSeconds: Double
    }

    /// 跑一次完整流程：起 helper → 收信封 → 判定。
    ///
    /// **不负责模型就位**：调用方先用 `SpeakerModelStore.provision()` 把模型放到
    /// `modelsDirectory` 下（那是首跑才做的事，混进这里会让每次识别都去碰一次模型目录）。
    /// 模型到底全不全也不在这里判——helper 的 `probe`/`diarize` 是唯一判定方
    static func diarize(
        session: RecordingSession,
        helper: URL,
        modelsDirectory: URL,
        timeoutOverrideSeconds: Double? = nil,
        ranAt: Date = Date()
    ) async -> RunReport {
        let timeout = timeoutOverrideSeconds
            ?? DiarizeTimeoutPolicy.timeoutSeconds(audioSeconds: Double(session.durationMillis) / 1000)

        guard let inputs = inputs(of: session) else {
            let run = DiarizeHelperRun(
                termination: nil, envelopeData: nil, stderrTail: "", wallSeconds: 0,
                timedOut: false, launchError: nil)
            return RunReport(
                helper: helper, run: run,
                evaluation: evaluate(session: session, run: run, ranAt: ranAt),
                timeoutSeconds: timeout)
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarize-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let invocation = DiarizeHelperInvocation(
            executable: helper, inputs: inputs, modelsDir: modelsDirectory,
            output: output, timeoutSeconds: timeout)
        let run = await DiarizeHelperRunner.run(invocation)
        return RunReport(
            helper: helper, run: run,
            evaluation: evaluate(session: session, run: run, ranAt: ranAt),
            timeoutSeconds: timeout)
    }
}
