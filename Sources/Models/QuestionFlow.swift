import Foundation

/// 提问 → 查答案的**纯状态机**（设计稿 §5 / §5.2）。
///
/// 为什么把这套判断从 Store 里抽出来：状态转移是学生能直接看见行为的规则
/// （「查询中不能再点」「有答案再查要先确认」「通道不通和没搜到不是一回事」），
/// 而 Store 会碰网络、碰磁盘，离线自检没法把每一种失败都走一遍。这里只做
/// 输入 → 输出，`--question-flow-selftest` 才能把 5 种状态的允许/禁止转移
/// 逐条钉住。
///
/// **这里不判断「配没配密钥」「会不会重复请求」**：那些是前置闸门
/// （`gate`），转移表只回答「当前状态遇到这个事件，合不合法、去哪」。
enum QuestionFlow {

    // MARK: - 事件

    /// 学生动作 + 查询结果。结果事件只可能在 `searching` 上被接受——
    /// 一个迟到的回调（用户已经重查、页面已经切走）不能把状态改回去
    enum Event: Equatable {
        /// 行内「查答案」
        case ask
        /// 失败 / 没搜到之后的「重试」
        case retry
        /// 有答案之后的「重新查询」——必须经确认
        case requery
        /// 检索到资料且模型给出可用正文
        case succeeded
        /// 检索成功但没有可用结果：一条资料都没搜到，或模型没给出可用答案
        case foundNothing
        /// 检索通道不通（网络 / 密钥）
        case channelFailed
        /// 通道通了，模型这一步失败（超时、额度、返回结构坏）
        case modelFailed
    }

    // MARK: - 转移

    struct Transition: Equatable {
        /// 这次事件合法吗
        var allowed: Bool
        /// 合法但必须二次确认（会覆盖已有答案）
        var requiresConfirmation: Bool
        /// nil = 状态不变
        var nextStatus: QuestionStatus?
        var nextFailure: QuestionFailure?
    }

    /// 转移表（§5.2）。**逐条实现，不做「差不多」的合并**：
    ///
    /// | 起点 | 事件 | 终点 |
    /// |---|---|---|
    /// | 任意非 searching | ask / retry / requery | searching（answered 时需确认） |
    /// | searching | succeeded | answered |
    /// | searching | foundNothing | noResults |
    /// | searching | channelFailed | failed(.channel) |
    /// | searching | modelFailed | failed(.model) |
    /// | searching | ask / retry / requery | 不变（忽略点击） |
    /// | 任意非 searching | 结果事件 | 不变（迟到的回调） |
    static func decide(current: QuestionStatus, event: Event) -> Transition {
        switch event {
        case .ask, .retry, .requery:
            guard current != .searching else {
                return Transition(allowed: false, requiresConfirmation: false,
                                  nextStatus: nil, nextFailure: nil)
            }
            // §5.1 两条回边的唯一区别：有没有学生见过的答案。有就必须确认，
            // 因为没有它重试会**静默**把旧答案和来源换掉（拍板第 4 条）
            return Transition(
                allowed: true,
                requiresConfirmation: current == .answered,
                nextStatus: .searching,
                nextFailure: nil
            )

        case .succeeded, .foundNothing, .channelFailed, .modelFailed:
            guard current == .searching else {
                return Transition(allowed: false, requiresConfirmation: false,
                                  nextStatus: nil, nextFailure: nil)
            }
            switch event {
            case .succeeded:
                return Transition(allowed: true, requiresConfirmation: false,
                                  nextStatus: .answered, nextFailure: nil)
            case .foundNothing:
                return Transition(allowed: true, requiresConfirmation: false,
                                  nextStatus: .noResults, nextFailure: nil)
            case .channelFailed:
                return Transition(allowed: true, requiresConfirmation: false,
                                  nextStatus: .failed, nextFailure: .channel)
            case .modelFailed:
                return Transition(allowed: true, requiresConfirmation: false,
                                  nextStatus: .failed, nextFailure: .model)
            case .ask, .retry, .requery:
                preconditionFailure("外层 switch 已经排除了这三个事件")
            }
        }
    }

    /// 「这次点击会不会覆盖学生已经看过的东西」。
    ///
    /// 判据是 **`status == .answered`**，不是 `answer != nil`：`noResults`
    /// 在「搜到了资料但模型没给出可用答案」时也留一份只含来源的
    /// `QuestionAnswer`（§2.3 要求把来源列出来），那不是学生见过的答案，
    /// 重试它不需要确认。
    static func owesConfirmation(_ status: QuestionStatus) -> Bool {
        status == .answered
    }

    // MARK: - 前置闸门（§6.5）

    enum Gate: Equatable {
        case proceed
        /// 同节课内同 `normalizedText` 的条目已经有答案：直接抄一份，不联网
        case copyAnswer(from: UUID)
        case blocked(Block)
    }

    enum Block: Equatable {
        /// 这一行已经在查
        case alreadySearching
        /// §6.5 第 3 条：元问题折叠区里的条目不显示查询入口，这里是防御
        case filtered
        /// 搜索或 DeepSeek 密钥缺一个（拍板第 9 条：列表照常显示，入口禁用）
        case notConfigured
        /// 同节课内同文本的另一条正在查：忽略这次点击，防止并发打两次
        case duplicateSearching
    }

    /// 点「查答案」时**按 §6.5 的顺序**判定，顺序不能换：
    /// 先挡掉已经在查的，再挡配置缺失（不弹新窗口），再挡元问题，
    /// 最后才看「同文本是不是已经有答案」。
    ///
    /// - Parameters:
    ///   - duplicateAnswerID: 同节课内同 `normalizedText` 且已 `answered`
    ///     的另一条（没有就是 nil）
    ///   - duplicateSearching: 同节课内同 `normalizedText` 的另一条正在查
    ///   - hasAnswer: 本条自己是不是已经有答案
    static func gate(status: QuestionStatus,
                     filtered: Bool,
                     isConfigured: Bool,
                     hasAnswer: Bool,
                     duplicateAnswerID: UUID?,
                     duplicateSearching: Bool) -> Gate {
        if status == .searching { return .blocked(.alreadySearching) }
        if !isConfigured { return .blocked(.notConfigured) }
        if filtered { return .blocked(.filtered) }
        if !hasAnswer, let duplicateAnswerID {
            return .copyAnswer(from: duplicateAnswerID)
        }
        if duplicateSearching { return .blocked(.duplicateSearching) }
        return .proceed
    }

    // MARK: - 文案

    /// 二次确认的正文（拍板第 4 条）。**必须原样出现「旧的答案和来源会被替换」**：
    /// 这是用户在拍板时点名要写的句子，自检直接断言这个子串
    static let overwriteConfirmation = "重新查询会覆盖已有答案，旧的答案和来源会被替换。"

    /// 通道不通。**沿用 `SuggestionError.searchUnavailable` 的措辞，不新造**
    /// （§8.1）。括号里的「不是没搜到」是 B 的硬要求，别删
    static let channelMessage = "检索通道不通——检查网络或搜索密钥（不是没搜到）"
    /// 一条资料都没搜到。沿用 `SuggestionError.noSearchResults` 的既有措辞
    static let emptyMessage = "联网没搜到可用内容，换个说法或稍后再试"
    /// 搜到了资料，但模型没给出可用正文。**不能复用上面两句**：
    /// 学生从这里该做的是「点来源自己看」，不是换说法，也不是查网络
    static let modelEmptyMessage = "网上有资料，但没能得出可靠答案"
    /// 模型这一步失败（超时 / 额度 / 返回结构坏）。和通道不通分开：
    /// 前者修网络或密钥，后者只能稍后再试
    static let modelFailedMessage = "模型这一步没成功（超时、额度或返回异常），稍后再试试"

    /// 失败行上那句人话。`failureNote`（「上次查询中断」）优先：
    /// 它比归类更具体，而归类只用来决定「重试哪一种」
    static func failureMessage(_ failure: QuestionFailure?, note: String?) -> String {
        if let note, !note.isEmpty { return note }
        switch failure {
        case .channel: return channelMessage
        case .model: return modelFailedMessage
        case .empty: return modelEmptyMessage
        case nil: return modelFailedMessage
        }
    }

    /// `noResults` 行上那句人话。**要区分「没搜到资料」和「有资料没答案」**：
    /// 两者状态相同（§4.4 把它们归成一档，因为都不是 `failed`），但学生
    /// 该做的事不同（换说法 vs 点来源自己看）
    static func noResultsMessage(hasSources: Bool) -> String {
        hasSources ? modelEmptyMessage : emptyMessage
    }
}
