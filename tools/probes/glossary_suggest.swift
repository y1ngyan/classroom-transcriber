// 联网生成词表探针：跑**真实链路**（Tavily 检索 + DeepSeek 抽取），并把每一级的原始产出打出来。
// 跑法: ./tools/probe.sh glossary_suggest <课程名>
//
// 为什么不放在 --xxx-selftest 里：自检必须是纯本地的（不发网络请求、不花钱、
// 不需要密钥）。而这一段的正确性**只有在真实链路上才能证明**——解析层可以
// 自检，但「检索式能不能搜到术语表」「模型抽出来的词对不对」只能跑真的。
//
// 这个探针故意**不复用** GlossaryStore.suggestFromWeb 的编排，而是自己按
// service 的三个原语走一遍：store 里那套写的是进度文案，这里要的是
// 每一级的原始数据，直接看原始流才能定位问题在检索还是抽取。

import Foundation

@main
struct GlossarySuggestProbe {

    /// 不用 `static func main() async`。
    ///
    /// 实测：在这个工程的多文件编译下（`-parse-as-library` + 41 个源文件），
    /// 异步 main **链接不出入口点**——报 `Undefined symbols: _main`，而同一份
    /// 文件单独编译却能过。项目里已经跑通的写法是 `Task` + `dispatchMain()`
    /// （见 App.swift 的 `--dedup-file`），照抄它，不跟编译器较劲。
    static func main() {
        Task {
            await run()
            exit(0)
        }
        dispatchMain()
    }

    static func run() async {
        // ---- 一、纯函数自检（本地，不发网络）----
        print("═══ 一、纯函数自检 ═══")
        for line in GlossarySuggestionService.selfTest() { print(line) }

        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("\n用法: ./tools/probe.sh glossary_suggest <课程名>")
            exit(2)
        }
        let course = args[1]

        print("\n═══ 二、真实链路 · 课程「\(course)」═══")

        // ---- 2.1 规划检索式 ----
        let planStart = Date()
        let queries: [String]
        do {
            queries = try await GlossarySuggestionService.planQueries(course: course)
        } catch {
            print("❌ 检索式规划失败: \(error)")
            exit(1)
        }
        print(String(format: "\n── 检索式（%.1fs）──", Date().timeIntervalSince(planStart)))
        for (index, query) in queries.enumerated() {
            print("  \(index + 1). \(query)")
        }
        // 独立判据：至少要有一条英文检索式，否则靶子就不对
        let hasEnglish = queries.contains { query in
            query.filter { $0.isLetter }.allSatisfy { $0.isASCII } && !query.isEmpty
        }
        print(hasEnglish ? "  ✅ 含英文检索式" : "  ❌ 三条里没有一条纯英文，靶子不对（要找的是英文术语表）")

        // ---- 2.2 联网检索 ----
        let searchStart = Date()
        let hits: [SearchHit]
        do {
            hits = try await GlossarySuggestionService.search(queries)
        } catch {
            print(String(format: "\n── 检索结果（%.1fs）──", Date().timeIntervalSince(searchStart)))
            print("❌ \(error.localizedDescription)")
            print("   这是「通道不通」，不是「没搜到」——后面几步测不了，先修网络或密钥")
            exit(1)
        }
        print(String(format: "\n── 检索结果（%.1fs，去重后 %d 条）──",
                     Date().timeIntervalSince(searchStart), hits.count))
        for (index, hit) in hits.enumerated() {
            print("  [\(index + 1)] \(hit.title.prefix(70))")
            print("      \(hit.url.prefix(95))")
            print("      \(hit.snippet.replacingOccurrences(of: "\n", with: " ").prefix(130))")
        }
        guard !hits.isEmpty else {
            print("\n❌ 一条结果都没有，后面的抽取没法跑")
            exit(1)
        }

        // 正文拼装（这一步是纯函数，顺便量它丢了多少）
        let body = GlossarySuggestionService.render(hits)
        let rawBytes = hits.reduce(0) { $0 + $1.snippet.count }
        print(String(format: "\n── 正文拼装 ── 原始 %d 字 → 喂给模型 %d 字（预算 %d）",
                     rawBytes, body.count, GlossarySuggestionService.extractionBudget))
        if body.count < rawBytes {
            print("  ℹ️ 被预算截断是正常的：检索结果总量超过预算时按块截尾")
        }

        // ---- 2.3 抽成条目 ----
        let extractStart = Date()
        let entries: [GlossaryEntry]
        do {
            entries = try await GlossarySuggestionService.extract(
                hits: hits, course: course, existingTerms: []
            )
        } catch {
            print("❌ 抽取失败: \(error)")
            exit(1)
        }
        print(String(format: "\n── 抽取结果（%.1fs，%d 条）──",
                     Date().timeIntervalSince(extractStart), entries.count))
        for (index, entry) in entries.enumerated() {
            print(String(format: "  %2d. %-32@ %@", index + 1, entry.term, entry.note))
        }

        // ---- 三、独立校验（不调用被测代码的校验函数）----
        print("\n═══ 三、独立校验 ═══")
        var passed = true
        func judge(_ name: String, _ ok: Bool, _ detail: String = "") {
            passed = passed && ok
            print("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        // 语义保证：联网生成的别名必须全空（拿不到"实测误转写"）
        let withAliases = entries.filter { !$0.aliases.isEmpty }
        judge("所有条目 aliases 为空", withAliases.isEmpty,
              withAliases.isEmpty ? "" : "违规 \(withAliases.count) 条：\(withAliases.map(\.term).joined(separator: "、"))")

        // 只要拉丁字母词条
        let nonLatin = entries.filter { entry in
            !entry.term.contains { $0.isLetter && $0.isASCII }
        }
        judge("条目都含拉丁字母", nonLatin.isEmpty,
              nonLatin.isEmpty ? "" : "违规：\(nonLatin.map(\.term).joined(separator: "、"))")

        judge("条数不超上限", entries.count <= GlossarySuggestionService.maxCandidates,
              "\(entries.count) / \(GlossarySuggestionService.maxCandidates)")

        judge("条目无重复",
              Set(entries.map { $0.term.lowercased() }).count == entries.count, "")

        let overLong = entries.filter { $0.term.count > 60 }
        judge("没有超长词条", overLong.isEmpty, overLong.isEmpty ? "" : "\(overLong.count) 条")

        print(passed ? "\n✅ 真实链路探针通过" : "\n❌ 真实链路探针未通过")
    }
}
