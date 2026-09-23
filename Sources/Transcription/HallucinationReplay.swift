import Foundation

/// `--hallucination-replay <探针日志>`：拿**已经跑好的**探针输出重算一遍判据。
///
/// **为什么要有这个**：调一次判据（改词表、改门限）如果每次都要重跑 whisper，
/// 一条 3 分钟的录音就要两分半——而判据本身是**纯函数**，输入（文本、电平、
/// 静音门）早就被探针完整写进 TSV 了。重算应该是瞬时的。
///
/// **为什么是 Swift 而不是外面写个 Python**：判据必须在**同一份实现**上重算。
/// 外面另写一遍 Python，两份实现必然漂——那时候「重算出来的数」和「生产会做的事」
/// 就是两回事，整个对照就作废了。这也是电平/静音门那两个助手当初被抽进
/// `WhisperHallucination` 而不是各写一份的同一个理由。
///
/// 解析的是 `WhisperWindowFileRun` 打的那段 TSV（列定义见那里的打印语句）。
/// 列变了这里要跟着变，所以打印语句上留了指向本文件的注释。
enum HallucinationReplay {

    /// 一行探针 TSV
    struct Row {
        let startMillis: Int
        let text: String
        let noSpeech: Double
        let level: Double
        let floor: Double
    }

    /// 从探针日志里切出 TSV 段。**必须靠那两条哨兵行**，不能靠「看起来像 TSV」——
    /// 日志里别的段也用制表符（比如逐段明细行），猜会猜错
    static func parse(log: String) -> [Row] {
        var rows: [Row] = []
        var inside = false
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("─── TSV（") { inside = true; continue }
            if line.hasPrefix("─── TSV 结束") { inside = false; continue }
            guard inside else { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, let start = Int(f[0]) else { continue }
            rows.append(Row(
                startMillis: start,
                text: f[4],
                noSpeech: Double(f[5]) ?? 0,
                level: Double(f[6]) ?? 0,
                floor: Double(f[7]) ?? 0
            ))
        }
        return rows
    }

    /// 对一批行跑判据，返回逐条结果。**这就是 `--hallucination-selftest` 之上的
    /// 真正回归**：自检用的是我编的用例，这里用的是真实录音跑出来的每一段
    static func analyze(_ rows: [Row]) -> (dropped: [(Row, WhisperHallucination.Verdict)], kept: Int) {
        var dropped: [(Row, WhisperHallucination.Verdict)] = []
        var kept = 0
        for row in rows {
            let verdict = WhisperHallucination.verdict(
                text: row.text,
                noSpeechProbability: row.noSpeech,
                audioLevel: row.level,
                silenceFloor: row.floor
            )
            if case .keep = verdict { kept += 1 } else { dropped.append((row, verdict)) }
        }
        return (dropped, kept)
    }

    static func report(log: String, label: String) -> [String] {
        let rows = parse(log: log)
        guard !rows.isEmpty else {
            return ["❌ \(label)：没解析出任何段——日志里没有 TSV 段（是不是没加 --probe-only？）"]
        }
        let (dropped, kept) = analyze(rows)
        var lines = ["─── 离线重算：\(label) ───"]
        let loudTotal = rows.filter { $0.level >= $0.floor }.count
        let droppedLoud = dropped.filter { $0.0.level >= $0.0.floor }.count
        let distinct = Set(dropped.map { WhisperHallucination.normalize($0.0.text) }).count
        let templates = dropped.filter { if case .dropSubtitleTemplate = $0.1 { return true }; return false }.count
        let annotations = dropped.count - templates

        lines.append(String(
            format: "  %d 段 → 留 %d / 丢 %d（模板 %d / 注释 %d），按文本去重后 %d 处",
            rows.count, kept, dropped.count, templates, annotations, distinct
        ))
        lines.append(String(
            format: "  有语音电平的段：%d → %d（被丢 %d = 误杀上界）",
            loudTotal, loudTotal - droppedLoud, droppedLoud
        ))
        lines.append("  机器可读：REPLAY_SUMMARY\t\(label)\t\(rows.count)\t\(kept)\t\(dropped.count)\t\(templates)\t\(annotations)\t\(distinct)\t\(loudTotal)\t\(loudTotal - droppedLoud)")
        for (row, verdict) in dropped {
            let kind: String
            switch verdict {
            case .dropSubtitleTemplate(let m): kind = "模板:\(m)"
            case .dropNonSpeechAnnotation: kind = "注释"
            case .keep: kind = "?"
            }
            lines.append(String(
                format: "    [%@ / 无语音%.6f / 电平%.5f vs 门%.5f%@] %@",
                kind, row.noSpeech, row.level, row.floor,
                row.level >= row.floor ? " ⚠响段" : "", row.text
            ))
        }
        return lines
    }
}
