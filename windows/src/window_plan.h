// 滑窗取窗计划（离线版）。移植自 macOS 版 WhisperWindowPipeline / WhisperWindowBuffer
// 的取窗节奏：**10 秒窗 / 3 秒步长**，收尾时把不足一窗的尾巴也送进去。
//
// 为什么不把步长放大到接近窗长（比如 9.6 秒）：macOS 上实测过，9.6 秒步长
// 只剩 0.4 秒重叠，会出现**整窗丢话**——每一窗的上下文只剩 0.4 秒，模型的
// 开头段经常落在窗口边界外，而合并器又只能看到重叠区，两者一叠加就是整句
// 消失。生产步长因此固定在 3 秒（重叠 7 秒，每句话平均被解码三次）。这个数
// 是**实测调出来的**，不是随手写的，所以这里写死、不做成命令行参数。

#pragma once

#include <cstddef>
#include <vector>

namespace ctw {

/// 一窗在整段音频里的位置。时间戳由样本下标换算（`startMillis`），
/// 合并器要求的就是这个数。
struct WindowSpan {
    size_t startSample = 0;
    size_t sampleCount = 0;
    int startMillis = 0;
    /// true = 收尾补的那一窗（长度可能不足 10 秒）
    bool tailFlush = false;
};

namespace plan {
constexpr double kWindowSeconds = 10.0;
constexpr double kStepSeconds = 3.0;
/// 收尾窗的最短长度。低于它不送模型：whisper 喂几百毫秒会编出幻觉文本。
constexpr double kMinimumFlushSeconds = 1.0;
}  // namespace plan

/// 生成取窗计划。
///
/// 前三个检查点（3/6/9 秒）拿到的是不足 10 秒的窗——这正是实时链路的形态
/// （缓冲里有多少就取多少），不是为了省事。收尾若还剩 >= 1 秒，再补一窗
/// （与 macOS `minimumFlushSeconds` 同值）。
std::vector<WindowSpan> planWindows(size_t totalSamples,
                                    double sampleRate = 16000.0,
                                    double windowSeconds = plan::kWindowSeconds,
                                    double stepSeconds = plan::kStepSeconds,
                                    double minimumFlushSeconds = plan::kMinimumFlushSeconds);

/// 全局时间戳：窗起点样本下标 → 毫秒。
int sampleToMillis(size_t sample, double sampleRate = 16000.0);

}  // namespace ctw
