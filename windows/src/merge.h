// 跨窗去重合并。移植自 macOS 版 Sources/Transcription/WhisperWindowMerger.swift
// 的三趟匹配 + 补定稿策略（那边有 900 行注释解释每个阈值是怎么定的，这里只留
// 结论和被实测推翻过的写法）。
//
// **纯函数**：不碰模型、不碰磁盘，所以能被构造出来的窗口序列钉住。

#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace ctw {

/// 一段转写结果。时间是**整段录音的全局毫秒**（已加上窗起点）。
struct Segment {
    int startMillis = 0;
    int endMillis = 0;
    std::string text;
    /// 弱语义：已被两个窗口独立确认，或已滑出「还能被覆盖」的范围。
    /// 不承诺文本从此不再变——后续窗按文本判据仍可能改写它（与 macOS 一致）。
    bool isFinal = false;
};

enum class TextRelation {
    Same,      ///< 归一化后相同 / 一个包含另一个
    Similar,   ///< 编辑距离 ≤ 较长者的 20%
    Different,
};

struct TextRelationResult {
    TextRelation relation = TextRelation::Different;
    size_t shorterLength = 0;  ///< 归一化后较短那条的**字符**数（不是字节）
};

/// 剥掉空白与标点后比较（定稿时识别器可能补标点，带标点比会把同一句判成两句）。
/// 20% 的阈值不给下限兜底：「第一点」和「第二点」只差一个字，必须判 different。
TextRelationResult classifyText(const std::string& a, const std::string& b);

struct MergeInput {
    /// 已合并的段（全局时间）
    std::vector<Segment> existing;
    /// 本窗识别结果，时间是**相对本窗起点**
    std::vector<Segment> windowSegments;
    int windowStartMillis = 0;
    /// 上一窗尾部（相对上一窗起点），用来判「两窗一致」定稿
    std::vector<Segment> previousTail;
    int previousWindowStartMillis = 0;
    int stepMillis = 3000;
};

struct MergeOutput {
    std::vector<Segment> segments;  ///< 按 startMillis 稳定排序
    /// 本窗应传给下一次合并的尾部（相对本窗起点）：结束时间 > 步长的那些段
    std::vector<Segment> pendingTail;
    std::vector<std::string> changes;  ///< 供日志复核
};

/// 合并一窗。
///
/// 三趟匹配（顺序与 macOS 相同，不能调换）：
/// 1. `.same` 且短者 ≥ 6 字：不看时间（换窗后同一句的时间戳会整体平移），
///    但**有上界**——候选与已有段的时间间隔必须 ≤ 一个步长。没有这个上界，
///    老师隔十几秒重复一句口头禅会被当成「同一句」，旧段的文本和时间戳被搬到
///    当前时刻（时间线损坏，那次重复也没留下自己的段）。
/// 2. `.similar` 且区间距离 ≤ 1 秒：盖住「同一句被重识别成重叠但错位的一版」。
/// 3. 时间真重叠且未定稿：视为内容修正，但先做**文本归属守卫**——若候选文本
///    明确属于另一个已有段，则不许按时间收编（否则整句原文会被覆盖）。
MergeOutput mergeWindow(const MergeInput& input, size_t scanBackLimit = 5);

}  // namespace ctw
