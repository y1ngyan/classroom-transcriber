# 架构

三层，边界很清楚：**能不能跨平台**是唯一的分层标准。

```
┌─────────────────────── 外壳（平台独占） ───────────────────────┐
│ macOS: SwiftUI + AppKit（Sources/Views, Sources/Theme）        │
│ Windows: 见 windows/（进行中，最小切片阶段）                    │
└───────────────────────────┬────────────────────────────────────┘
                            │ 无 UI 依赖的 Swift API
┌───────────────────────────▼────────────────────────────────────┐
│ 业务层（目前是 Swift，逻辑与平台无关，可移植）                   │
│ Sources/Transcription/  取窗、门控、合并、幻觉过滤、切分          │
│ Sources/Services/       模型管理、检索/核查/笔记、配置            │
│ Sources/Stores/         录音与设置状态                            │
│ Sources/Models/         数据模型（可 JSON 序列化，向后兼容）      │
└───────────────┬───────────────────────────────┬────────────────┘
                │                               │
┌───────────────▼─────────────┐   ┌─────────────▼──────────────┐
│ 推理/音频（平台相关）        │   │ 外部进程                    │
│ whisper.cpp（跨平台 ✅）     │   │ diarize-helper（FluidAudio）│
│ Apple Speech（Apple 独占）   │   │ 说话人分离，JSON 信封通信    │
│ CoreML / Metal（Apple）      │   │ 可替换为 ONNX/DirectML(win) │
└─────────────────────────────┘   └────────────────────────────┘
```

## 关键约定

**1. 转录是「滑窗 + 合并」，不是「整段丢给模型」**
10 秒窗 / 3 秒步长（重叠 7 秒）。`WhisperWindowBuffer` 管取窗，`WhisperWindowPipeline` 管门控与调度，
`WhisperWindowMerger` 管跨窗去重与定稿。**改步长要重跑灵敏度表**——历史上压重叠压丢过内容。

**2. 门控在解码之前**
`SpeechGate.evaluate()` 是纯函数（语音帧占比 + 整窗 p90），判静音的窗**直接不进 whisper**，
不是解完再丢。开关关掉时一个字节的判断都不做，保证「关掉 == 改造前」。

**3. 一切验证都要能无头复跑**
`tools/probes/*.sh` 是交付物的一部分：真录音四臂对照、变异注入（先证明判据会红，再证明还原后二进制逐字节一致）。
UI 用 `--ui-snapshot` 渲 PNG，自检在像素层面断言「卡片真从背景分出来了」。

**4. 数据向后兼容是硬约束**
用户可能有几十节课的历史存档。新字段一律可选 + 默认值，旧存档必须能读（`sessions/*.json`）。

## Windows 版的现实

SwiftUI 在 Windows 上不存在，AVFoundation/CoreAudio 也没有对应物。所以 Windows 版**不是移植**：

| 层 | macOS | Windows |
|---|---|---|
| UI | SwiftUI | WinUI 3 / Tauri（未定） |
| 录音 | AVFoundation | WASAPI |
| 转录 | whisper.cpp | whisper.cpp（同一份，可直接复用） |
| 说话人 | FluidAudio（CoreML） | ONNX Runtime / DirectML |
| 业务逻辑 | Swift | 需重写（或抽成 C++/Rust 共享库） |

当前进度：`windows/` 里只有「读 WAV → whisper.cpp → 打印文本」的最小切片 + CMake + CI，
用来先证明**模型推理这条链在 Windows 上能跑**，再决定 UI 和业务层怎么复用。

## 目录速查

| 路径 | 作用 |
|---|---|
| `Sources/Transcription/WhisperWindowPipeline.swift` | 取窗、门控、调度（改这里要跑四臂探针） |
| `Sources/Transcription/SpeechGate.swift` | 静音判据（纯函数，含自检） |
| `Sources/Transcription/WhisperHallucination.swift` | 幻觉过滤（事后兜底，注释里记着四次复现） |
| `Sources/Services/ModelDownloader.swift` | 模型下载（404 回落 + 失败文案） |
| `Sources/Theme/` | 设计 token；`.cardStyle()` 是唯一允许画卡片的地方 |
| `Sources/Snapshot/UISnapshot.swift` | 无头快照，14 张 + 像素判据 |
| `tools/probes/` | 全部可复跑的验收脚本 |
| `windows/` | Windows 最小切片 |
