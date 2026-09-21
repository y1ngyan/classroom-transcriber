import Foundation

/// 繁 → 简 转换。
///
/// 为什么需要：Whisper 的中文默认输出繁体（`習近平` 而不是 `习近平`）——
/// 它的中文训练语料里繁体占比高。Apple 那条链路原生给简体，所以这个问题
/// 只在接 Whisper 之后才冒出来。
///
/// **用系统的 ICU 变换，不自己维护映射表。** 这里原先是一张手写的
/// `[Character: Character]` 表（222 条），有两个各自都致命的问题：
///
/// 1. **它会崩。** 字面量里有 32 个重复键（測 / 試 / 設 / 產 / 習 / 業 / 據 …）。
///    Swift 对字典字面量的重复键**只在编译期发 warning**，运行时构造这个
///    字典直接 `SIGTRAP`（实测 `Trace/BPT trap: 5`，退出码 133）。它是
///    `static let`，所以是第一次用到繁简转换就整个崩掉。
/// 2. **逐字表在原理上做不到。** 繁简不是一对一映射，同一个字在不同词里
///    对应不同简体字：「著急」要转「着急」、「乾部」要转「干部」。实测里
///    这两条都出现了，逐字表必然转错。
///
/// 系统这条变换全覆盖、且带上下文规则（实测）：
///
/// ```
///   (開門) 謝謝收看! 請訂閱支持! 統籌高質量發展和高水平安全 … 著急 乾部
///   → (开门) 谢谢收看! 请订阅支持! 统筹高质量发展和高水平安全 … 着急 干部
/// ```
///
/// 用的是 Foundation 底下 ICU 的 `Traditional-Simplified` 变换。两个坑都实测过：
/// - `StringTransform` **没有** `hanTraditionalToSimplified` 这个成员
///   （编译报 `type 'StringTransform' has no member`），必须走 `rawValue:`；
/// - id 只能是 `Traditional-Simplified`，`Any-Traditional-Simplified` 返回 nil。
enum ChineseText {

    /// ICU 变换 id。放成常量而不是每次调用构造，避免热路径上重复建对象
    private static let simplifiedTransform = StringTransform(rawValue: "Traditional-Simplified")

    /// 把一段文本里的繁体转成简体。
    ///
    /// 变换不可用（系统缺这条 ICU 数据）时**原样返回**：宁可留几个繁体字，
    /// 也不要让整段文本变成空串——调用方拿到空串会当成「这段没识别出内容」
    static func toSimplified(_ text: String) -> String {
        text.applyingTransform(simplifiedTransform, reverse: false) ?? text
    }

    /// 这段文本里是否含繁体（自检和排障用）。
    ///
    /// 判据是「转换后变了没有」，不是「有没有命中某张表」——这样它天然
    /// 覆盖整张 ICU 表，不会像手写表那样漏字
    static func looksTraditional(_ text: String) -> Bool {
        !text.isEmpty && toSimplified(text) != text
    }

    /// 系统这条变换是否可用。不可用时 `toSimplified` 会退化成原样返回，
    /// 界面上会看到繁体字——这是需要第一时间知道的状态
    static var isAvailable: Bool {
        toSimplified("開") == "开"
    }
}
