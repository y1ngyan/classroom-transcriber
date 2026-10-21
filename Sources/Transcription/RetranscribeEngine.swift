import Foundation

/// 课后重转用哪个模型。**实时链路不走这里**——实时固定 medium
/// （见 `TranscriptionBackend` 的注释：Whisper 那条链路要贴着实时线跑，
/// large 的 0.49× 会把画面越拖越远）。
///
/// 用户拍板（P11-1 派单「用户拍板 1a」）：**课后重转默认 large-v3，实时仍 medium**。
/// 依据是同音频 A/B（`~/ClassroomTranscriber-design/模型AB实测-medium-vs-large.md`）：
/// 同一段 90 秒课堂录音，medium 覆盖率 85.9%、被幻觉过滤器丢掉 14 段；
/// large-v3 覆盖率 100%、字数 +38%、只丢 2 段。
///
/// **这是个可枚举的两档，不是自由字符串**：模型文件名、清单条目、预计时长倍率
/// 三件事必须一起走，写成字符串的话它们会在某次改动里分家（比如名字改了、
/// 倍率没改），而那种分家不报任何错。
enum RetranscribeEngine: String, CaseIterable, Identifiable, Sendable {
    case large
    case medium

    var id: String { rawValue }

    /// **默认档。** 只有一处写死，界面和入口都读它
    static let preferred: RetranscribeEngine = .large

    var fileName: String {
        switch self {
        case .large: return "ggml-large-v3-q5_0.bin"
        case .medium: return "ggml-medium-q5_0.bin"
        }
    }

    var label: String {
        switch self {
        case .large: return "large-v3（准，慢）"
        case .medium: return "medium（快，实时链路用的那个）"
        }
    }

    /// 实测倍率：**音频秒 ÷ 墙钟秒**（不是「实时倍率 × 时长」，方向别搞反）。
    ///
    /// 出处：`~/ClassroomTranscriber-design/模型AB实测-medium-vs-large.md`
    /// （2026-09-30，Hermes，同一段 90 秒课堂录音、滑窗 10 秒 / 步长 3 秒）：
    ///
    /// ```
    ///   medium  单窗耗时 均 3.38 秒 → 步长 3 秒 ÷ 3.38 秒 = 0.89×
    ///   large   单窗耗时 均 6.08 秒 → 步长 3 秒 ÷ 6.08 秒 = 0.49×
    /// ```
    ///
    /// **它为什么是一个常量而不是现测**：现测等于「先跑一遍再告诉你还要跑多久」，
    /// 而这句话的用处恰恰是在跑之前。代价说清楚——这是**一段 90 秒录音的中位数**
    /// 推出来的，课堂量级上会偏乐观（首窗 Metal 编译、内存压力都没进去），
    /// 所以界面上的措辞是「预计约」而不是「将耗时」。同一份记录里还有一条更硬的
    /// 实测：122.7 分钟拼接输入跑出了 1.02 倍实时（≈0.98×），和这里的 0.89× 同量级。
    ///
    /// ⚠️ 这两个数是**按 3 秒步长量的**（倍率的定义是「单窗耗时 ÷ 步长」）。
    /// P12-2 试过把步长压到 9.6 秒，那一版里它们会偏悲观约 3.2 倍；但那一版
    /// **没上生产**（压重叠会丢内容，见 `WhisperWindowPipeline.stepSeconds`），
    /// 所以生产仍是 3 秒步长，这两个数照旧描述当前管线。真要改步长，这两行
    /// 和那条钉住倍率的自检要一起重测
    var realtimeRate: Double {
        switch self {
        case .large: return 0.49
        case .medium: return 0.89
        }
    }

    /// 这段音频预计要跑多久（秒）。纯函数，自检直接喂边界值
    func estimatedSeconds(audioSeconds: Double) -> Double {
        guard audioSeconds > 0, realtimeRate > 0 else { return 0 }
        return audioSeconds / realtimeRate
    }

    /// 给人看的那句话（确认框、入口输出都用它）。**不许写成确定值**——
    /// 见 `realtimeRate` 里那段「代价说清楚」
    func estimatedText(audioSeconds: Double) -> String {
        guard audioSeconds > 0 else { return "时长未知" }
        let seconds = estimatedSeconds(audioSeconds: audioSeconds)
        let audioText = Self.clockText(audioSeconds)
        let estimate = seconds < 60
            ? String(format: "%.0f 秒", seconds)
            : (seconds < 3600
               ? String(format: "%.0f 分钟", seconds / 60)
               : String(format: "%.1f 小时", seconds / 3600))
        return "音频 \(audioText) · 预计约 \(estimate)（实测倍率 \(String(format: "%.2f", realtimeRate))×，见模型AB实测）"
    }

    private static func clockText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// 解析命令行/配置里的档位。**认不出来返回 nil，不猜**：
    /// 猜一个的结果是「用户以为跑的是 large，其实是 medium」——
    /// 这条包最忌讳的那类谎（见 `RetranscribeRequirement`）
    static func parse(_ raw: String?) -> RetranscribeEngine? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.isEmpty { return nil }
        // `large-v3` / `large_v3` 也认——它们是同一个档，写全名的人不少
        switch normalized {
        case "large", "large-v3", "large_v3": return .large
        case "medium": return .medium
        default: return nil
        }
    }
}

/// 这次重转到底能不能跑。**纯函数**（不看表、不碰磁盘），所以「缺模型 → 拦住
/// 且不许回落」这句话可以在无头自检里直接断言——
/// 和 P7-1 的 `BackendDecision` 同一个理由：要拦住的那条路径平时够不着。
enum RetranscribeDecision: Equatable, Sendable {
    /// 可以跑。三个数都要带着：它们就是「实际用的是哪个模型」这条判据的内容，
    /// 而且**每次都要现读磁盘**（`model.bytes` 来自当下这次 stat），
    /// 不是从配置里抄一个名字
    case ready(modelPath: String, bytes: Int64, revision: String)
    /// 拦住。`reason` 是给人看的完整文案（多行）：
    /// 路径 / 期望大小 / 怎么补，三件事缺一不可
    case blocked(reason: String)
}

enum RetranscribeRequirement {

    /// 裁决。
    ///
    /// - Parameters:
    ///   - model: 磁盘现状快照（`ModelAvailability.probe`）
    ///   - pin: 清单里钉的那一条。nil = 清单里没有这个文件（清单本身读不出来时
    ///     调用方自己报警，不归这里管）
    static func decide(
        engine: RetranscribeEngine,
        model: ModelAvailability,
        pin: ModelPin?
    ) -> RetranscribeDecision {
        guard let pin else {
            return .blocked(reason: blockMessage(
                engine: engine, model: model, pin: nil,
                why: "模型清单里没有这一条（清单只认它钉住的文件）"
            ))
        }

        guard model.exists else {
            return .blocked(reason: blockMessage(
                engine: engine, model: model, pin: pin, why: "模型文件不在"
            ))
        }

        // 比清单钉的字节数，**不是**比一个「差不多大」的门槛。
        //
        // 两个失败模式都要拦，而门槛只拦得住一个：
        //   · 下了一半的残file（1.08GB 只到 500MB）——门槛拦得住；
        //   · **文件名写着 large、内容其实是 medium**（539MB）——门槛拦不住，
        //     而它恰恰是本包最该拦的那一个：「你以为是 large 转的」。
        // 清单里的 size 是**那个 revision 下的真值**（P7-1 立的规矩），
        // 拿它比是这里能拿到的最强判据。
        //
        // 刻意**不比 sha256**：那是 1GB 的读盘（几秒），而下载器在下载时已经
        // 按 sha256 校验过一遍（`ModelDownloader` 的 pin 参数）。这里再算一遍
        // 换不到新的保障，只是把每次重转都拖慢几秒。所以本地文件被人在下载之后
        // 手改过这种情况，这一层认不出来——这正是 `ready` 要把实际字节数
        // 报给用户的原因（那行数字对不上时，人自己看得出来）
        if let size = model.sizeBytes, size < pin.size {
            return .blocked(reason: blockMessage(
                engine: engine, model: model, pin: pin,
                why: "模型文件存在但只有 \(ModelAvailability.mbText(size))，不到清单钉的 \(ModelAvailability.mbText(pin.size))"
            ))
        }

        return .ready(modelPath: model.path, bytes: model.sizeBytes ?? pin.size, revision: pin.revision)
    }

    private static func blockMessage(
        engine: RetranscribeEngine,
        model: ModelAvailability,
        pin: ModelPin?,
        why: String
    ) -> String {
        var lines = [
            "❌ 课后重转要用 \(engine.fileName)，但\(why)——本次不会改用别的模型",
            "   模型位置：\(model.path)",
        ]
        if let pin {
            lines.append("   期望大小：≥ \(ModelAvailability.mbText(pin.size))（清单钉的上游 \(pin.shortRevision)…）")
            lines.append("   去下载：「设置 › 音频」里的「下载重转模型」，或直接取")
            lines.append("           \(pin.url.absoluteString)")
        } else {
            lines.append("   清单位置：\(ModelManifest.resourceName).json（跑 ./build.sh 重新打包）")
        }
        // 这一行是这份文案存在的理由，别删：静默回落成 medium 正是本包要防的
        lines.append("   （不会静默回落到 medium——那会让你以为这份转录是 large 的产物）")
        return lines.joined(separator: "\n")
    }

    /// 界面/入口里那句「下载入口」的说明。**只写一处**——
    /// 文案和真实入口分家之后一定会有一边过期（P7-1 同一条规矩）
    static var downloadEntryDescription: String {
        "「设置 › 音频」里的「下载重转模型」（large-v3）"
    }

    /// 现读磁盘 + 清单，跑一次裁决。给界面和入口共用的那个入口
    static func resolve(engine: RetranscribeEngine) -> RetranscribeDecision {
        let manifest = try? ModelManifest.loadBundled()
        let pin = manifest?.pin(forFile: engine.fileName)
        let url = WhisperEngine.modelDirectory.appendingPathComponent(engine.fileName)
        // 清单读不出来时，用清单里本该有的那个大小当门槛是做不到的——
        // 那时传 pin 为 nil 会走到「清单里没有这一条」那一支，文案里
        // 直接说清「清单没读出来」，比编一个门槛数字诚实
        let minimum = pin?.size ?? WhisperEngine.expectedModelBytes
        return decide(
            engine: engine,
            model: .probe(at: url, minimumBytes: minimum),
            pin: pin
        )
    }
}
