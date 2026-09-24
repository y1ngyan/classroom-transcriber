/// 这次进程是不是「无头入口」（自检 / 探针 / 离线跑），而不是给人用的 GUI。
///
/// **为什么需要它**：`AppState` 会在 init 里按配置把 Whisper 预热起来（本机
/// config 里后端就是 whisper），而 `AppState` 是 `App` 的 `@State` 属性——
/// **属性默认值先于 `init()` 体求值**（实测），所以无头入口还没走到 `App.init`
/// 里那句 `if CommandLine.arguments.contains(…)`，`AppState` 就已经把预热派
/// 出去了；入口随后自己再构造一份，两份 ggml context 并发初始化，堆被写坏 →
/// 133 SIGTRAP（现场与推演见 `docs/Whisper推进报告.md` §3.3）。
///
/// 判据刻意是「命令行带了开关」而不是一份开关名单：名单会过期（新加一个自检
/// 开关忘了登记，那个竞态就悄悄回来了），而「GUI 是被 `open` 起来的、一个参数
/// 都没有」是结构性事实。退化方向也是安全的：万一将来真加了给 GUI 用的开关，
/// 后果只是**不预热**——点录制时多等一次模型加载，不会坏数据。
///
/// **为什么单独一个文件、不放在 `App.swift` 里**：`AppState.swift` 要用它，
/// 而 `tools/probe.sh` / `tools/probes/wav_kill.sh` / `tools/probes/ww_merger.sh`
/// 组源码表时**故意排除 `App.swift`**（那是 `@main`，探针自己带 main）。留在
/// `App.swift` 里的直接后果是这三个探针**编译不过**
/// （`Sources/AppState.swift:55:57: error: cannot find 'HeadlessEntry' in scope`
/// ——2026-09-24 核验者实测）。规则记在这里：**任何被 `App.swift` 之外引用的
/// 类型都不能住在 `App.swift` 里**，否则就是在给「独立路径验证」那条路挖坑，
/// 而那条路正是本项目查「App 里看着对、外面跑不对」的唯一入口。
enum HeadlessEntry {
    static var isActive: Bool {
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    }
}
