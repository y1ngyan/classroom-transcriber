import Foundation

/// 设计稿 §2.6 的 5 条校验。**全过才允许标注**；任何一条不过 →
/// App 侧 `session.diarization = nil`、所有 `segment.speakerId = nil`，
/// 把失败码存进 `diarizationFailure`。回退目标是 nil，**不是某个说话人**。
///
/// 注意：`speakerCount == 1` 且 5 条全过是**阳性结果**（单人讲授就该标成 S1）。
/// 区分靠「校验通过与否」，不是「说话人数」。
enum DiarizationValidationFailure: String, Equatable {
    /// 第 1 条：子进程不是干净退出。
    case processFailed
    /// 第 2 条：输出文件不存在/解不开/schemaVersion 不对/status 不是 ok/result 缺失。
    case envelopeInvalid
    /// 第 3 条：`result.audioSeconds` 与会话时长差超容差（拿错文件/半截结果）。
    case audioSecondsMismatch
    /// 第 4 条：segment 越界或零长。
    case segmentOutOfRange
    /// 第 5 条：有 ≥1s 的转录段却说 0 个说话人（前后矛盾）。
    case speakerCountContradiction
}

struct ValidationOutcome: Equatable {
    enum Result: Equatable {
        case ok
        case failure(DiarizationValidationFailure)
    }

    var result: Result
    var detail: String

    var isOK: Bool { result == .ok }
}

enum OutputValidator {
    /// 第 3 条容差：`max(2s, 1% × 会话时长)`。
    static func toleranceSeconds(sessionAudioSeconds: Double) -> Double {
        max(2.0, sessionAudioSeconds * 0.01)
    }

    /// 第 1 条：`terminationReason == .exit` 且 `terminationStatus == 0`。
    static func checkProcess(_ termination: ProcessTermination?) -> DiarizationValidationFailure? {
        guard let termination else { return .processFailed }
        guard termination.reason == .exit, termination.status == 0 else { return .processFailed }
        return nil
    }

    /// 第 2 条：能解码、`schemaVersion == 1`、`status == "ok"`、有 `result`。
    static func checkEnvelope(_ envelope: Envelope) -> DiarizationValidationFailure? {
        guard envelope.schemaVersion == Envelope.currentSchemaVersion else { return .envelopeInvalid }
        guard envelope.status == .ok else { return .envelopeInvalid }
        guard envelope.result != nil else { return .envelopeInvalid }
        return nil
    }

    /// 第 3 条。
    static func checkAudioSeconds(
        _ envelope: Envelope,
        sessionAudioSeconds: Double
    ) -> DiarizationValidationFailure? {
        guard let result = envelope.result else { return .envelopeInvalid }
        let tolerance = toleranceSeconds(sessionAudioSeconds: sessionAudioSeconds)
        let delta = abs(result.audioSeconds - sessionAudioSeconds)
        return delta <= tolerance ? nil : .audioSecondsMismatch
    }

    /// 第 4 条：每个 segment `0 ≤ start < end ≤ audioSeconds*1000 + 1000`。
    static func checkSegmentBounds(_ envelope: Envelope) -> DiarizationValidationFailure? {
        guard let result = envelope.result else { return .envelopeInvalid }
        let upper = result.audioSeconds * 1000 + 1000
        for span in result.segments {
            if span.startMillis < 0 { return .segmentOutOfRange }
            if span.endMillis <= span.startMillis { return .segmentOutOfRange }
            if Double(span.endMillis) > upper { return .segmentOutOfRange }
        }
        return nil
    }

    /// 第 5 条：会话里存在 ≥1 段时长 ≥1s 的转录段时，`speakerCount ≥ 1`。
    ///
    /// 反向语义（C-1 裁决 2）：`hasLongTranscriptSegment == false` 时
    /// `speakerCount == 0` 是**合法正常结果**（近静音 / 无人说话），App
    /// **不许因此重试** helper，**更不许贴 S1**；`diarization` 置空即可。
    static func checkSpeakerCount(
        _ envelope: Envelope,
        hasLongTranscriptSegment: Bool
    ) -> DiarizationValidationFailure? {
        guard let result = envelope.result else { return .envelopeInvalid }
        if hasLongTranscriptSegment && result.speakerCount < 1 {
            return .speakerCountContradiction
        }
        return nil
    }

    /// 全量 5 条。`envelopeData == nil` 等价于「没有信封」→ 第 1/2 条失败。
    static func validate(
        termination: ProcessTermination?,
        envelopeData: Data?,
        sessionAudioSeconds: Double,
        hasLongTranscriptSegment: Bool
    ) -> ValidationOutcome {
        if let failure = checkProcess(termination) {
            return ValidationOutcome(result: .failure(failure), detail: "process")
        }
        guard let data = envelopeData, let envelope = try? Envelope.decode(data) else {
            return ValidationOutcome(result: .failure(.envelopeInvalid), detail: "decode")
        }
        if let failure = checkEnvelope(envelope) {
            return ValidationOutcome(result: .failure(failure), detail: "envelope")
        }
        if let failure = checkAudioSeconds(envelope, sessionAudioSeconds: sessionAudioSeconds) {
            return ValidationOutcome(result: .failure(failure), detail: "audioSeconds")
        }
        if let failure = checkSegmentBounds(envelope) {
            return ValidationOutcome(result: .failure(failure), detail: "segmentBounds")
        }
        if let failure = checkSpeakerCount(envelope, hasLongTranscriptSegment: hasLongTranscriptSegment) {
            return ValidationOutcome(result: .failure(failure), detail: "speakerCount")
        }
        return ValidationOutcome(result: .ok, detail: "ok")
    }

    /// 额外自检（设计稿 §7 步骤 2 验收）：`speakerCount == Set(segments[].speakerId).count`。
    /// 不在 5 条之内，但 App 应一并拒绝不一致的信封。
    static func checkSpeakerCountConsistency(_ envelope: Envelope) -> Bool {
        guard let result = envelope.result else { return false }
        return result.speakerCount == Set(result.segments.map(\.speakerId)).count
    }
}
