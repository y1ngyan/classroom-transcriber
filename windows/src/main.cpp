// Windows 版切片：WAV → 重采样 16k → 静音门控 → 10 秒滑窗（3 秒步长）→
// whisper.cpp → 跨窗去重合并 → 中文文本。
//
// 采集（WASAPI）、说话人分离、界面都还没有——那些是下一步。
//
// 用法：
//   ct-win.exe <model.bin> <audio.wav> [language] [--gate on|off] [--verbose]
//   ct-win.exe --scan <audio.wav>          （只扫门控，不加载模型）
//
// 输入可以是真实课堂录音的原始格式：44.1/48 kHz、32-bit float、双声道，
// 程序自己下混 + 重采样到 16 kHz 单声道。
//
// 退出码：2 参数错 / 3 音频错 / 4 模型加载失败 / 5 转写失败。无参数时退 2，
// CI 的冒烟测试依赖这个约定。

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "audio.h"
#include "merge.h"
#include "speech_gate.h"
#include "whisper.h"
#include "window_plan.h"

namespace {

struct Options {
    const char* modelPath = nullptr;
    const char* wavPath = nullptr;
    const char* language = "zh";
    bool gateOn = true;      ///< 默认开：静音幻觉是已实测的缺陷，不是可选优化
    bool verbose = false;
    /// 只扫门控（逐窗判定 + 分布），**不加载模型**。对应 macOS 的 `--gate-scan`：
    /// 判据只吃音频，所以「阈值在这条录音上落在哪」不需要模型就能看到
    bool scan = false;
};

void printUsage(const char* argv0) {
    std::fprintf(stderr,
                 "用法: %s <model.bin> <audio.wav> [language] [--gate on|off] [--verbose]\n"
                 "      %s --scan <audio.wav>\n"
                 "  输入支持 16/24/32-bit 整数 PCM 或 float32 的 WAV，任意常见采样率（44.1k/48k 等），\n"
                 "  多声道会下混，然后重采样到 16 kHz 单声道。\n"
                 "  --gate on|off  静音门控（默认 on）；off 时一窗都不跳，与没有门控的路径一致\n"
                 "  --verbose      逐窗打印门控读数与合并变更\n"
                 "  --scan         只逐窗扫门控并打印分布，**不加载模型**（判据只吃音频）\n",
                 argv0, argv0);
}

bool parseGateValue(const char* value, bool& on) {
    std::string v(value);
    // 去掉首尾空白（命令行里带空格的情况）
    const size_t first = v.find_first_not_of(" \t\r\n");
    const size_t last = v.find_last_not_of(" \t\r\n");
    v = (first == std::string::npos) ? std::string() : v.substr(first, last - first + 1);
    for (char& c : v) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c - 'A' + 'a');
        }
    }
    if (v == "0" || v == "off" || v == "false" || v == "no") {
        on = false;
        return true;
    }
    if (v == "1" || v == "on" || v == "true" || v == "yes") {
        on = true;
        return true;
    }
    return false;
}

std::string trimAscii(const std::string& s) {
    const size_t first = s.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return std::string();
    }
    const size_t last = s.find_last_not_of(" \t\r\n");
    return s.substr(first, last - first + 1);
}

void printTimestamp(int millis, char* buf, size_t size) {
    const int minutes = millis / 60000;
    const int seconds = (millis / 1000) % 60;
    const int ms = millis % 1000;
    std::snprintf(buf, size, "%02d:%02d.%03d", minutes, seconds, ms);
}

/// 让 whisper 把一窗音频转成段（时间是**相对窗起点**的毫秒）
bool transcribeWindow(whisper_context* ctx,
                      const std::vector<float>& samples,
                      const Options& opt,
                      std::vector<ctw::Segment>& out) {
    whisper_full_params wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wp.print_progress = false;
    wp.print_realtime = false;
    wp.print_timestamps = false;  // 时间戳自己打，不让 whisper 打一份
    wp.print_special = false;
    wp.language = opt.language;
    wp.n_threads = 4;

    if (whisper_full(ctx, wp, samples.data(), static_cast<int>(samples.size())) != 0) {
        return false;
    }

    const int n = whisper_full_n_segments(ctx);
    out.clear();
    out.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        const std::string text = trimAscii(whisper_full_get_segment_text(ctx, i));
        if (text.empty()) {
            continue;  // 纯时间戳/空段：没有任何内容可显示，也没法参与去重
        }
        ctw::Segment seg;
        // whisper 的时间单位是 10 ms
        seg.startMillis = static_cast<int>(whisper_full_get_segment_t0(ctx, i)) * 10;
        seg.endMillis = static_cast<int>(whisper_full_get_segment_t1(ctx, i)) * 10;
        if (seg.endMillis < seg.startMillis) {
            seg.endMillis = seg.startMillis;
        }
        seg.text = text;
        out.push_back(seg);
    }
    return true;
}

/// `--scan`：逐窗判一遍门控并打出分布，**不加载模型**。
///
/// 存在的理由与 macOS 的 `--gate-scan` 相同：「0.10 / 0.01 这两个阈值在这条录音上
/// 落在哪、余量有多少」是个必须能被复核的问题。只报「判了 N 窗静音」没法复核，
/// 所以要同时给出两批的边界（判静音批的上界、判有声批的下界）。
int runGateScan(const std::vector<float>& pcm, const std::vector<ctw::WindowSpan>& windows) {
    int silentCount = 0;
    double skippedSeconds = 0.0;
    double silentMaxRatio = 0.0;
    double silentMaxP90 = 0.0;
    double speechMinRatio = 1e9;
    double speechMinP90 = 1e9;

    for (size_t w = 0; w < windows.size(); ++w) {
        const ctw::WindowSpan& span = windows[w];
        const float* begin = pcm.data() + span.startSample;
        const std::vector<float> samples(begin, begin + span.sampleCount);
        const ctw::GateReading reading = ctw::analyzeWindow(samples, ctw::kWhisperSampleRate);
        const ctw::GateVerdict verdict = ctw::evaluateWindow(samples, ctw::kWhisperSampleRate);
        std::printf("[窗 %3zu] 起点 %6dms · %s · %s\n", w + 1, span.startMillis,
                    reading.summaryLine().c_str(), verdict.isSilence ? "判静音" : "判有声");
        const double spanSeconds = static_cast<double>(span.sampleCount) / ctw::kWhisperSampleRate;
        if (verdict.isSilence) {
            ++silentCount;
            skippedSeconds += spanSeconds;
            silentMaxRatio = std::max(silentMaxRatio, reading.speechRatio);
            silentMaxP90 = std::max(silentMaxP90, reading.speech);
        } else {
            speechMinRatio = std::min(speechMinRatio, reading.speechRatio);
            speechMinP90 = std::min(speechMinP90, reading.speech);
        }
    }

    const double total = static_cast<double>(windows.size());
    std::printf("\n取窗 %zu · 判静音 %d（%.0f%%）· 跳过 %.1f 秒\n", windows.size(), silentCount,
                total > 0 ? static_cast<double>(silentCount) * 100.0 / total : 0.0, skippedSeconds);
    if (silentCount == 0) {
        std::printf("这批窗全部判有声（阈值 占比<%.2f 且 p90<%.4f 一次都没同时命中）\n",
                    ctw::gate::kMinSpeechRatio, ctw::gate::kSpeechCeiling);
        return 0;
    }
    if (speechMinRatio > 1e8) {
        std::printf("这批窗**全部判静音**：这条录音要么真的没人说话，要么电平普遍低于 p90 上限 %.4f\n",
                    ctw::gate::kSpeechCeiling);
        return 0;
    }
    std::printf("边界：判静音批 占比≤%.3f p90≤%.5f ｜ 判有声批 占比≥%.3f p90≥%.5f\n", silentMaxRatio,
                silentMaxP90, speechMinRatio, speechMinP90);
    const double ratioMargin = speechMinRatio - silentMaxRatio;
    const double p90Margin = speechMinP90 - silentMaxP90;
    std::printf("余量：占比 %.3f（门 %.2f）· p90 %.5f（上限 %.4f）\n", ratioMargin,
                ctw::gate::kMinSpeechRatio, p90Margin, ctw::gate::kSpeechCeiling);
    if (ratioMargin <= 0.0 || p90Margin <= 0.0) {
        std::printf("⚠️ 两批没有余量：有窗贴着阈值两侧，这条录音上判据不稳（换步长/窗长都要重扫）\n");
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    Options opt;
    std::vector<const char*> positional;

    for (int i = 1; i < argc; ++i) {
        const char* arg = argv[i];
        if (std::strcmp(arg, "--help") == 0 || std::strcmp(arg, "-h") == 0) {
            printUsage(argv[0]);
            return 0;
        }
        if (std::strcmp(arg, "--verbose") == 0) {
            opt.verbose = true;
            continue;
        }
        if (std::strcmp(arg, "--scan") == 0) {
            opt.scan = true;
            continue;
        }
        if (std::strcmp(arg, "--gate") == 0) {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "--gate 需要一个值（on|off）\n");
                return 2;
            }
            if (!parseGateValue(argv[++i], opt.gateOn)) {
                std::fprintf(stderr, "--gate 的值无法识别: %s\n", argv[i]);
                return 2;
            }
            continue;
        }
        if (std::strncmp(arg, "--gate=", 7) == 0) {
            if (!parseGateValue(arg + 7, opt.gateOn)) {
                std::fprintf(stderr, "--gate 的值无法识别: %s\n", arg + 7);
                return 2;
            }
            continue;
        }
        if (arg[0] == '-' && arg[1] != '\0') {
            std::fprintf(stderr, "未知选项: %s\n", arg);
            printUsage(argv[0]);
            return 2;
        }
        positional.push_back(arg);
    }

    if (opt.scan) {
        // 只扫门控：不加载模型，参数是「录音」本身
        if (positional.size() != 1) {
            std::fprintf(stderr, "--scan 只需要一个参数: <audio.wav>\n");
            return 2;
        }
        opt.wavPath = positional[0];
        opt.modelPath = nullptr;
    } else {
        if (positional.size() < 2) {
            printUsage(argv[0]);
            return 2;
        }
        opt.modelPath = positional[0];
        opt.wavPath = positional[1];
        if (positional.size() >= 3) {
            opt.language = positional[2];
        }
        if (positional.size() > 3) {
            std::fprintf(stderr, "多余的参数: %s\n", positional[3]);
            printUsage(argv[0]);
            return 2;
        }
    }

    std::vector<float> pcm;
    std::string audioError;
    if (!ctw::loadWav16kMono(opt.wavPath, pcm, audioError)) {
        std::fprintf(stderr, "音频读取失败: %s\n", audioError.c_str());
        return 3;
    }

    const double seconds = static_cast<double>(pcm.size()) / ctw::kWhisperSampleRate;
    const std::vector<ctw::WindowSpan> windows = ctw::planWindows(pcm.size(), ctw::kWhisperSampleRate);
    if (windows.empty()) {
        std::fprintf(stderr, "音频太短（%.2f 秒），不足一个收尾窗\n", seconds);
        return 3;
    }

    if (opt.scan) {
        return runGateScan(pcm, windows);
    }

    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = false;  // 最小切片先走 CPU，跑通再谈 DirectML
    whisper_context* ctx = whisper_init_from_file_with_params(opt.modelPath, cp);
    if (!ctx) {
        std::fprintf(stderr, "模型加载失败: %s\n", opt.modelPath);
        return 4;
    }

    std::vector<ctw::Segment> merged;
    std::vector<ctw::Segment> pendingTail;
    int previousWindowStartMillis = 0;

    int taken = 0;
    int skipped = 0;
    double skippedSeconds = 0.0;

    for (size_t w = 0; w < windows.size(); ++w) {
        const ctw::WindowSpan& span = windows[w];
        const float* begin = pcm.data() + span.startSample;
        std::vector<float> windowSamples(begin, begin + span.sampleCount);
        const double spanSeconds = static_cast<double>(span.sampleCount) / ctw::kWhisperSampleRate;

        if (opt.gateOn) {
            const ctw::GateVerdict verdict = ctw::evaluateWindow(windowSamples, ctw::kWhisperSampleRate);
            if (opt.verbose) {
                const ctw::GateReading reading = ctw::analyzeWindow(windowSamples, ctw::kWhisperSampleRate);
                std::fprintf(stderr, "[窗 %zu] 起点 %dms · %s · %s\n", w + 1, span.startMillis,
                             reading.summaryLine().c_str(), verdict.isSilence ? "判静音" : "判有声");
                if (verdict.isSilence) {
                    std::fprintf(stderr, "    跳过原因：%s\n", verdict.reason.c_str());
                }
            }
            if (verdict.isSilence) {
                ++skipped;
                skippedSeconds += spanSeconds;
                // 静音窗不进模型。尾部和「上一窗起点」都**不动**——它们描述的是
                // 上一次真正解码的那一窗，动一半会让合并器拿错配的时间基准
                // （macOS 版 `skipIfSilent` 同样不改这一对）
                continue;
            }
        } else if (opt.verbose) {
            std::fprintf(stderr, "[窗 %zu] 起点 %dms · %.1f 秒 · 门控关，直接解码\n", w + 1,
                         span.startMillis, spanSeconds);
        }

        std::vector<ctw::Segment> windowSegments;
        if (!transcribeWindow(ctx, windowSamples, opt, windowSegments)) {
            std::fprintf(stderr, "转写失败（窗起点 %dms）\n", span.startMillis);
            whisper_free(ctx);
            return 5;
        }
        ++taken;

        ctw::MergeInput input;
        input.existing = merged;
        input.windowSegments = windowSegments;
        input.windowStartMillis = span.startMillis;
        input.previousTail = pendingTail;
        input.previousWindowStartMillis = previousWindowStartMillis;
        input.stepMillis = static_cast<int>(ctw::plan::kStepSeconds * 1000);

        ctw::MergeOutput out = ctw::mergeWindow(input);
        merged = out.segments;
        pendingTail = out.pendingTail;
        previousWindowStartMillis = span.startMillis;

        if (opt.verbose) {
            for (const std::string& change : out.changes) {
                std::fprintf(stderr, "    %s\n", change.c_str());
            }
        }
    }

    whisper_free(ctx);

    for (const ctw::Segment& seg : merged) {
        char from[16] = {0};
        char to[16] = {0};
        printTimestamp(seg.startMillis, from, sizeof(from));
        printTimestamp(seg.endMillis, to, sizeof(to));
        std::printf("[%s -> %s] %s\n", from, to, seg.text.c_str());
    }
    std::printf("段数: %zu\n", merged.size());
    std::fprintf(stderr, "音频 %.1f 秒 · 取窗 %zu · 解码 %d · 跳静音 %d（%.1f 秒）· 门控 %s\n",
                 seconds, windows.size(), taken, skipped, skippedSeconds, opt.gateOn ? "开" : "关");
    return 0;
}
