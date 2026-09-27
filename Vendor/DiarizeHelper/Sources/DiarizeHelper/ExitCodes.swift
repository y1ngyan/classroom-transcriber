import Darwin
import Foundation

/// helper 的分类退出码（设计稿 §2.5）。
///
/// 约定：
/// - `status == "ok"` 是权威成功信号；退出码是给崩溃/超时兜底的。
/// - 没有「失败就回退成全员 S1」这条路。校验不过 → App 侧 `diarization = nil`。
enum HelperExitCode: Int32, CaseIterable, Equatable {
    case success = 0
    case badInvocation = 2
    case audioUnreadable = 3
    case audioUnsupported = 4
    case modelMissing = 5
    case modelLoadFailed = 6
    case inferenceFailed = 7
    case outputWriteFailed = 8
    case timeout = 9

    /// JSON 信封 `error.code` 的取值（与 App 侧 `DiarizationFailure` 归类同名）。
    var errorCode: String {
        switch self {
        case .success: return "ok"
        case .badInvocation: return "badInvocation"
        case .audioUnreadable: return "audioUnreadable"
        case .audioUnsupported: return "audioUnsupported"
        case .modelMissing: return "modelMissing"
        case .modelLoadFailed: return "modelLoadFailed"
        case .inferenceFailed: return "inferenceFailed"
        case .outputWriteFailed: return "outputWriteFailed"
        case .timeout: return "timeout"
        }
    }
}

/// 子进程结束后 App 能拿到的两个量（`Process.terminationReason` + `terminationStatus`）。
struct ProcessTermination: Equatable {
    enum Reason: Equatable {
        case exit
        case uncaughtSignal
    }

    var reason: Reason
    var status: Int32

    init(reason: Reason, status: Int32) {
        self.reason = reason
        self.status = status
    }
}

/// 退出码映射（纯函数，进无头自检）。
///
/// 设计稿 §2.5 / §2.6：
/// - `terminationReason == .exit` 且 status ∈ {0,2..9} → 对应分类；
/// - status 是别的值（例如 1）→ 未知，归「崩溃」→ `nil`；
/// - 被 SIGTERM 杀死 = App 超时 → `.timeout`(9)；
/// - 被其它信号杀死 → 「崩溃」→ `nil`；
/// - 根本没有信封 / 没拿到 termination → 「崩溃」→ `nil`。
enum ExitCodeClassifier {
    static func classify(_ termination: ProcessTermination) -> HelperExitCode? {
        switch termination.reason {
        case .exit:
            return HelperExitCode(rawValue: termination.status)
        case .uncaughtSignal:
            // SIGTERM 是 App watchdog 的 terminate()；其余（SEGV/KILL…）是崩溃。
            return termination.status == SIGTERM ? .timeout : nil
        }
    }
}
