// WAV 读取 + 下混 + 重采样。**不依赖 whisper**，所以单元测试可以单独编它。
//
// 为什么自己解 RIFF 而不引第三方库：切片只需要「文件头 → float 交错样本」
// 这一件事，量不到 300 行；引入 dr_wav / libsndfile 会把 Windows 构建多拉一个
// 依赖，而这个目录的存在意义正是「一条链最短能有多短」。

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace ctw {

/// 解出来的 WAV。样本已归一化到 [-1, 1]，交错排列（frame0[ch0,ch1,...], frame1[...]）。
struct WavPcm {
    std::vector<float> interleaved;
    uint32_t sampleRate = 0;
    uint16_t channels = 0;
    uint16_t bitsPerSample = 0;
    /// true = IEEE float（wFormatTag 3），false = 整数 PCM
    bool floatFormat = false;
};

/// 读 WAV。支持：
/// - 整数 PCM 8/16/24/32 bit（8 bit 按无符号处理，这是 RIFF 的规定）
/// - IEEE float 32 bit
/// - WAVE_FORMAT_EXTENSIBLE（0xFFFE，取子格式）
/// - fmt 块与 data 块顺序任意（data 在前也能读）
/// - 奇数长度的块补齐字节
///
/// 失败时 `error` 里是中文原因，返回 false。
bool readWavFile(const char* path, WavPcm& out, std::string& error);

/// 下混成单声道。
///
/// 规则：**只对非全零声道取平均**。理由来自真实课堂录音的两种形态：
/// - 双声道是同一声源（立体声话筒）→ 取平均，信噪比最好；
/// - 只有一路接了话筒（USB 单声道设备常见，另一路整段数字静音）→ 取平均会
///   把幅度砍半（-6 dB），而门控的 p90 判据贴着 0.01，砍半足以把真人说话
///   推进「静音」那一边。跳过全零声道就不会出现这种误判。
///
/// 全零输入返回全零。
std::vector<float> downmixToMono(const WavPcm& wav);

/// 线性插值重采样。
///
/// 为什么是线性插值、不引 libsamplerate（见 README「为什么不用 libsamplerate」）：
/// 目标是把课堂录音（44.1/48 kHz）落到 whisper 要的 16 kHz。线性插值在
/// 「通带内平坦度」和「抗镜像」上都劣于多相 FIR，但这里的信号是语音，
/// 8 kHz 以上的能量本来就少，而 whisper 的 log-mel 前端对那点残留别名不敏感
/// （在真实录音上验过：重采样前后转写文本一致）。代价换来的是一条没有
/// 第三方依赖、没有状态、可以逐样本写进单元测试的实现。
///
/// 输出长度 = round(in.size() * outRate / inRate)；直流分量严格保持
/// （常数输入 → 同一常数，插值权重和为 1）。
std::vector<float> resampleLinear(const std::vector<float>& in, double inRate, double outRate);

/// 一步到位：WAV → 16 kHz 单声道 float。whisper 只吃这个格式。
/// 源采样率已经是 16 kHz 时不做重采样（逐样本拷贝）。
bool loadWav16kMono(const char* path, std::vector<float>& out, std::string& error);

constexpr double kWhisperSampleRate = 16000.0;

}  // namespace ctw
