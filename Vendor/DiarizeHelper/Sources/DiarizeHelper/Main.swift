import Darwin
import Foundation

/// 无头入口（C-1 原型；主树的对应物是 `HeadlessEntry.isActive`，见设计稿 §10）。
///
/// 注意：文件名不是 `main.swift`，因为用了 `@main`。
@main
enum DiarizeHelperMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let code: Int32
        do {
            let subcommand = try CLIParser.parse(arguments)
            switch subcommand {
            case .help:
                Diagnostics.stdout(CLIParser.usage)
                code = HelperExitCode.success.rawValue
            case .selftest:
                // 纯函数；退出码 0/1。1 不在 helper 的分类码里，因为它只服务开发者自检。
                code = SelfTest.run() ? 0 : 1
            case .probe(let options):
                code = ProbeCommand.run(options)
            case .diarize(let options):
                code = await DiarizeCommand.run(options)
            case .download(let options):
                code = await DownloadCommand.run(options)
            }
        } catch let error as UsageError {
            Diagnostics.stderr("\(HelperExitCode.badInvocation.errorCode): \(error.message)")
            Diagnostics.stderr("")
            Diagnostics.stderr(CLIParser.usage)
            code = HelperExitCode.badInvocation.rawValue
        } catch {
            Diagnostics.stderr("未分类失败：\(error.localizedDescription)")
            code = HelperExitCode.inferenceFailed.rawValue
        }
        exit(code)
    }
}
