#!/usr/bin/env python3
"""阶段 3 §2 的阈值标定分析 —— 读 `--probe-only` 打出的 TSV，做统计与自助法。

用法:
    python3 tools/probes/p2_analyze.py /tmp/p3/s2_conf_*.txt
    python3 tools/probes/p2_analyze.py --labels tools/probes/p2_labels.tsv /tmp/p3/s2_conf_*.txt

为什么单独写一个脚本、而不是让 Swift 那边算完拉倒：
**置信区间要做自助法**，而那需要每段的原始逐字符值。Swift 侧只打印分布的分位数，
自助法要按「段」重采样、每轮重算判据，这在 Swift 里写起来和在这里写一样长，
但在这里改一行就能换个判据形状。

**这个脚本判的「崩坏」是人工标注，不是真值。** 标注是我读文本判的（`--labels`
给的那个文件），主观且会错。脚本能保证的只有「在给定标注下，这条线是这个表现」，
保证不了「标注是对的」——所以它同时打印标注的样本量和类别不平衡度。

判据形状与 `TranscriptQualityAssessor.grade(averageConfidence:lowConfidenceRatio:)`
严格一致：先判 poor（均值低 **或** 低置信占比高），再判 good（均值高 **且** 占比低），
其余 fair。
"""

import argparse
import glob
import random
import re
import statistics
import sys

TSV_BEGIN = "─── TSV（"
TSV_END = "─── TSV 结束 ───"

# 生产常数（Apple 标定），用来做基线对照
PROD = {"poor_ceiling": 0.70, "good_floor": 0.85,
        "poor_low_ratio": 0.30, "good_low_ratio": 0.15}


class Seg:
    __slots__ = ("source", "start_ms", "mean", "low_ratio", "chars", "text", "source_label")

    def __init__(self, source, start_ms, mean, low_ratio, chars, text):
        self.source, self.start_ms = source, start_ms
        self.mean, self.low_ratio = mean, low_ratio
        self.chars, self.text = chars, text

    def __repr__(self):
        return f"<Seg {self.mean:.3f} {self.text[:12]!r}>"


def parse_file(path):
    """从一份探针输出里取出 TSV 段。非 TSV 行一律忽略——探针输出里还有
    给人看的表和扫描结果，那些不是数据源。"""
    out, inside = [], False
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if line.startswith(TSV_BEGIN):
                inside = True
                continue
            if line.strip() == TSV_END:
                inside = False
                continue
            if not inside:
                continue
            parts = line.split("\t")
            if len(parts) != 5:
                continue
            start_ms, mean, low_ratio, chars, text = parts
            values = [float(v) for v in chars.split(",") if v] if chars else []
            out.append(Seg(path, int(start_ms), float(mean), float(low_ratio), values, text))
    return out


def quantiles(values, qs=(0.05, 0.25, 0.5, 0.75, 0.95)):
    if not values:
        return {}
    ordered = sorted(values)
    result = {}
    for q in qs:
        index = min(len(ordered) - 1, max(0, int(round(q * (len(ordered) - 1)))))
        result[q] = ordered[index]
    return result


def is_poor(seg, c):
    return seg.mean < c["poor_ceiling"] or seg.low_ratio > c["poor_low_ratio"]


def is_good(seg, c):
    return seg.mean >= c["good_floor"] and seg.low_ratio <= c["good_low_ratio"]


def line_stats(segments, constants):
    """按给定常数分档，返回 (good, fair, poor) 三个计数。"""
    g = f = p = 0
    for seg in segments:
        if is_poor(seg, constants):
            p += 1
        elif is_good(seg, constants):
            g += 1
        else:
            f += 1
    return g, f, p


def confusion(segments, labels, constants):
    """把「标注为崩坏」当正类，看这条判据抓得准不准。

    返回 (tp, fp, fn, tn)。判据的「异常」= poor 档。
    """
    tp = fp = fn = tn = 0
    for seg in segments:
        truth = labels[seg.source_label] == 1
        called = is_poor(seg, constants)
        if truth and called:
            tp += 1
        elif truth and not called:
            fn += 1
        elif not truth and called:
            fp += 1
        else:
            tn += 1
    return tp, fp, fn, tn


def balanced_accuracy(tp, fp, fn, tn):
    sens = tp / (tp + fn) if (tp + fn) else 0.0
    spec = tn / (tn + fp) if (tn + fp) else 0.0
    return (sens + spec) / 2


# 候选常数网格。故意取得比生产那套宽——标定要能看到「判据挪到这里会怎样」，
# 网格太窄就退化成「确认现状」。
POOR_CEILINGS = [0.85, 0.80, 0.75, 0.70, 0.65, 0.60, 0.55, 0.50, 0.45, 0.40]
GOOD_FLOORS = [0.90, 0.85, 0.80, 0.75]
POOR_LOW_RATIOS = [0.10, 0.20, 0.30, 0.40, 0.50, 0.60]
GOOD_LOW_RATIOS = [0.05, 0.10, 0.15, 0.20]


def best_on(segments, labels):
    """在标注上挑「平衡准确度最高」的那组常数。平手时取更靠近生产值的——
    平手说明数据分不开，那么「别乱动」比「挑个好看的」更对。"""
    best, best_score = None, -1.0
    for pc in POOR_CEILINGS:
        for gf in GOOD_FLOORS:
            if gf <= pc:
                continue
            for plr in POOR_LOW_RATIOS:
                for glr in GOOD_LOW_RATIOS:
                    c = {"poor_ceiling": pc, "good_floor": gf,
                         "poor_low_ratio": plr, "good_low_ratio": glr}
                    score = balanced_accuracy(*confusion(segments, labels, c))
                    tie = abs(pc - PROD["poor_ceiling"]) + abs(plr - PROD["poor_low_ratio"])
                    if score > best_score + 1e-9 or (
                        abs(score - best_score) <= 1e-9 and best and tie < best[1]
                    ):
                        best, best_score = (c, tie), score
    return best[0], best_score


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--labels", help="标注文件：每行 `<段序号>\t<0|1>`，1 = 崩坏")
    ap.add_argument("--bootstrap", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=20260922)
    args = ap.parse_args()

    paths = []
    for pattern in args.files:
        paths.extend(sorted(glob.glob(pattern)))
    if not paths:
        sys.exit("没有匹配到任何探针输出")

    per_file, all_segments = {}, []
    for path in paths:
        segments = parse_file(path)
        if not segments:
            print(f"⚠️ {path} 里没有 TSV 段（是不是没加 --probe-only？）")
            continue
        per_file[path] = segments
        all_segments.extend(segments)

    if not all_segments:
        sys.exit("所有文件都没有 TSV 段")

    print(f"═══ 样本：{len(per_file)} 条录音 · {len(all_segments)} 段 ═══")
    for path, segments in per_file.items():
        chars = [c for seg in segments for c in seg.chars]
        q = quantiles(chars)
        g, f, p = line_stats(segments, PROD)
        print(f"  {path.split('/')[-1]:<34} {len(segments):>4} 段 · {len(chars):>5} 字符"
              f" · 逐字符中位 {q.get(0.5, 0):.3f} / p05 {q.get(0.05, 0):.3f}"
              f" · 生产判据 可信 {g} / 存疑 {f} / 不可信 {p}")

    # ── 逐字符分布（这是 §2 直接要的那个「分布」）──
    chars = [c for seg in all_segments for c in seg.chars]
    q = quantiles(chars, (0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99))
    print("\n─── 逐字符置信度分布（全部录音合并）───")
    print("  n = %d" % len(chars))
    for key in sorted(q):
        print(f"    p{int(key * 100):<03d} {q[key]:.4f}")
    print(f"    均值 {statistics.fmean(chars):.4f}")
    for cut in (0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9):
        share = sum(1 for c in chars if c < cut) / len(chars)
        print(f"    < {cut:.1f} 的字符占比 {share * 100:5.1f}%")

    # ── 段均值：生产判据把多少段打进 poor ──
    print("\n─── 段均值 / 低置信占比 的分布 ───")
    means = [seg.mean for seg in all_segments]
    ratios = [seg.low_ratio for seg in all_segments]
    for name, values in (("段均值", means), ("低置信占比", ratios)):
        qq = quantiles(values, (0.05, 0.25, 0.5, 0.75, 0.95))
        print(f"  {name}: p05 {qq[0.05]:.3f} / p25 {qq[0.25]:.3f} / 中位 {qq[0.5]:.3f}"
              f" / p75 {qq[0.75]:.3f} / p95 {qq[0.95]:.3f}")
    print("  生产判据下按档位分组：")
    for name, predicate in (("可信(good)", lambda s: is_good(s, PROD) and not is_poor(s, PROD)),
                            ("存疑(fair)", lambda s: not is_good(s, PROD) and not is_poor(s, PROD)),
                            ("不可信(poor)", lambda s: is_poor(s, PROD))):
        group = [s for s in all_segments if predicate(s)]
        if not group:
            print(f"    {name}: 0 段")
            continue
        gm = statistics.fmean([s.mean for s in group])
        gr = statistics.fmean([s.low_ratio for s in group])
        gtext = statistics.fmean([len(s.text) for s in group])
        print(f"    {name}: {len(group):>3} 段 · 段均值 {gm:.3f} · 低置信占比 {gr:.3f}"
              f" · 平均段长 {gtext:.1f} 字")

    if not args.labels:
        print("\n（没给 --labels，跳过分离度与自助法。给一份标注才能标定阈值。）")
        return

    # ── 标注：按文件内序号 0..n-1 对齐 ──
    labels = {}
    with open(args.labels, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, value = line.split("\t")
            labels[key] = int(value)
    for index, seg in enumerate(all_segments):
        seg.source_label = str(index)
    missing = [str(i) for i in range(len(all_segments)) if str(i) not in labels]
    if missing:
        print(f"\n⚠️ 有 {len(missing)} 段没标注（前 10 个：{missing[:10]}）——"
              "只对有标注的段做统计")
    labeled = [s for s in all_segments if str(s.source_label) in labels]

    positives = sum(1 for s in labeled if labels[s.source_label] == 1)
    print(f"\n═══ 标注：{len(labeled)} 段，其中判崩坏 {positives}"
          f"（{positives / len(labeled) * 100:.0f}%）═══")

    print("\n─── 标注 × 生产判据 的混淆矩阵（正类 = 崩坏）───")
    tp, fp, fn, tn = confusion(labeled, labels, PROD)
    print(f"  抓到 {tp} · 漏 {fn} · 误报 {fp} · 正确放过 {tn}")
    if tp + fn:
        print(f"  召回 {tp / (tp + fn) * 100:.0f}%", end="")
    if tn + fp:
        print(f" · 特异度 {tn / (tn + fp) * 100:.0f}%", end="")
    print(f" · 平衡准确度 {balanced_accuracy(tp, fp, fn, tn) * 100:.0f}%")

    print("\n─── 标注组之间的分离度 ───")
    bad = [s for s in labeled if labels[s.source_label] == 1]
    ok = [s for s in labeled if labels[s.source_label] == 0]
    for name, extract in (("段均值", lambda s: s.mean), ("低置信占比", lambda s: s.low_ratio)):
        if bad and ok:
            bv = [extract(s) for s in bad]
            ov = [extract(s) for s in ok]
            print(f"  {name}: 崩坏 {statistics.fmean(bv):.3f}（n={len(bv)}）"
                  f" vs 可读 {statistics.fmean(ov):.3f}（n={len(ov)}）"
                  f" · 差 {statistics.fmean(ov) - statistics.fmean(bv):+.3f}")

    best, score = best_on(labeled, labels)
    print("\n─── 在标注上最优的一组常数（只换常数，判据形状不变）───")
    print(f"  poor 上限 {best['poor_ceiling']:.2f} / good 下限 {best['good_floor']:.2f}"
          f" / poor 低置信占比 {best['poor_low_ratio']:.2f}"
          f" / good 低置信占比 {best['good_low_ratio']:.2f}")
    print(f"  平衡准确度 {score * 100:.0f}%（生产那套是 "
          f"{balanced_accuracy(*confusion(labeled, labels, PROD)) * 100:.0f}%）")

    # ── 自助法：按「段」重采样，看最优常数有多稳 ──
    rng = random.Random(args.seed)
    picks = {"poor_ceiling": [], "good_floor": [], "poor_low_ratio": [], "good_low_ratio": []}
    scores = []
    for _ in range(args.bootstrap):
        sample = [labeled[rng.randrange(len(labeled))] for _ in range(len(labeled))]
        if not any(labels[s.source_label] == 1 for s in sample):
            continue
        if not any(labels[s.source_label] == 0 for s in sample):
            continue
        choice, got = best_on(sample, labels)
        for key in picks:
            picks[key].append(choice[key])
        scores.append(got)
    print(f"\n─── 自助法（按段重采样 {len(scores)} 次有效）───")
    for key in ("poor_ceiling", "poor_low_ratio", "good_floor", "good_low_ratio"):
        values = picks[key]
        if not values:
            continue
        qq = quantiles(values, (0.05, 0.5, 0.95))
        span = qq[0.95] - qq[0.05]
        # 取值本来就只有 4–6 档，区间跨 3 档以上就等于「没定下来」
        note = "  ← 区间跨度过大（取值本来就粗，说明数据分不开）" if span > 0.25 else ""
        print(f"  {key:<18} p05 {qq[0.05]:.2f} / 中位 {qq[0.5]:.2f} / p95 {qq[0.95]:.2f}"
              f"（跨 {span:.2f}）{note}")
    if scores:
        qq = quantiles(scores, (0.05, 0.5, 0.95))
        print(f"  平衡准确度         p05 {qq[0.05] * 100:.0f}% / 中位 {qq[0.5] * 100:.0f}%"
              f" / p95 {qq[0.95] * 100:.0f}%")


if __name__ == "__main__":
    main()
