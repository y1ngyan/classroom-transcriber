#include "audio.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace ctw {
namespace {

uint16_t le16(const unsigned char* p) {
    return static_cast<uint16_t>(static_cast<uint16_t>(p[0]) |
                                 (static_cast<uint16_t>(p[1]) << 8));
}

uint32_t le32(const unsigned char* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

/// 用 memcpy 而不是指针强转：float 的别名规则不允许 reinterpret_cast，
/// 在 -O2 下那种写法会被优化掉。
float floatFromBits(uint32_t bits) {
    float v = 0.0f;
    std::memcpy(&v, &bits, sizeof(v));
    return v;
}

float decodeSample(const unsigned char* p, uint16_t bits, bool isFloat) {
    if (isFloat) {
        return bits == 32 ? floatFromBits(le32(p)) : 0.0f;  // 64 位 float 在入口已拒
    }
    switch (bits) {
        case 8:
            // 8 bit WAV 是无符号的，128 是零点（RIFF 规定，不是笔误）
            return (static_cast<float>(p[0]) - 128.0f) / 128.0f;
        case 16:
            return static_cast<float>(static_cast<int16_t>(le16(p))) / 32768.0f;
        case 24: {
            // WAV 的 24 bit 是小端 3 字节：p[0] 是低 8 位。先按无符号拼出 24 位，
            // 再看 bit23 决定要不要减 2^24 做符号扩展（用减法而不是移位，
            // 避免依赖「负数右移是算术右移」这条实现定义的行为）
            const int32_t u = static_cast<int32_t>(static_cast<uint32_t>(p[0]) |
                                                  (static_cast<uint32_t>(p[1]) << 8) |
                                                  (static_cast<uint32_t>(p[2]) << 16));
            const int32_t v = (u & 0x800000) ? (u - 0x1000000) : u;
            return static_cast<float>(v) / 8388608.0f;
        }
        case 32:
            return static_cast<float>(static_cast<int32_t>(le32(p))) / 2147483648.0f;
        default:
            return 0.0f;
    }
}

// 文件偏移必须 64 位：Windows 的 long 只有 32 位，一节 3 小时 48k 立体声录音
// 是 2.7 GB，用 long 会在 ftell 上溢出（表现是「读到一半就 EOF」）
#if defined(_WIN32)
using FileOffset = long long;
FileOffset tellFile(std::FILE* f) { return static_cast<FileOffset>(_ftelli64(f)); }
bool seekFile(std::FILE* f, FileOffset offset) {
    return _fseeki64(f, offset, SEEK_SET) == 0;
}
#else
using FileOffset = long long;
FileOffset tellFile(std::FILE* f) { return static_cast<FileOffset>(std::ftell(f)); }
bool seekFile(std::FILE* f, FileOffset offset) {
    return std::fseek(f, static_cast<long>(offset), SEEK_SET) == 0;  // macOS/linux 的 long 是 64 位
}
#endif

bool isSupportedFormat(uint16_t tag, uint16_t bits) {
    if (tag == 1) {
        return bits == 8 || bits == 16 || bits == 24 || bits == 32;
    }
    if (tag == 3) {
        return bits == 32;
    }
    return false;
}

}  // namespace

bool readWavFile(const char* path, WavPcm& out, std::string& error) {
    out = WavPcm{};

    std::FILE* f = std::fopen(path, "rb");
    if (!f) {
        error = std::string("打不开文件: ") + path;
        return false;
    }

    unsigned char header[12] = {0};
    if (std::fread(header, 1, sizeof(header), f) != sizeof(header) ||
        std::memcmp(header, "RIFF", 4) != 0 || std::memcmp(header + 8, "WAVE", 4) != 0) {
        error = "不是 WAV 文件（缺 RIFF/WAVE 头）";
        std::fclose(f);
        return false;
    }

    FileOffset fileSize = 0;
    if (std::fseek(f, 0, SEEK_END) != 0 || (fileSize = tellFile(f)) < 0) {
        error = "读文件长度失败";
        std::fclose(f);
        return false;
    }
    if (!seekFile(f, 12)) {
        error = "读文件长度失败";
        std::fclose(f);
        return false;
    }

    uint16_t formatTag = 0;
    uint16_t channels = 0;
    uint32_t rate = 0;
    uint16_t blockAlign = 0;
    uint16_t bits = 0;
    FileOffset dataOffset = -1;
    uint32_t dataSize = 0;

    while (true) {
        unsigned char chunk[8] = {0};
        if (std::fread(chunk, 1, sizeof(chunk), f) != sizeof(chunk)) {
            break;  // 正常 EOF
        }
        const uint32_t size = le32(chunk + 4);
        const FileOffset payload = tellFile(f);
        if (payload < 0) {
            break;
        }

        if (std::memcmp(chunk, "fmt ", 4) == 0) {
            unsigned char fmt[40] = {0};
            const size_t want = size < sizeof(fmt) ? static_cast<size_t>(size) : sizeof(fmt);
            if (want < 16 || std::fread(fmt, 1, want, f) != want) {
                error = "fmt 块不完整";
                std::fclose(f);
                return false;
            }
            formatTag = le16(fmt);
            channels = le16(fmt + 2);
            rate = le32(fmt + 4);
            blockAlign = le16(fmt + 12);
            bits = le16(fmt + 14);
            if (formatTag == 0xFFFE) {
                // WAVE_FORMAT_EXTENSIBLE：真正的格式在 SubFormat GUID 的头两个字节
                if (want < 40) {
                    error = "WAVE_FORMAT_EXTENSIBLE 的 fmt 块不足 40 字节";
                    std::fclose(f);
                    return false;
                }
                formatTag = le16(fmt + 24);
            }
        } else if (std::memcmp(chunk, "data", 4) == 0) {
            const FileOffset remain = fileSize - payload;
            const uint32_t available = remain > 0 ? static_cast<uint32_t>(remain) : 0u;
            // size 为 0 表示「到文件尾」（流式写出的 WAV 常见）
            dataSize = (size == 0) ? available : (size > available ? available : size);
            dataOffset = payload;
        }

        const FileOffset next = payload + static_cast<FileOffset>(size) + static_cast<FileOffset>(size & 1u);
        if (next <= payload || !seekFile(f, next)) {
            break;
        }
    }

    if (dataOffset < 0) {
        error = "没有 data 块";
        std::fclose(f);
        return false;
    }
    if (channels == 0 || channels > 8) {
        error = "声道数不支持（1..8）";
        std::fclose(f);
        return false;
    }
    if (rate < 1000 || rate > 384000) {
        error = "采样率不支持（1k..384k）";
        std::fclose(f);
        return false;
    }
    if (!isSupportedFormat(formatTag, bits)) {
        char buf[128];
        std::snprintf(buf, sizeof(buf),
                      "不支持的格式（tag=%u, bits=%u）：只支持整数 PCM 8/16/24/32 与 float32",
                      static_cast<unsigned>(formatTag), static_cast<unsigned>(bits));
        error = buf;
        std::fclose(f);
        return false;
    }

    const size_t bytesPerSample = bits / 8u;
    const size_t minStride = bytesPerSample * channels;
    // blockAlign 一般等于 minStride；个别工具写成更大的值（容器对齐），
    // 按 stride 走才不会错位
    const size_t stride = blockAlign >= minStride ? static_cast<size_t>(blockAlign) : minStride;
    const size_t frames = dataSize / stride;
    if (frames == 0) {
        error = "data 块里没有样本";
        std::fclose(f);
        return false;
    }

    if (!seekFile(f, dataOffset)) {
        error = "定位 data 块失败";
        std::fclose(f);
        return false;
    }

    // **分块读**，不把整个 data 块再拷一份：三小时 48k 立体声 float 是 2.7 GB，
    // 多一份拷贝就是多一次 OOM 的机会。块大小只影响 IO 次数，不影响结果
    const size_t blockFrames = 65536;
    std::vector<unsigned char> raw(std::min(blockFrames, frames) * stride, 0);
    out.interleaved.resize(frames * channels);
    const bool isFloat = (formatTag == 3);
    size_t done = 0;
    while (done < frames) {
        const size_t want = std::min(blockFrames, frames - done);
        const size_t bytes = want * stride;
        if (std::fread(raw.data(), 1, bytes, f) != bytes) {
            error = "data 块读取不完整";
            std::fclose(f);
            return false;
        }
        for (size_t i = 0; i < want; ++i) {
            const unsigned char* frame = raw.data() + i * stride;
            for (size_t c = 0; c < channels; ++c) {
                out.interleaved[(done + i) * channels + c] =
                    decodeSample(frame + c * bytesPerSample, bits, isFloat);
            }
        }
        done += want;
    }
    std::fclose(f);
    out.sampleRate = rate;
    out.channels = channels;
    out.bitsPerSample = bits;
    out.floatFormat = isFloat;
    return true;
}

std::vector<float> downmixToMono(const WavPcm& wav) {
    const size_t channels = wav.channels;
    if (channels == 0) {
        return {};
    }
    const size_t frames = wav.interleaved.size() / channels;
    if (channels == 1) {
        return wav.interleaved;
    }

    std::vector<float> peak(channels, 0.0f);
    for (size_t i = 0; i < frames; ++i) {
        for (size_t c = 0; c < channels; ++c) {
            const float v = std::fabs(wav.interleaved[i * channels + c]);
            if (v > peak[c]) {
                peak[c] = v;
            }
        }
    }

    std::vector<size_t> active;
    active.reserve(channels);
    for (size_t c = 0; c < channels; ++c) {
        if (peak[c] > 0.0f) {
            active.push_back(c);
        }
    }
    if (active.empty()) {
        return std::vector<float>(frames, 0.0f);  // 整段数字静音
    }

    const float scale = 1.0f / static_cast<float>(active.size());
    std::vector<float> out(frames, 0.0f);
    for (size_t i = 0; i < frames; ++i) {
        float sum = 0.0f;
        for (size_t idx : active) {
            sum += wav.interleaved[i * channels + idx];
        }
        out[i] = sum * scale;
    }
    return out;
}

std::vector<float> resampleLinear(const std::vector<float>& in, double inRate, double outRate) {
    if (in.empty() || inRate <= 0.0 || outRate <= 0.0) {
        return {};
    }
    if (std::fabs(inRate - outRate) < 1e-9) {
        return in;  // 已经是要的采样率：逐样本拷贝，不留任何插值误差
    }

    const double exact = static_cast<double>(in.size()) * outRate / inRate;
    const size_t outLen = static_cast<size_t>(std::llround(exact));
    std::vector<float> out(outLen, 0.0f);

    const double ratio = inRate / outRate;  // 每个输出样本前进多少输入样本
    const size_t last = in.size() - 1;
    for (size_t i = 0; i < outLen; ++i) {
        const double pos = static_cast<double>(i) * ratio;
        size_t idx = static_cast<size_t>(pos);
        if (idx >= last) {
            out[i] = in[last];
            continue;
        }
        const float frac = static_cast<float>(pos - static_cast<double>(idx));
        out[i] = in[idx] * (1.0f - frac) + in[idx + 1] * frac;
    }
    return out;
}

bool loadWav16kMono(const char* path, std::vector<float>& out, std::string& error) {
    WavPcm wav;
    if (!readWavFile(path, wav, error)) {
        return false;
    }
    std::vector<float> mono = downmixToMono(wav);
    if (mono.empty()) {
        error = "下混之后没有样本";
        return false;
    }
    out = resampleLinear(mono, static_cast<double>(wav.sampleRate), kWhisperSampleRate);
    if (out.empty()) {
        error = "重采样之后没有样本";
        return false;
    }
    return true;
}

}  // namespace ctw
