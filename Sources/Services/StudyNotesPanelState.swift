import Foundation

/// 一次生成跑到第几片了。
///
/// **只有 `StudyNotesService.generate` 知道分片结构**，所以进度从那里往回报，
/// 而不是让界面自己按时间猜——猜出来的「大约还有 30 秒」既不准又不可自检。
/// `startedAt` 存的是起点而不是「已用秒数」：秒数是要给用户看的那一刻才算的，
/// 存成字段就得有人不停去更新它，而更新它的那段代码本身就是个会停摆的钟
struct StudyNotesProgress: Equatable, Sendable {
    var sliceIndex: Int
    var sliceCount: Int
    var startedAt: Date

    func elapsed(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// 界面上那一行。片号是 1 起的（「第 1 片」比「第 0 片」像人话）。
    ///
    /// `sliceCount == 0` 是真实存在的一小段：`generate` 报第一片之前要先分片、
    /// 算字符数、建锚点索引。那段时间里显示「第 0/0 片」比不显示更像出了故障，
    /// 所以单独一档文案
    func label(now: Date = Date()) -> String {
        let seconds = Int(elapsed(now: now))
        guard sliceCount > 0 else { return "正在生成：准备中 · 已用 \(seconds) 秒" }
        return "正在生成：第 \(sliceIndex)/\(sliceCount) 片 · 已用 \(seconds) 秒"
    }
}

/// 详情页那条「课后笔记」区块该显示哪一档。
///
/// **为什么抽成纯函数**：这五档的判断原来会自然长在 View 的 `if/else` 里，
/// 而 View 是唯一没法离线自检的地方——`--study-notes-ui-selftest` 碰不到它。
/// 判断一旦散进 View，「生成中该显示什么」就变成了只能靠肉眼在真机上确认的事。
/// 这里只做「输入 → 档位」的映射，不碰界面、不读全局状态
struct StudyNotesPanelState: Equatable {

    enum Phase: Equatable {
        /// 没有 API key，而且还没有笔记可看
        case needsKey
        /// 没笔记、没在生成、上次也没失败
        case empty
        /// 正在生成
        case generating
        /// 有笔记可看
        case ready
        /// 上次生成失败
        case failed(message: String)
    }

    var phase: Phase

    /// 生成/重新生成按钮为什么点不动。`nil` = 能点。
    ///
    /// **只要禁用了就必须有原因**，不许出现「灰着但一个字不说」——
    /// 那正是用户 2026-09-24 报的「点导出没反应」的形状（见 `NotesStore.
    /// exportDisabledReason` 的注释）。自检里有一条专门钉「禁用原因不能是空串」
    var generateDisabledReason: String?

    /// 已有的笔记还显不显示。
    ///
    /// **语义选择（派单书要求先说清）**：生成中和失败时，旧笔记**继续显示**。
    /// 理由：笔记是「重新生成」这个词指向的那份已有产出，重跑没成功之前把它
    /// 从界面上拿掉，用户看到的就是「我点了一下，东西没了」——而磁盘上它还在。
    /// 显示新旧两份不冲突：进度/错误在标题区，笔记正文在下面
    var showsExistingNotes: Bool

    var canGenerate: Bool { generateDisabledReason == nil }

    /// 输入 → 档位。**优先级是这里唯一的实质内容**，逐条都有理由：
    ///
    /// 1. **生成中最高**：这一瞬间有一个确定的动作在跑，进度是用户最需要知道的事，
    ///    压过「上次失败了」——上次的错误在重跑成功的瞬间就过期了；
    /// 2. **失败压过有笔记**：否则失败了界面一切照旧，用户以为重跑成功、
    ///    看的还是旧内容（旧笔记仍在下面显示，见 `showsExistingNotes`）；
    /// 3. **有笔记压过没 key**：笔记已经生成了，读它和导出它都不需要 key。
    ///    没 key 只是「不能再生成一份」，不该连看都不让看
    init(notes: StudyNotes?, progress: StudyNotesProgress?, error: String?, hasKey: Bool) {
        let hasExistingNotes = notes != nil

        // 只看「在不在跑」，不看跑的值：`StudyNotesProgress` 是给界面读的，
        // 档位判断只需要知道有这么一回事。写成 `if let` 会引入一个用不到的绑定，
        // 编译器那条 no-usage 告警就是基线之外多出来的东西
        if progress != nil {
            phase = .generating
            showsExistingNotes = hasExistingNotes
        } else if let error {
            phase = .failed(message: error)
            showsExistingNotes = hasExistingNotes
        } else if hasExistingNotes {
            phase = .ready
            showsExistingNotes = true
        } else if !hasKey {
            phase = .needsKey
            showsExistingNotes = false
        } else {
            phase = .empty
            showsExistingNotes = false
        }

        // key 排在「正在生成」前面：没有 key 是**恒久**的障碍，而「正在生成」
        // 是暂时的。两者同时出现时（用户在跑的过程中把配置删了），
        // 说「正在生成」会把真正要用户动手的那件事盖掉
        if !hasKey {
            generateDisabledReason = StudyNotesPanelState.missingKeyReason
        } else if phase == .generating {
            generateDisabledReason = "正在生成，等这一轮跑完再试"
        } else {
            generateDisabledReason = nil
        }
    }

    /// 没有 key 时那一行说明。**写清楚去哪儿配**，不是只说「不可用」——
    /// 用户看到的应该是下一步动作，不是一句状态
    static let missingKeyReason =
        "没有配置 DeepSeek 密钥，无法生成课后笔记。到「设置」里填入密钥后回来重试"

    /// 笔记正文那块 `MarkdownWebView` 要多高。
    ///
    /// 为什么必须有这个数：`WKWebView` 不会自己把高度报上来，而它被放在详情页
    /// 那个已经有 `ScrollView` 的页面里——不给固定高度就是 0 高，用户看到一片
    /// 空白，然后以为「生成失败了」。按条数估一个够用的高度，比测动态高度稳：
    /// 测出来的高度会在图片/表格加载完后再变一次，页面会跳
    ///
    /// 上下限是刻意的：太少会截断，太多会让一堂只有 3 条笔记的课留一大片空白
    static func notesViewportHeight(itemCount: Int) -> Double {
        let perItem = 46.0
        let chrome = 120.0
        return min(560, max(180, chrome + perItem * Double(max(0, itemCount))))
    }
}

// MARK: - 离线自检

extension StudyNotesPanelState {

    struct SelfTestResult {
        var lines: [String] = []
        var passed = 0
        var failed = 0
    }

    /// `--study-notes-ui-selftest`。
    ///
    /// **离线**：不联网、不花钱、不加载模型、不碰音频、不发声——这里测的是
    /// 「输入 → 该显示哪一档」的映射，一次模型调用都不该发生
    static func selfTest() -> SelfTestResult {
        var r = SelfTestResult()
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { r.passed += 1; r.lines.append("  ✅ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
            else { r.failed += 1; r.lines.append("  ❌ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
        }

        let sessionID = UUID()
        let notes = StudyNotes(
            sessionID: sessionID,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            model: "stub",
            items: [
                StudyItem(
                    kind: .summary,
                    text: "本节讲了梯度下降",
                    anchors: [Anchor(partID: UUID(), segmentID: UUID(), startMillis: 8_000)]
                )
            ],
            usage: nil
        )
        let progress = StudyNotesProgress(sliceIndex: 2, sliceCount: 7, startedAt: Date())

        // ① 四档各一例
        let empty = StudyNotesPanelState(notes: nil, progress: nil, error: nil, hasKey: true)
        check(empty.phase == .empty, "没笔记：显示「生成课后笔记」那一档", "\(empty.phase)")
        check(empty.canGenerate, "没笔记：按钮能点")
        check(!empty.showsExistingNotes, "没笔记：没有旧笔记可显示")

        let generating = StudyNotesPanelState(notes: nil, progress: progress, error: nil, hasKey: true)
        check(generating.phase == .generating, "生成中：显示进度那一档", "\(generating.phase)")
        check(generating.generateDisabledReason != nil, "生成中：按钮禁用",
              generating.generateDisabledReason ?? "（居然是 nil）")

        let ready = StudyNotesPanelState(notes: notes, progress: nil, error: nil, hasKey: true)
        check(ready.phase == .ready, "有笔记：显示笔记那一档", "\(ready.phase)")
        check(ready.showsExistingNotes, "有笔记：正文要显示")
        check(ready.canGenerate, "有笔记：还能重新生成")

        let failed = StudyNotesPanelState(notes: nil, progress: nil, error: "模型返回的 1 片全都不是合法 JSON", hasKey: true)
        check(failed.phase == .failed(message: "模型返回的 1 片全都不是合法 JSON"),
              "失败：显示错误那一档", "\(failed.phase)")
        check(failed.canGenerate, "失败：还能重试")

        // ② 无 key：禁用 + **必须给原因**
        let noKey = StudyNotesPanelState(notes: nil, progress: nil, error: nil, hasKey: false)
        check(noKey.phase == .needsKey, "无 key：单独一档，不是「没笔记」", "\(noKey.phase)")
        check(noKey.generateDisabledReason == missingKeyReason, "无 key：禁用",
              noKey.generateDisabledReason ?? "（居然是 nil）")
        check(!noKey.canGenerate, "无 key：按钮点不动")
        check((noKey.generateDisabledReason ?? "").contains("设置"),
              "无 key：说清去哪儿配，不是只说「不可用」", noKey.generateDisabledReason ?? "")

        // ③ 边界：生成中**且有旧笔记**——派单书要求先说清语义再断言。
        // 选的是：进度那一档（不是「有笔记」），且旧笔记继续显示
        let regenerating = StudyNotesPanelState(notes: notes, progress: progress, error: nil, hasKey: true)
        check(regenerating.phase == .generating,
              "边界·生成中且有旧笔记：显示进度，不是「有笔记」", "\(regenerating.phase)")
        check(regenerating.showsExistingNotes,
              "边界·生成中且有旧笔记：旧笔记继续显示（重跑没成功前不该把它拿走）")
        check(regenerating.generateDisabledReason != nil,
              "边界·生成中且有旧笔记：按钮禁用，不许并发跑第二次")

        // ④ 边界：失败**且有旧笔记**——同一条语义的另一半
        let failedWithOld = StudyNotesPanelState(
            notes: notes, progress: nil, error: "HTTP 500", hasKey: true
        )
        check(failedWithOld.phase == .failed(message: "HTTP 500"),
              "边界·失败且有旧笔记：错误要看得见，不能被旧笔记盖掉", "\(failedWithOld.phase)")
        check(failedWithOld.showsExistingNotes,
              "边界·失败且有旧笔记：旧笔记继续显示（重跑失败不等于产出没了）")

        // ⑤ 无 key **但有旧笔记**：读和导出都不需要 key，不该连看都不让看
        let noKeyWithOld = StudyNotesPanelState(notes: notes, progress: nil, error: nil, hasKey: false)
        check(noKeyWithOld.phase == .ready,
              "边界·无 key 但有旧笔记：仍然显示笔记（优先级：有笔记 > 没 key）", "\(noKeyWithOld.phase)")
        check(noKeyWithOld.showsExistingNotes, "边界·无 key 但有旧笔记：正文显示")
        check(!noKeyWithOld.canGenerate, "边界·无 key 但有旧笔记：重新生成仍然点不动")
        check(noKeyWithOld.generateDisabledReason == missingKeyReason,
              "边界·无 key 但有旧笔记：禁用原因还是密钥那条", noKeyWithOld.generateDisabledReason ?? "")

        // ⑥ 「禁用必须带原因」这条是个**不变量**，对全部输入成立。
        // 单点断言只能证明那几个点，这条扫一遍组合
        var silentDisables: [String] = []
        for hasNotes in [true, false] {
            for hasProgress in [true, false] {
                for hasError in [true, false] {
                    for hasKey in [true, false] {
                        let state = StudyNotesPanelState(
                            notes: hasNotes ? notes : nil,
                            progress: hasProgress ? progress : nil,
                            error: hasError ? "失败" : nil,
                            hasKey: hasKey
                        )
                        if !state.canGenerate, (state.generateDisabledReason ?? "").isEmpty {
                            silentDisables.append("notes=\(hasNotes) progress=\(hasProgress) error=\(hasError) key=\(hasKey)")
                        }
                    }
                }
            }
        }
        check(silentDisables.isEmpty,
              "不变量：16 种输入组合里没有一种「禁用了却不说为什么」",
              silentDisables.isEmpty ? "16 种组合全扫过" : silentDisables.joined(separator: " / "))

        // ⑦ 进度文案：片号是 1 起的，秒数是按传入的 now 算的
        let stamped = StudyNotesProgress(
            sliceIndex: 2, sliceCount: 7,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let label = stamped.label(now: Date(timeIntervalSince1970: 1_012))
        check(label.contains("第 2/7 片"), "进度文案：第几片/共几片", label)
        check(label.contains("12 秒"), "进度文案：已用时按 now 算，不是存下来的", label)

        // 还没分完片的那一小段：显示「第 0/0 片」比不显示更像出了故障
        let preparing = StudyNotesProgress(
            sliceIndex: 0, sliceCount: 0,
            startedAt: Date(timeIntervalSince1970: 1_000)
        ).label(now: Date(timeIntervalSince1970: 1_003))
        check(!preparing.contains("0/0") && preparing.contains("准备中"),
              "进度文案：还没分完片时不显示「第 0/0 片」", preparing)

        // ⑧ 正文视口高度：足够高才看得见，又不是无限高
        check(notesViewportHeight(itemCount: 0) >= 180,
              "正文高度：0 条也有下限，不会是 0 高的一片空白",
              "\(notesViewportHeight(itemCount: 0))")
        check(notesViewportHeight(itemCount: 28) > notesViewportHeight(itemCount: 3),
              "正文高度：条数多了要更高",
              "3 条 \(notesViewportHeight(itemCount: 3)) / 28 条 \(notesViewportHeight(itemCount: 28))")
        check(notesViewportHeight(itemCount: 100_000) <= 560,
              "正文高度：有条数上限，不会把整页撑开",
              "\(notesViewportHeight(itemCount: 100_000))")

        return r
    }
}
