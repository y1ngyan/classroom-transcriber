import Foundation

/// 映射函数的输入：一条转录段（**片段内相对毫秒**，与 `TranscriptSegment` 一致）。
struct MapTranscriptSegment: Equatable {
    var id: UUID
    var startMillis: Int
    var endMillis: Int

    init(id: UUID = UUID(), startMillis: Int, endMillis: Int) {
        self.id = id
        self.startMillis = startMillis
        self.endMillis = endMillis
    }
}

/// 映射函数的输入：一个 diar 段（**会话时间轴毫秒**）。
struct MapDiarSpan: Equatable {
    var speakerId: String
    var startMillis: Int
    var endMillis: Int

    init(speakerId: String, startMillis: Int, endMillis: Int) {
        self.speakerId = speakerId
        self.startMillis = startMillis
        self.endMillis = endMillis
    }
}

/// 设计稿 §3.2 的 `SpeakerAssignment`（此处用本地镜像类型，便于在 helper 里
/// 无头自检；C-2 会把它接到主树的 `TranscriptSegment`/`RecordingPart`/
/// `SpeakerDiarization` 上）。
enum SpeakerMapper {
    struct Assignment: Equatable {
        /// **「没标」由这里唯一表达**（C-1 裁决 1）：判据只认 `speakerId == nil`，
        /// 不要拿 `overlapRatio`（或 `isMixed`）反推是否标注。
        var speakerId: String?
        /// winner 覆盖率。**只有 `speakerId != nil` 时才有意义**；未标注时恒为 0，
        /// 且 0 不代表「覆盖率低」，只是一个占位值——诊断信息该走日志，不该走数据字段
        /// （设计稿 §3.2「未标时为 0」）。
        var overlapRatio: Double
        /// 本段内另一个人也占了可观时长。
        var isMixed: Bool

        /// 未标注：`speakerId == nil`。`overlapRatio == 0` 只是随之而来的占位值，
        /// **不是判据**；`isMixed` 可以仍为 true（多人但无多数派，拍板第 6 条）。
        static let unlabeled = Assignment(speakerId: nil, overlapRatio: 0, isMixed: false)

        /// 是否被标注。全项目统一用这个（它只等价于 `speakerId != nil`）。
        var isLabeled: Bool { speakerId != nil }
    }

    /// 阈值（设计稿 §3.2 默认值；真实录音上的取值见 §8 第 4 条，属未定）。
    static let defaultMinOverlapMillis = 200
    static let defaultMinOverlapRatio = 0.5
    static let defaultMixedShare = 0.25

    /// 纯函数：转录段（片段内相对时间）→ 说话人归属。无 IO、无时间依赖、同输入同输出。
    ///
    /// 区间一律半开 `[start, end)`。时间轴基准只有一处：`partOffsetMillis`（= App 的
    /// `RecordingPart.offsetMillis`）；函数内部**不引入第二套换算**。
    ///
    /// - Parameters:
    ///   - audioMillis: 会话音频总时长（毫秒），用于把 diar 段夹紧到 `[0, audioMillis+1000]`。
    static func assign(
        transcript: [MapTranscriptSegment],
        partOffsetMillis: Int,
        diarization: [MapDiarSpan],
        audioMillis: Int,
        minOverlapMillis: Int = defaultMinOverlapMillis,
        minOverlapRatio: Double = defaultMinOverlapRatio,
        mixedShare: Double = defaultMixedShare
    ) -> [UUID: Assignment] {
        let clampedUpperBound = audioMillis + 1000
        // 夹紧 + 丢掉零长/越界后为零长的 diar 段（设计稿 §3.3 第 6 条）。
        let usableSpans = diarization.compactMap { span -> MapDiarSpan? in
            let start = max(0, span.startMillis)
            let end = min(span.endMillis, clampedUpperBound)
            guard end > start else { return nil }
            return MapDiarSpan(speakerId: span.speakerId, startMillis: start, endMillis: end)
        }

        var output: [UUID: Assignment] = [:]
        for segment in transcript {
            let segmentStart = partOffsetMillis + segment.startMillis
            let segmentEnd = partOffsetMillis + segment.endMillis

            // 零长/反向转录段 → 直接 nil。
            guard segmentEnd > segmentStart else {
                output[segment.id] = .unlabeled
                continue
            }

            var overlapBySpeaker: [String: Int] = [:]
            // 每个 speaker 与 T 重叠最大的那个 diar 段的重叠量 + 中点，用于决胜②。
            var bestSingleSpanOverlapBySpeaker: [String: Int] = [:]
            var representativeMidpointBySpeaker: [String: Double] = [:]

            for span in usableSpans {
                let overlap = max(0, min(segmentEnd, span.endMillis) - max(segmentStart, span.startMillis))
                guard overlap > 0 else { continue }
                overlapBySpeaker[span.speakerId, default: 0] += overlap

                let previousBest = bestSingleSpanOverlapBySpeaker[span.speakerId] ?? -1
                if overlap > previousBest {
                    bestSingleSpanOverlapBySpeaker[span.speakerId] = overlap
                    representativeMidpointBySpeaker[span.speakerId] =
                        Double(span.startMillis + span.endMillis) / 2
                }
            }

            let totalOverlap = overlapBySpeaker.values.reduce(0, +)
            guard totalOverlap >= minOverlapMillis else {
                output[segment.id] = .unlabeled
                continue
            }

            let segmentMidpoint = Double(segmentStart + segmentEnd) / 2
            let winner = overlapBySpeaker.keys.min { lhs, rhs in
                let lhsOverlap = overlapBySpeaker[lhs] ?? 0
                let rhsOverlap = overlapBySpeaker[rhs] ?? 0
                if lhsOverlap != rhsOverlap { return lhsOverlap > rhsOverlap }
                let lhsDistance = abs((representativeMidpointBySpeaker[lhs] ?? segmentMidpoint) - segmentMidpoint)
                let rhsDistance = abs((representativeMidpointBySpeaker[rhs] ?? segmentMidpoint) - segmentMidpoint)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs < rhs
            }

            guard let winner else {
                output[segment.id] = .unlabeled
                continue
            }

            let winnerOverlap = overlapBySpeaker[winner] ?? 0
            let duration = Double(segmentEnd - segmentStart)
            let ratio = Double(winnerOverlap) / duration
            let secondSpeakerOverlap = totalOverlap - winnerOverlap
            let mixedThreshold = max(Double(minOverlapMillis), mixedShare * duration)
            let isMixed = Double(secondSpeakerOverlap) >= mixedThreshold

            if ratio < minOverlapRatio {
                // 没有多数派就不认；但保留 isMixed 让界面能显示「多人」（拍板第 6 条）。
                // 裁决 1：未标注时 overlapRatio 无意义、恒写 0；「没标」只由
                // speakerId == nil 表达（不要把原始 ratio 顺手记在这里当诊断）。
                output[segment.id] = Assignment(speakerId: nil, overlapRatio: 0, isMixed: isMixed)
            } else {
                output[segment.id] = Assignment(speakerId: winner, overlapRatio: ratio, isMixed: isMixed)
            }
        }
        return output
    }
}
