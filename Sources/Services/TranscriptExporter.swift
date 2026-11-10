import Foundation

/// 转录导出：把一节课的转录段渲染成 SRT / VTT / Markdown / JSON。
///
/// **纯函数，不碰磁盘、不弹面板、不 import AppKit**——理由和 `NotesExporter`
/// 那边同一句话：这段逻辑原来只可能长在 View 里，而 View 是全项目唯一
/// 没法离线自检的地方。导出的四份文本到底长什么样（序号对不对、时间戳
/// 进位有没有错、空段会不会漏成一条空字幕），必须能在无头进程里算出来
/// 并用断言钉住，否则「导出」又会变成一条只能靠肉眼看的路。
///
/// 落盘只在 `write` 一个函数里，且**不在 `write` 里弹面板**
/// （面板归 UI 层，见 `TranscriptExportSheet`）。
enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case srt
    case vtt
    case markdown
    case json

    var id: String { rawValue }

    var label: String {
        switch self {
        case .srt: return "SRT 字幕"
        case .vtt: return "WebVTT 字幕"
        case .markdown: return "纯文本 Markdown"
        case .json: return "JSON 原始段"
        }
    }

    /// 后缀**不跟 rawValue 走**：Markdown 要 `.md` 而不是 `.markdown`
    /// ——用户在访达里双击 `.markdown` 不一定有软件认领
    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .markdown: return "md"
        case .json: return "json"
        }
    }

    /// 哪些格式的「带不带时间戳」是有意义的。
    ///
    /// 只有 Markdown 是。SRT/VTT 的整个存在意义就是时间轴，去掉时间戳
    /// 只剩一堆无主的句子；JSON 是给程序读的原始段，时间戳是数据不是排版。
    /// 把这个判断放在这里而不是 View 里，是为了让「开关灰掉时该说什么」
    /// 也能被自检覆盖（同 `DiarizationPanelState.runDisabledReason` 的规矩：
    /// 灰着就必须有原因）
    var supportsTimestampToggle: Bool { self == .markdown }
}

/// 导出失败。三种情形分开报：用户要做的动作各不相同
/// （前者去录/去转，后者换路径）
enum TranscriptExportError: LocalizedError {
    case noSegments
    case writeFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "这条录音还没有转录内容，没有可导出的东西"
        case .writeFailed(let path, let reason):
            return "导出失败：写不进 \(path)（\(reason)）"
        }
    }
}

/// 导出源。详情页用的是**落盘的整条会话**，转录页用的是**当前内存里的段**。
///
/// 两处共用同一个渲染器，是因为「导出」在用户心里是同一件事：
/// 同一节课，不管从哪一页导，出来的文件该是一样的。各写一份的话，
/// 转录页那份迟早会少掉多片段偏移这一层（它没有 part，offset 恒为 0）
enum TranscriptExportSource {
    /// 会话（详情页）。多片段的 offset 在这里被折算成会话绝对时间
    case session(RecordingSession)
    /// 内存里的段（转录页）。单条流，offset 恒为 0
    case live(segments: [TranscriptSegment], startedAt: Date, title: String)

    var startedAt: Date {
        switch self {
        case .session(let session): return session.startedAt
        case .live(_, let startedAt, _): return startedAt
        }
    }

    var title: String {
        switch self {
        case .session(let session): return session.title
        case .live(_, _, let title): return title
        }
    }

    /// 会话时长。转录页只有内存段，取最后一段的结束时间
    var durationMillis: Int {
        switch self {
        case .session(let session): return session.durationMillis
        case .live(let segments, _, _):
            return segments.map(\.endTimeMillis).max() ?? 0
        }
    }

    /// 规整后的段（绝对时间、无空段、结束时间兜底）。UI 拿它数「几段」，
    /// **不要自己数**：界面显示 12 段、导出的文件里 11 条，是最难解释的一种不一致
    var preparedSegments: [TranscriptSegment] {
        switch self {
        case .session(let session): return TranscriptExporter.preparedSegments(from: session)
        case .live(let segments, _, _): return TranscriptExporter.preparedSegments(from: segments)
        }
    }

    func render(_ format: TranscriptExportFormat, includeTimestamps: Bool) throws -> String {
        switch self {
        case .session(let session):
            return try TranscriptExporter.render(
                format, session: session, includeTimestamps: includeTimestamps
            )
        case .live(let segments, _, _):
            return try TranscriptExporter.render(
                format, segments: segments, includeTimestamps: includeTimestamps
            )
        }
    }

    func defaultFileName(for format: TranscriptExportFormat) -> String {
        TranscriptExporter.defaultFileName(
            title: title, startedAt: startedAt, format: format
        )
    }

    /// 「复制全部文本」用的那份：Markdown 不带时间戳。
    ///
    /// 复制是为了**贴进别处**（笔记、聊天、作业），带一串 `[00:00:08]`
    /// 过去只会让人手删。要时间戳就去导出，那是另一件事
    func copyText() -> String {
        (try? render(.markdown, includeTimestamps: false)) ?? ""
    }
}

enum TranscriptExporter {

    // MARK: - 时间戳

    /// `00:00:08,000`（SRT）。逗号是 SRT 的硬规定，用点号很多播放器直接不认
    static func srtTimestamp(_ millis: Int) -> String {
        clock(millis, millisecondSeparator: ",")
    }

    /// `00:00:08.000`（WebVTT）
    static func vttTimestamp(_ millis: Int) -> String {
        clock(millis, millisecondSeparator: ".")
    }

    /// 毫秒 → `HH:MM:SS<sep>mmm`。
    ///
    /// **全部走整数除法**，不做浮点：`Double(millis) / 1000.0` 在 59_999 这种
    /// 值上会拿到 59.999000000000002，格式化再一舍入就成了 00:01:00,000——
    /// 字幕提前一秒，且只在个别值上错，肉眼根本查不出来。
    /// 小时位用 `%02d` 而不是 `%d`：超过 99 小时照样接着涨，不截断
    private static func clock(_ millis: Int, millisecondSeparator: String) -> String {
        let total = max(0, millis)
        let milliseconds = total % 1000
        let seconds = total / 1000
        return String(
            format: "%02d:%02d:%02d\(millisecondSeparator)%03d",
            seconds / 3600, (seconds % 3600) / 60, seconds % 60, milliseconds
        )
    }

    /// 纯文本里用的 `HH:MM:SS`
    static func shortTimestamp(_ millis: Int) -> String {
        let total = max(0, millis) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - 规整

    /// 最短一条字幕的时长。**不是「凑够多少秒好看」**，而是 SRT 的硬约束：
    /// `end <= start` 的那条 cue 在播放器里要么被丢掉、要么常驻不下屏
    static let minimumCueMillis = 800
    /// 没结束时间时按字数估的每字毫秒
    static let millisPerCharacter = 180
    /// 估出来的时长上限：一段 300 字的长段不该在屏幕上挂一分钟
    static let maximumCueMillis = 8_000

    /// 一条段落到字幕文本。**段内换行压成空格**：字幕的一条 cue 里放换行，
    /// 播放器会显示成两行，看起来像两条时间不同的字幕，而它们其实是同一句话
    static func normalizeText(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 会话 → 会话绝对时间轴上的一段段（多片段 offset 在这里折算一次）
    static func absoluteSegments(from session: RecordingSession) -> [TranscriptSegment] {
        session.parts.flatMap { part in
            // 复用 `absoluteCopy(in:)`：offset 的换算全项目只有那一处，
            // 这里再写一遍 `part.offsetMillis + start` 就多了一处会对不上的地方
            part.segments.map { $0.absoluteCopy(in: part) }
        }
    }

    static func preparedSegments(from session: RecordingSession) -> [TranscriptSegment] {
        prepare(absoluteSegments(from: session))
    }

    static func preparedSegments(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        prepare(segments)
    }

    /// 把原始段整理成「可以直接渲染」的那一份：
    ///   ① 去掉空/纯空白段（导出成一条空字幕是没有意义的，播放器里就是一块空白）；
    ///   ② 文本规整（换行 → 空格）；
    ///   ③ 负时间夹到 0，按起点排序（同起点保持原顺序——`sorted` 不保证稳定，
    ///      用原索引兜底）；
    ///   ④ 结束时间兜底：`end <= start` 时按字数估一个，估不出来给最短时长；
    ///   ⑤ 与下一段重叠的尾巴夹到下一段起点（两条字幕同时在屏上，
    ///      用户读到的是两句话叠在一起）
    static func prepare(_ raw: [TranscriptSegment]) -> [TranscriptSegment] {
        var items: [(index: Int, segment: TranscriptSegment)] = []
        // 用 `enumerated` 而不是 `filter`：后面排序要拿原索引做稳定排序的第二关键字
        for (index, segment) in raw.enumerated() {
            var copy = segment
            copy.text = normalizeText(segment.text)
            // 空白段直接丢。**在 JSON 里也不留**：四种格式的段数必须一致，
            // 否则「界面 5 段、导出 4 条」这种对不上的账没人能解释
            guard !copy.text.isEmpty else { continue }
            copy.startTimeMillis = max(0, segment.startTimeMillis)
            copy.endTimeMillis = max(0, segment.endTimeMillis)
            items.append((index, copy))
        }

        items.sort { a, b in
            a.segment.startTimeMillis == b.segment.startTimeMillis
                ? a.index < b.index
                : a.segment.startTimeMillis < b.segment.startTimeMillis
        }

        var out = items.map(\.segment)
        for i in out.indices {
            if out[i].endTimeMillis <= out[i].startTimeMillis {
                out[i].endTimeMillis = out[i].startTimeMillis + estimatedDuration(out[i].text)
            }
            // 反向段（end < start）在这一步已经归一成 end > start，不会把
            // `..<` 那个带检查的区间交给下游
            if i + 1 < out.count, out[i].endTimeMillis > out[i + 1].startTimeMillis {
                out[i].endTimeMillis = out[i + 1].startTimeMillis
            }
            // 夹到下一段之后仍可能不合法（两段起点相同），这时宁可让两条
            // 字幕同起点，也不能留一条 end == start 的 cue
            if out[i].endTimeMillis <= out[i].startTimeMillis {
                out[i].endTimeMillis = out[i].startTimeMillis + minimumCueMillis
            }
        }
        return out
    }

    private static func estimatedDuration(_ text: String) -> Int {
        min(maximumCueMillis, max(minimumCueMillis, text.count * millisPerCharacter))
    }

    // MARK: - 渲染

    static func render(
        _ format: TranscriptExportFormat,
        session: RecordingSession,
        includeTimestamps: Bool = true
    ) throws -> String {
        try render(
            format,
            prepared: preparedSegments(from: session),
            includeTimestamps: includeTimestamps,
            title: session.title,
            startedAt: session.startedAt,
            durationMillis: session.durationMillis
        )
    }

    static func render(
        _ format: TranscriptExportFormat,
        segments: [TranscriptSegment],
        includeTimestamps: Bool = true,
        title: String = "",
        startedAt: Date = Date()
    ) throws -> String {
        try render(
            format,
            prepared: preparedSegments(from: segments),
            includeTimestamps: includeTimestamps,
            title: title,
            startedAt: startedAt,
            durationMillis: segments.map(\.endTimeMillis).max() ?? 0
        )
    }

    /// 四种格式的唯一渲染入口。**空输入在这里抛错**，不返回空串：
    /// 返回空串的话，调用方会写下一个 0 字节文件并以为导出成功了
    /// （`NotesExporter.write` 那边同一条理由）
    static func render(
        _ format: TranscriptExportFormat,
        prepared: [TranscriptSegment],
        includeTimestamps: Bool,
        title: String,
        startedAt: Date,
        durationMillis: Int
    ) throws -> String {
        guard !prepared.isEmpty else { throw TranscriptExportError.noSegments }
        let entries = prepared.map {
            TranscriptExportEntry(
                startMillis: $0.startTimeMillis,
                endMillis: $0.endTimeMillis,
                text: $0.text,
                // 判据只有 `SpeakerLabel` 一处：`nil`、空串都算「没标」。
                // 这里不再自己判一遍，否则界面不显示、导出却印一个空的 `: `
                speaker: SpeakerLabel.text(for: $0)
            )
        }

        switch format {
        case .srt:
            return srt(entries)
        case .vtt:
            return vtt(entries)
        case .markdown:
            return markdown(entries, title: title, startedAt: startedAt,
                            durationMillis: durationMillis,
                            includeTimestamps: includeTimestamps)
        case .json:
            return try json(prepared)
        }
    }

    struct TranscriptExportEntry: Equatable {
        var startMillis: Int
        var endMillis: Int
        var text: String
        var speaker: String?
    }

    /// SRT：`序号 / 起止 / 文本`，块之间空一行，文件以换行结尾（POSIX 文本约定）
    static func srt(_ entries: [TranscriptExportEntry]) -> String {
        var blocks: [String] = []
        for (index, entry) in entries.enumerated() {
            // 序号从 1 开始、连续递增。**不用 `entry` 自己的 id 之类的东西**：
            // SRT 的序号是给播放器排序用的整数，跳号会被当成损坏
            var lines = [
                "\(index + 1)",
                "\(srtTimestamp(entry.startMillis)) --> \(srtTimestamp(entry.endMillis))",
            ]
            // 说话人写成 `S1: 文本` 前缀——SRT 没有专门的发言人字段
            // （那是 WebVTT 的 `<v>`），前缀是唯一带了还能被普遍读懂的形式
            lines.append(entry.speaker.map { "\($0): \(entry.text)" } ?? entry.text)
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// WebVTT：`WEBVTT` 头 + cue 块，时间戳用点号分隔毫秒，说话人用 `<v 标签>`
    static func vtt(_ entries: [TranscriptExportEntry]) -> String {
        var blocks: [String] = []
        for (index, entry) in entries.enumerated() {
            var lines = [
                "\(index + 1)",
                "\(vttTimestamp(entry.startMillis)) --> \(vttTimestamp(entry.endMillis))",
            ]
            // `<v S1>文本` 是 WebVTT 的发言人标注语法，播放器会当说话人显示
            // 而不是把标签当正文念出来
            lines.append(entry.speaker.map { "<v \($0)>\(entry.text)" } ?? entry.text)
            blocks.append(lines.joined(separator: "\n"))
        }
        // 头后面必须是空行，然后是第一块；少这个空行整个文件不被当成 VTT
        return "WEBVTT\n\n" + blocks.joined(separator: "\n\n") + "\n"
    }

    /// Markdown：**按说话人分段**。连续同一说话人的段并成一段，
    /// 换人就另起一段——手动整理课堂记录时，别人最需要的就是「这句话是谁说的」
    static func markdown(
        _ entries: [TranscriptExportEntry],
        title: String,
        startedAt: Date,
        durationMillis: Int,
        includeTimestamps: Bool
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let heading = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? "课堂转录"
            : "课堂转录 · \(title.trimmingCharacters(in: .whitespaces))"

        var lines: [String] = ["# \(heading)", ""]
        var meta = [formatter.string(from: startedAt), "\(entries.count) 段"]
        if durationMillis > 0 {
            meta.append("时长 \(shortTimestamp(durationMillis))")
        }
        lines.append("> " + meta.joined(separator: " · "))
        lines.append("")

        var index = 0
        while index < entries.count {
            let speaker = entries[index].speaker
            var block: [String] = []
            // 同说话人的连续段归一段。`speaker` 是 Optional，`==` 对
            // 「都是 nil」也会成立——没标说话人的连续几段本来就该并成一段
            while index < entries.count, entries[index].speaker == speaker {
                let entry = entries[index]
                block.append(includeTimestamps
                    ? "[\(shortTimestamp(entry.startMillis))] \(entry.text)"
                    : entry.text)
                index += 1
            }
            // 没标说话人时**不印一个占位标题**（不写「未知说话人」）：
            // 那是凭空多出来的一层分类，和 `SpeakerLabel` 那边
            // 「不显示错的是诚实的」是同一条拍板
            if let speaker {
                lines.append("**\(speaker)**")
                lines.append("")
            }
            lines.append(block.joined(separator: includeTimestamps ? "\n" : " "))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// JSON：规整后的**原始段**（绝对时间、已排序、空段已剔除），字段集
    /// 就是 `TranscriptSegment` 本身——要再加工的脚本不该去猜一套自定义结构。
    ///
    /// 排序键固定 + 不转义斜杠：导出件要能 diff（同一节课导两次，字节相同），
    /// 中文按 UTF-8 原样写出来而不是 `\u4eca`，否则人打开文件先看到一屏转义
    static func json(_ segments: [TranscriptSegment]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // 段的 `timestamp` 是墙上时间。ISO8601 给人读得懂；
        // 用它同时要求解码端也用同一个策略，自检里往返一次就是在钉这件事
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(segments)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - 文件名 / 落盘

    /// 默认文件名。标题参与命名（用户改过名的那节课，导出件一眼能认出来），
    /// 但 `/` `:` 这些路径分隔符必须换掉——`NSSavePanel` 会拒绝，命令行
    /// 直接写会多出一层不存在的目录
    static func defaultFileName(
        title: String,
        startedAt: Date,
        format: TranscriptExportFormat
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let base = sanitizedFileNameBase(title)
        return "\(base)-\(formatter.string(from: startedAt)).\(format.fileExtension)"
    }

    static func sanitizedFileNameBase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "课堂转录" }
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "课堂转录" : cleaned
    }

    /// 把渲染好的文本写到 url。
    ///
    /// 空白串按「没有内容」处理（同 `NotesExporter.write`）：存一个只有空格的
    /// 字幕文件毫无用处，而且会让调用方以为导出成功了
    static func write(_ text: String, to url: URL) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptExportError.noSegments
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw TranscriptExportError.writeFailed(
                path: url.path, reason: error.localizedDescription
            )
        }
    }
}

// MARK: - 无头自检

extension TranscriptExporter {

    struct SelfTestResult {
        var lines: [String] = []
        var passed = 0
        var failed = 0
    }

    /// 离线自检：不弹面板、不联网、不加载模型、不读真实录音库。
    ///
    /// 钉的五件事，每一件都对应用户真会遇到的一种坏结果：
    ///   ① 序号/时间戳格式（播放器不认 → 整个文件打不开）；
    ///   ② 毫秒进位与跨小时（字幕整体偏移一秒 / 一小时后全错）；
    ///   ③ 空段与重叠（屏幕上一条空白 / 两句话叠在一起）；
    ///   ④ 最后一句没有结束时间（最后一句话永远不消失）；
    ///   ⑤ 说话人为空（导出件里冒出 `: 文本` 或「未知说话人」）。
    static func selfTest() -> SelfTestResult {
        var r = SelfTestResult()
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { r.passed += 1; r.lines.append("  ✅ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
            else { r.failed += 1; r.lines.append("  ❌ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
        }

        func segment(
            _ text: String,
            _ start: Int,
            _ end: Int,
            speaker: String? = nil,
            at date: Date = Date(timeIntervalSince1970: 1_858_464_000)
        ) -> TranscriptSegment {
            var s = TranscriptSegment(
                text: text, isFinal: true,
                startTimeMillis: start, endTimeMillis: end,
                timestamp: date, languages: ["zh-CN"]
            )
            s.speakerId = speaker
            return s
        }

        // 夹具：跨两个片段（第二段 offset 一小时），含空段、重叠段、
        // 结束时间缺失段、没标说话人的段
        let partOne = RecordingPart(
            id: UUID(),
            fileName: "a.wav",
            startedAt: Date(timeIntervalSince1970: 1_858_464_000),
            durationMillis: 60_000,
            offsetMillis: 0,
            segments: [
                segment("今天我们讲梯度下降。", 8_000, 12_000, speaker: "S1"),
                segment("   \n\t  ", 20_000, 22_000),
                segment("老师，学习率怎么定？", 22_000, 40_000, speaker: "S2"),
                segment("最后一句没有结束时间", 30_000, 30_000),
            ]
        )
        let partTwo = RecordingPart(
            id: UUID(),
            fileName: "b.wav",
            startedAt: Date(timeIntervalSince1970: 1_858_467_600),
            durationMillis: 10_000,
            // 3_600_000 = 1 小时：跨小时的进位就在这里
            offsetMillis: 3_600_000,
            segments: [
                segment("跨小时的一句", 123_004, 125_000, speaker: "S1"),
            ]
        )
        let session = RecordingSession(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_858_464_000),
            updatedAt: Date(timeIntervalSince1970: 1_858_464_000),
            parts: [partOne, partTwo],
            title: "第3讲 / 优化"
        )

        let prepared = preparedSegments(from: session)

        // ① 空段被剔除。数字钉死：4 段里 1 段是纯空白
        check(prepared.count == 4,
              "空段被剔除（5 段里 1 段纯空白 → 4 段）", "\(prepared.count) 段")
        check(!prepared.contains { $0.text.trimmingCharacters(in: .whitespaces).isEmpty },
              "导出件里不存在一条空字幕")

        // ② 时间戳进位：这些值一个都不能错
        let carries: [(Int, String)] = [
            (0, "00:00:00,000"),
            (999, "00:00:00,999"),
            (1_999, "00:00:01,999"),
            (59_999, "00:00:59,999"),
            (60_000, "00:01:00,000"),
            (3_723_004, "01:02:03,004"),
        ]
        let wrong = carries.filter { srtTimestamp($0.0) != $0.1 }
        check(wrong.isEmpty, "毫秒进位（999→1,999→59,999→60,000 都不许四舍五入）",
              wrong.isEmpty ? "6 个值全对" : "错的是 \(wrong.map { "\($0.0)→\(srtTimestamp($0.0))" }.joined(separator: "、"))")

        // ③ 跨小时：第二段 offset 一小时，绝对时间必须是 01:02:03,004
        let srt = (try? render(.srt, session: session)) ?? ""
        check(srt.contains("01:02:03,004 --> 01:02:05,000"),
              "跨小时：片段 offset 折进绝对时间（3_723_004 → 01:02:03,004）")

        // ④ SRT 格式：序号连续、时间戳用逗号
        let blocks = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let indexes = blocks.compactMap { $0.split(separator: "\n").first.flatMap { Int($0) } }
        check(indexes == Array(1...max(1, prepared.count)),
              "SRT 序号从 1 开始且连续", indexes.map(String.init).joined(separator: ","))
        check(!srt.contains("00:00:08.000") && srt.contains("00:00:08,000"),
              "SRT 时间戳用逗号（用点号很多播放器不认）")

        // ⑤ 最后一句没有结束时间（end == start）：也要有一条**说得过去**的区间。
        //    单独取一段来钉，字面值写死：2 个字 → 2×180 不足最短 800ms → 5_800
        let bare = (try? render(.srt, segments: [segment("末句", 5_000, 5_000)])) ?? ""
        check(bare.contains("00:00:05,000 --> 00:00:05,800"),
              "最后一句没有结束时间时按字数估一个（5000→5800，不是 5000→5000）",
              bare.split(separator: "\n").dropFirst().first.map(String.init) ?? "渲染失败")

        let ranges = blocks.compactMap { block -> (Int, Int)? in
            let lines = block.split(separator: "\n")
            guard lines.count >= 2 else { return nil }
            let parts = lines[1].components(separatedBy: " --> ")
            guard parts.count == 2, let a = parseSRT(parts[0]), let b = parseSRT(parts[1]) else { return nil }
            return (a, b)
        }
        check(ranges.count == prepared.count && ranges.allSatisfy { $0.1 > $0.0 },
              "每一条 cue 的结束时间都晚于开始时间（end == start 会被播放器丢掉）",
              ranges.map { "\($0.0)→\($0.1)" }.joined(separator: " "))

        // ⑥ 重叠夹紧：第三段 22_000–40_000 与第四段 30_000 起重叠，
        //    尾巴必须夹到 30_000，否则两句话同时在屏上
        let clamped = ranges.first { $0.0 == 22_000 }
        check(clamped?.1 == 30_000,
              "与下一段重叠的尾巴夹到下一段起点（22000→30000）",
              clamped.map { "\($0.0)→\($0.1)" } ?? "没找到那条 cue")

        // ⑦ 说话人为空：不印占位、不留 `": "` 前缀
        check(srt.contains("\n最后一句没有结束时间\n"),
              "没标说话人时文本行就是纯文本（不印「未知说话人」）")
        let emptySpeaker = segment("空说话人标签", 1_000, 2_000, speaker: "")
        let emptyLabelSRT = (try? render(.srt, segments: [emptySpeaker])) ?? ""
        check(emptyLabelSRT.contains("\n空说话人标签\n"),
              "说话人是空串时也按「没标」处理（不能导出成「: 空说话人标签」）",
              emptyLabelSRT.split(separator: "\n").last.map(String.init) ?? "")

        // ⑧ 说话人有值：SRT 前缀 + VTT `<v>`
        check(srt.contains("S1: 今天我们讲梯度下降。"), "SRT 带上说话人前缀")
        let vtt = (try? render(.vtt, session: session)) ?? ""
        check(vtt.hasPrefix("WEBVTT\n\n"), "VTT 头（WEBVTT + 空行，少一个空行整份文件不作数）")
        check(vtt.contains("00:00:22.000 --> 00:00:30.000") && !vtt.contains("00:00:22,000"),
              "VTT 时间戳用点号")
        check(vtt.contains("<v S2>老师，学习率怎么定？"), "VTT 用 <v> 标说话人（不是当正文念出来）")
        check(vtt.split(separator: "\n").filter { $0.contains("-->") }.count == prepared.count,
              "VTT 与 SRT 段数一致", "\(vtt.split(separator: "\n").filter { $0.contains("-->") }.count) 条")

        // ⑨ Markdown：可选带时间戳，且按说话人分段
        let mdWithTime = (try? render(.markdown, session: session, includeTimestamps: true)) ?? ""
        let mdPlain = (try? render(.markdown, session: session, includeTimestamps: false)) ?? ""
        check(mdWithTime.contains("[00:00:08] 今天我们讲梯度下降。"),
              "Markdown 带时间戳时每段有 [HH:MM:SS]")
        check(!mdPlain.contains("[00:00:08]") && mdPlain.contains("今天我们讲梯度下降。"),
              "Markdown 不带时间戳时一个时间戳都不出现")
        // 先取 Range 再比，**不要在同一条 `&&` 里 force unwrap**：
        // 「说话人没印出来」时自检该红，不该崩（崩了整条链只会显示 133，
        // 看不出是哪一条断言的事）
        let s1At = mdPlain.range(of: "**S1**")
        let s2At = mdPlain.range(of: "**S2**")
        check(s1At != nil && s2At != nil && s1At!.lowerBound < s2At!.lowerBound,
              "Markdown 按说话人分段，且顺序跟时间走")
        check(mdPlain.contains("第3讲 / 优化") && mdPlain.contains("2028-11-22") && mdPlain.contains("4 段"),
              "Markdown 抬头带标题、日期、段数")

        // ⑩ JSON：能解回原始段，时间是会话绝对时间
        do {
            let json = try render(.json, session: session)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([TranscriptSegment].self, from: json.data(using: .utf8) ?? Data())
            check(decoded.count == prepared.count,
                  "JSON 与其余格式段数一致", "\(decoded.count) 条")
            check(decoded.contains { $0.startTimeMillis == 3_723_004 && $0.text == "跨小时的一句" },
                  "JSON 里是绝对时间（offset 已折进去）")
            check(decoded.first?.speakerId == "S1" && decoded.contains { $0.speakerId == nil },
                  "JSON 保留说话人字段（没标的仍然是 nil，不写空串）")
            check(json.contains("今天我们讲梯度下降"),
                  "JSON 不把中文转成 \\u 转义（人打开要能读）")
        } catch {
            check(false, "JSON 往返", "\(error.localizedDescription)")
        }

        // ⑪ 没有内容时必须**明确失败**，不是返回空串
        let emptySession = RecordingSession(
            id: UUID(), startedAt: Date(), updatedAt: Date(),
            parts: [RecordingPart(id: UUID(), fileName: "c.wav", startedAt: Date(), durationMillis: 1000,
                                  offsetMillis: 0, segments: [segment("  ", 0, 500)])]
        )
        do {
            _ = try render(.srt, session: emptySession)
            check(false, "没有内容时导出必须报错", "居然渲染成功了")
        } catch let error as TranscriptExportError {
            check((error.errorDescription ?? "").contains("没有可导出的"),
                  "没有内容时导出报错且说清原因", error.errorDescription ?? "")
        } catch {
            check(false, "没有内容时报错类型应是 TranscriptExportError", "\(type(of: error))")
        }

        // ⑫ 文件名：扩展名跟格式、日期跟会话、路径分隔符换掉
        let name = defaultFileName(
            title: "第3讲 / 优化: 下",
            startedAt: Date(timeIntervalSince1970: 1_858_464_000),
            format: .srt
        )
        check(name == "第3讲 - 优化- 下-2028-11-22.srt",
              "默认文件名：换掉路径分隔符 + 日期 + 扩展名", name)
        check(TranscriptExportFormat.allCases.map(\.fileExtension) == ["srt", "vtt", "md", "json"],
              "四种格式的扩展名（Markdown 是 .md 不是 .markdown）",
              TranscriptExportFormat.allCases.map(\.fileExtension).joined(separator: ","))

        // ⑬ 落盘：写得出、读回来一字不差；空文本必须报错
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ct-transcript-export-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let target = root.appendingPathComponent(name)
            try write(srt, to: target)
            let readBack = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            check(readBack == srt, "导出落盘：读回来与渲染结果逐字节相同",
                  "\(srt.utf8.count) 字节")
            do {
                try write("   \n ", to: root.appendingPathComponent("empty.srt"))
                check(false, "空文本落盘必须报错", "居然写成功了")
            } catch let error as TranscriptExportError {
                check((error.errorDescription ?? "").contains("还没有转录内容"),
                      "空文本落盘报错且说清原因", error.errorDescription ?? "")
            }
        } catch {
            check(false, "导出落盘", "\(error.localizedDescription)")
        }

        return r
    }

    /// `00:00:22,000` → 22000。自检用来反向确认 cue 的区间
    private static func parseSRT(_ text: String) -> Int? {
        let parts = text.replacingOccurrences(of: ",", with: ":").split(separator: ":")
        guard parts.count == 4,
              let h = Int(parts[0]), let m = Int(parts[1]),
              let s = Int(parts[2]), let ms = Int(parts[3]) else { return nil }
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }
}
