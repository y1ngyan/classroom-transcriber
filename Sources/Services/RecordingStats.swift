import Foundation

/// 录音页顶部「本周概览」的聚合结果（P15-2）。
///
/// 纯函数、只吃 `SessionSummary`：**不扫盘、不碰 store、不看当前界面**。
/// 这样它才能在自检里用固定日期跑，也才不会把「启动时用 IO 换画面」
/// 这条退化路径带回来——列表已经有 index.json 里的全部摘要，聚合只是
/// 对内存数组做一次分组求和。
struct RecordingStats: Equatable {
    /// 本周（周一 00:00 起）的总录音时长
    let weeklyDurationMillis: Int
    /// 本周的录音条数（列表上叫「段课」）
    let weeklySessionCount: Int
    /// 本周各录音里「存疑 + 不可信」的段数之和
    let doubtfulSegmentCount: Int
    /// 最近 7 天每天的时长，**已归一化**：0 是最旧的一天（6 天前），
    /// 6 是今天。最高的一天 = 1，没有录音的一天 = 0
    let dailyValues: [Double]

    /// 「4h 46m」/「46m」。列表里只放这一种写法：英文单位比「4 小时 46 分」
    /// 短一截，28pt 下两行并排也不会被挤换行
    var formattedWeeklyDuration: String {
        let minutes = weeklyDurationMillis / 60_000
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }
}

extension RecordingStats {

    static let dayCount = 7

    /// 聚合。`summaries` 为空、或本周一至今一条录音都没有时返回 nil——
    /// 视图据此整条不渲染。**不要返回一条全 0 的概览**：0h 0m 不是信息，
    /// 它只是在标题下面多占一行
    static func make(from summaries: [SessionSummary],
                     now: Date = Date(),
                     calendar: Calendar = .current) -> RecordingStats? {
        guard !summaries.isEmpty,
              let weekStart = weekStart(for: now, calendar: calendar)
        else { return nil }

        let thisWeek = summaries.filter {
            $0.startedAt >= weekStart && $0.startedAt <= now
        }
        guard !thisWeek.isEmpty else { return nil }

        let weekMillis = thisWeek.reduce(0) { $0 + $1.durationMillis }
        let doubtful = thisWeek.reduce(0) { $0 + $1.fairCount + $1.poorCount }

        // 最近 7 天：今天往前数 6 天。用 half-open 区间，边界那一条
        // 不会同时落进两天
        let todayStart = calendar.startOfDay(for: now)
        var dailyMillis: [Int] = []
        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else {
                dailyMillis.append(0)
                continue
            }
            let sum = summaries.reduce(0) { total, summary in
                summary.startedAt >= dayStart && summary.startedAt < dayEnd
                    ? total + summary.durationMillis
                    : total
            }
            dailyMillis.append(sum)
        }
        let maximum = dailyMillis.max() ?? 0
        let normalized = maximum > 0
            ? dailyMillis.map { Double($0) / Double(maximum) }
            : dailyMillis.map { _ in 0 }

        return RecordingStats(
            weeklyDurationMillis: weekMillis,
            weeklySessionCount: thisWeek.count,
            doubtfulSegmentCount: doubtful,
            dailyValues: normalized
        )
    }

    /// 本周起点：**周一 00:00**，与系统区域设置无关。
    ///
    /// 不能用 `calendar.dateInterval(of: .weekOfYear, for:)` 直接取：
    /// 那个区间跟着 `firstWeekday` 走，系统语言是英语时一周从周日开始，
    /// 「本周」就会多算一天。这里自己按 weekday 倒推：
    /// 周日 = 1，周一 = 2，…，周六 = 7
    static func weekStart(for now: Date, calendar: Calendar) -> Date? {
        let todayStart = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: todayStart)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: todayStart)
    }

    /// `--ui-snapshot` 用的固定读数。
    ///
    /// 快照 fixture 里的会话时间相对「现在」生成，跨周跑会变成另一组数字
    /// （周一拍和周五拍差一天、差一周）。概览条是这一包唯一的验收画面，
    /// 必须每天逐像素一致，所以在快照模式下直接给一组固定值：
    /// 三条不同时长（102 / 96 / 88 分钟，合计 4h 46m）、存疑 3 段。
    /// 柱子的位置和高度也与那三条对应：3 天前、昨天、今天
    static let snapshotFixture = RecordingStats(
        weeklyDurationMillis: (102 + 96 + 88) * 60_000,
        weeklySessionCount: 3,
        doubtfulSegmentCount: 3,
        dailyValues: [0, 0, 0, 1.0, 0, 88.0 / 102.0, 96.0 / 102.0]
    )

    // MARK: - 自检

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// `--recording-stats-selftest`：四条纯函数判据，固定日历、固定日期，
    /// 不读真实库、不联网、不碰界面
    static func selfTest() -> SelfTestResult {
        var lines: [String] = ["录音概览聚合自检（固定日期 · 纯内存）"]
        var passed = 0
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        // 固定 UTC 日历：结果不随跑自检的机器时区变
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ month: Int, _ day: Int, _ hour: Int = 0,
                  _ minute: Int = 0, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(
                year: 2026, month: month, day: day,
                hour: hour, minute: minute, second: second
            ))!
        }

        // 2026-10-30 是周五；本周一是 10-26 00:00
        let now = date(10, 30, 15)
        func summary(startedAt: Date, minutes: Int,
                     fair: Int = 0, poor: Int = 0) -> SessionSummary {
            var segments: [TranscriptSegment] = []
            for i in 0..<(fair + poor) {
                var segment = TranscriptSegment(
                    text: "第 \(i) 段", isFinal: true,
                    startTimeMillis: i * 1_000, endTimeMillis: (i + 1) * 1_000,
                    timestamp: startedAt, languages: ["zh-CN"]
                )
                segment.qualityGrade = i < fair ? .fair : .poor
                segments.append(segment)
            }
            let part = RecordingPart(
                id: UUID(), fileName: nil, startedAt: startedAt,
                durationMillis: minutes * 60_000, offsetMillis: 0, segments: segments
            )
            return SessionSummary(session: RecordingSession(
                id: UUID(), startedAt: startedAt, updatedAt: startedAt, parts: [part]
            ))
        }

        // ① 本周 = 周一 00:00 到现在。周一零点整算在内；
        //    上周日 23:59:59 不算
        let mondayMidnight = date(10, 26, 0)
        let lastSunday = date(10, 25, 23, 59, 59)
        let weekStats = make(from: [
            summary(startedAt: mondayMidnight, minutes: 60),
            summary(startedAt: lastSunday, minutes: 30),
        ], now: now, calendar: calendar)
        check(weekStats?.weeklySessionCount == 1,
              "本周区间从周一 00:00 起（上周日不计入）",
              "（实得 \(weekStats?.weeklySessionCount ?? -1) 条）")
        check(weekStats?.weeklyDurationMillis == 60 * 60_000,
              "本周总时长只算本周录音",
              "（实得 \(weekStats?.weeklyDurationMillis ?? -1) ms）")

        // ② 7 柱归一化：今天 60 分钟 = 1；两天前 30 = 0.5；
        //    六天前 15 = 0.25；其余空天 0
        let barStats = make(from: [
            summary(startedAt: date(10, 30, 9), minutes: 60),
            summary(startedAt: date(10, 28, 9), minutes: 30),
            summary(startedAt: date(10, 24, 9), minutes: 15),
        ], now: now, calendar: calendar)
        let values = barStats?.dailyValues ?? []
        check(values.count == dayCount,
              "7 根柱子", "（实得 \(values.count) 根）")
        check(values.last == 1.0 && values[2] == 0 && values[4] == 0.5 && values[0] == 0.25,
              "柱高按最大一天归一化，空天为 0",
              "（实得 \(values.map { String(format: "%.2f", $0) }.joined(separator: "/"))）")

        // ③ 没有录音 → nil（视图整条不渲染）。注意是**空数组**，
        //    不是「有录音但都在上周」——后者另有一条 guard，见 make 的注释
        check(make(from: [], now: now, calendar: calendar) == nil,
              "没有录音时返回 nil")

        // ④ 存疑 = 存疑 + 不可信，按**本周**的录音求和
        let doubtfulStats = make(from: [
            summary(startedAt: date(10, 29, 9), minutes: 20, fair: 2, poor: 1),
            summary(startedAt: date(10, 27, 9), minutes: 20, fair: 0, poor: 2),
            // 上周那条不该被算进来
            summary(startedAt: lastSunday, minutes: 20, fair: 9, poor: 9),
        ], now: now, calendar: calendar)
        check(doubtfulStats?.doubtfulSegmentCount == 5,
              "存疑段数 = 本周存疑 + 不可信之和",
              "（实得 \(doubtfulStats?.doubtfulSegmentCount ?? -1) 段）")

        lines.append("")
        lines.append(failed == 0
                     ? "✅ 录音概览聚合自检通过（\(passed) 条）"
                     : "❌ 录音概览聚合自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }
}
