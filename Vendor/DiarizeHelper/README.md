# diarize-helper（C-1 原型）

主树**外**的尖刀包。离线说话人识别 helper 的 CLI 契约 + JSON 信封 + 退出码 +
超时公式 + 5 条校验 + §3.4 映射纯函数 + 离线自检。

- **状态：只写了代码，未构建、未跑任何推理**（C-1 派单要求）。
- 依赖 FluidAudio 走**本地 path 依赖** `../FluidAudio`（commit `5c51c5c`），
  原型阶段**不引 submodule**，因此本包不需要网络去 fetch 依赖仓库。
- 产出位置：`~/ClassroomTranscriber-spike/C-helper/`。
- 绝不写/改/删 `/Users/you/ClassroomTranscriber`。

## 构建与自检（下一轮机器空了再跑）

```bash
cd ~/ClassroomTranscriber-spike/C-helper

# 1) 自检：不加载模型、不推理（裁决 3 的模型就位用例只在临时目录建空占位，不编译 CoreML）
swift build -c release
.build/release/diarize-helper --selftest; echo "exit=$?"

# 2) probe（空目录 → 退出码 5；模型齐全 → 0）
.build/release/diarize-helper probe --models-dir /tmp/empty --no-network; echo "exit=$?"

# 3) 真实录音（示例，文件名按实际改）
.build/release/diarize-helper diarize \
  --input "$HOME/Library/Application Support/ClassroomTranscriber/Recordings/课堂-XXXX.wav" \
  --offset-ms 0 \
  --models-dir "$HOME/Library/Application Support/ClassroomTranscriber/diarization-models" \
  --no-network --output /tmp/c.json; echo "exit=$?"; jq . /tmp/c.json
```

`Scripts/verify-next-round.sh` 把上面这些串成一条（含失败注入）。

## 文件清单

| 文件 | 作用 |
|---|---|
| `Package.swift` | SwiftPM 清单；executable `diarize-helper`，path 依赖 `../FluidAudio`，macOS 14 |
| `Sources/DiarizeHelper/Main.swift` | `@main` 无头入口；子命令分发 |
| `Sources/DiarizeHelper/CLI.swift` | 命令行契约与解析（probe / diarize / download / --selftest） |
| `Sources/DiarizeHelper/ExitCodes.swift` | 退出码 0/2–9、`error.code`、`ProcessTermination`、退出码映射 |
| `Sources/DiarizeHelper/Envelope.swift` | JSON 信封 schemaVersion 1；成功/失败构造；编解码；embedding 旁路 |
| `Sources/DiarizeHelper/TimeoutPolicy.swift` | 超时公式 `max(300s, 90s + audioSec/5)` + 5s kill 宽限 |
| `Sources/DiarizeHelper/HelperError.swift` | 内部失败类型 + stderr/stdout 诊断 |
| `Sources/DiarizeHelper/ModelPresence.swift` | **裁决 3**：模型就位判定的**唯一实现**（复刻 FluidAudio `ModelCache`/`loadModelsOnce` 的离线判定）；probe/diarize/download 共用 |
| `Sources/DiarizeHelper/ModelProbe.swift` | probe：模型就位判定（转发 `ModelPresence`）+ probe 子命令 |
| `Sources/DiarizeHelper/CompositeAudioSource.swift` | 多片段复合音频源（按 offset 摆到会话轴，空洞补零）+ 构建器 |
| `Sources/DiarizeHelper/DiarizeCommand.swift` | diarize：加载模型 → 推理 → 物化信封；错误分类（含裁决 2 noSpeech、裁决 4 禁用 `prepareModels`） |
| `Sources/DiarizeHelper/DownloadCommand.swift` | download：唯一联网子命令；只下载不加载 |
| `Sources/DiarizeHelper/Validation.swift` | §2.6 的 5 条校验（纯函数） |
| `Sources/DiarizeHelper/SpeakerMapper.swift` | §3.2/§3.3 映射纯函数（本地镜像类型）；裁决 1「未标注 ⟺ `speakerId == nil`」 |
| `Sources/DiarizeHelper/SelfTest.swift` | `--selftest`：信封/退出码/5 校验/10 映射/超时 + 裁决 1 不变量 + 裁决 2 近静音 + 裁决 3 probe/diarize 一致性 |
| `Scripts/verify-next-round.sh` | 下一轮验收命令（本轮不执行） |
| `REPORT.md` | 交付说明、验证计划、未验项、拿不准的点 |

## 与设计稿的两个已知偏差

1. **名字**：派单要求 executable `diarize-helper`，设计稿 §2.2 命令示例写 `DiarizeHelper`。
   实现取 module `DiarizeHelper` + product `diarize-helper`（命令行走派单的名字）。
2. **`SpeakerMapper` 在 helper 里**：设计稿把它放在主树（C-2 步骤 3）。派单要求
   这一包把 §3.4 的 10 条用例的纯函数部分一起交付，所以这里用**本地镜像类型**
   实现了一份可独立自检的版本；C-2 接主树时把这份算法原样搬过去，
   接到 `TranscriptSegment`/`RecordingPart`/`SpeakerDiarization` 上。
