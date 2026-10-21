#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P12-2 判据 ②③ 的比对器：拿两趟 `--whisper-window-file --dump-all` 的输出对账。

用法：
    python3 tools/probes/p12_2_gate_compare.py <参照臂.txt> <被测臂.txt> [--overlap-ms 500]
    python3 tools/probes/p12_2_gate_compare.py <真基线.txt> <参照臂.txt> --bridge

**参照臂不是真基线**：真基线（`6f664e8`）的 `--dump-all` 只打到秒、没有终点，
判不了「偏差 ≤ 500ms」；参照臂 = 同一份代码 + `--step 3.0`（取窗节奏与基线
逐字相同）+ 门控关，格式与被测臂一致。`--bridge` 就是证明这条替代成立的
那一步（见 `bridge()`）。

退出码：0 = 通过；1 = 红（逐条列出）；2 = 输入读不出来。

为什么要单独一个 python 而不是在 bash 里 grep：
  判据 ③ 是**逐段**的（每一段定稿文本都要在参照臂里找到对应、且起止偏差要
  小于重叠量），bash 里做这件事会写成一大坨 awk/while-read，而它本身
  又是一条要能变红的判据——写成看不懂的东西，红了也没人敢信。

**它只做对账，不做判定之外的加工**：文本怎么算「一致」、偏差怎么算，
都摆在 `judge_segments()` 里，一眼能读完。
"""

import os
import re
import sys

# ── 解析 ────────────────────────────────────────────────────────────────
#
# 段行（`--dump-all` 打的那种，`(state)` 是 P12-2 加的定稿标记）：
#     1 [00:00:09] (可信)[定稿] 9.600–19.600s 这句话是这一段的内容
SEG_RE = re.compile(
    r"^\s*(?:(\d+)\s+)?\[(\d{2}):(\d{2}):(\d{2})\]\s+\(([^)]*)\)\[(定稿|临时)\]"
    r"\s*(.*?)\s+([0-9]+\.[0-9]{3})–([0-9]+\.[0-9]{3})s\s(.*)$"
)
#
# 改造前（基线 `6f664e8`）的段行**是另一种形状**：只有秒级起点、没有结束
# 时间、也没有定稿标记——
#     1 [00:00:00] (存疑) (拍摄)
#     2 [00:00:10] (存疑) ✎2 谢谢大家的关注!
# 所以它单独一条正则。**它承载不了判据 ③**（那条要比毫秒级起止偏差，
# 比它的秒级分辨率还细），判据 ③ 拿的是「参照臂」（同代码换个步长，
# 格式与被测臂相同）；这条老格式只用来做**桥**（判据 ③b）：证明参照臂
# 确实复现了基线。
#
# 解析顺序不能反：新格式的段行也长得进这条老正则（它的 `[定稿] 9.6–19.6s`
# 会被当成正文），所以新格式必须先试
LEGACY_SEG_RE = re.compile(
    r"^\s*(\d+)\s+\[(\d{2}):(\d{2}):(\d{2})\]\s+\(([^)]*)\)\s*(.*)$"
)
# 老格式正文里的两个前缀标记：`❓L2`（提问检出）和 `✎3`（被改写次数）
LEGACY_MARK_RE = re.compile(r"^(?:❓L\d+\s*)?(?:✎\d+\s*)?")
SEGMENTS_RE = re.compile(r"^\s*段数 (\d+)（定稿 (\d+)）")
CHARS_RE = re.compile(r"^\s*总字数 (\d+)（最终输出）")
GATE_RE = re.compile(
    r"^\s*取窗 (\d+) · 跳过 (\d+)（([0-9.]+)%）· 跳过音频 ([0-9.]+) 秒 · 真的解了 (\d+) 窗")
CPU_RE = re.compile(
    r"^\s*转写耗时合计 ([0-9.]+) 秒（CPU·只算真解码的窗）· 离线全程 ([0-9.]+) 秒（墙钟）")
WINDOW_SUM_RE = re.compile(
    r"^\s*Whisper 滑窗 (\d+) 窗 · 单次转写 均 ([0-9.]+) / 中位 ([0-9.]+) / 最大 ([0-9.]+) 秒"
    r" · 步长 ([0-9.]+) 秒 → 占用 ([0-9.]+)%")
COVERAGE_RE = re.compile(r"^\s*覆盖率: 最晚段结束 ([0-9.]+) 秒 / 音频 ([0-9.]+) 秒 = ([0-9.]+)%")
HALLU_RE = re.compile(r"^─── 生产链路的幻觉过滤：丢了 (\d+) 段 ───")
HALLU_ZERO_RE = re.compile(r"^─── 生产链路的幻觉过滤：这一趟没丢任何段 ───")


class Arm:
    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        self.segments = []          # (start_s, end_s, is_final, text)
        self.count = self.finalized = self.chars = None
        self.gate = None            # (取窗, 跳过, 跳过率%, 跳过音频秒, 真的解了)
        self.cpu = self.wall = None
        self.window_count = self.window_mean = self.step = self.occupancy = None
        self.coverage_pct = self.coverage_end = self.audio_seconds = None
        self.hallucinations = None
        # 老格式（基线）解析到的段数。0 = 这一臂是新格式
        self.legacy_segments = 0
        with open(path, encoding="utf-8") as handle:
            for raw in handle:
                line = raw.rstrip("\n")
                if (match := SEG_RE.match(line)):
                    start = float(match.group(8))
                    end = float(match.group(9))
                    self.segments.append((start, end, match.group(6) == "定稿", match.group(10).strip()))
                    continue
                if (match := LEGACY_SEG_RE.match(line)):
                    # 老格式没有结束时间：结束位留 None（**不要拿起点凑**，
                    # 那会让「起点相同」伪造成「起止都相同」）。
                    # 也没有定稿标记：一律当候选（对「文本找不找得到」是宽的一边）
                    start = int(match.group(2)) * 3600 + int(match.group(3)) * 60 + int(match.group(4))
                    text = LEGACY_MARK_RE.sub("", match.group(6)).strip()
                    self.segments.append((float(start), None, True, text))
                    self.legacy_segments += 1
                    continue
                if (match := SEGMENTS_RE.match(line)):
                    self.count, self.finalized = int(match.group(1)), int(match.group(2))
                    continue
                if (match := CHARS_RE.match(line)):
                    self.chars = int(match.group(1))
                    continue
                if (match := GATE_RE.match(line)):
                    self.gate = (int(match.group(1)), int(match.group(2)), float(match.group(3)),
                                 float(match.group(4)), int(match.group(5)))
                    continue
                if (match := CPU_RE.match(line)):
                    self.cpu, self.wall = float(match.group(1)), float(match.group(2))
                    continue
                if (match := WINDOW_SUM_RE.match(line)):
                    self.window_count, self.window_mean = int(match.group(1)), float(match.group(2))
                    self.step, self.occupancy = float(match.group(5)), float(match.group(6))
                    continue
                if (match := COVERAGE_RE.match(line)):
                    self.coverage_end, self.audio_seconds = float(match.group(1)), float(match.group(2))
                    self.coverage_pct = float(match.group(3))
                    continue
                if (match := HALLU_RE.match(line)):
                    self.hallucinations = int(match.group(1))
                    continue
                if HALLU_ZERO_RE.match(line):
                    self.hallucinations = 0

    @property
    def finalized_segments(self):
        return [segment for segment in self.segments if segment[2]]

    @property
    def cpu_total(self):
        """解码 CPU 秒数。优先用门控那一段的「转写耗时合计」，没有就按
        「窗数 × 均耗时」算——**两者必须一致**，不一致说明有一臂的输出格式
        变了，那时宁可报 None 让人去看，也不要挑一个凑数"""
        if self.cpu is not None:
            return self.cpu
        if self.window_count is not None and self.window_mean is not None:
            return self.window_count * self.window_mean
        return None


# ── 判据 ③：文本对账 ────────────────────────────────────────────────────

def normalize(text):
    """比对用的归一：**只去空白**。

    刻意不做的两件事，各自有理由：
      · 不去标点——两臂送进 whisper 的是同一段音频，标点差异也是真差异；
      · 不去繁简——引擎出口已经过 `ChineseText.toSimplified`。
    去空白是因为段内换行/空格随窗口切分变，那与「内容有没有丢」无关"""
    return re.sub(r"\s+", "", text)


def text_relation(after_text, before_text):
    """文本一致、或互为前缀（判据 ③ 的原话）。返回 True/False 和说法"""
    a, b = normalize(after_text), normalize(before_text)
    if not a or not b:
        return False, "空文本"
    if a == b:
        return True, "一致"
    if a.startswith(b):
        return True, "改造后多出尾巴"
    if b.startswith(a):
        return True, "改造后少了尾巴"
    return False, "不一致"


def judge_segments(before, after, overlap_ms, out):
    """判据 ③ 本体：被测臂**每一段定稿文本**在参照臂里都能找到对应，
    且起止偏差 ≤ 重叠量。

    配对规则：文本能对上（一致或互为前缀）的候选里取**起点最近**的那一段。
    文本对不上的记为「文本缺失」；文本对上了但偏差超标的记为「时间超标」。
    两类都逐条打出来——只报个总数的话，核验侧没法自己复核是哪几句。
    """
    limit = overlap_ms / 1000.0
    before_final = before.finalized_segments
    after_final = after.finalized_segments
    text_miss, time_miss, matched = [], [], []

    # 改造后**一段定稿都没有**而改造前有：这不是「配对不上」，是整场被吞了。
    # 单列一条，因为变异①（阈值恒判静音）红的正是这里——那时 `text_miss`
    # 是空的，只看它就变成「没有配对失败」= 绿，判据会假通过
    if before_final and not after_final:
        out.append("─── 判据 ③（不许丢真人说话）：逐段文本对账 ───")
        out.append("  参照臂定稿 %d 段 · 被测臂定稿 0 段" % len(before_final))
        out.append("  ⛔ 改造后一段定稿都没有——真人说话被整场跳过")
        out.append("  （信息·不参与成败）参照臂的定稿段在被测臂里找不到对应的：%d 段"
                   % len(before_final))
        return False

    for start, end, _, text in after_final:
        candidates = [(b, text_relation(text, b[3])) for b in before_final]
        candidates = [(b, why) for b, (ok, why) in candidates if ok]
        if not candidates:
            text_miss.append((start, text))
            continue
        best, why = min(candidates, key=lambda pair: abs(pair[0][0] - start))
        d_start = abs(best[0] - start)
        # 任一侧是老格式（没有结束时间，None）时**只比起点**——不拿起点顶替
        # 终点，也不因此放行：比得少就是比得少，结果里会标出来。
        # 两侧都要判：这一条是 `TypeError: float - NoneType` 从真实跑里崩回来
        # 换来的（第一次跑，被测臂那一趟误用了基线二进制 → 它按老格式解析，
        # `end` 是 None）
        d_end = 0.0 if (best[1] is None or end is None) else abs(best[1] - end)
        if max(d_start, d_end) > limit:
            time_miss.append((start, text, best[0], best[1], d_start, d_end))
        else:
            matched.append((d_start, d_end))

    # 反方向的覆盖（**不是判据，是给核验侧看的信息**）：改造前的定稿段里
    # 有多少在改造后找不到对应。这个数大**不一定是丢内容**——改造前那句
    # 可能只是被并进了改造后的另一段（合并粒度不同），所以它单独列出来，
    # 不参与成败
    reverse_miss = 0
    for b in before_final:
        if not any(text_relation(a[3], b[3])[0] for a in after_final):
            reverse_miss += 1

    out.append("─── 判据 ③（不许丢真人说话）：逐段文本对账 ───")
    out.append("  参照臂定稿 %d 段 · 被测臂定稿 %d 段 · 重叠量上限 %dms"
               % (len(before_final), len(after_final), overlap_ms))
    out.append("  文本找到对应且起止偏差在限内：%d 段" % len(matched))
    if matched:
        worst = max(max(pair) for pair in matched)
        out.append("  最大偏差 %.3f 秒（限 %.3f 秒）" % (worst, limit))
    out.append("  文本找不到对应：%d 段" % len(text_miss))
    for start, text in text_miss[:20]:
        out.append("    ⛔ @%.3fs「%s」" % (start, text[:40]))
    out.append("  文本对上了但起止偏差超标：%d 段" % len(time_miss))
    for start, text, b_start, b_end, d_start, d_end in time_miss[:20]:
        # 参照臂是老格式（只有秒级起点、没有终点）时 `b_end` 是 None ——
        # 这一行曾经直接把它塞进 `%.3f`，`TypeError: must be real number,
        # not NoneType` 从真实跑里崩回来（基线那一趟就是老格式）
        span = "%.3f–%.3fs" % (b_start, b_end) if b_end is not None else "%.3f–?s" % b_start
        out.append("    ⛔ @%.3fs「%s」→ 参照臂 @%s（差 %.3f / %.3f 秒）"
                   % (start, text[:40], span, d_start, d_end))
    out.append("  （信息·不参与成败）参照臂的定稿段在被测臂里找不到对应的：%d 段"
               "——合并粒度不同也会造成这个数，它不等于丢内容"
               % reverse_miss)
    return not text_miss and not time_miss


# ── 判据 ③b：参照臂是不是真的复现了基线 ──────────────────────────────────

def bridge(baseline, ref, out):
    """桥：证明「参照臂」（同代码 + `--step 3.0` + 门控关）确实跑出了基线
    那条取窗路径。判据 ③ 用的是参照臂（理由见 `LEGACY_SEG_RE` 那段），
    所以必须先证参照臂代表得了「改造前」，否则 ③ 是对着一根没接上的线在量。

    比两件事，都是基线那份输出**给得出来**的：
      · 段数 / 总字数：两个计数必须相同
      · 逐段文本：基线每一段都要在参照臂里找得到（一致或互为前缀），
        且**起点**落在基线的秒级量化误差内（它的时间列只到秒，|Δ| ≤ 1 秒；
        参照臂是毫秒的，所以误差全部来自基线那边的截断）

    明确**不比**的：终点。基线根本不打终点，凑一个数出来只会让人以为比过
    """
    out.append("─── 判据 ③b（桥）：参照臂复现了基线吗 ───")
    if not baseline.legacy_segments:
        out.append("  ❌ 基线那一臂没解析出老格式的段行——它真的是基线二进制的输出吗？")
        return False
    if not ref.segments:
        out.append("  ❌ 参照臂一段都没有")
        return False
    out.append("  基线段行 %d 条（老格式：秒级起点、无终点）· 参照臂 %d 段"
               % (baseline.legacy_segments, len(ref.segments)))

    ok = True
    if baseline.count is not None and ref.count is not None and baseline.count != ref.count:
        out.append("  ❌ 段数不同：基线 %s · 参照臂 %s" % (baseline.count, ref.count))
        ok = False
    if baseline.chars is not None and ref.chars is not None and baseline.chars != ref.chars:
        out.append("  ❌ 总字数不同：基线 %s · 参照臂 %s" % (baseline.chars, ref.chars))
        ok = False

    misses, worst = [], 0.0
    for start, _, _, text in baseline.segments:
        candidates = [(r, text_relation(r[3], text)[0]) for r in ref.segments]
        candidates = [r for r, matched in candidates if matched]
        if not candidates:
            misses.append((start, text))
            continue
        best = min(candidates, key=lambda r: abs(r[0] - start))
        worst = max(worst, abs(best[0] - start))
    out.append("  基线每一段都在参照臂里找到对应：%d / %d 段"
               % (len(baseline.segments) - len(misses), len(baseline.segments)))
    out.append("  起点最大偏差 %.3f 秒（基线只到秒，容差就是它的量化步长 1 秒）" % worst)
    for start, text in misses[:20]:
        out.append("    ⛔ @%.0fs「%s」在参照臂里找不到" % (start, text[:40]))
    if misses or worst > 1.0:
        ok = False
    out.append("  结论：%s" % ("✅ 参照臂复现了基线" if ok else "❌ 桥没接上——判据 ③ 的参照臂不代表改造前"))
    return ok


# ── 判据 ②：跳过率与代价 ────────────────────────────────────────────────

def judge_skips(before, after, out):
    """判据 ② 的**打印**（成败由探针脚本判：这里只把数摆出来）。

    改造前那一臂没有门控那一段（那时的代码里没有这个东西），所以它的
    「跳过」是 0 / 未知——**不要拿 0 冒充「测出来是 0」**"""
    out.append("─── 判据 ②（正向）：跳过率与代价 ───")
    for arm in (before, after):
        if arm.gate:
            taken, skipped, rate, skipped_audio, decoded = arm.gate
            out.append("  %-10s 取窗 %d · 跳过 %d（%.1f%%）· 跳过音频 %.1f 秒 · 真的解了 %d 窗"
                       % (arm.name, taken, skipped, rate, skipped_audio, decoded))
            invariant = "恒等式：真的解了 == 取窗 - 跳过 → %s" % (
                "成立" if decoded == taken - skipped else "**不成立**")
            out.append("  %-10s %s" % ("", invariant))
        else:
            out.append("  %-10s 取窗/跳过：这一臂没有门控（改造前的代码里没有这个东西）" % arm.name)
        cpu = arm.cpu_total
        out.append("  %-10s 解码窗 %s · CPU %s 秒 · 墙钟 %s 秒 · 段 %s（定稿 %s）· 总字数 %s · 幻觉丢弃 %s"
                   % (arm.name,
                      arm.window_count if arm.window_count is not None else "?",
                      "%.1f" % cpu if cpu is not None else "?",
                      "%.1f" % arm.wall if arm.wall is not None else "?",
                      arm.count, arm.finalized, arm.chars,
                      arm.hallucinations if arm.hallucinations is not None else "?"))
        if arm.coverage_pct is not None:
            out.append("  %-10s 覆盖率 %.1f%%（最晚段结束 %.1f 秒 / 音频 %.1f 秒）"
                       % (arm.name, arm.coverage_pct, arm.coverage_end, arm.audio_seconds))
    before_cpu, after_cpu = before.cpu_total, after.cpu_total
    if before_cpu and after_cpu:
        out.append("  CPU 变化：%.1f → %.1f 秒（省 %.1f 秒，降到 %.0f%%）"
                   % (before_cpu, after_cpu, before_cpu - after_cpu,
                      after_cpu / before_cpu * 100))


def main():
    # 缺省 500ms = **实际**最大重叠量（标称 400ms，取窗落在 0.5 秒喂入块边界上，
    # 实际步长在 9.5/10.0 秒之间 → 实际重叠在 0/500ms 之间）。依据见
    # `p12_2_speech_gate.sh` 里 `OVERLAP_MS` 那段注释
    #
    # ⚠️ 参数要**按位吃**，不能「把不以 `--` 开头的都当地位置参数」——
    # `--overlap-ms 500` 的那个 `500` 不以 `--` 开头，那种写法会把它当成
    # 第三个位置参数，于是每次调用都打一遍用法、退出码 2（实测踩过：
    # 夹具测试里第一次跑就撞上）
    overlap_ms, bridge_mode = 500, False
    args, i = [], 0
    argv = sys.argv[1:]
    while i < len(argv):
        arg = argv[i]
        if arg == "--bridge":
            bridge_mode, i = True, i + 1
        elif arg.startswith("--overlap-ms="):
            overlap_ms, i = int(arg.split("=", 1)[1]), i + 1
        elif arg == "--overlap-ms":
            if i + 1 >= len(argv):
                print("❌ --overlap-ms 后面缺一个数字"); return 2
            overlap_ms, i = int(argv[i + 1]), i + 2
        elif arg.startswith("--"):
            # 不认识的开关**响亮拒绝**：静默忽略一个打错字的开关，
            # 会让「我以为按 500 判的」和「其实按缺省判的」长得一模一样
            print("❌ 不认识的开关：%s" % arg); return 2
        else:
            args.append(arg); i += 1
    if len(args) != 2:
        print(__doc__)
        return 2
    try:
        before, after = Arm(args[0]), Arm(args[1])
    except OSError as error:
        print("❌ 读不了输入：%s" % error)
        return 2
    # `--bridge`：把两个位置参数读成（真基线, 参照臂），只跑判据 ③b
    if bridge_mode:
        out = []
        ok = bridge(before, after, out)
        out.append("")
        out.append("判据 ③b 结论：%s" % ("✅ 通过" if ok else "❌ 红"))
        print("\n".join(out))
        return 0 if ok else 1
    # **只有参照那一臂**（第一个位置参数）段数为 0 才算「读不出来」：
    # 被测臂是 0 段是一个要判红的结论（见 `judge_segments`），
    # 不是输入格式的问题——把两者混起来看，变异①就会以「读不了输入」的方式红，
    # 那是误导
    if not before.segments:
        print("❌ %s 里一段都没解析出来——输入不是 --dump-all 的输出？" % before.path)
        return 2

    out = []
    judge_skips(before, after, out)
    out.append("")
    ok = judge_segments(before, after, overlap_ms, out)
    out.append("")
    out.append("判据 ③ 结论：%s" % ("✅ 通过" if ok else "❌ 红"))
    print("\n".join(out))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
