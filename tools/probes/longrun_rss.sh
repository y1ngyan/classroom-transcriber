#!/bin/bash
# P9-2 长跑：跑一条长录音，每 30 秒记一次目标进程的 RSS，输出 10 分钟分桶序列。
#
# 为什么是独立脚本而不是直接 nohup：这一跑 1-2 小时，要能在前台干等之外
# 拿到「进程还活着吗、现在多大」。脚本自己在后台跑并落盘，前台用 tail 看。
#
# 用法：
#   tools/probes/longrun_rss.sh --out <结果目录> --wav <wav> [--head 秒] [额外参数…]
#
# 落盘：
#   <结果目录>/stdout.txt  进程输出（一行都不截）
#   <结果目录>/rss.csv     每 30 秒一行：elapsed_s,rss_kb,cpu_pct
#   <结果目录>/meta.txt    退出码、墙钟、输入信息
set -u

PROBE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$PROBE_DIR/../.." && pwd)"
BIN="$REPO/build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber"

OUT=""; WAV=""
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --wav) WAV="$2"; shift 2 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done
[ -n "$OUT" ] || { echo "用法: $0 --out <目录> --wav <wav> [额外参数]"; exit 2; }
[ -n "$WAV" ] || { echo "用法: $0 --out <目录> --wav <wav> [额外参数]"; exit 2; }
[ -x "$BIN" ] || { echo "❌ 没有二进制，先 ./build.sh"; exit 2; }

mkdir -p "$OUT"
echo "输入: $WAV" > "$OUT/meta.txt"
echo "参数: ${EXTRA[*]:-（默认）}" >> "$OUT/meta.txt"
echo "开始: $(date '+%F %T')" >> "$OUT/meta.txt"

START=$(python3 -c 'import time;print(time.time())')
"$BIN" --whisper-window-file "$WAV" "${EXTRA[@]+"${EXTRA[@]}"}" \
    > "$OUT/stdout.txt" 2>&1 &
PID=$!
# 大括号是必须的：紧跟其后的是全角括号，bash 在 UTF-8 locale 下会把那几个
# 字节当成变量名的一部分，`$PID（…` 直接 unbound（这个脚本第一版就死在这）
echo "PID: ${PID}" >> "$OUT/meta.txt"
echo "PID=${PID}（每 30 秒采样一次 RSS）"

# cputime 是**累计** CPU 时间（HH:MM:SS），不是 `ps -o %cpu` 那个衰减均值——
# 均值会把「开头 40 秒在读文件、后面全在算」这一段糊成 20%，看不出真实占用。
# 分桶时用相邻两次的差值算「平均占了几个核」
echo "elapsed_s,rss_kb,cpu_pct,cputime" > "$OUT/rss.csv"
PEAK=0
while kill -0 "$PID" 2>/dev/null; do
  read -r RSS CPU CTIME <<<"$(ps -o rss=,%cpu=,cputime= -p "$PID" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
  if [ -n "${RSS:-}" ]; then
    NOW=$(python3 -c "import time;print(f'{time.time()-$START:.1f}')")
    echo "$NOW,$RSS,$CPU,$CTIME" >> "$OUT/rss.csv"
    [ "$RSS" -gt "$PEAK" ] && PEAK=$RSS
  fi
  sleep 30
done
wait "$PID"; CODE=$?
END=$(python3 -c 'import time;print(time.time())')
WALL=$(python3 -c "print(f'{$END-$START:.1f}')")

{
  echo "退出码: $CODE"
  echo "墙钟: ${WALL} 秒"
  echo "峰值 RSS: $PEAK KB = $(python3 -c "print(f'{$PEAK/1024:.1f}')") MB"
} >> "$OUT/meta.txt"

echo "✅ 跑完 exit=$CODE 墙钟=${WALL}s 峰值RSS=$((PEAK/1024))MB"
echo "── 10 分钟分桶 ──"
python3 - "$OUT/rss.csv" <<'PY'
import csv, sys
def cputime_s(s):
    if not s:
        return None
    parts = [float(x) for x in s.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    return parts[0] * 3600 + parts[1] * 60 + parts[2]


rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    print("（没有采样）"); raise SystemExit
bucket = {}
for r in rows:
    t = float(r["elapsed_s"]); b = int(t // 600)
    bucket.setdefault(b, []).append(
        (t, int(r["rss_kb"]), float(r["cpu_pct"]), cputime_s(r.get("cputime", "")))
    )
print(f"{'桶(分)':>8} {'样本':>4} {'中位RSS(MB)':>12} {'最大RSS(MB)':>12} "
      f"{'核占用':>8} {'ps%cpu均':>9}")
for b in sorted(bucket):
    v = bucket[b]
    rss = sorted(x[1] for x in v); med = rss[len(rss)//2]
    cpu = sum(x[2] for x in v) / len(v)
    # 核占用 = 本桶内 CPU 时间增量 / 墙钟增量。比 ps 的衰减均值可信
    usable = [x for x in v if x[3] is not None]
    cores = float("nan")
    if len(usable) >= 2 and usable[-1][0] > usable[0][0]:
        cores = (usable[-1][3] - usable[0][3]) / (usable[-1][0] - usable[0][0])
    print(f"{b*10:>5}-{(b+1)*10:<3} {len(v):>4} {med/1024:>12.1f} {max(rss)/1024:>12.1f} "
          f"{cores:>8.2f} {cpu:>9.1f}")
PY
