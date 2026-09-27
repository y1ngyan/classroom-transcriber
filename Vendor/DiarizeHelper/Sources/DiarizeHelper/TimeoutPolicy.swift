import Foundation

/// 超时公式（设计稿 §2.7）：
/// `max(300s, 90s + audioSeconds/5)`。
///
/// 依据：实测最慢 98.6× 实时，45 min → 约 27s 纯计算；模型加载/编译首见 66.4s。
/// 除以 5 已含约 4× 余量。到期 `terminate()`，5s 后 `kill(SIGKILL)`，判 `.timeout`。
///
/// helper 自己不实现超时（App 的 watchdog 做）；这里把公式固化成纯函数，
/// 让 App 与 helper 用同一份判据，并进无头自检。
enum TimeoutPolicy {
    static let floorSeconds: Double = 300
    static let baseSeconds: Double = 90
    static let realtimeDivisor: Double = 5

    static func timeoutSeconds(audioSeconds: Double) -> Double {
        max(floorSeconds, baseSeconds + audioSeconds / realtimeDivisor)
    }

    /// watchdog 给 helper 的 SIGTERM 之后，宽限多久再 SIGKILL。
    static let killGraceSeconds: Double = 5
}
