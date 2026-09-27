#!/bin/bash
# P9-2 补充：把「读文件 + 重采样」那一段的**瞬时**峰值拍下来（1 秒粒度）。
#
# 为什么单独一个脚本：`longrun_rss.sh` 是 30 秒一采，而这一段整个落在头两次
# 采样之间——实测长跑第一个样本 `t=0.0 → 208 KB`、第二个 `t=30.1 → 1027 MB`，
# 中间那 1810 MB 的尖峰它一个字都看不见。**30 秒粒度报出来的「峰值」是采样
# 峰值，不是真峰值**，这两个数在结论里必须分清。
#
# 为什么 `--head` 不影响这一测：`WhisperWindowFileRun` 是**先整条读满再截断**
# （读在截断之前），所以哪怕只要前 20 秒，那 1.32 GiB 的 Float32 缓冲照样在场。
#
# 用法：
#   tools/probes/longrun_transient.sh --wav <wav> [--head 20]
#
# 落盘：$OUT/series.csv（t,rss_kb）。默认 OUT=/tmp/p9-2/transient。

set -u

PROBE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$PROBE_DIR/../.." && pwd)"
BIN="$REPO/build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber"

WAV=""; HEAD=20; OUT=/tmp/p9-2/transient
while [ $# -gt 0 ]; do
  case "$1" in
    --wav) WAV="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done
[ -n "$WAV" ] || { echo "用法: $0 --wav <wav> [--head 秒] [--out 目录]"; exit 2; }
[ -x "$BIN" ] || { echo "❌ 没有二进制，先 ./build.sh"; exit 2; }
mkdir -p "$OUT"

echo "t_s,rss_kb" > "$OUT/series.csv"
START=$(python3 -c 'import time;print(time.time())')
"$BIN" --whisper-window-file "$WAV" --head "$HEAD" > "$OUT/stdout.txt" 2>&1 &
PID=$!
# `${PID}` 的大括号不是风格问题：紧跟其后的是全角标点，bash 在 UTF-8 locale 下
# 会把那几个字节并进变量名（`longrun_rss.sh` 第一版就死在这）
while kill -0 "${PID}" 2>/dev/null; do
  E=$(python3 -c "import time;print(f'{time.time()-$START:.2f}')")
  R=$(ps -o rss= -p "${PID}" 2>/dev/null | tr -d ' ')
  [ -n "$R" ] && echo "$E,$R" >> "$OUT/series.csv"
  sleep 1
done
wait "${PID}"; CODE=$?

python3 - "$OUT/series.csv" "$CODE" <<'PY'
import sys
rows = []
for line in open(sys.argv[1]).read().splitlines()[1:]:
    p = line.split(",")
    if len(p) == 2 and p[1]:
        rows.append((float(p[0]), float(p[1])))
if not rows:
    print("❌ 一个样本都没有"); raise SystemExit(1)
peak = max(rows, key=lambda r: r[1])
print(f"样本 {len(rows)} · 覆盖 {rows[-1][0]:.1f} 秒 · 退出码 {sys.argv[2]}")
print(f"**瞬时峰值 RSS {peak[1] / 1024:.0f} MB @ t={peak[0]:.1f}s**")
for t, r in rows:
    print(f"  t={t:6.2f}s  RSS={r / 1024:8.1f} MB")
PY
