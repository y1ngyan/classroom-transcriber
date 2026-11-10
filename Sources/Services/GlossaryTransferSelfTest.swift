import Foundation

/// `GlossaryTransfer` 的离线自检。纯本地：不联网、不读用户词表。
///
/// 判据都围着一件事：**自己的导出必须能被自己导入回来，且一个字段都不丢**。
/// 「我把词表发给同学，他导不进去」是这类功能唯一真正的失败形态
enum GlossaryTransferSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    private final class Checker {
        var lines: [String] = []
        var passed = 0
        var failed = 0
        func note(_ text: String) { lines.append(text) }
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(title)" + (detail.isEmpty ? "" : " · \(detail)"))
        }
    }

    static func run() -> SelfTestResult {
        let c = Checker()
        c.note("术语表导入 / 导出自检（纯本地 · 不联网、不读用户词表）")

        c.note("")
        c.note("─── 一、导出 ───")
        checkExport(c)

        c.note("")
        c.note("─── 二、导入（三种格式）───")
        checkImport(c)

        c.note("")
        c.note("─── 三、合并规则 ───")
        checkMerge(c)

        c.note("")
        c.note(c.failed == 0
            ? "✅ 术语表导入导出自检通过（\(c.passed) 条）"
            : "❌ 术语表导入导出自检未通过（过 \(c.passed) / 红 \(c.failed)）")
        return SelfTestResult(lines: c.lines, passed: c.passed, failed: c.failed)
    }

    // MARK: - 一

    private static func checkExport(_ c: Checker) {
        let entries = fixture()
        let csv = GlossaryTransfer.csv(entries)
        c.check(csv.hasPrefix("\u{FEFF}"), "CSV 带 BOM（Windows Excel 不串码）")
        c.check(csv.contains("术语,误听写法,释义"), "CSV 有表头")
        c.check(csv.contains("梯度下降,Machin learning|梯度递减,沿负梯度方向迭代"),
                "三个字段按行写出，误听写法用 | 分隔")
        c.check(csv.contains("\"学习率,学习速率\""), "含逗号的字段被引号包裹",
                csv.split(separator: "\n").first { $0.contains("学习率") }.map(String.init) ?? "无")

        let text = GlossaryTransfer.shareText(entries)
        c.check(text.contains("梯度下降（误听：Machin learning、梯度递减） — 沿负梯度方向迭代"),
                "分享文本一行一个词，带误听与释义")
        c.check(!text.contains("术语,"), "分享文本不含表头（粘进聊天框不该有）")

        let json = GlossaryTransfer.json([entries[0]])
        c.check(json.contains("\"term\" : \"梯度下降\""), "JSON 用盘上同构字段名")
        c.check(json.contains("梯度下降") && !json.contains("\\u68af"), "JSON 不转义中文")
    }

    // MARK: - 二

    private static func checkImport(_ c: Checker) {
        let entries = fixture()

        // 自己的 CSV 导回来
        let roundTrip = GlossaryTransfer.parse(GlossaryTransfer.csv(entries))
        c.check(roundTrip.entries.count == entries.count,
                "自家 CSV 导回来条数一致", "\(roundTrip.entries.count)/\(entries.count)")
        c.check(roundTrip.entries.first?.term == "梯度下降", "术语名一致")
        c.check(roundTrip.entries.first?.aliases == ["Machin learning", "梯度递减"],
                "误听写法按 | 拆开还原", roundTrip.entries.first?.aliases.joined(separator: "/") ?? "无")
        c.check(roundTrip.entries.first?.note == "沿负梯度方向迭代", "释义一致")
        c.check(roundTrip.entries.contains { $0.term == "学习率,学习速率" && $0.note == "先大后小" },
                "带逗号被引号包裹的字段也能还原（引号不被当成内容）",
                roundTrip.entries.map(\.term).joined(separator: " / "))

        // JSON 导回来
        let fromJSON = GlossaryTransfer.parse(GlossaryTransfer.json(entries))
        c.check(fromJSON.entries.count == entries.count, "自家 JSON 导回来条数一致")

        // Excel 复制出来的制表符文本
        let tsv = "术语\t误听写法\t释义\n反向传播\t反向传递|BP\t从后往前传\n"
        let fromTSV = GlossaryTransfer.parse(tsv)
        c.check(fromTSV.entries.count == 1 && fromTSV.entries[0].term == "反向传播",
                "制表符格式（Excel 复制）能导入", "\(fromTSV.entries.count) 条")
        c.check(fromTSV.entries.first?.aliases == ["反向传递", "BP"], "制表符格式的误听写法也拆开")

        // 没有表头、只有两列
        let twoColumns = "GPU\n显存\n"
        let noHeader = GlossaryTransfer.parse(twoColumns)
        c.check(noHeader.entries.count == 2, "没表头、只有一列也能导入", "\(noHeader.entries.count) 条")

        // 空行与空 term
        let dirty = "术语,误听写法,释义\n\n,Nothing,空术语\n有效词,,说明\n"
        let parsedDirty = GlossaryTransfer.parse(dirty)
        c.check(parsedDirty.entries.count == 1 && parsedDirty.entries[0].term == "有效词",
                "空 term 的行被丢掉，有效行保留", "\(parsedDirty.entries.count) 条")
        c.check(parsedDirty.rejected == 1, "被丢掉的行计入 rejected", "\(parsedDirty.rejected)")

        // 文件内重复
        let duplicated = "术语\n梯度下降\n梯度下降\nGPU\n"
        let deduped = GlossaryTransfer.parse(duplicated)
        c.check(deduped.entries.count == 2, "文件内重复的 term 只留一条", "\(deduped.entries.count) 条")
        c.check(deduped.selfDuplicates == 1, "重复条数被记下来（界面要说清楚丢了几条）")

        c.check(GlossaryTransfer.parse("").entries.isEmpty, "空文本返回空（不报错）")
        c.check(GlossaryTransfer.parse("这不是词表").entries.count == 1,
                "单行文本按一个术语处理（不硬判格式错）")
    }

    // MARK: - 三

    private static func checkMerge(_ c: Checker) {
        let local = [GlossaryEntry(term: "梯度下降", aliases: [], note: "我自己改过的释义")]
        let incoming = [
            GlossaryEntry(term: "梯度下降", aliases: ["Machin learning"], note: "别人的释义"),
            GlossaryEntry(term: "学习率", aliases: [], note: "步长"),
            GlossaryEntry(term: "GPU", aliases: [], note: "显卡"),
        ]
        let merged = GlossaryTransfer.merge(existing: local, incoming: incoming)
        c.check(merged.added == 2 && merged.skipped == 1,
                "新增 2 条、跳过 1 条重复", "added=\(merged.added) skipped=\(merged.skipped)")
        c.check(merged.entries.first?.note == "我自己改过的释义",
                "重复时保留本地那条（本地可能被人手改过）")
        c.check(merged.entries.count == 3, "合并后条数 = 本地 + 新增", "\(merged.entries.count) 条")

        let caseInsensitive = GlossaryTransfer.merge(
            existing: [GlossaryEntry(term: "GPU", aliases: [], note: "本地")],
            incoming: [GlossaryEntry(term: "gpu", aliases: [], note: "导入")])
        c.check(caseInsensitive.skipped == 1 && caseInsensitive.added == 0,
                "大小写不同视作同一个词（GPU == gpu）",
                "added=\(caseInsensitive.added) skipped=\(caseInsensitive.skipped)")
    }

    // MARK: - 夹具

    private static func fixture() -> [GlossaryEntry] {
        [
            GlossaryEntry(term: "梯度下降", aliases: ["Machin learning", "梯度递减"],
                          note: "沿负梯度方向迭代"),
            GlossaryEntry(term: "学习率,学习速率", aliases: [], note: "先大后小"),
        ]
    }
}
