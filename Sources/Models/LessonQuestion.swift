import Foundation

// MARK: - 状态与失败归类（设计稿 §4.4）

/// 一条问题的查询状态。§5 的状态机就是围着它转的。
///
/// **`noResults` 和 `failed` 必须分开**（§4.4 的「为什么」）：B 的硬要求是
/// 「通道不通 ≠ 没搜到」。两者共用一个状态的话，界面上总有一天会退化成同一句话；
/// 分开之后，写文案的人必须分别回答「这行该说什么」。
enum QuestionStatus: String, Codable, CaseIterable {
    case unasked
    case searching
    case answered
    case noResults
    case failed

    /// 认不出来的 rawValue 回落 `.unasked`，**不抛错**。
    ///
    /// 为什么不是「未知就抛」：问题条目跟着**会话文件**走（§4.1），一条抛出去
    /// 整条会话就读不出来——用户看到的是「那节课的录音从列表里消失了」，
    /// 而这只是「有行字我没见过」。同 `QuestionSensitivity.of` 的取舍。
    static func of(_ raw: String?) -> QuestionStatus {
        guard let raw, let value = QuestionStatus(rawValue: raw) else { return .unasked }
        return value
    }
}

/// 失败归类。只回答「重试时该说哪一种失败」，详细错误信息**不持久化**（§5.2）。
enum QuestionFailure: String, Codable, CaseIterable {
    /// 通道不通：对应既有的 `SuggestionError.searchUnavailable(detail:)`。
    /// **不新造错误类型**（§8.1）
    case channel
    /// 通道通了，模型这一步失败（超时、额度、返回结构坏）
    case model
    /// 通道通了、资料也搜到了，但没能得出可用答案（§5.2 的空答案判据）
    case empty

    /// 未知 rawValue **回落 nil 而不是某个默认归类**：归类是拿来选文案的，
    /// 认不出来时「没有归类」才是实话——硬塞一个 channel 会让界面说
    /// 「检查网络」，而这次失败可能根本不是网络
    static func of(_ raw: String?) -> QuestionFailure? {
        guard let raw else { return nil }
        return QuestionFailure(rawValue: raw)
    }
}

/// 答案的来源类型。**目前唯一的取值**。
///
/// 存在的意义不是分类，是让「这是 AI 检索结果」成为**数据属性**而不只是一句
/// 文案（§4.3）：将来加别的来源类型（老师讲义、教材）时，界面必须显式分支处理，
/// 不会因为「反正都一样」把新来源默认混进 AI 检索结果里。
enum QuestionOrigin: String, Codable, CaseIterable {
    case aiWebSearch

    static func of(_ raw: String?) -> QuestionOrigin {
        guard let raw, let value = QuestionOrigin(rawValue: raw) else { return .aiWebSearch }
        return value
    }
}

// MARK: - 答案（§4.3）

/// 一条答案的来源。
///
/// **标题与 URL 只能由代码从真实 `SearchHit` 原样拷过来**（拍板第 5 条）：
/// 模型至多在正文里引用来源编号，**无权填链接**。这样「引用了一个不存在的
/// 页面」这类最恶劣的编造在结构上不可能发生（§8.2）。
///
/// 注意这与现有 `FactCheckService`（让模型填 title/url）**有意不一致**，
/// 不要为了「统一」把它改回去（拍板结论「用户特别关注的两条」）。
struct AnswerSource: Codable, Equatable, Identifiable {
    var title: String
    var url: String

    /// 用 URL 当 id：来源就是「哪一页」，同一次检索里 URL 不重复。
    /// **不另存一个 UUID**——那会给「同一个页面」凭空造出两个身份，
    /// 而去重、比对都该按 URL 走
    var id: String { url }
}

/// 一次查询的答案。挂在 `LessonQuestion.answer` 上（nil = 没查过）。
struct QuestionAnswer: Codable, Equatable {
    /// 固定文案。**存一份进盘里**（§4.3）：渲染层即使拿不到这个常量
    /// （别的写入方、老存档、单独拷出去的 json）也必须显示它。
    /// 它是「答案不会被误认为老师原话」三道防线里的第二道（§8.3）
    static let aiNotice = "AI 检索结果，非老师所说"

    var id: UUID
    /// 模型产出的正文，按 Markdown 存（渲染器已存在）。**不硬截断**（拍板第 8 条）
    var markdown: String
    var sources: [AnswerSource]
    var createdAt: Date
    /// 哪个模型产出的。属于「可追责信息」，必须可见
    var model: String
    /// `tavily` / `serper`。同一次答案换过通道的话来源质量会变，留痕
    var searchProvider: String
    var origin: QuestionOrigin
    var notice: String

    init(
        id: UUID = UUID(),
        markdown: String,
        sources: [AnswerSource],
        createdAt: Date = Date(),
        model: String,
        searchProvider: String,
        origin: QuestionOrigin = .aiWebSearch,
        notice: String = QuestionAnswer.aiNotice
    ) {
        self.id = id
        self.markdown = markdown
        self.sources = sources
        self.createdAt = createdAt
        self.model = model
        self.searchProvider = searchProvider
        self.origin = origin
        self.notice = notice
    }

    /// 手写解码：**每个字段都有默认值**（§4.6.2 「一条坏不能连坐」）。
    ///
    /// 合成解码在这里有个坑，和 `TranscriptSegment` 那条注释是同一个：
    /// 有默认值的非可选属性遇到缺键**照样抛 `keyNotFound`**（合成器只看
    /// 属性是不是 Optional，不看等号后面的默认值）。`notice` 正好是这种字段，
    /// 而它恰恰是最不能缺的那一个。
    private enum CodingKeys: String, CodingKey {
        case id, markdown, sources, createdAt, model, searchProvider, origin, notice
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        sources = try c.decodeIfPresent([AnswerSource].self, forKey: .sources) ?? []
        // 缺生成的答案用 1970 而不是 `Date()`：**「现在」会把一个不知道什么时候
        // 生成的答案显示成「刚查的」**，那是在编一个学生信以为真的时间
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        searchProvider = try c.decodeIfPresent(String.self, forKey: .searchProvider) ?? ""
        origin = QuestionOrigin.of(try c.decodeIfPresent(String.self, forKey: .origin))
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? Self.aiNotice
    }
}

// MARK: - schema 版本

/// 问题条目的 schema 版本。
///
/// 作用只有一个：让「要不要对这条旧会话跑一次按需回填」有个可判定的门槛
/// （§4.6.4）。**它不是迁移版本号**——本包不做事先的全量迁移，
/// 旧存档在第一次打开提问页时才回填
enum LessonQuestionSchema {
    /// 旧存档缺这个键时视作 0（`decodeIfPresent ?? 0`），所以 0 的含义是
    /// 「还没回填过」。**0 不当可用版本**，同 `SpeakerDiarization.schemaVersion`
    static let current = 1
}

// MARK: - 问题条目（§4.2）

/// 一条「老师问过的问题」。跟着会话文件走（§4.1）：一条录音被删掉时，
/// 它的问题和答案一起消失，不需要第二套级联删除逻辑。
struct LessonQuestion: Identifiable, Codable, Equatable {
    let id: UUID
    /// 展示用的问题本体，**直接取 `QuestionDetector` 的 `coreQuestion`**，
    /// 不在这里二次清洗（§4.2）：再洗一遍会让用户看到的问题和检测器判成的
    /// 问题对不上，而排查时正是要拿两者对照
    var text: String
    /// 老师原句。检测器剥口头禅可能剥错，没有对照就分不清「检测错了」
    /// 还是「我记错了」
    var rawSentence: String
    /// **会话时间轴上的绝对毫秒**（§4.2）。必须走 `RecordingSession.absoluteRange`：
    /// 多段「接着录」的会话里，段内偏移会让学生回录音时定位到 0 点去
    var startTimeMillis: Int
    /// 指回 `TranscriptSegment.id`，用来做去重、回填和「看上下文」。
    /// **可空是刻意的**：重转会把整段 segments 换掉（id 全变），
    /// 那时这条引用就悬空——悬空就当「找不到上下文」，不因此丢条目（§4.6.5）
    var sourceSegmentID: UUID?
    /// 沿用 `QuestionDetector` 的 `questionLevel`（1 点名预警 / 2 确认提问）
    var level: Int
    /// 去重键（§6）。**存字符串而不是哈希**：调试时能直接肉眼比对，
    /// 且没有碰撞风险，代价只是每条约几十字节
    var normalizedText: String
    var status: QuestionStatus
    var failure: QuestionFailure?
    /// 失败时附的一句人话（§4.6.3 的「上次查询中断」）。
    ///
    /// 为什么另开一个字段：`failure` 是枚举 rawValue，装不下句子；
    /// 而「被改写过的僵尸条目」和「真的模型调用失败」在 `failed(.model)`
    /// 这一格上长得一模一样，界面分不出来。留一个字符串位，是让那句
    /// 解释**有地方落**
    var failureNote: String?
    /// 同一个归一化问题在这节课里被问了几次（默认 1）。主列表只占一行，
    /// 数字不丢（§6.4）
    var askedCount: Int
    /// 是否被元问题表命中（默认 false）。**命中不删除，只改归属**（§7.4）。
    /// 元问题表本身是后面那一包的事，本包只留字段与它的默认值
    var filtered: Bool
    /// nil = 没查过
    var answer: QuestionAnswer?

    init(
        id: UUID = UUID(),
        text: String,
        rawSentence: String,
        startTimeMillis: Int,
        sourceSegmentID: UUID? = nil,
        level: Int,
        status: QuestionStatus = .unasked,
        failure: QuestionFailure? = nil,
        failureNote: String? = nil,
        askedCount: Int = 1,
        filtered: Bool = false,
        answer: QuestionAnswer? = nil
    ) {
        self.id = id
        self.text = text
        self.rawSentence = rawSentence
        self.startTimeMillis = startTimeMillis
        self.sourceSegmentID = sourceSegmentID
        self.level = level
        // 去重键在构造时算：调用方拿不到一个「和 text 对不上」的键。
        // 解码那条路走盘上的值（见 init(from:)），两条路都只此一处
        self.normalizedText = Self.normalizeForDedup(text)
        self.status = status
        self.failure = failure
        self.failureNote = failureNote
        self.askedCount = askedCount
        self.filtered = filtered
        self.answer = answer
    }

    // MARK: - 向后兼容（§4.6.2）

    private enum CodingKeys: String, CodingKey {
        case id, text, rawSentence, startTimeMillis, sourceSegmentID, level
        case normalizedText, status, failure, failureNote, askedCount, filtered, answer
    }

    /// 手写解码，**每个后加字段都有默认值**。任何一条问题坏掉都不该连坐整条会话。
    ///
    /// 只有 `id` / `text` 是硬解：这两个缺了，这条记录连「它是什么」都说不出来，
    /// 该抛出去让外面那层 `LenientElement` 把它单独丢掉（见那边的注释）
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)

        rawSentence = try c.decodeIfPresent(String.self, forKey: .rawSentence) ?? text
        startTimeMillis = try c.decodeIfPresent(Int.self, forKey: .startTimeMillis) ?? 0
        sourceSegmentID = try c.decodeIfPresent(UUID.self, forKey: .sourceSegmentID)
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 0
        // 缺键就现算：老存档没有这个键，而它必须和 text 对得上，
        // 落一个空串会让这节课所有条目互相「相等」
        normalizedText = try c.decodeIfPresent(String.self, forKey: .normalizedText)
            ?? Self.normalizeForDedup(text)
        status = QuestionStatus.of(try c.decodeIfPresent(String.self, forKey: .status))
        failure = QuestionFailure.of(try c.decodeIfPresent(String.self, forKey: .failure))
        failureNote = try c.decodeIfPresent(String.self, forKey: .failureNote)
        askedCount = try c.decodeIfPresent(Int.self, forKey: .askedCount) ?? 1
        filtered = try c.decodeIfPresent(Bool.self, forKey: .filtered) ?? false
        // 答案坏了不该把「老师问过这个」一起带走：整条问题留着，答案当没查过。
        // 界面显示的是一行「待查」，而不是这一行凭空消失
        answer = (try? c.decodeIfPresent(QuestionAnswer.self, forKey: .answer)) ?? nil

        // ── 僵尸「查询中」一律改写（§4.6.3）──
        //
        // App 被杀时不可能有请求还在跑，所以磁盘上读到 `searching` 只可能意味着
        // 「上次查询中断」。保留「查询中」的代价是那行**永远转圈**，而且
        // 按 §5.2 的前置闸门它既等不到结果也不能重查——一个学生无能为力的死状态。
        //
        // **只在解码期改**：写盘时 `.searching` 是一个合法状态（§5.2：
        // 「写 status=searching 并落盘」），改写发生在「读到它」这一侧
        if status == .searching {
            status = .failed
            failure = .model
            failureNote = Self.interruptedNote
        }
    }

    /// 僵尸条目的解释文案（§4.6.3）。界面上与「模型调用失败」共用
    /// `failed(.model)` 这一格，靠 `failureNote` 那句区分
    static let interruptedNote = "上次查询中断"

    // MARK: - 归一化（§6.1 / §6.2）

    /// 去重键的算法：**归一化后完全相等才算同一个问题**（§6.1）。
    ///
    /// 不做模糊匹配、不做相似度阈值。理由不是「省事」：阈值无法验收（没人能说清
    /// 0.82 和 0.83 哪个对），而且它会把「什么是梯度下降」和「什么是梯度消失」
    /// 合并成一条，**把学生已经查过的答案换掉**。
    ///
    /// n1–n6 按顺序执行，每一步都是纯字符串操作：
    /// n1 全角标点折半角 → n2 空白折叠 + 去首尾 → n3 英文字母小写 →
    /// n4 只去**首尾**标点 → n5 去**尾随**语气词 → n6 再去首尾空白。
    /// 每一步「为什么」见下面逐条注释，**顺序不能换**：
    /// n4 必须在 n5 之前（「…下降呢？」要先去掉问号才露得出那个「呢」），
    /// n6 必须在 n5 之后（剥语气词会重新露出空格）。
    ///
    /// 明确不做（§6.2 末）：
    /// - **近义词归一**（「解释一下」→「什么是」）：要语义判断，违背「本地不调模型」；
    /// - **按标点整句切分**：问题本体就是 `coreQuestion` 一整句，切开会把
    ///   「什么是 X，为什么 Y」拆成两个问题，改变学生看到的对象
    static func normalizeForDedup(_ input: String) -> String {
        // ── n1 全角标点折半角 ──
        // 集合与 `QuestionDetector.TextNorm` 一致：不然同节课里
        // 「什么是 X？」和「什么是 X?」会被当成两个问题
        var s = String(input.map { fullWidthToHalfWidth[$0] ?? $0 })

        // ── n2 空白折叠成一个半角空格，再去首尾 ──
        // 先折 U+3000：`\s` 归 ICU 解释时确实覆盖它，但显式折一次不依赖
        // 那个细节，读起来也不用去查 ICU 的类表
        s = s.replacingOccurrences(of: "\u{3000}", with: " ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)

        // ── n3 英文字母转小写 ──
        // 课堂里英文术语大小写不稳定（Machine Learning / machine learning）
        s = s.lowercased()

        // ── n4 只去首尾标点 ──
        // 中文书面问句末尾可省「？」，识别器也不保证带标点。
        // **只去首尾，不去中间**：中间标点承载逻辑连接
        let punctuation: Set<Character> = ["?", ".", "!", ",", ";", ":", "、", "，", "。", "？", "！", "；", "："]
        s = s.trimmingEnds(in: punctuation)

        // ── n5 去尾随语气词 ──
        // 课堂口语几乎必带，问题是同一个。**「吗」不在集合里**：它决定句子
        // 是不是问句（「听懂了吗」vs「听懂了」），去掉会把陈述和疑问混起来
        let tailParticles: Set<Character> = ["呢", "吧", "啊", "呀", "哦", "嘛"]
        while let last = s.last, tailParticles.contains(last) {
            s.removeLast()
        }

        // ── n6 再去首尾空白 ──
        // n5 剥完之后可能又漏出空格（「…下降 呢」）
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// n1 的折叠表。只折标点与引号，**不折字母数字**：全角数字（１２３）
    /// 在课堂转录里几乎不出现，而把它们也折了会给「同一个问题的两种写法」
    /// 多开一扇门
    private static let fullWidthToHalfWidth: [Character: Character] = [
        "？": "?", "！": "!", "，": ",", "。": ".", "：": ":", "；": ";",
        "（": "(", "）": ")", "【": "[", "】": "]",
        "“": "\"", "”": "\"", "‘": "'", "’": "'",
    ]

    // MARK: - 入列去重（§6.3 第 1 条）

    enum EnqueueOutcome: Equatable {
        /// 新条目进列
        case appended
        /// 同 `normalizedText` 的条目已在列：只把 `askedCount` 加一
        case merged(into: UUID)
    }

    /// 入列：同 `normalizedText` → **不新建条目**，`askedCount += 1`。
    ///
    /// 时间与原句**保留最早那次**（§6.3）：主列表按时间排序，学生找
    /// 「老师第一次问这个」比找最后一次有用。所以这里不是无脑保留已有条目——
    /// 而是比一次时间，让「最早」这条规则**不依赖入列顺序**成立
    /// （回填是按片段顺序走的，但重转、并发写入都可能打乱它）。
    ///
    /// 合并时**不动** `status` / `answer` / `filtered` / `id`：那些属于
    /// 「这一行」而不是「这一次提问」，学生已经查过的答案不能因为老师又问了
    /// 一遍就被抹掉
    @discardableResult
    static func enqueue(
        _ candidate: LessonQuestion,
        into questions: inout [LessonQuestion]
    ) -> EnqueueOutcome {
        guard let index = questions.firstIndex(where: { $0.normalizedText == candidate.normalizedText })
        else {
            questions.append(candidate)
            return .appended
        }

        questions[index].askedCount += 1
        if candidate.startTimeMillis < questions[index].startTimeMillis {
            // 后到的这次更早：把它换上去，连同这条最早出现的原句与出处
            questions[index].text = candidate.text
            questions[index].rawSentence = candidate.rawSentence
            questions[index].startTimeMillis = candidate.startTimeMillis
            questions[index].sourceSegmentID = candidate.sourceSegmentID
            questions[index].level = candidate.level
        }
        return .merged(into: questions[index].id)
    }

    /// 列表展示顺序：按时间。**不在入列时排序**（§6.4 是展示层的事）——
    /// 数据层保持「入列顺序」，让上面那条「保留最早」的规则能被单独验证
    static func sortedByTime(_ questions: [LessonQuestion]) -> [LessonQuestion] {
        questions.sorted { $0.startTimeMillis < $1.startTimeMillis }
    }
}

private extension String {
    /// 去掉**首尾**属于集合的字符（中间的不动）。
    ///
    /// 为什么不用 `trimmingCharacters(in:)`：那个收的是 `CharacterSet`，
    /// 而 `CharacterSet` 是按 Unicode 类别组织的——中文标点放进去会连
    /// 类别里同组的一大片一起命中（`QuestionDetector` 那条注释写过同一件事）
    func trimmingEnds(in set: Set<Character>) -> String {
        var s = self
        while let first = s.first, set.contains(first) { s.removeFirst() }
        while let last = s.last, set.contains(last) { s.removeLast() }
        return s
    }
}

// MARK: - 数组元素的宽容解码（§4.6.2）

/// 数组里**一条坏掉的元素不许连坐整条会话**：`[LessonQuestion]` 里有一条
/// 缺 id（或类型不对），不能让整条会话读不出来——那在用户那边表现为
/// 「这节课的录音从列表里消失了」。
///
/// 这个写法成立的前提是 `JSONDecoder` 的 unkeyed container 在元素解码抛错时
/// **索引已经前进**，所以 `try?` 掉一条之后下一条照样解得出。前提是实测来的，
/// 见 `--questions-selftest` 里「坏条目 + 两条好条目」那条判据
struct LenientElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

// MARK: - 按需回填（§4.6.4）

extension RecordingSession {

    /// 旧存档按需回填：对每条 segment 跑一次
    /// `QuestionDetector(sensitivity: 当前设置)`，命中的写进 `questions`，
    /// 并把版本推到当前值。
    ///
    /// **不做事先的全量迁移**：一次性扫全部会话会在启动路径上付解码全量正文的
    /// 代价（那正是 `SessionSummary` 当初存在的原因）。回填发生在
    /// 「打开提问页」那一刻，代价落在学生已经点进去等它的那一次。
    ///
    /// 返回「这次有没有真的跑」——调用方靠它决定要不要落盘。
    /// 版本已达当前值就直接返回 false，**幂等**（重复调用不会翻倍条目）。
    @discardableResult
    mutating func backfillQuestions(sensitivity: QuestionSensitivity) -> Bool {
        // 灵敏度关闭时不回填、也**不盖章**：关了当然一条都测不出来，但把
        // 「一条都没测」记成「已经回填过」，学生下次打开灵敏度时就再也看不到
        // 这些旧录音的问题了（版本门槛会拦住重跑）。宁可每次打开都白跑一遍空转
        guard sensitivity != .off else { return false }
        guard questionSchemaVersion < LessonQuestionSchema.current else { return false }

        let detector = QuestionDetector(sensitivity: sensitivity)
        for part in parts {
            for segment in part.segments {
                guard let hit = detector.detect(segment.text) else { continue }
                let question = LessonQuestion(
                    text: hit.coreQuestion,
                    // 原句就是**转录文本本身**，不是检测器归一化过的那份：
                    // 界面上「原句」要和转录页里那一行逐字对得上
                    rawSentence: segment.text,
                    // 会话时间轴（片段偏移 + 段内偏移）。反向段拿到的是空区间的
                    // 下界，也就是它声明的起点，与 `absoluteRange` 的约定一致
                    startTimeMillis: RecordingSession.absoluteRange(of: segment, in: part).lowerBound,
                    sourceSegmentID: segment.id,
                    level: hit.level
                )
                LessonQuestion.enqueue(question, into: &questions)
            }
        }
        questionSchemaVersion = LessonQuestionSchema.current

        // **不动 `updatedAt`**：回填是打开页面时顺手做的读操作，不是用户对这条
        // 录音的改动。改它会让列表上的「最近更新」变成一句假话
        return true
    }
}
