import Foundation

/// helper 内部失败：退出码 + 给信封/诊断用的短原因（设计稿 §2.7：stderr 走日志，
/// 界面只给一句短原因）。
struct HelperFailure: Error {
    var code: HelperExitCode
    var message: String
}

enum Diagnostics {
    static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func stdout(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
}
