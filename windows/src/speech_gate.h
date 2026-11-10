// 静音门控。移植自 macOS 版 Sources/Transcription/SpeechGate.swift +
// MicLevelMetrics.swift 的判据（两个项目里这两处必须同口径，否则同一段音频
// 在两边会得出不同结论）。
//
// **纯函数**：给样本、出判定，不碰模型、不碰磁盘。所以单元测试能用构造出来的
// 波形把它钉住（数字静音 / 底噪 / 人声 / 均匀小声人声 / 半静音半说话）。

#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace ctw {

struct GateReading {
    double windowSeconds = 0.0;
    int frameCount = 0;
    double floor = 0.0;    ///< 20ms 帧 RMS 的 p5
    double median = 0.0;   ///< 帧 RMS 的 p50
    double speech = 0.0;   ///< 帧 RMS 的 p90
    double speechRatio = 0.0;  ///< 帧 RMS > max(floor*3, 0.005) 的帧占比

    double dynamicRangeDb() const;
    std::string summaryLine() const;
};

struct GateVerdict {
    bool isSilence = false;
    /// 命中的判据（进日志，方便在真实录音上复核「为什么这窗被跳了」）
    std::string reason;
};

namespace gate {

/// 语音帧占比的门。与 macOS 版 `SpeechGate.minSpeechRatio` 同值。
/// 实测分布（两批真实课堂录音）见 macOS 侧注释：判静音那批上界 0.084、
/// 判有声那批下界 0.108，这个数落在两批之间。
constexpr double kMinSpeechRatio = 0.10;

/// 整窗 p90 的绝对上限（约 -40 dBFS）。挡的是「电平均匀的人声」这个形态：
/// 整窗都在说话时 p5 取到的就是人声本身 → 阈值被抬到人声之上 → 语音帧占比
/// 算成 0，只看第一条会把满窗人声判死。取低一点：漏跳一窗的代价是多花两秒，
/// 错跳一窗的代价是丢掉真人说话。
constexpr double kSpeechCeiling = 0.01;

/// 帧长 20 ms，与 macOS `MicLevelMetrics.frameSeconds` 同口径。
constexpr double kFrameSeconds = 0.02;

/// 语音帧阈值下限（绝对下限，防止数字静音时 floor=0 导致 threshold=0）
constexpr double kFrameThresholdFloor = 0.005;

}  // namespace gate

/// 算一窗的读数。`samples` 是 16 kHz 单声道。
GateReading analyzeWindow(const std::vector<float>& samples, double sampleRate = 16000.0);

/// 判据本体。**两条都成立才判静音**（纯函数，变异注入点就在这里）。
bool isSilence(const GateReading& reading);

/// 一窗的判定。空样本判「有声、不跳」：没有音频可跳，也不该说「这里没人说话」。
GateVerdict evaluateWindow(const std::vector<float>& samples, double sampleRate = 16000.0);

}  // namespace ctw
