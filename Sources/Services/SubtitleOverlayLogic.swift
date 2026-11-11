import Foundation

/// 悬浮字幕的**纯逻辑**：显示哪几行、什么时候收起、文字怎么截。
///
/// 抽出来是因为这块的状态机最容易「看着对、用起来怪」：
/// 老师停顿 3 秒字幕就整个消失、一句话太长把岛撑成一条横幅、
/// 上一句刚定稿下一句还没出来时闪一下空白——这些都不是像素判据能抓的，
/// 但可以在这儿用几个带时间的断言钉住。
enum SubtitleOverlayLogic {

    /// 岛里最多放几行（一句正在说的 + 上一句）
    static let maxLines = 2

    /// 一行最多多少字；超了从**头部**截（课堂里重点是句尾的结论）
    static let maxCharactersPerLine = 46

    /// 静止多久算「没人在说话」，收起成小胶囊
    static let idleSeconds: Double = 6

    struct Snapshot: Equatable {
        /// 要显示的行（新的在后）
        var lines: [String]
        /// 是否收起成小胶囊（没人在说话）
        var collapsed: Bool
    }

    /// - Parameters:
    ///   - recent: 最近的句子文本（新的在后），调用方一般给最后 3–5 条
    ///   - secondsSinceUpdate: 距最后一次更新的秒数
    static func snapshot(recent: [String], secondsSinceUpdate: Double) -> Snapshot {
        let cleaned = recent
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { trim($0) }
        let lines = Array(cleaned.suffix(maxLines))
        return Snapshot(lines: lines, collapsed: secondsSinceUpdate >= idleSeconds || lines.isEmpty)
    }

    static func trim(_ text: String) -> String {
        guard text.count > maxCharactersPerLine else { return text }
        let tail = text.suffix(maxCharactersPerLine)
        return "…" + tail
    }

    /// 岛宽随最长一行变化，但夹在 [minWidth, maxWidth]。
    /// 单位是「字宽」而不是像素：中文与拉丁字母宽度差一倍，按字算才不会一半空一半挤
    static let minWidthUnits: Double = 12
    static let maxWidthUnits: Double = 40

    static func widthUnits(for lines: [String]) -> Double {
        let longest = lines.map { Double($0.count) }.max() ?? 0
        return min(maxWidthUnits, max(minWidthUnits, longest))
    }
}
