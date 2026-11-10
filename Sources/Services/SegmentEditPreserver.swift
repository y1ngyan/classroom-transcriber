import Foundation

/// 重转时保住用户手改过的句子（P17）。
///
/// 重转是**整段覆盖**：`RecordingsStore.retranscribe` 拿新的识别结果直接替换
/// `part.segments`。用户在前一版里双击改过的错字，如果就这么被换掉，
/// 等于「刚教会 App 的正确写法又被它忘干净」，而且没有任何提示。
///
/// 匹配按时间戳：两轮识别的切段边界不会完全一样（甚至同一条音频切出来
/// 的段数都可能不同），所以不能用「第 N 段对第 N 段」。这里给每个新段
/// 找时间上重叠最多、且重叠足够多的旧段（旧段必须 `edited == true`），
/// 一个旧段最多用一次——避免同一条人工修改被复制到相邻好几个新段上。
///
/// 纯函数、不碰磁盘：自检可以在临时目录里跑真实 store，也可以直接喂数组。
enum SegmentEditPreserver {

    /// 一次「人工文本覆盖了识别文本」的记录，给日志和自检用
    struct Preserved: Equatable {
        /// 新结果里那一段的起点（片段内相对毫秒）
        let newStartMillis: Int
        /// 人工文本原来所在的旧段起点
        let oldStartMillis: Int
        let text: String
    }

    struct Result: Equatable {
        var segments: [TranscriptSegment]
        var preserved: [Preserved]

        var isEmpty: Bool { preserved.isEmpty }
    }

    /// 旧段与新段的重叠必须达到「较短那一段时长的一半」才算同一句。
    ///
    /// 为什么不是「有重叠就算」：句子之间的边界本身就在漂，一个 8 秒的
    /// 人工改句和隔壁 10 秒的新段重叠 0.3 秒，那多半是切在了同一个气口上，
    /// 不是同一句。阈值定死在这里，改它要先跑 `SegmentEditSelfTest`
    static let minimumOverlapRatio = 0.5

    static func merge(new newSegments: [TranscriptSegment],
                      old oldSegments: [TranscriptSegment]) -> Result {
        let candidates = oldSegments.filter(\.edited)
        guard !candidates.isEmpty else {
            return Result(segments: newSegments, preserved: [])
        }

        var usedOld = Set<UUID>()
        var preserved: [Preserved] = []

        let merged = newSegments.map { newSegment -> TranscriptSegment in
            var best: (segment: TranscriptSegment, overlap: Int)?
            for old in candidates where !usedOld.contains(old.id) {
                let overlap = overlapMillis(newSegment, old)
                guard overlap > 0 else { continue }
                let shorter = min(newSegment.durationMillis, old.durationMillis)
                // 零时长的段没有 ratio 可言；要求精确相同就不给它们开例外
                guard shorter > 0,
                      Double(overlap) >= Double(shorter) * minimumOverlapRatio
                else { continue }
                if best == nil || overlap > best!.overlap {
                    best = (old, overlap)
                }
            }
            guard let best else { return newSegment }

            usedOld.insert(best.segment.id)
            preserved.append(Preserved(
                newStartMillis: newSegment.startTimeMillis,
                oldStartMillis: best.segment.startTimeMillis,
                text: best.segment.text
            ))
            // 只换文本和「改过」标记。id / 时间戳 / 语言 / 质量分档都跟着
            // 新结果走——那些是新识别器对这条音频的判断，人工改的只是字
            var copy = newSegment
            copy.text = best.segment.text
            copy.edited = true
            return copy
        }

        return Result(segments: merged, preserved: preserved)
    }

    private static func overlapMillis(_ a: TranscriptSegment,
                                      _ b: TranscriptSegment) -> Int {
        max(0, min(a.endTimeMillis, b.endTimeMillis)
            - max(a.startTimeMillis, b.startTimeMillis))
    }
}
