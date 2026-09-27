import Foundation

/// helper 构建标识。设计稿 §2.4 示例值。
/// 正式集成时改成从 build.sh 注入（FluidAudio commit + helper 版本）。
enum HelperBuild {
    static let identifier = "fluidaudio-5c51c5c+helper-1"
}

/// `status` 是权威成功信号（设计稿 §2.4）。
enum EnvelopeStatus: String, Codable, Equatable {
    case ok
    case error
}

/// 一段输入音频在会话时间轴上的位置（设计稿 §2.4 `inputs[]`）。
struct EnvelopeInput: Codable, Equatable {
    /// 文件名（basename），不是绝对路径——信封是给学生看的诊断，不扩散本机路径。
    var path: String
    /// 该片段在会话时间轴上的起点，直接来自 `RecordingPart.offsetMillis`。
    var offsetMillis: Int
    /// 这个片段解码后的实际时长（helper 自己算的，可能与 `durationMillis` 有 <1s 差）。
    var audioSeconds: Double
}

/// 一个说话人段（会话时间轴，整数毫秒）。
struct SpeakerSpanJSON: Codable, Equatable {
    /// 原样保留 FluidAudio 的 `S1`/`S2`；课内归一在 App 侧做。
    var speakerId: String
    var startMillis: Int
    var endMillis: Int
    var qualityScore: Double
}

struct EnvelopeResult: Codable, Equatable {
    /// 复合音频源的总时长（会话时间轴）。
    var audioSeconds: Double
    var speakerCount: Int
    var segments: [SpeakerSpanJSON]
}

struct EnvelopeTimings: Codable, Equatable {
    var wallSeconds: Double
    var loadSeconds: Double
    var segmentationSeconds: Double
    var embeddingSeconds: Double
    var clusteringSeconds: Double
}

struct EnvelopeError: Codable, Equatable {
    var code: String
    var message: String
}

/// 输出 JSON 信封，`schemaVersion: 1`（设计稿 §2.4）。
///
/// 成功与失败共用一个类型：成功填 `result`，失败填 `error`。
/// 不落 embedding（拍板第 4 条）；要留证据走 `--embeddings-out` 旁路。
struct Envelope: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var status: EnvelopeStatus
    var helperBuild: String?
    var mode: String?
    var inputs: [EnvelopeInput]?
    var result: EnvelopeResult?
    var timings: EnvelopeTimings?
    var error: EnvelopeError?

    // MARK: - 构造

    static func ok(
        inputs: [EnvelopeInput],
        result: EnvelopeResult,
        timings: EnvelopeTimings
    ) -> Envelope {
        Envelope(
            schemaVersion: currentSchemaVersion,
            status: .ok,
            helperBuild: HelperBuild.identifier,
            mode: "offline",
            inputs: inputs,
            result: result,
            timings: timings,
            error: nil
        )
    }

    static func failure(code: String, message: String) -> Envelope {
        Envelope(
            schemaVersion: currentSchemaVersion,
            status: .error,
            helperBuild: HelperBuild.identifier,
            mode: "offline",
            inputs: nil,
            result: nil,
            timings: nil,
            error: EnvelopeError(code: code, message: message)
        )
    }

    // MARK: - 编解码（自检覆盖：encode→decode 往返）

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // sortedKeys 保证同一输入 → 同一字节（便于自检与 diff）。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Envelope {
        try decoder.decode(Envelope.self, from: data)
    }

    /// 原子写到 `--output` 指定路径；失败由调用方归类为退出码 8。
    static func write(_ envelope: Envelope, to path: String) throws {
        let data = try envelope.encoded()
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - embedding 旁路（默认不写；`--embeddings-out` 才写）

/// `--embeddings-out` 的旁路信封。与主信封分开，主信封永远不带 embedding。
struct EmbeddingsEnvelope: Codable, Equatable {
    var schemaVersion: Int
    var helperBuild: String
    var embeddings: [EmbeddingEntry]

    struct EmbeddingEntry: Codable, Equatable {
        var speakerId: String
        var startMillis: Int
        var endMillis: Int
        var embedding: [Float]
    }

    static func make(from spans: [SpeakerSpanJSON], raw: [[Float]]) -> EmbeddingsEnvelope {
        let entries = zip(spans, raw).map { pair -> EmbeddingEntry in
            EmbeddingEntry(
                speakerId: pair.0.speakerId,
                startMillis: pair.0.startMillis,
                endMillis: pair.0.endMillis,
                embedding: pair.1
            )
        }
        return EmbeddingsEnvelope(
            schemaVersion: Envelope.currentSchemaVersion,
            helperBuild: HelperBuild.identifier,
            embeddings: entries
        )
    }

    static func write(_ envelope: EmbeddingsEnvelope, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
