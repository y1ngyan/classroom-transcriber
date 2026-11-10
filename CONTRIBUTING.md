# 参与开发

先读 [ARCHITECTURE.md](ARCHITECTURE.md)。这个项目有一条不太常见、但必须理解的规矩：

> **「自检全绿」不等于「做对了」。**

历史上两次事故都是全绿状态下发生的：
- 界面快照「页头写着共 3 条录音，列表区一张卡片都没有」，51 条像素判据一条都没报；
- 滑窗重叠压到 0.4 秒，探针全过，但同一段真人录音少了 17 个字、中间整窗空白。

所以这里的 PR 要求证据，不是形容词。

## 环境

macOS 26+、Command Line Tools（不需要完整 Xcode）、Homebrew：

```bash
brew install whisper.cpp
./build.sh                              # → build/ClassroomTranscriber.app
```

模型不随仓库分发，首次启动会引导下载（约 514 MB）。

## 提交前必须跑

```bash
BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
$BIN --selftest                 # 主自检
$BIN --speech-gate-selftest     # 门控纯函数
$BIN --ui-snapshot /tmp/ui-snap # 界面快照（14 张 PNG + 像素判据）
tools/probes/exit_codes.sh      # 退出码与关键路径（记得带 CLASSROOM_BIN=$BIN）
```

## PR 规矩

1. **一个 PR 一件事。** 功能、重构、修 bug 不要混在一起；混合 PR 一律要求拆分。
2. **碰这几处必须带前后对照**（真实录音，用仓库外的你自己的录音，别提交音频）：
   - `SpeechGate`（静音判据）、`WhisperWindowPipeline`（取窗/步长/门控）；
   - 任何会改变「哪些窗口进模型」的改动。
   对照要给出：取窗数、跳过数、段数、字数、覆盖率，改造前后并排。
3. **判据要有分辨力**：新增断言后，请把被测逻辑故意改坏一次，确认断言真的会红，
   再改回来（`tools/probes/*mutations*.sh` 是现成写法）。
4. **不许为了让测试变绿去改期望值。** 期望错了要单独说明为什么错。
5. **UI 改动附快照**：`--ui-snapshot` 出的 PNG 贴进 PR；只说「更好看了」不算证据。

## 不要做的事

- 不要提交模型、音频、`~/Library/Application Support/` 下的任何用户数据；
- 不要在测试里播放声音、打开麦克风或修改系统音频设置——CI 上没有麦克风，本地也不该为了测试去动它；
- 不要引入需要联网才能跑的测试；联网功能一律可 mock；
- 不要用宽匹配 `pkill` / `killall` 清理进程，按 PID 杀。

## 从哪开始

- 标了 `good first issue` 的通常是不碰转录管线的：导出格式、界面细节、文案、文档；
- 想碰管线，先读 `Sources/Transcription/WhisperHallucination.swift` 的注释——那里记着静音幻觉的四次复现。

## 提交信息

中文或英文都行，但请写清三件事：**改了什么 / 为什么 / 怎么验证的**。
```
P12-2：静音窗不进模型（门控·第一步）

长静音录音前 120 秒：38 窗跳 28（73.7%），解码 CPU 114.0→41.9 秒；
有说话的录音上 24 段/218 字/97.5%，与基线逐项相同。
验证：tools/probes/p12_2_speech_gate.sh 四臂 + exit_codes 50 条
```
