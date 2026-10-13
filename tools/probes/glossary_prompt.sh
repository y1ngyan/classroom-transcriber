#!/bin/bash
# 术语表前移（P12-1）的**可复跑判据**。
#
# 它跑真模型、真录音，所以不进 `exit_codes.sh` 那条「快、确定性」的扫描。
#
# 判据四条：
#   ① 两臂都跑完，且**同一段音频、同一个模型**（唯一变量是那个开关）；
#   ② 开的那一臂**真的送了** prompt —— 报告行说「开」、且 prompt 非空；
#   ③ 关的那一臂**一个字节都没送** —— 输出里连「术语表前移」这一节都没有。
#      这一条是「关掉开关时参数与今天逐字节一致」在无头这一侧的机器判据；
#   ④ 四个数（段数 / 总字数 / 词表命中数 / prompt 长度与正文）两臂都打出来，
#      **不断言命中数一定上升**——那是测量结果，不是判据。要看着数字说人话，
#      不许把期望改成能让它变绿的那个样子。
#
# 用法：
#   tools/probes/glossary_prompt.sh                     # 默认取会话第一段、前 60 秒
#   tools/probes/glossary_prompt.sh --head 90
#   tools/probes/glossary_prompt.sh --offset 3000 --head 180  # 从第 3000 秒起取 180 秒
#   tools/probes/glossary_prompt.sh --window-timeout 7200     # 抬墙钟上限（缺省 7200）
#   tools/probes/glossary_prompt.sh --session <会话 json>
#   CLASSROOM_BIN=build-verify/... tools/probes/glossary_prompt.sh
#
# **不碰麦克风、不发声、不改系统音量、不写用户的真实库**：输入录音只读，
# 截取出来的副本和两臂的日志全部落在临时目录里。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN="${CLASSROOM_BIN:-build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}"
LIB="$HOME/Library/Application Support/ClassroomTranscriber"
SESSIONS="$LIB/sessions"
RECORDINGS="$LIB/recordings"
MODELS="${CLASSROOM_MODELS_DIR:-$LIB/models}"

# 缺省 60 秒、不是 180：这条入口的 `run()` 把结果**攒到最后一次性交出来**，
# 所以 1800 秒的墙钟上限一掐，那一跑**一个字都没落地**（连段数都没有），
# 两臂全废。180 秒 × `--repeat 2` × 两臂在这台机器上跑不完 1800 秒——
# 首次写这个脚本时就是这么栽的（2026-10-13，on.log 末行「❌ 离线跑超时」）。
# 60 秒 + 抬高的 `--window-timeout` 能跑完，而且 60 秒里的窗数（~17 窗/遍）
# 已经够看出「命中数有没有动」。
HEAD=60
OFFSET=0
SESSION=""
MODEL=""
# 墙钟上限。缺省也是 1800（App.swift 的默认值我们不动），这里显式抬高。
# 这台机器有常驻并发负载（Hermes/WorkBuddy 等常吃满 CPU），实测远慢于
# `App.swift` 里记的 1.02 倍实时，所以留足余量
TIMEOUT=7200
while [ $# -gt 0 ]; do
  case "$1" in
    --window-timeout) TIMEOUT="$2"; shift 2 ;;
    --head)    HEAD="$2"; shift 2 ;;
    --offset)  OFFSET="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    *) echo "❌ 认不出来的参数：$1"; exit 2 ;;
  esac
done

[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 ./build.sh"; exit 1; }

PASS=0
FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "════ 术语表前移 A/B（P12-1）════"
echo "二进制: $BIN"

# ── 找一个真实录音 ──
#
# 默认挑会话文件里**唯一那个单段、时长最长**的：多段的会话要拼接，而这一包
# 不测拼接（那是 P11-1 的 `--allow-partial` 和长跑那套的事）
if [ -z "$SESSION" ]; then
  SESSION=$(python3 - "$SESSIONS" <<'PY'
import glob, json, os, sys
best, best_dur = None, -1
for p in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    # index.json 是同目录下唯一一个**顶层是数组**的文件，不是会话
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

WAV=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
f=d['parts'][0].get('fileName')
print(f or '')
" "$SESSION")
[ -n "$WAV" ] || { echo "❌ 会话里那段没有音频文件（那次录制没开存档）"; exit 1; }
WAV="$RECORDINGS/$(basename "$WAV")"
[ -f "$WAV" ] || { echo "❌ 音频不在：$WAV"; exit 1; }

echo "会话: $(basename "$SESSION")"
echo "录音: $(basename "$WAV")（只读）"

# ── 截一段（可选）──
#
# **在临时目录里截**，不动原文件。换 offset 是为了绕开「录音开头是教室杂音 /
# 空场」那种片段——在那种音频上做 A/B，两臂都只剩幻觉，量不出任何东西
TMP=$(mktemp -d "${TMPDIR:-/tmp}/p12-glossary.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
SAMPLE="$WAV"
if [ "$OFFSET" != "0" ]; then
  SAMPLE="$TMP/sample.wav"
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "❌ --offset 需要 ffmpeg（截到临时目录用，不动原文件）"; exit 1
  fi
  ffmpeg -v error -ss "$OFFSET" -t "$HEAD" -i "$WAV" -c copy "$SAMPLE" || {
    echo "❌ ffmpeg 截取失败"; exit 1; }
  echo "样本: 从第 ${OFFSET} 秒起截 ${HEAD} 秒 → 临时目录"
else
  echo "样本: 原文件前 ${HEAD} 秒（--head）"
fi

# ── 模型 ──
MODEL_ARG=()
if [ -n "$MODEL" ]; then
  [ -f "$MODEL" ] || { echo "❌ 模型不在：$MODEL"; exit 1; }
  export CLASSROOM_WHISPER_MODEL="$MODEL"
  echo "模型: $(basename "$MODEL")"
else
  echo "模型: 默认（$(basename "$MODELS/ggml-medium-q5_0.bin")）"
fi
echo ""

# ── 两臂 ──
#
# `--glossary-prompt` = 用磁盘术语表（和界面/重转同一个出处）；
# 不给这个开关 = 与加这一包之前**逐字节一致**的那条路
# `--repeat 2`：**第一遍是冷启动**（Metal 着色器编译、模型首帧），
# 它的单窗耗时比稳态高好几倍。两臂各跑两遍，内容看第 1 遍（冷启动不影响
# 「转出了什么」），耗时看第 2 遍（两臂都热了才可比）。
# 只看一遍会得出「送 prompt 让每一窗慢 4 倍」这种结论——那是冷启动，不是 prompt
#
# 关臂带 `--glossary-score`：**只数命中、不送**。不带的话关臂一个词表都没有，
# 命中栏是空的——而命中数是这一包的主判据，靠空栏比不出任何东西。
# 它和不带这个开关时「送进 whisper 的参数」逐字节一致（`initial_prompt` 照样是
# nullptr），差别只在输出里多了一段打分。③ 那条 grep 就是钉这件事的
echo "── 臂 A：术语前移 开（每臂两遍，耗时看第 2 遍）──"
"$BIN" --whisper-window-file "$SAMPLE" --head "$HEAD" --repeat 2 \
       --window-timeout "$TIMEOUT" --glossary-prompt > "$TMP/on.log" 2>&1
ON_EXIT=$?
echo "── 臂 B：术语前移 关（每臂两遍，耗时看第 2 遍）──"
"$BIN" --whisper-window-file "$SAMPLE" --head "$HEAD" --repeat 2 \
       --window-timeout "$TIMEOUT" --glossary-score > "$TMP/off.log" 2>&1
OFF_EXIT=$?

# ── ① 两臂都跑完 ──
[ "$ON_EXIT" = "0" ] && ok "臂 A（开）exit=0" || bad "臂 A（开）exit=$ON_EXIT"
[ "$OFF_EXIT" = "0" ] && ok "臂 B（关）exit=0" || bad "臂 B（关）exit=$OFF_EXIT"

# ── ② 开的那一臂真的送了 ──
ON_NOTE=$(grep -m1 '^  术语前移：' "$TMP/on.log")
if [[ "$ON_NOTE" == *"术语前移：开"* ]]; then
  ok "开臂的报告行说「开」：${ON_NOTE#  }"
else
  bad "开臂的报告行没说「开」（实得：${ON_NOTE:-无}）"
fi
ON_PROMPT=$(grep -m1 '^  prompt 长度 ' "$TMP/on.log")
if [ -n "$ON_PROMPT" ]; then
  ok "开臂打出了 prompt 的长度与正文"
else
  bad "开臂没有 prompt 那一行 —— 开关开了却没送出去"
fi
# `--glossary-prompt-text` 之外还有一条路会让这里绿：词表读不出来。
# 所以额外要求「装进 N 条」的 N ≥ 1
ON_KEPT=$(grep -m1 -o '装进 [0-9]* 条' "$TMP/on.log" | grep -o '[0-9]*' | head -1)
if [ -n "$ON_KEPT" ] && [ "$ON_KEPT" -ge 1 ]; then
  ok "开臂装进了 ${ON_KEPT} 条术语（不是「开了但一条没送」）"
else
  bad "开臂装进的条数是 ${ON_KEPT:-未知} —— 词表读不出来或上限小到装不下"
fi

# ── ③ 关的那一臂一个字节都没送 ──
if grep -q '术语表前移\|initial_prompt\|prompt 长度' "$TMP/off.log"; then
  bad "关臂里出现了「术语表前移 / initial_prompt」——关掉开关后参数和今天不一样了"
else
  ok "关臂输出里没有任何 prompt 痕迹（关掉 = 与今天逐字节一致）"
fi

# ── ④ 四个数：两臂都打出来 ──
note() { grep -m1 -o "$2" "$1" | head -1; }
seg()  { note "$1" '段数 [0-9]*（定稿 [0-9]*）' | sed 's/^段数 //;s/（定稿 /（定稿 /'; }
chars(){ note "$1" '总字数 [0-9]*（最终输出）' | sed 's/^总字数 //;s/（最终输出）//'; }
hit()  { note "$1" '词表命中：[0-9]*/[0-9]* 个词正确出现 · 出现次数合计 [0-9]*'; }
wall() { note "$1" '离线全程 [0-9.]* 秒' | sed 's/^离线全程 //;s/ 秒$//'; }
occ()  { note "$1" 'Whisper 滑窗 [0-9]* 窗 · 单次转写 均 [0-9.]* / 中位 [0-9.]* / 最大 [0-9.]* 秒 · 步长 [0-9.]* 秒 → 占用 [0-9]*%'; }
# 第 2 遍（暖态）的单窗均值：冷启动已经把着色器编完了，两臂这时才可比
warm() { grep '第 2/2 遍' "$1" | grep -o '均 [0-9.]*' | head -1 | sed 's/^均 //'; }

echo ""
echo "── 对照（同一段音频、同一个模型，唯一变量是那个开关）──"
printf '  %-22s %-14s %-14s\n' "项" "臂A 开" "臂B 关"
printf '  %-22s %-14s %-14s\n' "段数"    "$(seg "$TMP/on.log")"   "$(seg "$TMP/off.log")"
printf '  %-22s %-14s %-14s\n' "总字数"  "$(chars "$TMP/on.log")" "$(chars "$TMP/off.log")"
printf '  %-22s %-14s %-14s\n' "词表命中" "$(hit "$TMP/on.log")"  "$(hit "$TMP/off.log")"
printf '  %-22s %-14s %-14s\n' "墙钟(秒)" "$(wall "$TMP/on.log")" "$(wall "$TMP/off.log")"
printf '  %-22s %-14s %-14s\n' "暖态单窗均(秒)" "$(warm "$TMP/on.log")" "$(warm "$TMP/off.log")"
echo ""
echo "  prompt 长度：$(grep -m1 -o 'prompt 长度 [0-9]* 字' "$TMP/on.log" || echo 无)"
echo "  $(grep -m1 '^  prompt 长度 ' "$TMP/on.log" | sed 's/^  prompt 长度 [0-9]* 字 · //' || true)"
echo "  单窗：A $(occ "$TMP/on.log")"
echo "        B $(occ "$TMP/off.log")"
echo ""
echo "  两臂日志：${TMP}（脚本退出时删掉；要看细节就把它拿走）"

echo ""
if [ "$FAIL" = "0" ]; then
  echo "  ── ${PASS} 条全过（命中数只报不判：那要看数字说人话）──"
else
  echo "  ── ${PASS} 过 / ${FAIL} 红 ──"
fi
exit $([ "$FAIL" = "0" ] && echo 0 || echo 1)
