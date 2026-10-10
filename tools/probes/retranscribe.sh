#!/bin/bash
# 课后重转（P11-1）的**可复跑判据**。
#
# 它跑的是真模型、真录音，所以不进 `exit_codes.sh` 那条「快、确定性」的扫描——
# 一条 large 的 120 秒样本就要六七分钟。这条脚本是给「换一次模型/改一次重转」
# 之后照着复跑用的。
#
# 判据四条，缺一条这个包就不算交付：
#   ① **实际加载的是哪一个模型**——断言输出里那行路径，是 whisper 真打开的文件，
#      不是一句「已用 large」。变异「把重转引擎写死回 medium」就是靠它红的；
#   ② **large 真的比 medium 转出来的多**——同一段音频两个引擎各跑一遍，
#      段数和字数都要多（数不许只看一次：一次测量证明不了任何事）；
#   ③ **输入会话文件一个字节没动**——跑前跑后 sha256 相同。这个入口只写
#      `--out` 里的副本，③ 是这件事的机器判据；
#   ④ **缺 large 时响亮拒绝**——把模型目录指向空目录，退出码非 0 且说出
#      「不会静默回落到 medium」。这一条**不需要真模型**，秒级。
#
# 用法：
#   tools/probes/retranscribe.sh                 # 默认 head 120 秒
#   tools/probes/retranscribe.sh --head 30       # 想快点就截短（这是半份音频，
#                                                # 只用来量段数/字数谁多）
#   tools/probes/retranscribe.sh --session <会话 json>
#   CLASSROOM_BIN=build-verify/... tools/probes/retranscribe.sh
#
# **不碰麦克风、不发声、不改系统音量、不写用户的真实库**：输入会话是从库里
# 复制到临时目录的一份副本，输出全部落在临时目录里。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN="${CLASSROOM_BIN:-build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}"
LIB="$HOME/Library/Application Support/ClassroomTranscriber"
SESSIONS="$LIB/sessions"
MODELS="${CLASSROOM_MODELS_DIR:-$LIB/models}"

HEAD=120
SESSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head)    HEAD="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    *) echo "❌ 认不出来的参数：$1"; exit 2 ;;
  esac
done

[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 ./build.sh"; exit 1; }

FAIL=0
PASS=0
ok()   { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "════ 课后重转判据（P11-1）════"
echo "二进制: $BIN"
echo "模型目录: $MODELS"
echo ""

# ── ④ 缺 large 时响亮拒绝（先跑，秒级，且不加载模型）──
#
# 模型的裁决发生在**读音频之前**，所以这里不需要真音频：一条把 segments 清空的
# 夹具会话就够走到那一支。夹具在临时目录里造，用户真实库只读。
#
# **medium 必须真的在那边**（`cp -c` 做 APFS 写时复制克隆，不占第二份空间）：
# 目录全空时，「缺 large 就换 medium」那种实现照样会走到「medium 也不在」，
# 照样退出非 0——判据全绿而回落已经落码。这条判据能红，全靠这个现场。
#
# 也**不能用符号链接**（试过，不行）：`ModelAvailability.probe` 走
# `FileManager.attributesOfItem(atPath:)`，它不跟随符号链接，拿到的是链接自身
# 的大小（实测 89 字节），夹具就退化成「medium 也不在」。见 `exit_codes.sh`
# 里同一条夹具的注释
echo "── ④ 缺 large 时响亮拒绝（模型目录里只有 medium）──"
EMPTY="$(mktemp -d)"
FIXTURE="$(mktemp -d)"
OUTDIR="$(mktemp -d)"
if [ -f "$MODELS/ggml-medium-q5_0.bin" ]; then
  cp -c "$MODELS/ggml-medium-q5_0.bin" "$EMPTY/ggml-medium-q5_0.bin"
else
  echo "  ⏭  本机没有 medium 模型，「回落能不能成功」这个现场造不出来，跳过"
fi
cat > "$FIXTURE/fixture.json" <<JSON
{"id":"00000000-0000-0000-0000-0000000000AA","startedAt":0,"updatedAt":0,
 "parts":[{"id":"00000000-0000-0000-0000-0000000000BB","fileName":"fixture.wav",
 "startedAt":0,"durationMillis":120000,"offsetMillis":0,"segments":[]}]}
JSON
REFUSE_OUT="$(env CLASSROOM_MODELS_DIR="$EMPTY" "$BIN" --retranscribe "$FIXTURE/fixture.json" \
  --out "$OUTDIR" --engine large --head "$HEAD" --allow-partial 2>&1)"
REFUSE_CODE=$?
if [ "$REFUSE_CODE" != "0" ] \
   && printf '%s' "$REFUSE_OUT" | grep -qF "不会静默回落到 medium" \
   && printf '%s' "$REFUSE_OUT" | grep -qF "ggml-large-v3-q5_0.bin"; then
  ok "缺 large → exit=${REFUSE_CODE}，且说出了「不会静默回落到 medium」"
else
  bad "缺 large 没有响亮拒绝（exit=${REFUSE_CODE}，期望非 0 且带理由）"
  printf '       %s\n' "$(printf '%s' "$REFUSE_OUT" | head -3 | tr '\n' ' ')"
fi
# 「拒绝」还必须是「一个字都没写」——拦住了却在 out 里留了半份，
# 等于把拦截变成了一个更隐蔽的假绿
if [ -z "$(ls -A "$OUTDIR" 2>/dev/null)" ]; then
  ok "被拦住的这一趟没有往 --out 里写任何文件"
else
  bad "被拦住了却写了东西：$(ls -A "$OUTDIR" | tr '\n' ' ')"
fi
rm -rf "$EMPTY" "$FIXTURE" "$OUTDIR"

# ── 挑一条会话 ──
if [ -z "$SESSION" ]; then
  # 挑**最短**的一条：判据是「两个引擎谁多」，跟会话长短无关，
  # 而课堂量级（两千秒）跑一趟是小时级，不该是默认行为
  SESSION="$(python3 - "$SESSIONS" <<'PY'
import glob, json, os, sys
best, best_dur = None, None
for path in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(path))
        parts = d.get("parts", [])
        if not parts or not all(isinstance(p, dict) for p in parts):
            continue
        dur = sum(p.get("durationMillis", 0) for p in parts)
        if dur <= 0:
            continue
        if best_dur is None or dur < best_dur:
            best, best_dur = path, dur
    except Exception:
        continue
print(best or "")
PY
)"
fi
[ -n "$SESSION" ] && [ -f "$SESSION" ] || { echo "❌ 找不到可用的会话（${SESSIONS}）"; exit 1; }

T="$(mktemp -d)"
mkdir -p "$T/in"
cp "$SESSION" "$T/in/session.json"
BEFORE="$(shasum -a 256 "$T/in/session.json" | awk '{print $1}')"
echo ""
echo "会话: $SESSION"
echo "副本: $T/in/session.json（sha256 ${BEFORE}）"
echo "截断: 每段前 $HEAD 秒（测量用；转出来是半份，所以带 --allow-partial）"
echo ""

run_engine() { # run_engine <档> → 打日志，回显段数/字数，落全局 EXIT/SEGS/CHARS/MODEL_LINE
  local engine="$1"
  "$BIN" --retranscribe "$T/in/session.json" --out "$T/out-$engine" \
    --engine "$engine" --head "$HEAD" --allow-partial > "$T/$engine.log" 2>&1
  EXIT=$?
  SEGS="$(grep -oE '段数 [0-9]+' "$T/$engine.log" | tail -1 | awk '{print $2}')"
  CHARS="$(grep -oE '字数 [0-9]+' "$T/$engine.log" | tail -1 | awk '{print $2}')"
  MODEL_LINE="$(grep -F '🔎 实际加载的模型:' "$T/$engine.log" | tail -1)"
}

echo "── ①②③ 同一段音频，两个引擎各跑一遍 ──"
run_engine medium
MED_EXIT=$EXIT; MED_SEGS=$SEGS; MED_CHARS=$CHARS; MED_MODEL="$MODEL_LINE"
printf '  medium: exit=%s · 段数=%s · 字数=%s\n' "$MED_EXIT" "$MED_SEGS" "$MED_CHARS"
printf '          %s\n' "$MED_MODEL"

run_engine large
LRG_EXIT=$EXIT; LRG_SEGS=$SEGS; LRG_CHARS=$CHARS; LRG_MODEL="$MODEL_LINE"
printf '  large : exit=%s · 段数=%s · 字数=%s\n' "$LRG_EXIT" "$LRG_SEGS" "$LRG_CHARS"
printf '          %s\n' "$LRG_MODEL"

echo ""
# ① 判据是**路径**，不是「已用 large」那句话：一句话可以由任何一个常量拼出来
if printf '%s' "$LRG_MODEL" | grep -qF "$MODELS/ggml-large-v3-q5_0.bin"; then
  ok "① large 那趟实际加载的是 $MODELS/ggml-large-v3-q5_0.bin"
else
  bad "① large 那趟实际加载的不是 large（${LRG_MODEL}）"
fi
if printf '%s' "$MED_MODEL" | grep -qF "$MODELS/ggml-medium-q5_0.bin"; then
  ok "① medium 那趟实际加载的是 $MODELS/ggml-medium-q5_0.bin"
else
  bad "① medium 那趟实际加载的不是 medium（${MED_MODEL}）"
fi
[ "$LRG_EXIT" = "0" ] && ok "large 那趟 exit=0" || bad "large 那趟 exit=$LRG_EXIT"
[ "$MED_EXIT" = "0" ] && ok "medium 那趟 exit=0" || bad "medium 那趟 exit=$MED_EXIT"

# ② 同一段音频，large 的段数与字数都要比 medium 多
if [ -n "$LRG_SEGS" ] && [ -n "$MED_SEGS" ] && [ "$LRG_SEGS" -gt "$MED_SEGS" ]; then
  ok "② large 段数更多（$LRG_SEGS > ${MED_SEGS}）"
else
  bad "② large 段数没有更多（large=$LRG_SEGS medium=${MED_SEGS}）"
fi
if [ -n "$LRG_CHARS" ] && [ -n "$MED_CHARS" ] && [ "$LRG_CHARS" -gt "$MED_CHARS" ]; then
  ok "② large 字数更多（$LRG_CHARS > ${MED_CHARS}）"
else
  bad "② large 字数没有更多（large=$LRG_CHARS medium=${MED_CHARS}）"
fi

# ③ 输入会话文件跑前跑后 sha256 相同（这个入口只写 --out 里的副本）
AFTER="$(shasum -a 256 "$T/in/session.json" | awk '{print $1}')"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "③ 输入会话 sha256 未变（${BEFORE}）"
else
  bad "③ 输入会话被改了：$BEFORE → $AFTER"
fi
# 副本里要真的写上了出处——「跑了但没记账」是这一包最不该出现的形状
if grep -qF '"transcriptionProvenance"' "$T/out-large/session.json" 2>/dev/null; then
  ok "③ 副本里写出了 transcriptionProvenance"
else
  bad "③ 副本里没有 transcriptionProvenance"
fi
if grep -qF '"modelFile" : "ggml-large-v3-q5_0.bin"' "$T/out-large/session.json" 2>/dev/null; then
  ok "③ 出处里记的是 large-v3 那一份"
else
  bad "③ 出处里记的不是 large-v3"
fi

# ── ⑤ store 那条路：取消之后旧转录还在不在 ──
#
# ①②③④ 走的是 `--retranscribe`（`RetranscribeRun`），而**用户点「重转」走的是
# `RecordingsStore`**——两条路。这一条把 store 真的驱动一遍（真加载模型、真转
# 合成音频），验的是本包唯一会**悄悄毁掉用户看过的内容**的那件事：
# 中途取消之后，存档文件的 sha256 必须一个字节都不变。
#
# 这条放这儿而不是 `exit_codes.sh`：它要真模型、要 `say`、跑一趟一分多钟，
# 而那边是「快、确定性」的扫描。缺 large 就 ⏭ 跳过——**不假装验过**
echo ""
echo "── ⑤ store 路径 · 取消不留半个转录 ──"
STORE_OUT="$("$BIN" --retranscribe-store-selftest 2>&1)"
STORE_CODE=$?
if [ -f "$MODELS/ggml-large-v3-q5_0.bin" ]; then
  if [ "$STORE_CODE" = "0" ] \
     && printf '%s' "$STORE_OUT" | grep -qF "✅ 课后重转 store 自检通过"; then
    ok "⑤ store 路径自检通过（$(printf '%s' "$STORE_OUT" | grep -oE 'store 自检通过（[0-9]+ 条）' | tail -1)）"
  else
    bad "⑤ store 路径自检没过（exit=${STORE_CODE}）"
    printf '%s\n' "$STORE_OUT" | grep -E '❌' | sed 's/^/       /' | head -5
  fi
  # 取消那一条是重点，单独回显出来：判据绿了但「取消的时机」是空转的话，
  # 上面那条绿是假的（见自检里 `sawWindow` 那条 check）
  printf '%s\n' "$STORE_OUT" | grep -F "取消的时机落在了第一段转了一半的时候" \
    | sed 's/^/       /'
else
  echo "  ⏭  本机没有 large 模型，store 路径自检跳过（它在缺模型时会响亮失败、不算通过）"
fi

echo ""
echo "日志留在 ${T}（medium.log / large.log），要复查就去看"
echo "──── 合计：过的有 $PASS 条，没过 $FAIL 条 ────"
[ "$FAIL" = "0" ] && echo "✅ 课后重转判据全过" || echo "❌ 有判据没过，逐条看上面"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
