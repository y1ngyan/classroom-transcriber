// windows 切片的单元测试。**不依赖 whisper、不依赖模型、不依赖网络**。
//
// 覆盖四块，每一块都钉的是「改造前会静默错掉」的那类东西：
//   1. 重采样：输出长度、直流分量、下混规则（真实录音格式 44.1k/48k/float32/双声道）
//   2. 门控：判据边界值（0.10 / 0.01 是开区间）、构造波形上的判定方向
//   3. 取窗与时间戳映射：10 秒窗 / 3 秒步长、收尾窗、毫秒换算
//   4. 跨窗合并：重叠去重、不许吞内容、时间戳换算
//
// 断言里凡是「阈值」都**写死数值**，不拿实现再算一遍——重复实现算出来的
// 期望值只能证明两处代码一致，证明不了它们是对的。

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "audio.h"
#include "merge.h"
#include "speech_gate.h"
#include "window_plan.h"

namespace {

int g_checks = 0;
int g_failures = 0;
std::string g_section;

void check(bool cond, const char* expr, int line) {
    ++g_checks;
    if (!cond) {
        ++g_failures;
        std::printf("  ❌ [%s] 第 %d 行: %s\n", g_section.c_str(), line, expr);
    }
}

#define CHECK(cond) check((cond), #cond, __LINE__)

/// 越界安全访问：变异（比如去掉收尾窗）会让容器变短，直接下标就是段错误，
/// 而段错误在 CI 日志里等于「不知道哪条断言红了」。返回默认值，让断言自己说话。
template <typename T>
const T& at(const std::vector<T>& v, size_t i) {
    static const T fallback{};
    return i < v.size() ? v[i] : fallback;
}

template <typename T>
const T& backOf(const std::vector<T>& v) {
    static const T fallback{};
    return v.empty() ? fallback : v.back();
}

void section(const char* name) {
    g_section = name;
    std::printf("── %s\n", name);
}

// MARK: - 波形构造（确定性，不用随机数：随机数会让「为什么过」不可复现）

std::vector<float> makeTone(double seconds, double rate, float amplitude, double freq) {
    const size_t n = static_cast<size_t>(seconds * rate);
    std::vector<float> out(n, 0.0f);
    for (size_t i = 0; i < n; ++i) {
        out[i] = amplitude * static_cast<float>(std::sin(2.0 * 3.14159265358979323846 * freq *
                                                         static_cast<double>(i) / rate));
    }
    return out;
}

std::vector<float> makeConst(double seconds, double rate, float value) {
    return std::vector<float>(static_cast<size_t>(seconds * rate), value);
}

/// LCG 噪声：与 macOS 自检同一套写法，保证同一条用例在任何机器上给出同一个数
std::vector<float> makeNoise(double seconds, double rate, float amplitude, uint64_t seed) {
    const size_t n = static_cast<size_t>(seconds * rate);
    std::vector<float> out(n, 0.0f);
    uint64_t state = seed * 6364136223846793005ULL + 1442695040888963407ULL;
    for (size_t i = 0; i < n; ++i) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        const double unit = static_cast<double>(state >> 11) / static_cast<double>(1ULL << 53) * 2.0 - 1.0;
        out[i] = amplitude * static_cast<float>(unit);
    }
    return out;
}

/// 说话 + 停顿交替（模拟真人语流）
std::vector<float> makeSpeechWithPauses(double seconds, double rate, float amplitude,
                                        double burst, double gap) {
    std::vector<float> out;
    const size_t total = static_cast<size_t>(seconds * rate);
    out.reserve(total + 1);
    while (out.size() < total) {
        const std::vector<float> tone = makeTone(burst, rate, amplitude, 300.0);
        out.insert(out.end(), tone.begin(), tone.end());
        out.insert(out.end(), static_cast<size_t>(gap * rate), 0.0f);
    }
    out.resize(total);
    return out;
}

// MARK: - WAV 写盘夹具（用于验证解析，不是被测代码）

void put16(std::vector<unsigned char>& buf, uint16_t v) {
    buf.push_back(static_cast<unsigned char>(v & 0xFF));
    buf.push_back(static_cast<unsigned char>((v >> 8) & 0xFF));
}

void put32(std::vector<unsigned char>& buf, uint32_t v) {
    buf.push_back(static_cast<unsigned char>(v & 0xFF));
    buf.push_back(static_cast<unsigned char>((v >> 8) & 0xFF));
    buf.push_back(static_cast<unsigned char>((v >> 16) & 0xFF));
    buf.push_back(static_cast<unsigned char>((v >> 24) & 0xFF));
}

void putTag(std::vector<unsigned char>& buf, const char* tag) {
    for (int i = 0; i < 4; ++i) {
        buf.push_back(static_cast<unsigned char>(tag[i]));
    }
}

/// 写一个 WAV。`samples` 是交错排列、归一化到 [-1,1] 的样本。
std::string writeWav(const std::string& name, uint32_t rate, uint16_t channels, uint16_t bits,
                     bool isFloat, const std::vector<float>& samples) {
    const std::filesystem::path path = std::filesystem::temp_directory_path() / name;
    std::vector<unsigned char> data;
    const size_t bytesPerSample = bits / 8u;
    data.reserve(samples.size() * bytesPerSample);
    for (float s : samples) {
        if (isFloat) {
            float v = s;
            unsigned char raw[4];
            std::memcpy(raw, &v, 4);
            for (int i = 0; i < 4; ++i) {
                data.push_back(raw[i]);
            }
            continue;
        }
        switch (bits) {
            case 8: {
                double v = static_cast<double>(s) * 127.0 + 128.0;
                v = v < 0 ? 0 : (v > 255 ? 255 : v);
                data.push_back(static_cast<unsigned char>(std::lround(v)));
                break;
            }
            case 16: {
                double v = static_cast<double>(s) * 32767.0;
                const int32_t iv = static_cast<int32_t>(std::lround(v));
                const uint16_t u = static_cast<uint16_t>(static_cast<int16_t>(iv));
                data.push_back(static_cast<unsigned char>(u & 0xFF));
                data.push_back(static_cast<unsigned char>((u >> 8) & 0xFF));
                break;
            }
            case 24: {
                double v = static_cast<double>(s) * 8388607.0;
                const int32_t iv = static_cast<int32_t>(std::lround(v));
                const uint32_t u = static_cast<uint32_t>(iv);
                data.push_back(static_cast<unsigned char>(u & 0xFF));
                data.push_back(static_cast<unsigned char>((u >> 8) & 0xFF));
                data.push_back(static_cast<unsigned char>((u >> 16) & 0xFF));
                break;
            }
            case 32: {
                double v = static_cast<double>(s) * 2147483647.0;
                const int32_t iv = static_cast<int32_t>(std::llround(v));
                const uint32_t u = static_cast<uint32_t>(iv);
                put32(data, u);
                break;
            }
            default:
                break;
        }
    }

    std::vector<unsigned char> file;
    putTag(file, "RIFF");
    put32(file, static_cast<uint32_t>(36 + data.size()));
    putTag(file, "WAVE");
    putTag(file, "fmt ");
    put32(file, 16);
    put16(file, static_cast<uint16_t>(isFloat ? 3 : 1));
    put16(file, channels);
    put32(file, rate);
    put32(file, rate * channels * static_cast<uint32_t>(bytesPerSample));
    put16(file, static_cast<uint16_t>(channels * bytesPerSample));
    put16(file, bits);
    putTag(file, "data");
    put32(file, static_cast<uint32_t>(data.size()));
    file.insert(file.end(), data.begin(), data.end());

    std::FILE* f = std::fopen(path.string().c_str(), "wb");
    if (!f) {
        std::printf("  ❌ 写不出夹具文件: %s\n", path.string().c_str());
        ++g_failures;
        return std::string();
    }
    std::fwrite(file.data(), 1, file.size(), f);
    std::fclose(f);
    return path.string();
}

double maxAbsDiff(const std::vector<float>& a, const std::vector<float>& b) {
    if (a.size() != b.size()) {
        return 1e9;
    }
    double worst = 0.0;
    for (size_t i = 0; i < a.size(); ++i) {
        worst = std::max(worst, std::fabs(static_cast<double>(a[i]) - static_cast<double>(b[i])));
    }
    return worst;
}

size_t zeroCrossings(const std::vector<float>& x) {
    size_t n = 0;
    for (size_t i = 1; i < x.size(); ++i) {
        if ((x[i - 1] <= 0.0f && x[i] > 0.0f) || (x[i - 1] > 0.0f && x[i] <= 0.0f)) {
            ++n;
        }
    }
    return n;
}

// MARK: - 一、重采样

void testResample() {
    section("重采样（44.1k/48k → 16k，线性插值）");

    // 长度：1 秒 44.1k → 恰好 16000 个 16k 样本
    {
        const std::vector<float> in = makeConst(1.0, 44100.0, 0.5f);
        const std::vector<float> out = ctw::resampleLinear(in, 44100.0, 16000.0);
        CHECK(out.size() == 16000);
        // 2 秒 48k → 恰好 32000
        const std::vector<float> in2 = makeConst(2.0, 48000.0, 0.5f);
        CHECK(ctw::resampleLinear(in2, 48000.0, 16000.0).size() == 32000);
        // 长度取**四舍五入**不是截断：1001 个 48k 样本 → 333.67 → 334（截断会得 333）
        std::vector<float> oddSamples(1001, 0.1f);
        CHECK(ctw::resampleLinear(oddSamples, 48000.0, 16000.0).size() == 334);
    }

    // 直流分量：常数输入必须原样输出（插值权重和为 1）。
    // 这条挡的是「按 int 截断做插值」「权重写反」「输出末尾多补一个 0」这三类
    {
        const std::vector<float> in = makeConst(1.0, 48000.0, 0.25f);
        const std::vector<float> out = ctw::resampleLinear(in, 48000.0, 16000.0);
        double worst = 0.0;
        for (float v : out) {
            worst = std::max(worst, std::fabs(static_cast<double>(v) - 0.25));
        }
        CHECK(worst < 1e-6);
        // 10 ms（441 样本）的短缓冲：输出 160 个，仍然全是 0.25
        const std::vector<float> shortIn = makeConst(0.01, 44100.0, 0.25f);
        const std::vector<float> shortOut = ctw::resampleLinear(shortIn, 44100.0, 16000.0);
        CHECK(shortOut.size() == 160);
        CHECK(shortOut.front() == 0.25f && shortOut.back() == 0.25f);
    }

    // 采样率已经一致时逐样本拷贝（不留插值误差）
    {
        const std::vector<float> in = makeNoise(0.5, 16000.0, 0.3f, 11);
        const std::vector<float> out = ctw::resampleLinear(in, 16000.0, 16000.0);
        CHECK(out == in);
    }

    // 线性斜坡：插值的**方向**要验，光验直流分量验不出来
    // （权重写反时常数输入照样是常数，只有斜率会把差暴露出来）
    {
        std::vector<float> in(44100);
        for (size_t i = 0; i < in.size(); ++i) {
            in[i] = static_cast<float>(i) / 44100.0f;
        }
        const std::vector<float> out = ctw::resampleLinear(in, 44100.0, 16000.0);
        CHECK(out.size() == 16000);
        double worst = 0.0;
        for (size_t i = 0; i < out.size(); ++i) {
            // 期望值直接写成「第 i 个输出样本对应的时间」，不拿实现再算一遍
            const double expected = static_cast<double>(i) / 16000.0;
            worst = std::max(worst, std::fabs(static_cast<double>(out[i]) - expected));
        }
        CHECK(worst < 1e-6);
    }

    // 频率是否保住：1 kHz 正弦，1 秒内过零次数应约为 2000
    {
        const std::vector<float> in = makeTone(1.0, 48000.0, 1.0f, 1000.0);
        const std::vector<float> out = ctw::resampleLinear(in, 48000.0, 16000.0);
        float peak = 0.0f;
        for (float v : out) {
            peak = std::max(peak, std::fabs(v));
        }
        CHECK(peak > 0.95f && peak < 1.01f);
        const size_t zc = zeroCrossings(out);
        CHECK(zc >= 1980 && zc <= 2020);
    }

    // 空输入不崩
    {
        CHECK(ctw::resampleLinear({}, 48000.0, 16000.0).empty());
        CHECK(ctw::resampleLinear(makeConst(0.1, 48000.0, 0.1f), 0.0, 16000.0).empty());
    }
}

// MARK: - 二、下混

void testDownmix() {
    section("下混（双声道 → 单声道）");

    // 两声道相同（立体声同一音源）：结果应等于那一份
    {
        ctw::WavPcm wav;
        wav.channels = 2;
        const std::vector<float> mono = makeNoise(0.1, 16000.0, 0.4f, 3);
        for (float v : mono) {
            wav.interleaved.push_back(v);
            wav.interleaved.push_back(v);
        }
        const std::vector<float> out = ctw::downmixToMono(wav);
        CHECK(out.size() == mono.size());
        CHECK(maxAbsDiff(out, mono) < 1e-6);
    }

    // 右声道整段数字静音（只接了一路话筒）：不能把幅度砍半
    {
        ctw::WavPcm wav;
        wav.channels = 2;
        const std::vector<float> mono = makeNoise(0.1, 16000.0, 0.4f, 5);
        for (float v : mono) {
            wav.interleaved.push_back(v);
            wav.interleaved.push_back(0.0f);
        }
        const std::vector<float> out = ctw::downmixToMono(wav);
        CHECK(maxAbsDiff(out, mono) < 1e-6);
    }

    // 两路都有效：取平均
    {
        ctw::WavPcm wav;
        wav.channels = 2;
        wav.interleaved = {0.5f, 0.1f, -0.4f, 0.2f};
        const std::vector<float> out = ctw::downmixToMono(wav);
        CHECK(out.size() == 2);
        CHECK(std::fabs(out[0] - 0.3f) < 1e-6f);
        CHECK(std::fabs(out[1] - (-0.1f)) < 1e-6f);
    }

    // 全零输入不崩、输出全零
    {
        ctw::WavPcm wav;
        wav.channels = 2;
        wav.interleaved = std::vector<float>(200, 0.0f);
        const std::vector<float> out = ctw::downmixToMono(wav);
        CHECK(out.size() == 100);
        CHECK(out[0] == 0.0f);
    }
}

// MARK: - 三、WAV 解析（真实录音会碰到的四种容器）

void testWavParsing() {
    section("WAV 解析（16/24/32-bit 整数、float32、双声道）");

    // 16 kHz / 16-bit 单声道
    {
        const std::vector<float> samples = {0.0f, 0.5f, -0.5f, 0.25f};
        const std::string path = writeWav("ct_test_s16.wav", 16000, 1, 16, false, samples);
        ctw::WavPcm wav;
        std::string err;
        CHECK(ctw::readWavFile(path.c_str(), wav, err));
        CHECK(wav.sampleRate == 16000);
        CHECK(wav.channels == 1);
        CHECK(wav.bitsPerSample == 16);
        CHECK(!wav.floatFormat);
        CHECK(wav.interleaved.size() == samples.size());
        CHECK(std::fabs(at(wav.interleaved, 1) - 0.5f) < 1e-4f);
        CHECK(std::fabs(at(wav.interleaved, 2) - (-0.5f)) < 1e-4f);
        std::filesystem::remove(path);
    }

    // 48 kHz / 32-bit float 双声道（真实课堂录音最常见的形态）
    {
        std::vector<float> interleaved;
        const std::vector<float> left = makeTone(0.1, 48000.0, 0.5f, 440.0);
        for (float v : left) {
            interleaved.push_back(v);
            interleaved.push_back(0.0f);
        }
        const std::string path = writeWav("ct_test_f32.wav", 48000, 2, 32, true, interleaved);
        ctw::WavPcm wav;
        std::string err;
        CHECK(ctw::readWavFile(path.c_str(), wav, err));
        CHECK(wav.sampleRate == 48000);
        CHECK(wav.channels == 2);
        CHECK(wav.bitsPerSample == 32);
        CHECK(wav.floatFormat);
        CHECK(wav.interleaved.size() == interleaved.size());
        CHECK(maxAbsDiff(wav.interleaved, interleaved) < 1e-7);

        // 一步到位：48k 双声道 → 16k 单声道
        std::vector<float> mono16k;
        CHECK(ctw::loadWav16kMono(path.c_str(), mono16k, err));
        CHECK(mono16k.size() == 1600);
        std::filesystem::remove(path);
    }

    // 44.1 kHz / 24-bit 双声道
    {
        std::vector<float> interleaved;
        for (int i = 0; i < 4410; ++i) {
            const float v = (i % 2 == 0) ? 0.5f : -0.5f;
            interleaved.push_back(v);
            interleaved.push_back(v);
        }
        const std::string path = writeWav("ct_test_s24.wav", 44100, 2, 24, false, interleaved);
        ctw::WavPcm wav;
        std::string err;
        CHECK(ctw::readWavFile(path.c_str(), wav, err));
        CHECK(wav.sampleRate == 44100);
        CHECK(wav.bitsPerSample == 24);
        CHECK(wav.interleaved.size() == interleaved.size());
        CHECK(std::fabs(at(wav.interleaved, 0) - 0.5f) < 1e-5f);
        CHECK(std::fabs(at(wav.interleaved, 1) - 0.5f) < 1e-5f);   // 同一帧的右声道
        CHECK(std::fabs(at(wav.interleaved, 2) - (-0.5f)) < 1e-5f);  // 负值：符号扩展对不对

        std::vector<float> mono16k;
        CHECK(ctw::loadWav16kMono(path.c_str(), mono16k, err));
        CHECK(mono16k.size() == 1600);  // 0.1 秒
        std::filesystem::remove(path);
    }

    // 8-bit 无符号（陷阱：128 是零点）
    {
        const std::vector<float> samples = {0.0f, 0.5f, -0.5f};
        const std::string path = writeWav("ct_test_u8.wav", 16000, 1, 8, false, samples);
        ctw::WavPcm wav;
        std::string err;
        CHECK(ctw::readWavFile(path.c_str(), wav, err));
        CHECK(wav.interleaved.size() == 3);
        CHECK(std::fabs(at(wav.interleaved, 0)) <= 1.0f / 128.0f);
        CHECK(std::fabs(at(wav.interleaved, 1) - 0.5f) < 0.01f);
        CHECK(std::fabs(at(wav.interleaved, 2) - (-0.5f)) < 0.01f);
        std::filesystem::remove(path);
    }

    // 不存在的文件：报错不崩
    {
        ctw::WavPcm wav;
        std::string err;
        CHECK(!ctw::readWavFile("/nonexistent/ct_test.wav", wav, err));
        CHECK(!err.empty());
    }
}

// MARK: - 四、门控

void testGate() {
    section("静音门控（判据边界与构造波形）");

    // 常量钉死：这两个数被改动，下面所有实测结论就都作废了
    CHECK(ctw::gate::kMinSpeechRatio == 0.10);
    CHECK(ctw::gate::kSpeechCeiling == 0.01);
    CHECK(ctw::gate::kFrameSeconds == 0.02);

    // 帧数：10 秒 16k → 500 个 20ms 帧
    {
        const std::vector<float> samples = makeConst(10.0, 16000.0, 0.0f);
        const ctw::GateReading reading = ctw::analyzeWindow(samples, 16000.0);
        CHECK(reading.frameCount == 500);
        CHECK(std::fabs(reading.windowSeconds - 10.0) < 1e-9);
    }

    // 该判静音的形态
    {
        CHECK(ctw::evaluateWindow(makeConst(10.0, 16000.0, 0.0f), 16000.0).isSilence);
        CHECK(ctw::evaluateWindow(makeNoise(10.0, 16000.0, 0.0002f, 1), 16000.0).isSilence);
        CHECK(ctw::evaluateWindow(makeNoise(10.0, 16000.0, 0.002f, 7), 16000.0).isSilence);
    }

    // 该判有声的形态（丢内容那一侧，同等重要）
    {
        const std::vector<float> speech = makeSpeechWithPauses(10.0, 16000.0, 0.05f, 1.0, 0.5);
        CHECK(!ctw::evaluateWindow(speech, 16000.0).isSilence);

        // 一半静音一半说话：句子之间的停顿不许把整窗带走
        std::vector<float> half = makeConst(5.0, 16000.0, 0.0f);
        const std::vector<float> tone = makeTone(5.0, 16000.0, 0.05f, 300.0);
        half.insert(half.end(), tone.begin(), tone.end());
        CHECK(!ctw::evaluateWindow(half, 16000.0).isSilence);

        // 电平均匀的连续人声（0.02、无停顿）：这是 p90 绝对上限存在的唯一理由。
        // 去掉第二条判据，这一条立刻变红
        CHECK(!ctw::evaluateWindow(makeTone(10.0, 16000.0, 0.02f, 300.0), 16000.0).isSilence);
    }

    // 已知误判：连续小声说话（p90 低于绝对上限）会被判成静音。
    // 钉住它是为了「哪天别人改了判据，这一条会红，而不是以为门控从不误判」
    {
        CHECK(ctw::evaluateWindow(makeTone(10.0, 16000.0, 0.006f, 300.0), 16000.0).isSilence);
    }

    // 判据边界：两条都是**开区间**（< 而不是 <=）
    {
        ctw::GateReading reading;
        reading.windowSeconds = 10.0;
        reading.frameCount = 500;
        reading.floor = 0.001;
        reading.median = 0.002;

        reading.speechRatio = 0.0999;
        reading.speech = 0.0099;
        CHECK(ctw::isSilence(reading));

        reading.speechRatio = 0.10;  // 恰好等于门：不算静音
        reading.speech = 0.0099;
        CHECK(!ctw::isSilence(reading));

        reading.speechRatio = 0.0999;
        reading.speech = 0.01;  // 恰好等于上限：不算静音
        CHECK(!ctw::isSilence(reading));

        reading.speechRatio = 0.09;  // 占比低但 p90 高
        reading.speech = 0.02;
        CHECK(!ctw::isSilence(reading));

        reading.speechRatio = 0.90;  // p90 低但占比高
        reading.speech = 0.001;
        CHECK(!ctw::isSilence(reading));

        ctw::GateReading empty;
        CHECK(!ctw::isSilence(empty));  // 空窗不判静音
        CHECK(!ctw::evaluateWindow({}, 16000.0).isSilence);
    }

    // 判静音时必须给得出原因（日志里要能复核）
    {
        const ctw::GateVerdict verdict = ctw::evaluateWindow(makeConst(10.0, 16000.0, 0.0f), 16000.0);
        CHECK(verdict.isSilence);
        CHECK(!verdict.reason.empty());
    }
}

// MARK: - 五、取窗与时间戳

void testWindowPlan() {
    section("取窗与时间戳（10 秒窗 / 3 秒步长）");

    const double rate = 16000.0;
    CHECK(ctw::plan::kWindowSeconds == 10.0);
    CHECK(ctw::plan::kStepSeconds == 3.0);
    CHECK(ctw::plan::kMinimumFlushSeconds == 1.0);

    // 30 秒：检查点 3..30，共 10 窗；前 3 窗是不足 10 秒的碎片，之后每次滑 3 秒
    {
        const std::vector<ctw::WindowSpan> windows = ctw::planWindows(30u * 16000u, rate);
        CHECK(windows.size() == 10);
        CHECK(at(windows, 0).startMillis == 0 && at(windows, 0).sampleCount == 3u * 16000u);
        CHECK(at(windows, 1).startMillis == 0 && at(windows, 1).sampleCount == 6u * 16000u);
        CHECK(at(windows, 2).startMillis == 0 && at(windows, 2).sampleCount == 9u * 16000u);
        CHECK(at(windows, 3).startMillis == 2000 && at(windows, 3).sampleCount == 10u * 16000u);
        CHECK(at(windows, 4).startMillis == 5000);
        CHECK(backOf(windows).startMillis == 20000);
        CHECK(backOf(windows).startSample + backOf(windows).sampleCount == 30u * 16000u);
    }

    // 10.5 秒：检查点 3/6/9 三窗，收尾补一窗 [0.5s, 10.5s]
    {
        const std::vector<ctw::WindowSpan> windows = ctw::planWindows(168000u, rate);  // 10.5s
        CHECK(windows.size() == 4);
        CHECK(backOf(windows).tailFlush);
        CHECK(backOf(windows).startMillis == 500);
        CHECK(backOf(windows).sampleCount == 160000u);
        CHECK(backOf(windows).startSample + backOf(windows).sampleCount == 168000u);
    }

    // 9.5 秒：最后只剩 0.5 秒，低于收尾门槛 → 不补窗（喂几百毫秒会编出幻觉文本）
    {
        const std::vector<ctw::WindowSpan> windows = ctw::planWindows(152000u, rate);
        CHECK(windows.size() == 3);
        CHECK(!backOf(windows).tailFlush);
        CHECK(backOf(windows).startMillis == 0 && backOf(windows).sampleCount == 144000u);
    }

    // 2 秒：一个收尾窗，起点 0
    {
        const std::vector<ctw::WindowSpan> windows = ctw::planWindows(32000u, rate);
        CHECK(windows.size() == 1);
        CHECK(at(windows, 0).startMillis == 0);
        CHECK(at(windows, 0).sampleCount == 32000u);
        CHECK(at(windows, 0).tailFlush);
    }

    // 0.5 秒：什么都不取
    {
        CHECK(ctw::planWindows(8000u, rate).empty());
        CHECK(ctw::planWindows(0u, rate).empty());
    }

    // 窗不越界、起点单调不减、毫秒换算正确
    {
        const std::vector<ctw::WindowSpan> windows = ctw::planWindows(95u * 16000u + 1234u, rate);
        CHECK(!windows.empty());
        size_t previousStart = 0;
        for (const ctw::WindowSpan& span : windows) {
            CHECK(span.startSample + span.sampleCount <= 95u * 16000u + 1234u);
            CHECK(span.startSample >= previousStart);
            CHECK(span.startMillis == static_cast<int>(span.startSample / 16u));
            previousStart = span.startSample;
        }
    }

    // 采样率不是 16k 时时间戳仍按真实采样率换算
    {
        CHECK(ctw::sampleToMillis(44100u, 44100.0) == 1000);
        CHECK(ctw::sampleToMillis(48000u, 48000.0) == 1000);
        CHECK(ctw::sampleToMillis(160u, 16000.0) == 10);
    }
}

// MARK: - 六、合并

namespace {

ctw::Segment seg(const std::string& text, int start, int end) {
    ctw::Segment s;
    s.startMillis = start;
    s.endMillis = end;
    s.text = text;
    return s;
}

/// 模拟生产：按序喂窗口，维护 merged / pendingTail / previousWindowStartMillis
struct Feeder {
    std::vector<ctw::Segment> merged;
    std::vector<ctw::Segment> pendingTail;
    int previousWindowStartMillis = 0;
    int stepMillis = 3000;

    void feed(int windowStartMillis, const std::vector<ctw::Segment>& segments) {
        ctw::MergeInput input;
        input.existing = merged;
        input.windowSegments = segments;
        input.windowStartMillis = windowStartMillis;
        input.previousTail = pendingTail;
        input.previousWindowStartMillis = previousWindowStartMillis;
        input.stepMillis = stepMillis;
        const ctw::MergeOutput out = ctw::mergeWindow(input);
        merged = out.segments;
        pendingTail = out.pendingTail;
        previousWindowStartMillis = windowStartMillis;
    }
};

}  // namespace

void testMerge() {
    section("跨窗合并（重叠去重 / 不许吞内容 / 时间戳）");

    // 文本关系：这是三趟匹配的地基
    {
        CHECK(ctw::classifyText("今天我们讲梯度下降", "今天我们讲梯度下降").relation == ctw::TextRelation::Same);
        // 标点差异必须归一化掉（定稿时识别器会补标点）
        const ctw::TextRelationResult punct =
            ctw::classifyText("今天我们讲梯度下降。", "今天我们讲梯度下降");
        CHECK(punct.relation == ctw::TextRelation::Same);
        CHECK(punct.shorterLength == 9);
        // 一字之差、长句 → similar
        CHECK(ctw::classifyText("梯度下降是一个优化算法", "梯度下降是一个优化方法").relation ==
              ctw::TextRelation::Similar);
        // 两个字之差、8 字句（25%）→ different：20% 的上界必须真的卡在 20%
        CHECK(ctw::classifyText("我们讲正则化方法", "我们讲正则化技巧").relation ==
              ctw::TextRelation::Different);
        // 一字之差、短句 → different（20% 阈值不给下限兜底）
        CHECK(ctw::classifyText("第一点", "第二点").relation == ctw::TextRelation::Different);
        CHECK(ctw::classifyText("", "第二点").relation == ctw::TextRelation::Different);
    }

    // 两个重叠窗报同一句：只能留一段
    {
        Feeder f;
        f.feed(0, {seg("今天我们讲梯度下降", 0, 3000), seg("它的核心思想是沿着负梯度方向迭代", 3000, 7000)});
        // 同一批句子在下一窗里被整体平移一个步长（换窗后 whisper 的时间戳会平移）
        f.feed(3000, {seg("今天我们讲梯度下降", 0, 3000), seg("它的核心思想是沿着负梯度方向迭代", 3000, 7000)});
        CHECK(f.merged.size() == 2);  // 不许重复
        CHECK(at(f.merged, 0).text == "今天我们讲梯度下降");
        CHECK(at(f.merged, 1).text == "它的核心思想是沿着负梯度方向迭代");
        // 时间戳取**新一窗**的版本（全局 = 窗起点 + 窗内偏移）。
        // 这是 macOS 版的既有取舍：同一句会被重识别若干次，合并后保留最后一次
        // 的位置，最多向前漂一个步长。不要在这里断言 0/3000——那是窗内偏移
        CHECK(at(f.merged, 0).startMillis == 3000);
        CHECK(at(f.merged, 1).startMillis == 6000);
        CHECK(at(f.merged, 0).isFinal && at(f.merged, 1).isFinal);  // 两窗一致 → 落定
    }

    // 相邻窗里是两句**不同**的话：不许合并
    {
        Feeder f;
        f.feed(0, {seg("今天我们讲梯度下降", 0, 3000)});
        f.feed(3000, {seg("学习率太大会震荡", 0, 3000)});
        CHECK(f.merged.size() == 2);
        CHECK(at(f.merged, 0).text == "今天我们讲梯度下降");
        CHECK(at(f.merged, 1).text == "学习率太大会震荡");
        CHECK(at(f.merged, 1).startMillis == 3000);
    }

    // 老师隔十几秒重复同一句口头禅：**必须留下两段**。
    // 第一趟匹配的上界是「一个步长」，没有它这里会被并成一段（内容丢失）
    {
        Feeder f;
        f.feed(0, {seg("同学们注意这里是重点", 0, 1000)});
        f.feed(9000, {seg("同学们注意这里是重点", 1000, 2000)});  // 全局 [10000,11000]
        CHECK(f.merged.size() == 2);
    }

    // 同一句在相邻窗里被重识别成「多几个字」：按 same 判据收敛成一段
    {
        Feeder f;
        f.feed(0, {seg("今天我们讲梯度下降", 0, 3000)});
        f.feed(3000, {seg("今天我们讲梯度下降算法", 0, 3500)});
        CHECK(f.merged.size() == 1);
        CHECK(at(f.merged, 0).text == "今天我们讲梯度下降算法");  // 后一版覆盖前一版
        CHECK(at(f.merged, 0).startMillis == 3000);
    }

    // 窗内文本换了（重叠但识别成不同句子、且该段未定稿）：视为修正，不新增
    {
        Feeder f;
        f.feed(0, {seg("这一行大概是什么意思呢", 4000, 6000)});
        f.feed(3000, {seg("这一行代码是什么意思", 2000, 4000)});  // 全局 [5000,7000]，重叠
        CHECK(f.merged.size() == 1);
        CHECK(at(f.merged, 0).text == "这一行代码是什么意思");
    }

    // pendingTail：只有结束时间超过一个步长的段才交给下一窗
    {
        ctw::MergeInput input;
        input.windowStartMillis = 0;
        input.stepMillis = 3000;
        input.windowSegments = {seg("早一点的句子", 0, 1000), seg("跨过步长的句子", 2000, 6000)};
        const ctw::MergeOutput out = ctw::mergeWindow(input);
        CHECK(out.pendingTail.size() == 1);
        CHECK(out.pendingTail[0].text == "跨过步长的句子");
        CHECK(out.pendingTail[0].startMillis == 2000);  // 相对窗起点，不是全局
    }

    // 合并结果按时间排序（新段迟到也不会打乱时间线）
    {
        Feeder f;
        f.feed(3000, {seg("后出现但位置靠后的一句", 4000, 6000)});  // 全局 [7000,9000]
        f.feed(6000, {seg("后一窗里却在更早位置的一句", 0, 1000)});  // 全局 [6000,7000]
        CHECK(f.merged.size() == 2);
        CHECK(at(f.merged, 0).startMillis == 6000);
        CHECK(at(f.merged, 1).startMillis == 7000);
    }

    // 一节课的合成序列：三窗、每窗都重复上一窗的内容，最终段数 = 真句数
    {
        Feeder f;
        f.feed(0, {seg("第一句讲的是梯度下降", 0, 3000), seg("第二句讲的是学习率", 3000, 6000)});
        f.feed(3000, {seg("第二句讲的是学习率", 0, 3000), seg("第三句讲的是动量", 3000, 6000)});
        f.feed(6000, {seg("第三句讲的是动量", 0, 3000), seg("第四句讲的是正则化", 3000, 6000)});
        CHECK(f.merged.size() == 4);
        CHECK(at(f.merged, 0).text == "第一句讲的是梯度下降");
        CHECK(at(f.merged, 1).text == "第二句讲的是学习率");
        CHECK(at(f.merged, 2).text == "第三句讲的是动量");
        CHECK(at(f.merged, 3).text == "第四句讲的是正则化");
        // 时间戳连续：每句间隔 3 秒（构造上如此）
        CHECK(at(f.merged, 1).startMillis == 3000);
        CHECK(at(f.merged, 2).startMillis == 6000);
        CHECK(at(f.merged, 3).startMillis == 9000);
    }

    // 空窗不改变已有内容
    {
        Feeder f;
        f.feed(0, {seg("这一句应该留下来", 0, 2000)});
        f.feed(3000, {});
        CHECK(f.merged.size() == 1);
        CHECK(at(f.merged, 0).text == "这一句应该留下来");
    }
}

}  // namespace

int main() {
    std::printf("windows 切片单元测试（不加载模型、不碰麦克风）\n");

    testResample();
    testDownmix();
    testWavParsing();
    testGate();
    testWindowPlan();
    testMerge();

    std::printf("\n共 %d 条断言，失败 %d 条\n", g_checks, g_failures);
    if (g_failures == 0) {
        std::printf("✅ 全部通过\n");
        return 0;
    }
    std::printf("❌ 有断言失败\n");
    return 1;
}
