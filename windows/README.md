# Windows 版（最小切片）

**当前只做一件事：证明「WAV → whisper.cpp → 中文文本」这条链在 Windows 上能跑。**
采集、门控、滑窗、界面都还没有。

## 它是什么

一个命令行程序：读 16 kHz / 16-bit PCM 的 WAV，调 whisper.cpp 转写，按时间戳打印。

```
[00:00.00 -> 00:04.32] 今天讲梯度下降，它其实是在参数空间里找下降最快的方向。
[00:04.32 -> 00:09.10] 学习率太大会震荡，太小会收敛得很慢。
段数: 2
```

## 为什么先做这个

macOS 版的四层里三层是 Apple 独占（SwiftUI / AVFoundation / CoreML），只有 whisper.cpp 能直接跨平台。
所以先用最小切片把**推理这条链**钉死：如果模型加载、中文输出、时间戳都对，后面的 UI 和采集才有意义；
否则先谈界面是浪费。

## 构建

需要 CMake ≥ 3.20 和 VS 2022（或 clang-cl）：

```powershell
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

首次配置会 `FetchContent` 拉 whisper.cpp（固定 tag），并要求联网。

## 准备输入

whisper 只吃 **16 kHz 单声道 PCM**。转换：

```powershell
ffmpeg -i lesson.m4a -ar 16000 -ac 1 -c:a pcm_s16le lesson.wav
```

模型不在仓库里，去 whisper.cpp 的 Models 页拿一个（`ggml-medium-q5_0.bin` 约 514 MB 是 macOS 版在用的那个）。

## 跑

```powershell
build\Release\ct-win.exe ggml-medium-q5_0.bin lesson.wav zh
```

## 下一步（想帮忙可以直接开工）

1. **WASAPI 采集**：44.1/48 kHz 浮点 → 重采样到 16 kHz，写成分片 WAV；
2. **滑窗调度**：复用 macOS 版 `WhisperWindowPipeline` 的策略（10 秒窗 / 3 秒步长），
   注意：**不要把重叠压到 0.5 秒以下**——macOS 上实测会整窗丢话；
3. **VAD 门控**：静音窗不进模型（macOS 版判据：语音帧占比 < 0.10 且整窗 p90 < 0.01）；
4. **说话人分离**：macOS 用 FluidAudio(CoreML)，Windows 需要 ONNX Runtime / DirectML 方案；
5. **UI**：Tauri 或 WinUI 3，二选一（还没定，欢迎提 issue 讨论）。

## 已知限制

- 只支持 16 kHz — 其他采样率直接报错，不在程序里重采样；
- 只支持 PCM 16-bit — 浮点 WAV 会报错；
- 多声道只取左声道；
- 单进程、无流式，整段读完再转（离线切片，不是产品形态）。
