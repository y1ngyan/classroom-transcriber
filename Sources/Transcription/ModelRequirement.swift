import Foundation

/// 模型在不在、够不够大。一个**快照**，不是查询——`decide` 因此是纯函数，
/// 可以在没有文件系统的自检里随便构造边界值。
struct ModelAvailability: Equatable, Sendable {
    /// 用户/程序看到的那个路径。被拦住时要原样报给用户，
    /// 否则「模型放哪儿」只能靠猜
    var path: String
    var exists: Bool
    /// 存在时的大小。取不到就是 nil
    var sizeBytes: Int64?
    /// 合格下界，来自 `WhisperEngine.expectedModelBytes`
    var minimumBytes: Int64

    var sizeDescription: String {
        guard let sizeBytes else { return "大小未知" }
        return Self.mbText(sizeBytes)
    }

    var minimumDescription: String { Self.mbText(minimumBytes) }

    /// 小于 100MB 时保留一位小数；**不到 1MB 就换 KB**。
    ///
    /// 不是洁癖：`%.0f` 会把 200KB 印成「0 MB」，而这句话是要念给用户听的
    /// ——「不到 0 MB」等于没说。自检的夹具用几百 KB，正好落在这一档上，
    /// 第一次跑就被这条抓出来了（判据原本写死成真模型的「500」，红了）。
    ///
    /// KB 那一档是**同一类问题再往下一层**：留着一位小数的 MB 也只是把
    /// 「0 MB」变成「0.0 MB」。屏幕上唯一会出现真·KB 级残文件的地方就是
    /// 这里（用户手动放了个 12KB 的碎屑在模型目录里），而那时最该说清楚
    /// 的就是「它到底多小」
    /// 1KB 以下再补一档字节数——`%.0f` 会把 9 字节印成「0 KB」，那是
    /// **文件非空却说成零**，比「0.0 MB」更难看出来（见 `ModelCache.byteText`）
    /// 内部（不是 private）：重转那条路的拦截文案也要用它，而两处各写一份
    /// 「怎么把字节数说成人话」迟早会漂移成两种说法
    static func mbText(_ bytes: Int64) -> String {
        if bytes < 1_000 { return "\(bytes) 字节" }
        if bytes < 1_000_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        let mb = Double(bytes) / 1_000_000
        return mb >= 100 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
    }

    /// 从磁盘现读一份。**只读 metadata**，不把 514MB 读进内存
    static func probe(at url: URL, minimumBytes: Int64) -> ModelAvailability {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int64
        return ModelAvailability(
            path: url.path,
            exists: attributes != nil,
            sizeBytes: size,
            minimumBytes: minimumBytes
        )
    }
}

/// 「这一次录音到底走哪条后端」的裁决。
///
/// 之所以**从起录路径里抽出来做成纯函数**：这条规则是 P7-1 里最硬的一条
/// （缺模型时不许静默降级），而它原本埋在 `TranscriptionEngine.startWhisper()`
/// 的一个 `guard` 里——那条路径要麦克风、要权限、要 GUI，核验根本够不着。
/// 抽成纯函数之后，「Whisper + 模型缺失 → 拦住」这句话可以在无头自检里
/// 直接断言，包括断言**它没有变成 `.apple`**。
enum BackendDecision: Equatable, Sendable {
    /// 走系统识别。**模型在不在和这条路无关**——这是正常路径，不是错误
    case apple
    /// 走 Whisper 本地，模型在位
    case whisper(modelPath: String)
    /// 拦住。`reason` 是给人看的完整文案（多行），必须含
    /// 路径 / 期望大小 / 下载入口三件事
    case blocked(reason: String)

    /// 界面上那一行状态用的摘要（第一行）
    var summary: String? {
        guard case .blocked(let reason) = self else { return nil }
        return reason.split(separator: "\n").first.map(String.init)
    }

    /// 这次实际会用的后端。被拦住时是 nil——**不是 `.apple`**，
    /// 别让「没跑起来」被读成「跑了 Apple」
    var effectiveBackend: TranscriptionBackend? {
        switch self {
        case .apple: return .apple
        case .whisper: return .whisper
        case .blocked: return nil
        }
    }
}

enum ModelRequirement {

    /// 裁决。**纯函数**，不看表、不碰磁盘。
    ///
    /// - Parameter downloadEntry: 下载入口的描述（界面上从哪儿点、或网址）
    static func decide(
        backend: TranscriptionBackend,
        model: ModelAvailability,
        downloadEntry: String
    ) -> BackendDecision {

        // 后端是 Apple：模型在不在**都不影响这次录音**。不报错、不提示、
        // 不「顺手检查一下」——把一条与本次无关的信息塞进状态行，只会让
        // 真正的错误更难被看见
        guard backend == .whisper else { return .apple }

        guard model.exists else {
            return .blocked(reason: blockMessage(model: model, downloadEntry: downloadEntry,
                                                 why: "模型文件不在"))
        }

        // 在位但明显不是一份完整模型（多半是上次下了一半的残file）。
        // 这里拦下的理由和「不在」是同一个：whisper 的 `init` 对残文件
        // 会直接失败，而用户看到的现象是一样的——录完一整节课、一个字没有
        if let size = model.sizeBytes, size < model.minimumBytes {
            return .blocked(reason: blockMessage(
                model: model, downloadEntry: downloadEntry,
                why: "模型文件存在但只有 \(model.sizeDescription)，不到 \(model.minimumDescription)"
            ))
        }

        return .whisper(modelPath: model.path)
    }

    private static func blockMessage(model: ModelAvailability, downloadEntry: String, why: String) -> String {
        """
        ❌ 后端设为「Whisper 本地」，但\(why)——本次不会改用系统识别
           模型位置：\(model.path)
           期望大小：≥ \(model.minimumDescription)（完整模型约 514 MB）
           去下载：\(downloadEntry)
        """
    }

    /// 界面/自检里用的那句「下载入口」描述。**只写一处**：文案和真实入口
    /// 分家之后一定会有一边过期
    static var downloadEntryDescription: String {
        "「设置 › 音频」里的「下载模型」，或直接取 \(WhisperEngine.modelURL)"
    }
}

extension TranscriptionBackend {

    /// 后端 + 模型现状 → 裁决。给界面和起录路径共用的那一个入口
    static func decide(
        backend: TranscriptionBackend,
        modelURL: URL = WhisperEngine.resolvedModelURL
    ) -> BackendDecision {
        ModelRequirement.decide(
            backend: backend,
            model: .probe(at: modelURL, minimumBytes: WhisperEngine.expectedModelBytes),
            downloadEntry: ModelRequirement.downloadEntryDescription
        )
    }
}
