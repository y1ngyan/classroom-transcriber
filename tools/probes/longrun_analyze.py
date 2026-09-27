#!/usr/bin/env python3
"""把 `--whisper-window-file --timing` 的逐窗表按音频时间分桶（P9-2）。

为什么要这一层：逐窗表有两三千行，肉眼看不出趋势。本包的核心判据是
「**内存有上限曲线而不是线性涨**」，而逐窗表里那一列 `进程MB` 就是**进程内部
自报**的同一件事——它和外面 `ps` 采到的 RSS 互为佐证。另外「段数增长时，
合并耗时是线性还是更差」也只能从这一列的时间序列上看。

用法：
    python3 tools/probes/longrun_analyze.py <stdout.txt> [--bucket-min 10]
"""
import argparse
import re
import sys

# 与 WhisperWindowFileRun.timingTable 的 format 串一一对应
ROW = re.compile(
    r"^\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+"
    r"([\d.]+)\s+([\d.]+)\s+(\d+)%\s+(\d+)"
)
SUMMARY = re.compile(r"^\s+(\d+) 窗 · 离线全程 ([\d.]+) 秒（音频 ([\d.]+) 秒）")
SEGMENTS = re.compile(r"^\s+段数 (\d+)（定稿 (\d+)）")
COVERAGE = re.compile(r"^\s+覆盖率: 最晚段结束 ([\d.]+) 秒 / 音频 ([\d.]+) 秒 = ([\d.]+)%")
CONSTRUCT = re.compile(r"构造 ggml context 次数: (\d+)")
FOOTPRINT_LINE = re.compile(r"进程 (\d+) MB")


def median(values):
    if not values:
        return float("nan")
    s = sorted(values)
    return s[len(s) // 2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stdout")
    ap.add_argument("--bucket-min", type=float, default=10.0)
    args = ap.parse_args()

    rows, summary, seg_line, cover, construct = [], None, None, None, None
    for line in open(args.stdout, encoding="utf-8", errors="replace"):
        m = ROW.match(line)
        if m:
            rows.append({
                "index": int(m.group(1)), "start_s": float(m.group(2)),
                "audio_s": float(m.group(3)), "elapsed_s": float(m.group(4)),
                "new": int(m.group(5)), "chars": int(m.group(6)),
                "rms": float(m.group(7)), "voiced": int(m.group(9)),
                "mb": float(m.group(10)),
            })
            continue
        if summary is None:
            s = SUMMARY.match(line)
            if s:
                summary = tuple(float(s.group(i)) for i in (1, 2, 3))
                continue
        if seg_line is None:
            s = SEGMENTS.match(line)
            if s:
                seg_line = (int(s.group(1)), int(s.group(2)))
                continue
        if cover is None:
            c = COVERAGE.match(line)
            if c:
                cover = tuple(float(c.group(i)) for i in (1, 2, 3))
                continue
        if construct is None:
            c = CONSTRUCT.search(line)
            if c:
                construct = int(c.group(1))

    if not rows:
        sys.exit("❌ 没解析到逐窗表——stdout 里没有 --timing 的输出？")

    print(f"逐窗行 {len(rows)} 条")
    if summary:
        print(f"离线全程 {summary[1]:.1f} 秒 / 音频 {summary[2]:.1f} 秒 "
              f"= {summary[2] / summary[1]:.2f} 倍实时（1.0 = 刚好实时）")
    if seg_line:
        print(f"段数 {seg_line[0]}（定稿 {seg_line[1]}）")
    if cover:
        print(f"覆盖率 {cover[2]:.1f}%")
    if construct is not None:
        print(f"构造 ggml context 次数 {construct}"
              f"{'  ✅ = 1' if construct == 1 else '  ❌ 长跑里不该不是 1'}")

    width = args.bucket_min * 60
    buckets = {}
    for r in rows:
        buckets.setdefault(int(r["start_s"] // width), []).append(r)

    print(f"\n{'音频区间(分)':>12} {'窗数':>5} {'耗时中位':>9} {'耗时最大':>9} "
          f"{'耗时精算/窗':>11} {'进程MB中位':>10} {'进程MB最大':>10} {'认字':>7}")
    for key in sorted(buckets):
        v = buckets[key]
        elapsed = [x["elapsed_s"] for x in v]
        mb = [x["mb"] for x in v]
        print(f"{key * args.bucket_min:>5.0f}-{(key + 1) * args.bucket_min:<6.0f} "
              f"{len(v):>5} {median(elapsed):>9.2f} {max(elapsed):>9.2f} "
              f"{sum(elapsed) / len(v) / v[0]['audio_s']:>11.1f} "
              f"{median(mb):>10.0f} {max(mb):>10.0f} "
              f"{sum(x['chars'] for x in v):>7}")

    # 「合并/转写耗时随段数增长是线性还是更差」：把耗时对**时间**做前后半段对比，
    # 而不是对段数——段数和时间在这一跑里强共线，分不出彼此，所以只说
    # 「后半段比前半段慢了几成」，并把认字量一并给出（内容变了就不是复杂度的锅）
    half = len(rows) // 2
    first, second = rows[:half], rows[half:]
    e1, e2 = median([x["elapsed_s"] for x in first]), median([x["elapsed_s"] for x in second])
    c1, c2 = sum(x["chars"] for x in first), sum(x["chars"] for x in second)
    print(f"\n前半段：窗耗时中位 {e1:.2f}s · 认字 {c1}")
    print(f"后半段：窗耗时中位 {e2:.2f}s · 认字 {c2}")
    print(f"后半/前半 耗时比 {e2 / e1:.2f}×  认字比 {c2 / c1:.2f}×"
          f"  —— 两者同步 = 内容相关；耗时比明显更大才谈得上复杂度")


if __name__ == "__main__":
    main()
