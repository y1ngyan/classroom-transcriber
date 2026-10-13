#!/bin/bash
# 三个模型的 **app 内**真实倍率（P12-1 附带的一件小事）。
#
# 为什么不能用 whisper-cli 的数字：cli 是「整段一次性喂进去」，而 app 走的是
# 10 秒窗 / 3 秒步长的滑窗（70% 重叠）——**同一段音频在 app 里要被转三遍多**。
# 两者根本不是一个量级，cli 的 4.74× 换算不出 app 里是多少，只能自己量。
#
# 倍率的定义：**音频秒 ÷ 墙钟秒**（和 `RetranscribeEngine.realtimeRate` 同一个
# 定义，方向别搞反——不是「墙钟 ÷ 音频」）。两个数都给：
#   · 端到端：整条滑窗跑完的 wall time（含第 1 窗的冷启动）
#   · 稳态：第 2 遍（`--repeat 2`，模型与着色器都热了）的单窗均值 → 步长 ÷ 它
# 课堂量级（几十分钟）上稳态那个数才描述得住，因为冷启动只有一次。
#
# 用法：
#   tools/probes/model_rates.sh                      # 默认取会话第一段前 60 秒
#   tools/probes/model_rates.sh --offset 3000 --head 90
#   tools/probes/model_rates.sh --window-timeout 7200
#   CLASSROOM_BIN=build-verify/... tools/probes/model_rates.sh
#
# **只读用户的库**：录音只读，日志和截取的副本落在临时目录。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN="${CLASSROOM_BIN:-build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}"
LIB="$HOME/Library/Application Support/ClassroomTranscriber"
SESSIONS="$LIB/sessions"
RECORDINGS="$LIB/recordings"
MODELS="${CLASSROOM_MODELS_DIR:-$LIB/models}"

# 缺省 60 秒：三个模型 × `--repeat 2` = 六遍，`run()` 又是攒到最后才交结果，
# 一超时（默认 1800 秒）整跑作废、一个字都不落地。见 glossary_prompt.sh 里同一段注释
HEAD=60
OFFSET=0
SESSION=""
# 墙钟上限（App.swift 的默认 1800 不动，这里显式抬高；见 glossary_prompt.sh）
TIMEOUT=7200
while [ $# -gt 0 ]; do
  case "$1" in
    --window-timeout) TIMEOUT="$2"; shift 2 ;;
    --head)    HEAD="$2"; shift 2 ;;
    --offset)  OFFSET="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    *) echo "❌ 认不出来的参数：$1"; exit 2 ;;
  esac
done

[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 ./build.sh"; exit 1; }

echo "════ 三个模型的 app 内倍率（P12-1）════"
echo "二进制: $BIN"

if [ -z "$SESSION" ]; then
  SESSION=$(python3 - "$SESSIONS" <<'PY'
import glob, json, os, sys
best, best_dur = None, -1
for p in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    parts = d.get("parts") or []
    if len(parts) != 1:
        continue
    dur = parts[0].get("durationMillis") or 0
    if dur > best_dur:
        best, best_dur = p, dur
print(best or "")
PY
)
fi
[ -n "$SESSION" ] && [ -f "$SESSION" ] || { echo "❌ 找不到可用的会话 json（用 --session 指定）"; exit 1; }

WAV="$RECORDINGS/$(basename "$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['parts'][0].get('fileName') or '')
" "$SESSION")")"
[ -f "$WAV" ] || { echo "❌ 音频不在：$WAV"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/p12-rates.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

SAMPLE="$WAV"
if [ "$OFFSET" != "0" ]; then
  SAMPLE="$TMP/sample.wav"
  command -v ffmpeg >/dev/null 2>&1 || { echo "❌ --offset 需要 ffmpeg"; exit 1; }
  ffmpeg -v error -ss "$OFFSET" -t "$HEAD" -i "$WAV" -c copy "$SAMPLE" || exit 1
fi

echo "会话: $(basename "$SESSION")"
echo "录音: $(basename "$WAV")（只读，起始第 ${OFFSET} 秒、取 ${HEAD} 秒）"
echo ""

FAIL=0
printf '  %-26s %8s %8s %10s %10s %12s\n' "模型" "段数" "总字数" "音频(秒)" "墙钟(秒)" "端到端倍率"
printf '  %-26s %8s %8s %10s %10s %12s\n' "──" "──" "────" "──────" "──────" "─────────"
for NAME in medium large turbo; do
  case "$NAME" in
    medium) MODEL="$MODELS/ggml-medium-q5_0.bin" ;;
    large)  MODEL="$MODELS/ggml-large-v3-q5_0.bin" ;;
    turbo)  MODEL="$MODELS/ggml-large-v3-turbo-q5_0.bin" ;;
  esac
  if [ ! -f "$MODEL" ]; then
    printf '  %-26s %s\n' "$NAME" "⏭ 模型不在：$(basename "$MODEL")"
    continue
  fi
  CLASSROOM_WHISPER_MODEL="$MODEL" \
    "$BIN" --whisper-window-file "$SAMPLE" --head "$HEAD" --repeat 2 \
           --window-timeout "$TIMEOUT" > "$TMP/$NAME.log" 2>&1
  EXIT=$?
  if [ "$EXIT" != "0" ]; then
    printf '  %-26s ❌ exit=%s\n' "$NAME" "$EXIT"
    FAIL=$((FAIL + 1))
    continue
  fi
  SEG=$(grep -m1 -o '段数 [0-9]*（' "$TMP/$NAME.log" | grep -o '[0-9]*')
  CHARS=$(grep -m1 -o '总字数 [0-9]*（最终输出）' "$TMP/$NAME.log" | grep -o '[0-9]*')
  AUDIO=$(grep -m1 -o '（音频 [0-9.]* 秒）' "$TMP/$NAME.log" | grep -o '[0-9.]*')
  WALL=$(grep -m1 -o '离线全程 [0-9.]* 秒' "$TMP/$NAME.log" | grep -o '[0-9.]*')
  RATE=$(python3 -c "print(f'{float('${AUDIO:-0}')/float('${WALL:-1}'):.2f}')")
  printf '  %-26s %8s %8s %10s %10s %12s\n' "$NAME" "${SEG:-?}" "${CHARS:-?}" "${AUDIO:-?}" "${WALL:-?}" "${RATE}×"
done

echo ""
echo "── 稳态（第 2 遍，冷启动已摊掉；课堂量级看这一列）──"
for NAME in medium large turbo; do
  [ -f "$TMP/$NAME.log" ] || continue
  MEAN=$(grep '第 2/2 遍' "$TMP/$NAME.log" | grep -o '均 [0-9.]*' | head -1 | sed 's/^均 //')
  [ -n "$MEAN" ] || continue
  STEP=$(grep -m1 -o '步长 [0-9.]* 秒' "$TMP/$NAME.log" | grep -o '[0-9.]*')
  python3 -c "
step=float('${STEP:-3.0}'); mean=float('$MEAN')
print(f'  {\"$NAME\":<26} 单窗均 {mean:6.2f} 秒 → 倍率 {step/mean:.2f}×（步长 {step:g} 秒）')"
done

echo ""
echo "  对照：RetranscribeEngine 里写死的常量是 medium 0.89× / large 0.49×"
echo "  （出处是 90 秒样本的单窗中位数，见模型AB实测）。这一节量的是同一条路，"
echo "   数字对不上就以这里为准——那条常量该改了。"
echo "  日志：${TMP}（脚本退出时删掉）"
exit $([ "$FAIL" = "0" ] && echo 0 || echo 1)
