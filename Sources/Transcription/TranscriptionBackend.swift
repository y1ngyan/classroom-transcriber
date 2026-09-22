import Foundation

/// 实时转录用哪个后端。
///
/// **默认 Apple，而且这个默认值不许改**（接线这一包的硬约束）。
/// 理由不是「Apple 更好」，是风险不对称：Whisper 这条链路是第一次接进
/// 录音路径，接错了会让一节课**整段丢失**（这台机器上已经发生过一次），
/// 而 Apple 那条链路是每天都在跑的。所以 Whisper 必须由用户在设置里
/// 显式打开——默认关，明天的课照常录。等真实录音上核完质量再翻默认值，
/// 那只是一行。
enum TranscriptionBackend: String, CaseIterable, Identifiable {
    case apple
    case whisper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: return "系统（Apple）"
        case .whisper: return "Whisper 本地"
        }
    }

    var hint: String {
        switch self {
        case .apple:
            return "系统语音识别。随系统走，启动即用，不额外占内存；低质量音频（远场、底噪高）上表现明显更差。"
        case .whisper:
            return "本地 Whisper 模型（medium-q5_0，514MB）。低质量音频上识别更准，自带标点与断句；代价是"
                + "首次准备要十几秒（之后有缓存），以及约 1GB 内存。句子按 10 秒窗口出，界面上会晚 10 秒左右才出现。"
        }
    }

    /// 认不出来的值一律回落 `.apple`：配置文件里写错了、或者将来删掉了某个
    /// 后端，都不该把用户带到一个起不来的状态——而 Apple 是那个「一定起得来」的。
    static func of(_ raw: String?) -> TranscriptionBackend {
        guard let raw else { return .apple }
        return TranscriptionBackend(rawValue: raw.lowercased()) ?? .apple
    }
}
