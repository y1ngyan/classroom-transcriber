// Windows 版最小切片：WAV → whisper.cpp → 文字。
//
// 目的只有一个：证明「模型推理这条链」在 Windows 上能跑通、能出正确的中文。
// 采集（WASAPI）、门控、滑窗调度、界面都还没有——那些是下一步。
//
// 用法：
//   ct-win.exe model.bin audio.wav [language]
// 要求：WAV 为 PCM 16-bit，16 kHz，单/双声道（双声道取左声道）。

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "whisper.h"

namespace {

bool readWav16kMono(const char* path, std::vector<float>& out) {
    FILE* f = std::fopen(path, "rb");
    if (!f) { std::fprintf(stderr, "打不开文件: %s\n", path); return false; }

    char riff[4], wave[4];
    uint32_t riffSize = 0;
    if (std::fread(riff, 1, 4, f) != 4 || std::fread(&riffSize, 4, 1, f) != 1 ||
        std::fread(wave, 1, 4, f) != 4 || std::memcmp(riff, "RIFF", 4) != 0 ||
        std::memcmp(wave, "WAVE", 4) != 0) {
        std::fprintf(stderr, "不是 WAV 文件\n"); std::fclose(f); return false;
    }

    uint16_t channels = 0, bits = 0;
    uint32_t rate = 0;
    std::vector<int16_t> pcm;

    while (true) {
        char id[4]; uint32_t size = 0;
        if (std::fread(id, 1, 4, f) != 4 || std::fread(&size, 4, 1, f) != 1) break;
        if (std::memcmp(id, "fmt ", 4) == 0) {
            uint16_t fmt = 0;
            std::fread(&fmt, 2, 1, f);
            std::fread(&channels, 2, 1, f);
            std::fread(&rate, 4, 1, f);
            std::fseek(f, 6, SEEK_CUR);          // byteRate + blockAlign
            std::fread(&bits, 2, 1, f);
            if (size > 16) std::fseek(f, (long)(size - 16), SEEK_CUR);
            if (fmt != 1 || bits != 16) {
                std::fprintf(stderr, "只支持 PCM 16-bit（当前 fmt=%u bits=%u）\n", fmt, bits);
                std::fclose(f); return false;
            }
        } else if (std::memcmp(id, "data", 4) == 0) {
            pcm.resize(size / 2);
            std::fread(pcm.data(), 2, pcm.size(), f);
            break;
        } else {
            std::fseek(f, (long)size + (size & 1), SEEK_CUR);
        }
    }
    std::fclose(f);

    if (pcm.empty() || channels == 0) { std::fprintf(stderr, "没有音频数据\n"); return false; }
    if (rate != WHISPER_SAMPLE_RATE) {
        std::fprintf(stderr, "要求 16 kHz（当前 %u Hz）：先转成 16k 单声道再跑\n", rate);
        return false;
    }

    out.resize(pcm.size() / channels);
    for (size_t i = 0; i < out.size(); ++i) {
        out[i] = pcm[i * channels] / 32768.0f;   // 多声道只取左声道
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "用法: %s <model.bin> <audio.wav> [language]\n", argv[0]);
        return 2;
    }
    const char* modelPath = argv[1];
    const char* wavPath   = argv[2];
    const char* language  = (argc > 3) ? argv[3] : "zh";

    std::vector<float> pcm;
    if (!readWav16kMono(wavPath, pcm)) return 3;

    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = false;                          // 最小切片先走 CPU，跑通再谈 DirectML
    whisper_context* ctx = whisper_init_from_file_with_params(modelPath, cp);
    if (!ctx) { std::fprintf(stderr, "模型加载失败: %s\n", modelPath); return 4; }

    whisper_full_params wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wp.print_progress = false;
    wp.print_realtime = false;
    wp.print_timestamps = true;
    wp.language = language;
    wp.n_threads = 4;

    if (whisper_full(ctx, wp, pcm.data(), (int)pcm.size()) != 0) {
        std::fprintf(stderr, "转写失败\n"); whisper_free(ctx); return 5;
    }

    const int n = whisper_full_n_segments(ctx);
    for (int i = 0; i < n; ++i) {
        const int64_t t0 = whisper_full_get_segment_t0(ctx, i);
        const int64_t t1 = whisper_full_get_segment_t1(ctx, i);
        std::printf("[%02lld:%02lld.%03lld -> %02lld:%02lld.%03lld] %s\n",
                    (long long)(t0 / 6000), (long long)((t0 / 100) % 60), (long long)((t0 % 100) * 10),
                    (long long)(t1 / 6000), (long long)((t1 / 100) % 60), (long long)((t1 % 100) * 10),
                    whisper_full_get_segment_text(ctx, i));
    }
    std::printf("段数: %d\n", n);

    whisper_free(ctx);
    return 0;
}
