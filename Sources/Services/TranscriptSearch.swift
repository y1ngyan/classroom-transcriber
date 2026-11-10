import Foundation

/// 跨录音全文检索：在**所有课的转录段**里找一句话。
///
/// 为什么自己写而不是上 SQLite FTS：这个场景要的是「中文模糊命中 + 排得准」，
/// FTS5 的默认分词器对中文只能整段当词，`unicode61` 又不切汉字；要中文就得引
/// 分词扩展（或按字切再自己合并），复杂度与引入一个库差不多，还得管索引落盘与迁移。
/// 而 55 节课大约一万多段，内存里建一次 bigram 倒排只要几十毫秒。
///
/// 中文没有词边界，所以按**二元字组**切：`梯度下降` → `梯度`/`度下`/`下降`。
/// 查询同样切 bigram，命中越多分越高；单字查询退化成子串匹配（否则一个 bigram 都没有）。
enum TranscriptSearch {

    /// 调用方从 `RecordingSession` 摊平后交进来的一节课。
    /// 时间用**会话绝对毫秒**（片段 offset 已折进去），这样结果能直接跳播放位置。
    struct Doc: Equatable {
        var sessionID: UUID
        var title: String
        var course: String
        var startedAt: Date
        var segments: [Segment]

        init(sessionID: UUID, title: String, course: String, startedAt: Date, segments: [Segment]) {
            self.sessionID = sessionID
            self.title = title
            self.course = course
            self.startedAt = startedAt
            self.segments = segments
        }
    }

    struct Segment: Equatable {
        var startMillis: Int
        var text: String

        init(startMillis: Int, text: String) {
            self.startMillis = startMillis
            self.text = text
        }
    }

    /// 一条命中：哪节课、哪一段、命中位置。
    struct Hit: Equatable {
        var sessionID: UUID
        var title: String
        var course: String
        var startedAt: Date
        var startMillis: Int
        var text: String
        /// 片段（已截好窗口）；`matchRange` 是片段里命中词的位置，供界面高亮
        var snippet: String
        var matchRange: Range<String.Index>?
        var score: Int
    }

    /// 一节课的汇总（界面上先列课，再展开句子）
    struct SectionHit: Equatable {
        var sessionID: UUID
        var title: String
        var course: String
        var startedAt: Date
        var hits: [Hit]

        var best: Int { hits.first?.score ?? 0 }
    }

    // MARK: - 索引

    /// 倒排索引。`postings[bigram] = [段序号]`，段序号指向 `entries`
    struct Index {
        fileprivate var entries: [(doc: Doc, segmentIndex: Int, normalized: String, titleNormalized: String)] = []
        fileprivate var postings: [String: [Int]] = [:]

        var documentCount: Int {
            Dictionary(grouping: entries, by: { $0.doc.sessionID }).count
        }

        var segmentCount: Int { entries.count }
    }

    static func build(_ docs: [Doc]) -> Index {
        var index = Index()
        for doc in docs {
            let titleNormalized = normalize(doc.title + " " + doc.course)
            for (offset, segment) in doc.segments.enumerated() {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let slot = index.entries.count
                let normalized = normalize(text)
                index.entries.append((doc, offset, normalized, titleNormalized))
                for gram in bigrams(normalized) {
                    index.postings[gram, default: []].append(slot)
                }
            }
        }
        return index
    }

    // MARK: - 检索

    static func search(_ query: String, in index: Index, limit: Int = 40) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let normalizedQuery = normalize(trimmed)
        let grams = bigrams(normalizedQuery)

        var candidates: [Int: Int] = [:]     // 槽位 → 命中 bigram 数
        if grams.isEmpty {
            // 单字查询：没有 bigram，退回子串扫描（一万段也就一次遍历）
            for (slot, entry) in index.entries.enumerated() where entry.normalized.contains(normalizedQuery) {
                candidates[slot] = 1
            }
        } else {
            for gram in grams {
                for slot in index.postings[gram] ?? [] {
                    candidates[slot, default: 0] += 1
                }
            }
        }

        var hits: [Hit] = []
        for (slot, matchedGrams) in candidates {
            let entry = index.entries[slot]
            // 分数：命中的 bigram 数 × 3 + 密度（命中占比），标题/课程命中再加 12。
            // 密度这一项是为了让「一句话里几乎整句都对上」排在「长篇里偶然出现」前面
            let density = grams.isEmpty ? 0 : (matchedGrams * 100) / max(1, grams.count)
            var score = matchedGrams * 3 + density
            // 标题/课程命中给一个大加成：用户搜「反向传播」时，他要的是**那节课**，
            // 不是正文里偶然提到一次的三处。12 分的那版压不住整句正文命中（实测变异：
            // 去掉加成后结果不变，说明这条判据当时是空的）
            if !normalizedQuery.isEmpty, entry.titleNormalized.contains(normalizedQuery) {
                score += 150
            }
            let (snippet, range) = makeSnippet(text: entry.normalized, segment: entry.doc.segments[entry.segmentIndex].text,
                                               query: normalizedQuery)
            hits.append(Hit(sessionID: entry.doc.sessionID,
                            title: entry.doc.title,
                            course: entry.doc.course,
                            startedAt: entry.doc.startedAt,
                            startMillis: entry.doc.segments[entry.segmentIndex].startMillis,
                            text: entry.doc.segments[entry.segmentIndex].text,
                            snippet: snippet,
                            matchRange: range,
                            score: score))
        }

        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.startMillis < $1.startMillis
        }
        return Array(hits.prefix(limit))
    }

    /// 按课聚合：界面先列「哪几节课讲过」，再展开句子
    static func sections(_ hits: [Hit]) -> [SectionHit] {
        var order: [UUID] = []
        var grouped: [UUID: [Hit]] = [:]
        for hit in hits {
            if grouped[hit.sessionID] == nil { order.append(hit.sessionID) }
            grouped[hit.sessionID, default: []].append(hit)
        }
        return order.compactMap { id in
            guard let list = grouped[id], let first = list.first else { return nil }
            return SectionHit(sessionID: id, title: first.title, course: first.course,
                              startedAt: first.startedAt, hits: list)
        }
    }

    // MARK: - 归一化与分词

    /// 归一到「可比」：忽略大小写与全半角差异，去掉标点之外的噪音留给 bigram 自己处理
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 二元字组。标点与空白先剔除：`梯度，下降` 与 `梯度下降` 应该命中同一批
    static func bigrams(_ text: String) -> Set<String> {
        // 自己先归一：调用方忘了 fold 也不会因为大小写/全半角漏命中
        let stripped = normalize(text).filter { !$0.isWhitespace && !$0.isPunctuation }
        guard stripped.count >= 2 else { return [] }
        let characters = Array(stripped)
        var grams = Set<String>()
        for index in 0..<(characters.count - 1) {
            grams.insert(String(characters[index...(index + 1)]))
        }
        return grams
    }

    /// 片段：命中位置前后各 18 个字符，两头加省略号。
    /// `matchRange` 落在**原句**上（不是片段），因为片段里做下标换算极易错位，
    /// 界面直接用原句高亮更省事——片段只用于一眼扫读
    static func makeSnippet(text: String, segment: String, query: String)
        -> (String, Range<String.Index>?) {
        let normalizedSegment = normalize(segment)
        guard !query.isEmpty, let found = normalizedSegment.range(of: query) else {
            let head = segment.prefix(60)
            return (segment.count > 60 ? head + "…" : String(head), nil)
        }
        let radius = 18
        let startOffset = normalizedSegment.distance(from: normalizedSegment.startIndex, to: found.lowerBound)
        let endOffset = normalizedSegment.distance(from: normalizedSegment.startIndex, to: found.upperBound)

        // 归一化可能改变字符数（全半角折叠），换算回原句时按比例截断并夹到合法范围
        let ratio = segment.isEmpty ? 1.0 : Double(segment.count) / Double(max(1, normalizedSegment.count))
        let lower = max(0, Int(Double(startOffset) * ratio) - radius)
        let upper = min(segment.count, Int(Double(endOffset) * ratio) + radius)
        let startIndex = segment.index(segment.startIndex, offsetBy: lower)
        let endIndex = segment.index(segment.startIndex, offsetBy: upper)
        var snippet = String(segment[startIndex..<endIndex])
        if lower > 0 { snippet = "…" + snippet }
        if upper < segment.count { snippet += "…" }

        let matchRange = segment.range(of: query, options: [.caseInsensitive, .widthInsensitive])
        return (snippet, matchRange)
    }
}
