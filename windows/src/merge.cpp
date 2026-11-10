#include "merge.h"

#include <algorithm>
#include <cstdio>

namespace ctw {
namespace {

// MARK: - UTF-8 按码点处理

std::vector<uint32_t> decodeUtf8(const std::string& s) {
    std::vector<uint32_t> out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        uint32_t cp = 0;
        size_t len = 0;
        if (c < 0x80) {
            cp = c;
            len = 1;
        } else if ((c & 0xE0) == 0xC0) {
            cp = c & 0x1Fu;
            len = 2;
        } else if ((c & 0xF0) == 0xE0) {
            cp = c & 0x0Fu;
            len = 3;
        } else if ((c & 0xF8) == 0xF0) {
            cp = c & 0x07u;
            len = 4;
        } else {
            out.push_back(0xFFFD);
            ++i;
            continue;
        }
        if (i + len > s.size()) {
            out.push_back(0xFFFD);
            break;
        }
        bool ok = true;
        for (size_t k = 1; k < len; ++k) {
            const unsigned char cc = static_cast<unsigned char>(s[i + k]);
            if ((cc & 0xC0) != 0x80) {
                ok = false;
                break;
            }
            cp = (cp << 6) | (cc & 0x3Fu);
        }
        if (!ok) {
            out.push_back(0xFFFD);
            ++i;
            continue;
        }
        out.push_back(cp);
        i += len;
    }
    return out;
}

/// 与 macOS `TranscriptionEngine.matchIgnoredChars` 同一批字符（ASCII + 全角标点）
bool isIgnoredCodePoint(uint32_t cp) {
    switch (cp) {
        case ' ':
        case '\n':
        case '\r':
        case '\t':
        case 0x3002:  // 。
        case 0xFF0C:  // ，
        case 0x3001:  // 、
        case 0xFF1B:  // ；
        case 0xFF1A:  // ：
        case 0xFF01:  // ！
        case 0xFF1F:  // ？
        case 0x2026:  // …
        case '.':
        case ',':
        case ';':
        case ':':
        case '!':
        case '?':
            return true;
        default:
            return false;
    }
}

std::vector<uint32_t> normalizeForMatch(const std::string& text) {
    const std::vector<uint32_t> cps = decodeUtf8(text);
    std::vector<uint32_t> out;
    out.reserve(cps.size());
    for (uint32_t cp : cps) {
        if (!isIgnoredCodePoint(cp)) {
            out.push_back(cp);
        }
    }
    return out;
}

/// 编辑距离。输入已归一化、课堂段很少超过几百字，O(n·m) 完全够用。
size_t levenshtein(const std::vector<uint32_t>& a, const std::vector<uint32_t>& b) {
    if (a.empty()) {
        return b.size();
    }
    if (b.empty()) {
        return a.size();
    }
    std::vector<size_t> prev(b.size() + 1);
    std::vector<size_t> curr(b.size() + 1);
    for (size_t j = 0; j <= b.size(); ++j) {
        prev[j] = j;
    }
    for (size_t i = 0; i < a.size(); ++i) {
        curr[0] = i + 1;
        for (size_t j = 0; j < b.size(); ++j) {
            const size_t cost = (a[i] == b[j]) ? 0u : 1u;
            curr[j + 1] = std::min(std::min(prev[j + 1] + 1, curr[j] + 1), prev[j] + cost);
        }
        std::swap(prev, curr);
    }
    return prev[b.size()];
}

bool containsRange(const std::vector<uint32_t>& haystack, const std::vector<uint32_t>& needle) {
    if (needle.empty() || needle.size() > haystack.size()) {
        return false;
    }
    const auto it = std::search(haystack.begin(), haystack.end(), needle.begin(), needle.end());
    return it != haystack.end();
}

// MARK: - 时间区间

int intervalGapMillis(const Segment& a, const Segment& b) {
    return std::max(0, std::max(a.startMillis - b.endMillis, b.startMillis - a.endMillis));
}

bool overlaps(const Segment& a, const Segment& b) {
    return a.startMillis < b.endMillis && a.endMillis > b.startMillis;
}

Segment toGlobal(const Segment& s, int baseMillis) {
    Segment g = s;
    g.startMillis = s.startMillis + baseMillis;
    g.endMillis = s.endMillis + baseMillis;
    return g;
}

/// 稳定性：候选在上一窗尾部里存在，且时间重叠、文本 `.same` 且短者 ≥ 6 字
bool isStable(const Segment& candidate, const std::vector<Segment>& previousTailGlobal) {
    for (const Segment& prev : previousTailGlobal) {
        if (!overlaps(candidate, prev)) {
            continue;
        }
        const TextRelationResult rel = classifyText(candidate.text, prev.text);
        if (rel.relation == TextRelation::Same && rel.shorterLength >= 6) {
            return true;
        }
    }
    return false;
}

/// 候选的文本是否明确属于**别的**段（第三趟的守卫）
bool hasTextAffinityElsewhere(const std::vector<Segment>& existing,
                              size_t lower,
                              const Segment& candidate,
                              size_t excluding) {
    for (size_t i = lower; i < existing.size(); ++i) {
        if (i == excluding) {
            continue;
        }
        const TextRelationResult rel = classifyText(existing[i].text, candidate.text);
        if (rel.relation == TextRelation::Same && rel.shorterLength >= 6) {
            return true;
        }
        if (rel.relation == TextRelation::Similar) {
            return true;
        }
    }
    return false;
}

/// 三趟匹配。返回 false 表示「新建一段」。
bool matchIndex(const std::vector<Segment>& existing,
                const Segment& candidate,
                size_t scanBackLimit,
                int maxIntervalGapMillis,
                size_t& outIndex,
                bool& guardTripped) {
    guardTripped = false;
    if (existing.empty()) {
        return false;
    }
    const size_t lower = existing.size() > scanBackLimit ? existing.size() - scanBackLimit : 0;

    // 第一趟：same(≥6) + 间隔 ≤ 一个步长
    for (size_t i = existing.size(); i > lower; --i) {
        const size_t index = i - 1;
        if (intervalGapMillis(existing[index], candidate) > maxIntervalGapMillis) {
            continue;
        }
        const TextRelationResult rel = classifyText(existing[index].text, candidate.text);
        if (rel.relation == TextRelation::Same && rel.shorterLength >= 6) {
            outIndex = index;
            return true;
        }
    }

    // 第二趟：similar + 区间距离 ≤ 1 秒
    for (size_t i = existing.size(); i > lower; --i) {
        const size_t index = i - 1;
        if (classifyText(existing[index].text, candidate.text).relation != TextRelation::Similar) {
            continue;
        }
        if (intervalGapMillis(existing[index], candidate) > 1000) {
            continue;
        }
        outIndex = index;
        return true;
    }

    // 第三趟：时间重叠且未定稿 + 文本归属守卫
    for (size_t i = existing.size(); i > lower; --i) {
        const size_t index = i - 1;
        if (existing[index].isFinal) {
            continue;
        }
        if (!overlaps(existing[index], candidate)) {
            continue;
        }
        if (hasTextAffinityElsewhere(existing, lower, candidate, index)) {
            guardTripped = true;
            return false;
        }
        outIndex = index;
        return true;
    }

    return false;
}

std::string truncated(const std::string& text) {
    // 只用于日志：按字节截到 30 以内，UTF-8 中间截断在日志里只是显示瑕疵
    return text.size() > 30 ? text.substr(0, 30) : text;
}

}  // namespace

TextRelationResult classifyText(const std::string& a, const std::string& b) {
    TextRelationResult result;
    const std::vector<uint32_t> na = normalizeForMatch(a);
    const std::vector<uint32_t> nb = normalizeForMatch(b);
    if (na.empty() || nb.empty()) {
        return result;  // Different
    }
    if (na == nb || containsRange(na, nb) || containsRange(nb, na)) {
        result.relation = TextRelation::Same;
        result.shorterLength = std::min(na.size(), nb.size());
        return result;
    }
    const size_t distance = levenshtein(na, nb);
    const size_t longer = std::max(na.size(), nb.size());
    if (distance * 5 <= longer) {
        result.relation = TextRelation::Similar;
    }
    result.shorterLength = std::min(na.size(), nb.size());
    return result;
}

MergeOutput mergeWindow(const MergeInput& input, size_t scanBackLimit) {
    MergeOutput out;
    out.segments = input.existing;

    std::vector<Segment> candidates;
    candidates.reserve(input.windowSegments.size());
    for (const Segment& seg : input.windowSegments) {
        candidates.push_back(toGlobal(seg, input.windowStartMillis));
    }

    // 本窗的尾部：结束时间超出一步长的段，下一窗还会再看到它们
    for (const Segment& seg : input.windowSegments) {
        if (seg.endMillis > input.stepMillis) {
            out.pendingTail.push_back(seg);
        }
    }

    std::vector<Segment> previousTailGlobal;
    previousTailGlobal.reserve(input.previousTail.size());
    for (const Segment& seg : input.previousTail) {
        previousTailGlobal.push_back(toGlobal(seg, input.previousWindowStartMillis));
    }

    for (const Segment& candidate : candidates) {
        size_t index = 0;
        bool guardTripped = false;
        if (matchIndex(out.segments, candidate, scanBackLimit, input.stepMillis, index, guardTripped)) {
            const bool shouldStabilize = !out.segments[index].isFinal && isStable(candidate, previousTailGlobal);
            out.segments[index] = candidate;  // 文本、时间戳一起换（换的是一整段的版本）
            if (shouldStabilize) {
                out.segments[index].isFinal = true;
                out.changes.push_back("落定（两窗一致）：" + truncated(candidate.text));
            } else {
                out.changes.push_back("刷新：" + truncated(candidate.text));
            }
        } else {
            out.segments.push_back(candidate);
            out.changes.push_back((guardTripped ? std::string("新增（文本归属在别处）：")
                                               : std::string("新增：")) +
                                  truncated(candidate.text));
        }
    }

    // 补定稿：滑出「还能被覆盖」范围的段，从此不会再有任何窗口按时间重叠碰到它，
    // 两窗一致的判据对它们永远为假。少了这一步，这些段会一直停在临时态。
    // ⚠️ 前提是 stepMillis > 0（调用方按步长推进窗口起点）。
    const int coverageEndMillis = input.windowStartMillis + input.stepMillis;
    for (Segment& seg : out.segments) {
        if (!seg.isFinal && seg.endMillis <= coverageEndMillis) {
            seg.isFinal = true;
            out.changes.push_back("补定稿（滑出覆盖）：" + truncated(seg.text));
        }
    }

    std::stable_sort(out.segments.begin(), out.segments.end(),
                     [](const Segment& a, const Segment& b) { return a.startMillis < b.startMillis; });
    return out;
}

}  // namespace ctw
