#!/usr/bin/env bash
# C-1 自门控：等机器真的空（按 C-1验证放行.md §先自门控）
#
# 判据（两个都满足才算一次「满足」）：
#   ① 没有 whisper / 编译进程：pgrep -f "whisper|swift-frontend|p3_temperature" 为空
#   ② 另一个 agent 空闲：tmux capture-pane -pt transcribe 的**全屏**里没有 "esc to interrupt"
#
# 每 15 秒采一次。放行条件：连续采样都满足，且这段空闲跨度 >= 60 秒。
# 因为 15s 间隔下 4 次采样只跨 45 秒，这里实现为「连续 5 次满足」= 60 秒跨度，
# 与文件里「连续 60 秒不变」一致（4 次）。最长等 40 分钟；到点仍忙则退出 1。
#
# 注意：本脚本写成文件再执行，是为了让 pgrep -f 的 pattern 不出现在
# 执行进程的命令行里，避免自己匹配自己。

set -uo pipefail

INTERVAL="${INTERVAL:-15}"
MAX_SECONDS="${MAX_SECONDS:-2400}"
NEED="${NEED:-5}"          # 连续满足次数（5 次 × 15s = 60s 跨度）
SESSION="${SESSION:-transcribe}"
PATTERN='whisper|swift-frontend|p3_temperature'

deadline=$(( $(date +%s) + MAX_SECONDS ))
streak=0
sample=0

echo "== gate-wait start $(date '+%F %T') interval=${INTERVAL}s need=${NEED} max=${MAX_SECONDS}s session=${SESSION} =="

while :; do
  now=$(date +%s)
  if (( now >= deadline )); then
    echo "== GATE TIMEOUT $(date '+%F %T')：等了 ${MAX_SECONDS}s 仍不满足，停下，不硬上。streak=${streak} =="
    exit 1
  fi

  sample=$((sample + 1))
  stamp=$(date '+%F %T')

  # ① 进程
  procs="$(pgrep -fl "$PATTERN" 2>/dev/null)"
  if [[ -z "$procs" ]]; then
    c1="OK"
  else
    c1="BUSY"
  fi

  # ② tmux 全屏
  pane="$(tmux capture-pane -pt "$SESSION" 2>/dev/null)"
  if [[ -z "$pane" ]]; then
    c2="NO_SESSION"
    esc_hit="(capture failed or empty)"
  elif grep -q 'esc to interrupt' <<<"$pane"; then
    c2="BUSY"
    esc_hit="esc to interrupt present"
  else
    c2="OK"
    esc_hit="no esc"
  fi

  if [[ "$c1" == "OK" && "$c2" == "OK" ]]; then
    streak=$((streak + 1))
    if (( streak >= NEED )); then
      span=$(( streak * INTERVAL ))
      echo "[$stamp] sample#$sample proc=OK tmux=OK streak=${streak} span~${span}s"
      echo "== GATE OPEN $(date '+%F %T')：连续 ${streak} 次满足（跨度 ~${span}s >= 60s）。可以构建。 =="
      exit 0
    fi
  else
    streak=0
  fi

  echo "[$stamp] sample#$sample proc=${c1} tmux=${c2} streak=${streak} | ${esc_hit}"
  if [[ -n "$procs" ]]; then
    echo "    procs: $(head -c 400 <<<"$procs" | tr '\n' ';')"
  fi

  sleep "$INTERVAL"
done
