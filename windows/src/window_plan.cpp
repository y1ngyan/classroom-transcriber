#include "window_plan.h"

#include <algorithm>
#include <cmath>

namespace ctw {

int sampleToMillis(size_t sample, double sampleRate) {
    if (sampleRate <= 0.0) {
        return 0;
    }
    return static_cast<int>(std::llround(static_cast<double>(sample) * 1000.0 / sampleRate));
}

std::vector<WindowSpan> planWindows(size_t totalSamples,
                                    double sampleRate,
                                    double windowSeconds,
                                    double stepSeconds,
                                    double minimumFlushSeconds) {
    std::vector<WindowSpan> windows;
    if (totalSamples == 0 || sampleRate <= 0.0 || windowSeconds <= 0.0 || stepSeconds <= 0.0) {
        return windows;
    }

    const size_t windowSamples = static_cast<size_t>(std::llround(windowSeconds * sampleRate));
    const size_t stepSamples = static_cast<size_t>(std::llround(stepSeconds * sampleRate));
    const size_t minFlushSamples = static_cast<size_t>(std::llround(minimumFlushSeconds * sampleRate));
    if (windowSamples == 0 || stepSamples == 0) {
        return windows;
    }

    size_t lastEnd = 0;
    // 检查点：一个步长、两个步长……每个检查点取「往回一个窗长」的后缀，
    // 与 macOS `windowWithOrigin`（取最后 N 个样本）等价
    for (size_t cursor = stepSamples; cursor <= totalSamples; cursor += stepSamples) {
        WindowSpan span;
        span.startSample = cursor > windowSamples ? cursor - windowSamples : 0;
        span.sampleCount = cursor - span.startSample;
        span.startMillis = sampleToMillis(span.startSample, sampleRate);
        if (span.sampleCount > 0) {
            windows.push_back(span);
            lastEnd = cursor;
        }
    }

    // 收尾：最后一个检查点之后还剩的音频。太短就不送模型（会编出幻觉文本）
    if (totalSamples > lastEnd && totalSamples - lastEnd >= minFlushSamples) {
        WindowSpan span;
        span.startSample = totalSamples > windowSamples ? totalSamples - windowSamples : 0;
        span.sampleCount = totalSamples - span.startSample;
        span.startMillis = sampleToMillis(span.startSample, sampleRate);
        span.tailFlush = true;
        // 与最后一窗完全重合就没必要再解一遍（防止 total 恰好等于某检查点时重复）
        const bool duplicate = !windows.empty() &&
                               windows.back().startSample == span.startSample &&
                               windows.back().sampleCount == span.sampleCount;
        if (!duplicate && span.sampleCount > 0) {
            windows.push_back(span);
        }
    }

    return windows;
}

}  // namespace ctw
