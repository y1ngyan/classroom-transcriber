import Foundation

/// `probe` 的 JSON 报告。probe 只检查模型文件在不在，**不做推理、不加载/编译模型**
/// （设计稿 §2.2、§7 步骤 1）。
struct ProbeReport: Codable, Equatable {
    var schemaVersion: Int
    var status: String
    var helperBuild: String
    var mode: String
    var modelsReady: Bool
    var repoPath: String
    var missing: [String]

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }
}

/// probe 面的结果类型 = 统一的 `ModelPresence.Verdict`（刻意不再另立一套字段，
/// 否则「同一份实现」又会退化成两个形状）。
typealias ModelProbeResult = ModelPresence.Verdict

/// 模型就位判定（probe 面）。
///
/// **判定逻辑不在这个文件里**：由 `ModelPresence.evaluate` 统一实现（C-1 裁决 3），
/// probe / diarize / download 三处共用同一份。这里只做「probe 面的适配」，
/// 保证 probe 的结论与 diarize 的预检、以及 FluidAudio 真正 load 时的
/// `modelMissing` 判定一致。
enum ModelProbe {
    /// revision marker 文件名（转发，保留旧调用点）。
    static let revisionMarkerName = ModelPresence.revisionMarkerName

    /// probe 面的就位判定 = 直接取 `ModelPresence.evaluate` 的结果。
    static func inspect(modelsDir: URL) -> ModelProbeResult {
        ModelPresence.evaluate(modelsDir: modelsDir)
    }
}

enum ProbeCommand {
    static func run(_ options: ProbeOptions) -> Int32 {
        let modelsDir = URL(fileURLWithPath: options.modelsDir, isDirectory: true)
        let result = ModelProbe.inspect(modelsDir: modelsDir)
        let report = ProbeReport(
            schemaVersion: Envelope.currentSchemaVersion,
            status: result.ready ? EnvelopeStatus.ok.rawValue : EnvelopeStatus.error.rawValue,
            helperBuild: HelperBuild.identifier,
            mode: "offline",
            modelsReady: result.ready,
            repoPath: result.repoPath,
            missing: result.missing
        )
        if let data = try? report.encoded(), let text = String(data: data, encoding: .utf8) {
            Diagnostics.stdout(text)
        }
        if result.ready {
            return HelperExitCode.success.rawValue
        }
        Diagnostics.stderr(
            "modelMissing: \(result.missing.joined(separator: ", ")) under \(result.repoPath)"
                + (result.revisionOK ? "" : "（revision marker 不匹配；需要重新 download）")
        )
        return HelperExitCode.modelMissing.rawValue
    }
}
