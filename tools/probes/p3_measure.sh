#!/bin/bash
# 阶段 3 的测量驱动：本包所有数字的复现入口就是它（数字本身在各探针的输出里，
# 没有另写一份报告）。
#
# **全程不发声、不动系统音量、不动音频设备**（铁律，见 docs/design.md 与
# no-playback-for-mic-verification）。所有测量都走离线文件路径
# （`--whisper-window-file`），不需要麦克风，也不需要人说话。
#
# 用法:
#   ./tools/probes/p3_measure.sh            # 全跑（约 18 分钟）
#   OUT=/tmp/p3 ./tools/probes/p3_measure.sh
#
# 输出（默认 /tmp/p3/）:
#   s1_outlier_r2.txt    §1 离群窗：逐窗耗时表 + 同进程连跑两遍 + 慢窗原始输出
#                        + 关掉 temperature fallback 的因果对照（含 §4 的重复段统计）
#   s3_fw3/5/10.txt      §3 首窗最小长度 3 / 5 / 10 秒
#   s1_bench.txt         §1 交叉核对：独立探针（tools/probes/bench.swift）走另一条路径
#   s2_conf_*.txt        §2 逐段置信度分布 + 阈值扫描（每条录音一份）
#
# 每一步都打时间戳：耗时本身也是数据（§1 问的就是耗时）。
#
# 注意：**不要同时跑两个 build.sh**（会争同一个 build/ 目录）。这个脚本假设
# `./build.sh` 已经跑完。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
OUT="${OUT:-/tmp/p3}"
MAIN="$REC/课堂-20260918-101340.wav"

mkdir -p "$OUT"
[ -x "$BIN" ] || { echo "❌ 没有 $BIN，先跑 ./build.sh"; exit 1; }
[ -f "$MAIN" ] || { echo "❌ 找不到主录音: $MAIN"; exit 1; }

step() { echo; echo "════ $(date '+%H:%M:%S')  $* ════"; }

step "§1 + §4：$(basename "$MAIN")，逐窗耗时 + 同进程连跑两遍 + 全段 dump + 慢窗成因"
"$BIN" --whisper-window-file "$MAIN" --timing --repeat 2 --dump-all \
  --slow-windows 6 --fallback-probe 3 \
  --label "§1 离群窗 / §4 重复段" > "$OUT/s1_outlier_r2.txt" 2>&1
echo "  exit=$? · $(wc -l < "$OUT/s1_outlier_r2.txt") 行"

step "§3：同一条录音，首窗最小长度 3 / 5 / 10 秒（只取前 60 秒）"
for w in 3 5 10; do
  echo "  ▸ 首窗 ${w}s …"
  "$BIN" --whisper-window-file "$MAIN" --head 60 --first-window "$w" --timing \
    --label "§3 首窗=${w}s" > "$OUT/s3_fw${w}.txt" 2>&1
  echo "    exit=$?"
done

step "§1 交叉核对：独立探针 bench（不走管线，直接调引擎；从音频中点起 32 窗）"
./tools/probe.sh bench "$MAIN" 10 32 > "$OUT/s1_bench.txt" 2>&1
echo "  exit=$? · $(wc -l < "$OUT/s1_bench.txt") 行"

step "§2：逐段置信度分布 + 阈值扫描（多条真实录音，互不重叠的 10 秒窗）"
for name in 课堂-20260918-095806 课堂-20260918-101340 课堂-20260920-143738 课堂-20260921-092351; do
  echo "  ▸ $name …"
  "$BIN" --whisper-window-file "$REC/$name.wav" --probe-only --probe-step 10 --sweep \
    --label "§2 $name" > "$OUT/s2_conf_${name}.txt" 2>&1
  echo "    exit=$?"
done

step "全部跑完"
ls -la "$OUT"
