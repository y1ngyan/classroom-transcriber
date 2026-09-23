#!/bin/bash
# §1 幻觉治理的判据：同一组真实录音，改动前后对比 + 误杀率。
#
# 为什么用 `--probe-only`：它绕开合并器、逐段打引擎的**原始**输出，
# 一趟同时给出「改动前」（原始段）和「改动后」（套上 WhisperHallucination 的
# 结果）。生产链路那一趟的丢弃记录另由 `--whisper-window-file` 打（见末尾），
# 用来证明那句过滤真的接上了——探针证明不了这个。
#
# 用法：
#   ./tools/probes/p4_hallucination.sh              # 默认三条（合计约 14 分钟）
#   HEAD=300 ./tools/probes/p4_hallucination.sh     # 每条只跑前 300 秒
#   WAVS="a.wav b.wav" ./tools/probes/p4_hallucination.sh
#
# 铁律：不放声、不改音量、不改默认后端。全程只读 wav。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
[ -x "$BIN" ] || { echo "❌ 没有 $BIN，先跑 ./build.sh"; exit 1; }

HEAD="${HEAD:-0}"
OUT="${OUT:-/tmp/p4_hallucination}"

if [ -n "${WAVS:-}" ]; then
  # shellcheck disable=SC2206
  FILES=($WAVS)
else
  FILES=(
    "$REC/课堂-20260918-101340.wav"   # 191.6 秒，已实测有 5 处幻觉
    "$REC/课堂-20260920-143738.wav"   # 266.1 秒
    "$REC/课堂-20260921-092351.wav"   # 383.3 秒
  )
fi

mkdir -p "$OUT"
# 空数组在 macOS 自带的 bash 3.2 上配合 `set -u` 会报 unbound variable，
# 所以不能写 `HEADARG=()` 之后直接 `"${HEADARG[@]}"`——用 `+` 展开形式，
# 长度为 0 时整段消失。这个坑让第一版脚本在第一条录音上就死了
HEADARG=()
[ "$HEAD" != "0" ] && HEADARG=(--head "$HEAD")

echo "════ §1 幻觉治理：改动前后对照 ════"
[ "$HEAD" != "0" ] && echo "（每条只跑前 $HEAD 秒）"
echo

TOTAL_BEFORE=0; TOTAL_AFTER=0; TOTAL_TPL=0; TOTAL_ANN=0
TOTAL_LOUD_BEFORE=0; TOTAL_LOUD_AFTER=0; TOTAL_KILLED=0
SUMMARY="$OUT/summary.tsv"
: > "$SUMMARY"

for wav in "${FILES[@]}"; do
  name="$(basename "$wav" .wav)"
  log="$OUT/$name.log"
  # 复用日志的前提是**它比二进制新**。判据改了（改词表、改门限）之后，
  # 旧日志里的 HALLU_SUMMARY 是上一次判据跑出来的数——直接复用会拿着
  # 过期数字当「改动后」。这个陷阱踩过一次，所以比 mtime 而不是「文件在不在」
  if [ ! -f "$log" ] || [ "$BIN" -nt "$log" ]; then
    printf '▶ %s …' "$name"
    "$BIN" --whisper-window-file "$wav" --probe-only --probe-step 10 ${HEADARG[@]+"${HEADARG[@]}"} \
      > "$log" 2>&1
    printf ' exit=%s\n' "$?"
  else
    printf '▶ %s（复用已有日志；它比二进制新）\n' "$name"
  fi

  line="$(grep -m1 'HALLU_SUMMARY' "$log" | tr -d '\r')"
  if [ -z "$line" ]; then
    echo "  ⚠️ 没有 HALLU_SUMMARY —— 这一条没跑到（看 $log 末尾）"
    tail -5 "$log" | sed 's/^/     /'
    continue
  fi
  # HALLU_SUMMARY  orig  kept  dropped  template  annotation  loudTotal  loudKept
  read -r _ before after dropped tpl ann loudBefore loudAfter <<<"$line"
  killed=$((loudBefore - loudAfter))
  TOTAL_BEFORE=$((TOTAL_BEFORE + before)); TOTAL_AFTER=$((TOTAL_AFTER + after))
  TOTAL_TPL=$((TOTAL_TPL + tpl));           TOTAL_ANN=$((TOTAL_ANN + ann))
  TOTAL_LOUD_BEFORE=$((TOTAL_LOUD_BEFORE + loudBefore))
  TOTAL_LOUD_AFTER=$((TOTAL_LOUD_AFTER + loudAfter))
  TOTAL_KILLED=$((TOTAL_KILLED + killed))
  printf '  段数 %s → %s（丢 %s：模板 %s / 注释 %s）· 有语音电平的段 %s → %s（被丢 %s）\n' \
    "$before" "$after" "$dropped" "$tpl" "$ann" "$loudBefore" "$loudAfter" "$killed"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$before" "$after" "$dropped" "$tpl" "$ann" "$loudBefore" "$loudAfter" >> "$SUMMARY"
done

echo
echo "──── 汇总（$(wc -l < "$SUMMARY" | tr -d ' ') 条录音）────"
printf '  段数            %s → %s\n' "$TOTAL_BEFORE" "$TOTAL_AFTER"
printf '  丢掉的段        模板 %s / 非语音注释 %s\n' "$TOTAL_TPL" "$TOTAL_ANN"
printf '  有语音电平的段   %s → %s\n' "$TOTAL_LOUD_BEFORE" "$TOTAL_LOUD_AFTER"
printf '  误杀上界        %s 段（= 被丢的段里电平够高的）\n' "$TOTAL_KILLED"
if [ "$TOTAL_LOUD_BEFORE" != "0" ]; then
  printf '  误杀上界占比    %.2f%%（分母 = 改动前有语音电平的段）\n' \
    "$(echo "$TOTAL_KILLED $TOTAL_LOUD_BEFORE" | awk '{printf "%.2f", $1/$2*100}')"
fi
echo
echo "  逐条明细：$SUMMARY"
echo "  被丢掉的每一条原文都在各条日志的「丢掉的全部内容」段——**响段要人工看**，"
echo "  数字只给上界（电平高 ≠ 语音，音乐掌声也高）"
echo
echo "════ 离线重算（同一份判据，不用再跑 whisper）════"
# `--hallucination-replay` 读上面那些日志的 TSV、调**同一个** WhisperHallucination
# 重算。它和上面的 HALLU_SUMMARY 是两次独立计算，**对不上就是有 bug**——
# 这是这个入口顺带提供的交叉校验（HALLU_SUMMARY 由探针自己算，replay 由解析
# 日志再算一遍，两条路各自实现，只有都走同一份判据才可能一致）
# 空数组在 bash 3.2 + `set -u` 下连 `${#REPLAY[@]}` 都会报 unbound variable，
# 所以用一个计数器判断，不碰数组长度
#
# ⚠️ 这个交叉校验**只在同一次跑里成立**。上面每趟都带 mtime 守卫（BIN 比日志新
# 就重跑），所以正常走完时两边是同一个二进制产的，对不上才真是 bug。但要是**手工**
# 拿 `--hallucination-replay` 去读一份**旧判据**留下的日志，两边必然对不上——
# 那是日志过期，不是 bug。核验者 2026-09-24 提醒过这一点
REPLAY=(); REPLAY_N=0
for wav in "${FILES[@]}"; do
  log="$OUT/$(basename "$wav" .wav).log"
  if [ -f "$log" ]; then REPLAY+=("$log"); REPLAY_N=$((REPLAY_N + 1)); fi
done
if [ "$REPLAY_N" -gt 0 ]; then
  "$BIN" --hallucination-replay "${REPLAY[@]}"
else
  echo "  ⏭ 没有可用的日志"
fi
echo
echo "════ 生产链路是否真的接上了（另一条判据）════"
echo "  下面这一趟走的是生产路径（滑窗 + 合并器），丢弃记录由管线自己打印。"
echo "  探针那趟证明不了这件事。"
SHORT="$REC/课堂-20260918-101340.wav"
if [ -f "$SHORT" ]; then
  prod="$OUT/production-path.log"
  "$BIN" --whisper-window-file "$SHORT" --head 120 > "$prod" 2>&1
  grep -A20 '生产链路的幻觉过滤' "$prod" | sed 's/^/  /' | head -25
else
  echo "  ⏭ 找不到 $SHORT"
fi
