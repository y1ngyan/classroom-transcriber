import Foundation

/// 提问列表的两个计数口径——**纯函数，不碰磁盘、不碰网络**，好离线自检。
///
/// 为什么要单独抽出来：这两个数直接印在提问页页头上（「N 个问题 · X 个已查 · Y 个待查」），
/// 而口径弄错过一次——当时「已查」只数 `.answered`，于是「有答案 1 / 查不到 1 / 未查 1」
/// 的页面写「1 个已查」，把「查过但没得出可靠答案」和「查失败」都算成了没查。
///
/// 口径定义（与 `QuestionStatus` 的五态一一对应，不留没归属的态）：
/// - 已查 `queried`：`.answered` `.noResults` `.failed` —— 点过查询、系统真的去问了；
/// - 待查 `pending`：`.unasked` `.searching` —— 还没问过 / 正在问；
/// - 两者互斥且穷尽：`queried + pending == 传入列表的条数`。
enum QuestionTally {

    /// 查过的条数。**只看传进来的这批**（调用方传 `mainQuestions`，被元问题表命中的折叠项不计）。
    static func queried(_ list: [LessonQuestion]) -> Int {
        list.reduce(0) { acc, q in acc + (isQueried(q.status) ? 1 : 0) }
    }

    /// 还等着查的条数
    static func pending(_ list: [LessonQuestion]) -> Int {
        list.reduce(0) { acc, q in acc + (isQueried(q.status) ? 0 : 1) }
    }

    static func isQueried(_ status: QuestionStatus) -> Bool {
        switch status {
        case .answered, .noResults, .failed: return true
        case .unasked, .searching: return false
        }
    }
}
