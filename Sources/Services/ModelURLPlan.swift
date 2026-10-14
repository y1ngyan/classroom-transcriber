import Foundation

/// 「这一次去哪个地址取件」的**形状规划**。纯函数：不联网、不碰文件、不改状态。
///
/// 为什么需要它（2026-10-13 实测，记录见 `发现-模型下载URL-404-20261013.md`）：
/// 清单把三个模型都钉在同一个 40 位 commit 上，`ModelPin.url` 由
/// `repo + revision + file` 拼成 `…/resolve/<40位sha>/<file>`。同一个形状
/// 在 2026-09-29 还是 302（那次记录里留着只在 302 上出现的 `x-repo-commit`），
/// 今天对**每一个文件**都是 404——连 `README.md` 也 404，而同 sha 的
/// **12 位前缀**照样 302。所以坏的不是「文件不在这一版」，是镜像解析不了
/// 这一个 commit 的 40 位写法。
///
/// 修法**不是**「以后一律用 12 位」：镜像明天可能又变回去。要的是一条**回落链**：
/// 先按清单钉的全 sha 请求，**只有 404** 才换成同一个 commit 的 12 位前缀再试一次。
/// 换的只是「取件路径」，不是「信任对象」——内容仍由清单的 size + sha256 钉死
/// （见 `ModelFile.validationFailure`），回落成功的那一份也要过同一道校验。
enum ModelURLPlan {

    /// 回落到短 ref 时取多少位。12 位是 git 的惯用缩写长度，也是 2026-10-13
    /// 实测在镜像上能取到件的那一种（同一个 sha、同一个文件）。
    static let fallbackPrefixLength = 12

    // MARK: - 「认不认这个响应」

    /// **只有 404 才回落。**
    ///
    /// 403/401 是鉴权、429 是限流、5xx 是源自己抖动、超时是链路——同一个源对
    /// 同一个对象的态度，不会因为 ref 写短了就改变。对这些换形状只会把一句
    /// 明确的话（「服务器返回 HTTP 429」）拖成三次转圈之后的另一句更远的话。
    /// 而 404 恰恰是「这个 ref 解析不出来」，正是换形状能治的那一种。
    static func shouldFallBack(statusCode: Int) -> Bool {
        statusCode == 404
    }

    // MARK: - 「有哪几种形状」

    /// 清单里那一版的取件形状，**顺序即尝试顺序**。
    ///
    /// 两条形状指向的是**同一个 commit 的同一个文件**：短的那条由
    /// `shortened(pin.revision)` 切出来（见下），不是另一个 ref、更不是 `main`。
    /// 清单里那条 40 位 sha 是来源锚点，一个字符都不动它。
    ///
    /// 形状不止一种时，第一条**永远是调用方给的那个 URL**——清单钉的地址
    /// 保持是「首选」，回落是例外而不是常态。
    static func variants(for pin: ModelPin) -> [URL] {
        variants(url: pin.url, revision: pin.revision)
    }

    /// 核心那一个：给定 URL + 这个 URL 该指向的 revision（清单钉的那一版）。
    ///
    /// `revision` 传 nil = 只有 URL 的那条路（`--model-fetch`，没有清单），
    /// 那时从 URL 路径里 `/resolve/<ref>/` 那一段取 ref——**前缀就是从它自己
    /// 切出来的**，所以两条形状说的是同一个 commit。
    static func variants(url: URL, revision: String?) -> [URL] {
        // 清单钉的值优先：URL 上那一段可能是夹具手工给的，清单才是「这一版是
        // 谁」的权威。reference 为空时退到 URL 自己那一段
        let ref = revision.flatMap { $0.isEmpty ? nil : $0 } ?? resolveRef(of: url) ?? ""
        guard let short = shortened(ref), let shortURL = replacingRef(of: url, with: short) else {
            // ref 本身就 ≤12 位、不是十六进制、或者 URL 里没有 `resolve` 那一段
            // ——那时没有第二种形状可言。**不硬凑**：宁可不回落，也不去改一个
            // 我们不认识的 URL
            return [url]
        }
        return [url, shortURL]
    }

    // MARK: - 给人看的说法

    /// 这一条 URL 用的是哪种取件形状。下载报告里要能读出这个（「静默换源」
    /// 是不可接受的形状——用户得能知道这次是从哪儿取的件）。
    static func shapeLabel(of url: URL) -> String {
        guard let ref = resolveRef(of: url) else {
            return "单一形状（URL 里没有 /resolve/<ref>/ 这一段，没有可回落的东西）"
        }
        if ref.count == fallbackPrefixLength {
            return "\(ref.count) 位 sha 前缀（同一 commit 的缩写）"
        }
        return "\(ref.count) 位 sha"
    }

    // MARK: - 拼装

    /// URL 路径里 `/resolve/<ref>/` 那一段的 ref。形状不对返回 nil
    static func resolveRef(of url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "resolve"), i + 1 < parts.count else { return nil }
        let ref = parts[i + 1]
        return ref.isEmpty ? nil : ref
    }

    /// 短 ref。**只做「截断」，不做别的**：短于等于 12 位就没有第二种形状
    /// （返回 nil，而不是「再换一个 ref」）；非十六进制的 ref 也不碰——
    /// 那种位置上出现的东西不是 commit sha，截它没有意义
    static func shortened(_ ref: String) -> String? {
        guard ref.count > fallbackPrefixLength, ref.allSatisfy(\.isHexDigit) else { return nil }
        return String(ref.prefix(fallbackPrefixLength))
    }

    /// 把 `/resolve/<ref>/` 那一段的 ref 换成 `newRef`。
    ///
    /// **按路径段替换，不做字符串替换**：文件名里可能出现 `resolve` 字样，
    /// 字符串替换会换错地方。形状不对（没有 `resolve` 段、或它后面没有东西）
    /// 时返回 nil——那时宁可不回落，也不去改一个我们不认识的 URL
    static func replacingRef(of url: URL, with newRef: String) -> URL? {
        var parts = url.pathComponents
        guard let i = parts.firstIndex(of: "resolve"), i + 1 < parts.count else { return nil }
        parts[i + 1] = newRef
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // pathComponents 的第一段是 "/"，拼回去时要自己补回开头的斜杠
        components?.path = "/" + parts.dropFirst().joined(separator: "/")
        return components?.url
    }
}

/// 「404 时换不换取件形状」这个策略。
///
/// 默认 **on**：2026-10-13 起镜像对清单那个 commit 的 40 位 sha 一律 404，
/// 关掉就等于这个 App 再也下不了模型。
///
/// 留一个进程级的关法是为了**能证明回落真的在起作用**：探针
/// `tools/probes/model_download_url.sh` 臂②拿同一个 URL 在关掉回落时跑一遍，
/// 必须是**失败**的——「开了才成」这句话需要有对照组，否则「成功」也可能
/// 只是今天镜像恰好又能认 40 位了。
enum URLFallbackPolicy: Equatable, Sendable {
    case on
    case off

    /// `CLASSROOM_MODEL_URL_FALLBACK=0`（也认 off/false/no）关掉
    static let environmentKey = "CLASSROOM_MODEL_URL_FALLBACK"

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URLFallbackPolicy {
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return .on }
        switch raw {
        case "0", "off", "false", "no": return .off
        default: return .on
        }
    }
}
