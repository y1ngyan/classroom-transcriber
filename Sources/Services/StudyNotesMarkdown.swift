import Foundation

/// `StudyNotes` → Markdown。**纯函数，不碰磁盘、不碰界面**。
///
/// 为什么单独一步而不是让 View 直接拼字符串：拼出来的那份文本要经
/// `NotesExporter.write` 落盘，而落盘那条路径的判据（写没写成、内容与产出一致）
/// 只有在文本本身可离线算出来的时候才测得了。View 里拼的话，
/// 「导出的是不是用户看到的那份」就只能靠肉眼比
///
/// 复用 `NotesService.formatTimestamp`：时间戳格式全项目只有那一处，
/// 这里再写一遍 `%02d:%02d:%02d`，改了格式就会有两套时间戳
enum StudyNotesMarkdown {

    /// 渲染成一份可直接导出的 Markdown。
    ///
    /// 按 `StudyItemKind.allCases` 的顺序分组（摘要 → 重点 → 待办 → 考点 →
    /// 术语），**空组不出现**——给一堂没有待办的课印一个空的「## 待办」标题，
    /// 用户会以为是自己漏看了什么。组内顺序沿用 `items` 的顺序
    /// （`generate` 已经按锚点时间排过）
    static func render(_ notes: StudyNotes) -> String {
        var lines: [String] = ["# 课后笔记", ""]

        // 抬头：日期与模型。重跑会得到不同的结果，导出件得能自己说明是哪一份
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("> 生成于 \(formatter.string(from: notes.generatedAt)) · \(notes.model)")
        lines.append("")

        for kind in StudyItemKind.allCases {
            let group = notes.items.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            lines.append("## \(kind.label)")
            lines.append("")
            for item in group {
                lines.append("- \(line(for: item))")
            }
            lines.append("")
        }

        if let usage = notes.usage {
            lines.append("---")
            lines.append("")
            lines.append(
                "> 用时 \(String(format: "%.1f", usage.elapsedSeconds)) 秒 · "
                + "\(usage.sliceCount) 片 · 估算 \(String(format: "%.4f", usage.estimatedYuan)) 元"
            )
            lines.append("")
        }

        // 末尾留一个换行：POSIX 文本文件以换行结尾，`cat` 出来的最后一行
        // 不会和 shell 提示符黏在一起
        return lines.joined(separator: "\n")
    }

    /// 一条要点。时间戳取**第一个锚点**——一条要点可以挂多个锚点（见
    /// `StudyNotesService.validate`），正文里列一长串时间戳会盖掉正文本身。
    /// 完整的锚点列表在 `.notes.json` 里，导出件是给人读的
    static func line(for item: StudyItem) -> String {
        guard let first = item.anchors.min(by: { $0.startMillis < $1.startMillis }) else {
            // 走不到：没有锚点的条目压根构造不出来。真走到了也不编一个时间戳，
            // 只省掉那一段——编出来的时间戳正是这一包最不想看到的东西
            return item.text
        }
        return "\(item.text) [\(NotesService.formatTimestamp(first.startMillis))]"
    }
}

// MARK: - 离线自检

extension StudyNotesMarkdown {

    struct SelfTestResult {
        var lines: [String] = []
        var passed = 0
        var failed = 0
    }

    /// 离线自检：不联网、不花钱、不加载模型、不发声，写盘那两条在临时目录里跑。
    ///
    /// 钉的是「用户看到的和导出去的是不是同一份」——`--export-notes-selftest`
    /// 已经在 `NotesExporter` 那一层钉过「写出去的和给进去的一字不差」，
    /// 这里钉的是**给进去的那份文本本身对不对**
    static func selfTest() -> SelfTestResult {
        var r = SelfTestResult()
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { r.passed += 1; r.lines.append("  ✅ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
            else { r.failed += 1; r.lines.append("  ❌ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
        }

        let partID = UUID()
        func anchor(_ millis: Int) -> Anchor {
            Anchor(partID: partID, segmentID: UUID(), startMillis: millis)
        }
        let notes = StudyNotes(
            sessionID: UUID(),
            generatedAt: Date(timeIntervalSince1970: 1_858_464_000),   // 2028-11-22 12:00 UTC
            model: "stub-model",
            items: [
                StudyItem(kind: .keyPoint, text: "梯度下降沿负梯度迭代", anchors: [anchor(743_000)]),
                StudyItem(kind: .summary, text: "本节讲优化", anchors: [anchor(8_000)]),
                StudyItem(kind: .keyPoint, text: "学习率决定步长", anchors: [anchor(22_000), anchor(58_000)]),
            ],
            usage: nil
        )
        let markdown = render(notes)

        // ① 分组顺序：摘要必须在重点前面（`StudyItemKind.allCases` 的顺序）
        let summaryAt = markdown.range(of: "## 摘要")
        let keyPointAt = markdown.range(of: "## 重点")
        check(summaryAt != nil && keyPointAt != nil
              && summaryAt!.lowerBound < keyPointAt!.lowerBound,
              "分组顺序：摘要排在重点前面")

        // ② 空组不出现：这份笔记没有待办/考点/术语
        var emptyGroups: [String] = []
        for label in ["待办", "考点", "术语"] where markdown.contains("## \(label)") {
            emptyGroups.append(label)
        }
        check(emptyGroups.isEmpty, "空组不出现（没有待办的课不该印一个空的「## 待办」）",
              emptyGroups.isEmpty ? "待办/考点/术语 都没出现" : "多出来了：\(emptyGroups.joined(separator: "、"))")

        // ③ 每条带时间戳，且取**最靠前**的那个锚点
        check(markdown.contains("- 梯度下降沿负梯度迭代 [00:12:23]"),
              "每条带时间戳（会话轴 743000ms → 00:12:23）")
        check(markdown.contains("- 学习率决定步长 [00:00:22]"),
              "多锚点取最靠前的那个（22000 而不是 58000）")

        // ④ 抬头写清「这份是谁写的、什么时候写的」
        check(markdown.contains("stub-model") && markdown.contains("2028-11-22"),
              "抬头带日期与模型标识")

        // ⑤ 没有锚点时不编时间戳。走不到（没有锚点的条目构造不出来），
        //    但真走到了也绝不能编一个——编时间戳正是这一包最不想看到的东西
        let orphan = StudyItem(kind: .keyPoint, text: "孤条", anchors: [])
        check(line(for: orphan) == "孤条",
              "没有锚点时不编时间戳（只省掉那一段）", line(for: orphan))

        // ⑥ 导出往返：render 出来的文本经 **NotesExporter** 落盘，读回来一字不差。
        //    这条把「复用修好的那条导出路径」这件事钉住——另写一份文件写入的实现
        //    不会经过 NotesExporter.write，也就不会经过它的空内容/写失败判据
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ct-study-notes-md-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let target = try NotesExporter.resolveTarget(
                path: root.appendingPathComponent("note.md").path
            )
            try NotesExporter.write(markdown, to: target)
            let readBack = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            check(readBack == markdown,
                  "导出往返：经 NotesExporter 落盘后与渲染结果逐字节相同",
                  readBack == markdown ? "\(markdown.utf8.count) 字节" : "读回来和写出去的不一样")
        } catch {
            check(false, "导出往返", "\(error.localizedDescription)")
        }

        return r
    }
}
