import Foundation

/// 命令行契约（设计稿 §2.2）。
///
/// ```
/// diarize-helper probe    --models-dir <dir> [--no-network]
/// diarize-helper diarize  --input <abs.wav> --offset-ms <int> [--input ... --offset-ms ...]
///                         --models-dir <dir>
///                         --output <abs.json>
///                         [--compute-units ane|cpu|all]   # 默认 ane
///                         [--no-network]                  # 生产恒开
///                         [--embeddings-out <abs.json>]   # 默认不写
/// diarize-helper download --models-dir <dir>             # 唯一允许联网的子命令
/// diarize-helper --selftest                              # 离线自检（不加载模型）
/// ```
///
/// 名字说明：派单要求包/产物名 `diarize-helper`；设计稿命令示例写作 `DiarizeHelper`。
/// 二者是同一个 target（module `DiarizeHelper`，product `diarize-helper`）。

struct UsageError: Error {
    var message: String
}

enum ComputeUnitsArg: String, CaseIterable, Equatable {
    case ane
    case cpu
    case all

    static let `default`: ComputeUnitsArg = .ane
}

struct ProbeOptions: Equatable {
    var modelsDir: String
    var noNetwork: Bool
}

struct DiarizeInputArg: Equatable {
    var path: String
    var offsetMillis: Int
}

struct DiarizeOptions: Equatable {
    var inputs: [DiarizeInputArg]
    var modelsDir: String
    var output: String
    var computeUnits: ComputeUnitsArg
    var noNetwork: Bool
    var embeddingsOut: String?
}

struct DownloadOptions: Equatable {
    var modelsDir: String
}

enum Subcommand: Equatable {
    case help
    case selftest
    case probe(ProbeOptions)
    case diarize(DiarizeOptions)
    case download(DownloadOptions)
}

enum CLIParser {
    static let usage = """
        diarize-helper — 离线说话人识别 helper（C-1 原型）

        USAGE:
          diarize-helper probe    --models-dir <dir> [--no-network]
          diarize-helper diarize  --input <abs.wav> --offset-ms <int> [--input ... --offset-ms ...]
                                  --models-dir <dir>
                                  --output <abs.json>
                                  [--compute-units ane|cpu|all]
                                  [--no-network]
                                  [--embeddings-out <abs.json>]
          diarize-helper download --models-dir <dir>
          diarize-helper --selftest
          diarize-helper --help

        EXIT CODES:
          0 成功（status == "ok"）
          2 用法错误
          3 输入文件不存在/不可读
          4 音频格式不支持/解码失败
          5 模型缺失（且 --no-network）
          6 模型加载/编译失败
          7 推理失败
          8 输出写失败
          9 被 SIGTERM（App 超时）

        NOTE:
          `--selftest` 只跑纯函数，不加载模型、不做任何推理；退出码 0/1。
          `--no-network` 生产恒开；只有 `download` 子命令允许联网。
        """

    static func parse(_ args: [String]) throws -> Subcommand {
        if args.isEmpty {
            throw UsageError(message: "缺少子命令")
        }
        if args.contains("--help") || args.contains("-h") {
            return .help
        }
        if args.contains("--selftest") {
            return .selftest
        }

        var rest = args[...]
        let first = rest.removeFirst()
        switch first {
        case "help":
            return .help
        case "probe":
            return .probe(try parseProbe(Array(rest)))
        case "diarize":
            return .diarize(try parseDiarize(Array(rest)))
        case "download":
            return .download(try parseDownload(Array(rest)))
        default:
            throw UsageError(message: "未知子命令：\(first)")
        }
    }

    // MARK: - probe

    private static func parseProbe(_ args: [String]) throws -> ProbeOptions {
        var modelsDir: String?
        var noNetwork = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--models-dir":
                modelsDir = try value(args, at: &i, flag: "--models-dir")
            case "--no-network":
                noNetwork = true
                i += 1
            default:
                throw UsageError(message: "probe 不认识的参数：\(args[i])")
            }
        }
        guard let modelsDir else {
            throw UsageError(message: "probe 缺少 --models-dir")
        }
        return ProbeOptions(modelsDir: modelsDir, noNetwork: noNetwork)
    }

    // MARK: - diarize

    private static func parseDiarize(_ args: [String]) throws -> DiarizeOptions {
        var inputs: [String] = []
        var offsets: [Int] = []
        var modelsDir: String?
        var output: String?
        var computeUnits = ComputeUnitsArg.default
        var noNetwork = false
        var embeddingsOut: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--input":
                inputs.append(try value(args, at: &i, flag: "--input"))
            case "--offset-ms":
                let raw = try value(args, at: &i, flag: "--offset-ms")
                guard let parsed = Int(raw), parsed >= 0 else {
                    throw UsageError(message: "--offset-ms 需要 >= 0 的整数，收到：\(raw)")
                }
                offsets.append(parsed)
            case "--models-dir":
                modelsDir = try value(args, at: &i, flag: "--models-dir")
            case "--output":
                output = try value(args, at: &i, flag: "--output")
            case "--compute-units":
                let raw = try value(args, at: &i, flag: "--compute-units")
                guard let parsed = ComputeUnitsArg(rawValue: raw) else {
                    throw UsageError(message: "--compute-units 只接受 ane|cpu|all，收到：\(raw)")
                }
                computeUnits = parsed
            case "--no-network":
                noNetwork = true
                i += 1
            case "--embeddings-out":
                embeddingsOut = try value(args, at: &i, flag: "--embeddings-out")
            default:
                throw UsageError(message: "diarize 不认识的参数：\(args[i])")
            }
        }

        guard !inputs.isEmpty else {
            throw UsageError(message: "diarize 至少需要一个 --input")
        }
        guard inputs.count == offsets.count else {
            throw UsageError(
                message: "每个 --input 必须紧跟一个 --offset-ms（现在 input=\(inputs.count), offset=\(offsets.count)）")
        }
        guard let modelsDir else {
            throw UsageError(message: "diarize 缺少 --models-dir")
        }
        guard let output else {
            throw UsageError(message: "diarize 缺少 --output")
        }

        let pairs = zip(inputs, offsets).map { DiarizeInputArg(path: $0.0, offsetMillis: $0.1) }
        return DiarizeOptions(
            inputs: pairs,
            modelsDir: modelsDir,
            output: output,
            computeUnits: computeUnits,
            noNetwork: noNetwork,
            embeddingsOut: embeddingsOut
        )
    }

    // MARK: - download

    private static func parseDownload(_ args: [String]) throws -> DownloadOptions {
        var modelsDir: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--models-dir":
                modelsDir = try value(args, at: &i, flag: "--models-dir")
            default:
                throw UsageError(message: "download 不认识的参数：\(args[i])")
            }
        }
        guard let modelsDir else {
            throw UsageError(message: "download 缺少 --models-dir")
        }
        return DownloadOptions(modelsDir: modelsDir)
    }

    // MARK: - helpers

    private static func value(_ args: [String], at index: inout Int, flag: String) throws -> String {
        guard index + 1 < args.count else {
            throw UsageError(message: "\(flag) 后面缺少值")
        }
        let v = args[index + 1]
        index += 2
        return v
    }
}
