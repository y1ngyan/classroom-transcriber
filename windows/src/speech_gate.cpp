#include "speech_gate.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace ctw {
namespace {

/// 分位数：下标算法与 macOS 版 `MicLevelMetrics.percentile` 逐字相同
/// （`count/20`、`count/2`、`count*9/10`）。换成插值法会让两边对同一段音频
/// 报出不同的底噪，而看的人只会以为其中一个算错了。
double percentile(const std::vector<double>& sorted, double q) {
    if (sorted.empty()) {
        return 0.0;
    }
    size_t index = 0;
    if (q < 0.5) {
        index = static_cast<size_t>(static_cast<double>(sorted.size()) * q);
    } else if (q < 0.9) {
        index = sorted.size() / 2;
    } else {
        index = sorted.size() * 9 / 10;
    }
    index = std::min(std::max<size_t>(index, 0), sorted.size() - 1);
    return sorted[index];
}

}  // namespace

double GateReading::dynamicRangeDb() const {
    const double hi = std::max(speech, 1e-7);
    const double lo = std::max(floor, 1e-7);
    return 20.0 * std::log10(hi / lo);
}

std::string GateReading::summaryLine() const {
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "%.1f 秒窗 · 语音帧占比 %.3f · p90 %.5f(%.1f dBFS) · 底噪 %.5f · 中位 %.5f · 动态范围 %.1f dB",
                  windowSeconds, speechRatio, speech,
                  speech <= 0.0 ? -120.0 : std::max(-120.0, 20.0 * std::log10(speech)),
                  floor, median, dynamicRangeDb());
    return std::string(buf);
}

GateReading analyzeWindow(const std::vector<float>& samples, double sampleRate) {
    GateReading reading;
    if (sampleRate <= 0.0) {
        return reading;
    }
    reading.windowSeconds = static_cast<double>(samples.size()) / sampleRate;

    const size_t frameSize = static_cast<size_t>(std::max(1.0, sampleRate * gate::kFrameSeconds));
    std::vector<double> rms;
    if (frameSize > 0 && samples.size() >= frameSize) {
        rms.reserve(samples.size() / frameSize);
        for (size_t i = 0; i + frameSize <= samples.size(); i += frameSize) {
            double sum = 0.0;
            for (size_t j = i; j < i + frameSize; ++j) {
                const double v = static_cast<double>(samples[j]);
                sum += v * v;
            }
            rms.push_back(std::sqrt(sum / static_cast<double>(frameSize)));
        }
    }

    reading.frameCount = static_cast<int>(
        static_cast<double>(samples.size()) / sampleRate / gate::kFrameSeconds);
    if (rms.empty()) {
        reading.frameCount = 0;
        return reading;
    }

    std::vector<double> sorted = rms;
    std::sort(sorted.begin(), sorted.end());
    reading.floor = percentile(sorted, 0.05);
    reading.median = percentile(sorted, 0.50);
    reading.speech = percentile(sorted, 0.90);

    const double threshold = std::max(reading.floor * 3.0, gate::kFrameThresholdFloor);
    size_t above = 0;
    for (double v : sorted) {
        if (v > threshold) {
            ++above;
        }
    }
    reading.speechRatio = static_cast<double>(above) / static_cast<double>(sorted.size());
    return reading;
}

bool isSilence(const GateReading& reading) {
    if (reading.frameCount <= 0) {
        return false;  // 空窗没有「静音」可言
    }
    if (!(reading.speechRatio < gate::kMinSpeechRatio)) {
        return false;  // 用 !(a<b) 而不是 a>=b：NaN 也必须走「不判静音」
    }
    return reading.speech < gate::kSpeechCeiling;
}

GateVerdict evaluateWindow(const std::vector<float>& samples, double sampleRate) {
    GateVerdict verdict;
    if (samples.empty()) {
        return verdict;  // 有声、不跳
    }
    const GateReading reading = analyzeWindow(samples, sampleRate);
    if (isSilence(reading)) {
        char buf[160];
        std::snprintf(buf, sizeof(buf), "语音帧占比 %.3f<%.2f 且 p90 %.5f<%.5f", reading.speechRatio,
                      gate::kMinSpeechRatio, reading.speech, gate::kSpeechCeiling);
        verdict.isSilence = true;
        verdict.reason = buf;
    }
    return verdict;
}

}  // namespace ctw
