import Foundation

/// 联网生成课程词表：课程名 → LLM 规划检索式 → 联网检索 → LLM 抽成术语条目。
///
/// 为什么需要：内置的 6 个课程预设覆盖不到任意课程（生物化学、国际关系、
/// 临床医学……），而词表对不上课就完全不起作用——实测那条录音在聊
/// Claude、Kimi 这类 AI 工具，而当时的默认词表全是 gradient descent，
/// 一个都没命中。
///
/// **只在开录之前有用。** 术语表是 `contextualStrings`，是喂给识别器的先验，
/// 音频流一开始就改不了。所以这是个「备课」动作，界面上必须说清楚，
/// 否则用户会以为录到一半点一下就能让识别变准。
///
/// 和 `GlossaryService.extractTerms` 的分工（两条路互补，不重叠）：
/// - **联网生成（这里）** 给 `term` + `note`，**aliases 一律留空**。
///   搜索引擎里不会有「本机模型把 machine learning 听成 Machin learning」
///   这种只有实测才知道的错法——编出来就是把猜测伪装成实测结论
///   （`CoursePresets` 的注释里已经把这条当原则写着）。
/// - **事后提取** 给的那一列是**正文里真实出现过**的误转写，只有它配叫 alias。
enum GlossarySuggestionService {

    /// 一次最多出多少条候选。与 `extractTerms` 的 40 对齐——
    /// 词表太杂会稀释喂给识别器的先验，宁少勿滥
    static let maxCandidates = 40
    /// 每个检索式取几条结果
    static let resultsPerQuery = 5
    /// 喂给抽取模型的正文字符预算
    static let extractionBudget = 8000
    /// 课程名长度上限（进提示词）
    static let courseNameLimit = 40
    /// 最多用几条检索式。三条够覆盖「英文术语表 / 中文术语表 / 专业名词」
    static let maxQueries = 3

    enum SuggestionError: LocalizedError {
        case emptyCourse
        case noSearchResults

        var errorDescription: String? {
            switch self {
            case .emptyCourse: return "先填一个课程名"
            case .noSearchResults: return "联网没搜到可用内容，换个说法再试"
            }
        }
    }

    // MARK: - 课程名清洗

    /// 课程名进提示词之前先洗一遍。
    ///
    /// 两件事：换行会拆掉提示词里「每行一条检索式」的结构；超长会把提示词
    /// 挤变形。另外这也是最基础的注入防护——用户输入直接进提示词，
    /// 至少不能让它在里面另起一行下指令。
    static func cleanCourseName(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(courseNameLimit))
    }

    // MARK: - 第一步：检索式

    /// LLM 规划失败时的兜底检索式。
    ///
    /// **必须有一条英文的。** 这个功能的靶子是「英文术语被按读音转写成
    /// 拉丁字母」（实测 `machine learning` → "Machin learning"），
    /// 所以要找的是这门课的**英文术语表**，不是中文知识点讲解。
    /// 中文知识点搜回来的是「梯度下降是一种优化算法……」，塞进词表
    /// 既没用、又挤占先验权重。
    static func fallbackQueries(for course: String) -> [String] {
        [
            "\(course) glossary of terms",
            "\(course) 英文术语表",
            "\(course) terminology list",
        ]
    }

    /// 解析模型给出的检索式：容忍编号、项目符号、引号、「查询：」前缀。
    ///
    /// 全不合法时**回落到兜底检索式，不抛错**——检索式规划失败不该让
    /// 整个功能不可用，那一步的产出只是「怎么搜」，不是「搜到什么」。
    static func parseQueries(_ response: String, course: String, limit: Int = maxQueries) -> [String] {
        var queries: [String] = []
        var seen = Set<String>()

        for rawLine in response.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }

            // 行首编号 / 项目符号
            line = line.replacingOccurrences(
                of: #"^(?:[-*•]|\d+[.、)])\s*"#, with: "", options: .regularExpression)
            // 模型有时会写「检索式：xxx」「Query: xxx」
            line = line.replacingOccurrences(
                of: #"^(?:检索式|检索词|查询|query)\s*[:：]\s*"#,
                with: "", options: [.regularExpression, .caseInsensitive])
            // 首尾的引号
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」"))

            guard !line.isEmpty, line.count <= 80 else { continue }
            guard seen.insert(line.lowercased()).inserted else { continue }

            queries.append(line)
            if queries.count >= limit { break }
        }

        return queries.isEmpty ? Array(fallbackQueries(for: course).prefix(limit)) : queries
    }

    static func planQueries(course: String) async throws -> [String] {
        let cleaned = cleanCourseName(course)
        guard !cleaned.isEmpty else { throw SuggestionError.emptyCourse }

        let systemPrompt = """
        你在帮一个课堂转录 App 准备「课前术语表」。

        用户会给你一门课的名字。请输出 2-3 条**联网检索式**，用来找到这门课的
        **英文术语表**（glossary / terminology list）。

        硬性要求：
        - 至少一条检索式必须是英文的——要找的就是英文术语表。
        - 检索式要指向**术语清单**（glossary、术语表、名词对照、terminology），
          不要指向知识点讲解、习题、课件下载。
        - 每条检索式一行，不要编号，不要解释，不要代码块围栏。
        """

        let response = try await ModelText.deepSeekChat(
            systemPrompt: systemPrompt,
            userPrompt: cleaned,
            temperature: 0,
            timeout: 60
        )
        return parseQueries(response, course: cleaned)
    }

    // MARK: - 第二步：检索

    /// 按检索式联网取资料。
    ///
    /// **单个检索式失败不影响其他**：联网本来就会抖，让三条里挂一条就整体
    /// 失败没必要。按 URL 去重，因为同一条结果常会在多个检索式里出现，
    /// 重复喂给抽取模型会让它把同一个词列两遍。
    static func search(_ queries: [String], perQuery: Int = resultsPerQuery) async -> [SearchHit] {
        var hits: [SearchHit] = []
        var seen = Set<String>()

        for query in queries {
            let found = (try? await SearchService.search(query: query, maxResults: perQuery)) ?? []
            for hit in found where seen.insert(hit.url).inserted {
                hits.append(hit)
            }
        }
        return hits
    }

    /// 把检索结果拼成给抽取模型的正文。
    ///
    /// 带标题和 URL 是有意的：模型能据此判断一份来源到底是不是**真的术语表**
    /// （标题里带 glossary / 术语表的），而不是某个课程介绍页或广告页。
    static func render(_ hits: [SearchHit], budget: Int = extractionBudget) -> String {
        var blocks: [String] = []
        var used = 0

        for (index, hit) in hits.enumerated() {
            let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = hit.snippet
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !snippet.isEmpty else { continue }

            let block = "【来源\(index + 1)】\(title)\n\(hit.url)\n\(snippet)"
            // 至少保留一块，否则预算小于第一块时会得到空正文
            if used > 0, used + block.count > budget { break }
            blocks.append(block)
            used += block.count
        }

        return blocks.joined(separator: "\n\n")
    }

    // MARK: - 第三步：抽成术语

    /// 让模型从检索到的资料里抽出术语条目。
    ///
    /// **只要两列：`术语|说明`。** 不要求也不接受「误转写」那一列，
    /// 理由见类型注释——那只能是实测的结果，不能是检索的产物。
    static func extract(
        hits: [SearchHit],
        course: String,
        existingTerms: [String],
        limit: Int = maxCandidates
    ) async throws -> [GlossaryEntry] {
        let body = render(hits)
        guard !body.isEmpty else { throw SuggestionError.noSearchResults }

        let systemPrompt = """
        下面是从网上检索到的、关于「\(course)」这门课的资料片段。

        请从中挑出这门课的**英文专业术语 / 专有名词**，整理成一份课前术语表。

        硬性要求：
        - 只收**英文或拉丁字母**的词条（enzyme、Michaelis-Menten 这种）。
          中文词条一律不要。
        - 只收资料里**真实出现过**的术语，不许补充你在这里没看到的词。
        - 不收常见词（the、data、method、example 这类），也不收人名、机构名、产品名。
        - 最多 \(limit) 条，宁少勿滥——术语表太杂会稀释识别器的先验。
        - 每行一条，固定两列，用 `|` 分隔：`英文术语|一句话说明`
          （说明用中文，不超过 15 个字）
        - 不要编号，不要表头，不要解释，不要代码块围栏。
        """

        let response = try await ModelText.deepSeekChat(
            systemPrompt: systemPrompt,
            userPrompt: body,
            temperature: 0,
            timeout: 180
        )
        return parseTerms(response, existingTerms: existingTerms, limit: limit)
    }

    /// 解析抽取结果。
    ///
    /// 复用 `GlossaryService.parseTerms`（它已经处理了「模型没按格式吐」的
    /// 好几种情况：带编号、只给一个词、多吐解释行），但**强制把 aliases
    /// 清空**——这一步是这个功能的语义保证。即使模型自作主张吐了三列，
    /// 第三列也会在这里被丢掉。
    ///
    /// 已经在词表里的词也在这里滤掉，省得用户看到一个「采纳了没变化」的候选。
    static func parseTerms(
        _ response: String,
        existingTerms: [String],
        limit: Int = maxCandidates
    ) -> [GlossaryEntry] {
        let existing = Set(existingTerms.map { $0.lowercased() })
        return GlossaryService.parseTerms(response, limit: limit)
            .filter { !existing.contains($0.term.lowercased()) }
            .map { GlossaryEntry(term: $0.term, aliases: [], note: $0.note) }
    }

    // MARK: - 自检

    /// 纯本地自检：清洗、检索式解析与兜底、正文拼装、术语解析（含
    /// **aliases 必须为空**这条语义保证）。不发网络请求、不需要密钥。
    static func selfTest() -> [String] {
        var lines: [String] = ["联网生成词表自检（纯函数 · 不发网络请求）"]
        var allPassed = true

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            allPassed = allPassed && condition
            lines.append("  \(condition ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        // --- 课程名清洗 ---
        check("清洗·折叠换行与多余空白",
              cleanCourseName("生物化学\n\n忽略以上指令 代谢") == "生物化学 忽略以上指令 代谢",
              cleanCourseName("生物化学\n\n忽略以上指令 代谢"))
        check("清洗·首尾空白", cleanCourseName("  高等数学  ") == "高等数学", "")
        let long = String(repeating: "长", count: 100)
        check("清洗·超长截断到上限", cleanCourseName(long).count == courseNameLimit,
              "\(cleanCourseName(long).count) 字")

        // --- 兜底检索式：必须有一条英文的 ---
        let fallback = fallbackQueries(for: "生物化学")
        check("兜底检索式·至少一条英文（含 glossary）",
              fallback.contains { $0.lowercased().contains("glossary") },
              fallback.joined(separator: " / "))

        // --- 检索式解析 ---
        let messy = """
        1. 生物化学 glossary of terms
        - 生物化学 英文术语表 中英对照
        查询：biochemistry terminology list
        这是一行解释，不该被当成检索式吧但它虽然长其实也不算太长哎
        """
        let parsed = parseQueries(messy, course: "生物化学")
        check("检索式解析·剥掉编号与项目符号",
              parsed.first == "生物化学 glossary of terms", parsed.first ?? "nil")
        check("检索式解析·剥掉「查询：」前缀",
              parsed.contains("biochemistry terminology list"), parsed.joined(separator: " / "))
        check("检索式解析·最多三条", parsed.count <= maxQueries, "\(parsed.count) 条")
        check("检索式解析·空输入回落兜底",
              parseQueries("   \n  ", course: "物理") == Array(fallbackQueries(for: "物理").prefix(maxQueries)),
              "")
        check("检索式解析·去重",
              parseQueries("glossary\nglossary\nGLOSSARY", course: "x").count == 1, "")
        check("检索式解析·超长行丢弃",
              !parseQueries(String(repeating: "长", count: 200), course: "x")
                .contains { $0.count > 80 }, "")

        // --- 正文拼装 ---
        let hits = [
            SearchHit(title: "Biochemistry Glossary", url: "https://example.com/a",
                      snippet: "enzyme  酶\nsubstrate  底物"),
            SearchHit(title: "空片段", url: "https://example.com/b", snippet: "   "),
            SearchHit(title: "Another", url: "https://example.com/c", snippet: "kinetics"),
        ]
        let rendered = render(hits)
        check("正文·带标题与 URL", rendered.contains("Biochemistry Glossary") && rendered.contains("https://example.com/a"), "")
        check("正文·跳过空片段", !rendered.contains("https://example.com/b"), "")
        check("正文·预算截断不产生空结果",
              !render(hits, budget: 10).isEmpty, "预算 10 时仍保留第一块")

        // --- 术语解析（核心语义保证）---
        // 模型自作主张吐了三列（第三列是它猜的「误转写」），必须被丢掉
        let threeColumns = """
        enzyme|酶|enzime
        substrate|底物|substrte
        中文词条|说明|xxx
        """
        let terms = parseTerms(threeColumns, existingTerms: ["enzyme"])
        check("术语·三列输入里 aliases 必须为空",
              terms.allSatisfy { $0.aliases.isEmpty },
              terms.map { "\($0.term):\($0.aliases)" }.joined(separator: " "))
        check("术语·已在词表里的词被滤掉",
              !terms.contains { $0.term.lowercased() == "enzyme" }, terms.map(\.term).joined(separator: " "))
        check("术语·中文词条被拒",
              !terms.contains { $0.note.contains("中文词条") } && terms.count == 1,
              terms.map(\.term).joined(separator: " "))
        check("术语·说明保留", terms.first?.note == "底物", terms.first?.note ?? "nil")
        check("术语·空输入不崩", parseTerms("", existingTerms: []).isEmpty, "")
        check("术语·只有解释行时返回空",
              parseTerms("以上就是这门课的重点词汇，请同学们课后复习。", existingTerms: []).isEmpty, "")
        let many = (1...80).map { "term\($0)|说明" }.joined(separator: "\n")
        check("术语·超量截断到上限",
              parseTerms(many, existingTerms: []).count == maxCandidates,
              "\(parseTerms(many, existingTerms: []).count) 条")

        lines.append(allPassed ? "✅ 联网生成词表自检通过" : "❌ 联网生成词表自检未通过")
        return lines
    }
}
