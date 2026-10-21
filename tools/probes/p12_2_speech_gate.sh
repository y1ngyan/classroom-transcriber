#!/bin/bash
# P12-2 静音门控（第一步）· 验收探针
#
# 四臂对照，全部跑**真实录音**（用户库里的课堂录音，不造输入）：
#   · 改造前   = 基线 `6f664e8`（无门控、步长 3 秒）——在**临时 worktree** 里编，
#                不动工作区、不动用户那份 `build/`
#   · 改造前取窗·参照 = 新代码 + `--step 3.0` + `CLASSROOM_SPEECH_GATE=off`
#   · 改造后·门控关 = 新代码 + `CLASSROOM_SPEECH_GATE=off`（判「关掉与今天一致」）
#   · 改造后·门控开 = 新代码（缺省）
#
# **为什么非要有「参照」那一臂**：判据 ③ 要判「同一句话的起止偏差 ≤ 500ms」，
# 而基线那份 `--dump-all` 只打到秒——`1 [00:00:00] (存疑) (拍摄)`，没有毫秒列、
# 没有终点、没有定稿标记。秒级分辨率比判据本身还粗（实测：解析器读基线输出
# 时**一段都解析不出来**，判据直接变成「读不了输入」）。参照臂用**同一份代码 +
# 基线步长**：取窗节奏与基线逐字相同（基线源码就是「按 0.5 秒分块喂入 +
# `nextWindowAt += stepMillis`」），输出格式与被测臂相同，于是逐段按毫秒对账
# 成立。参照臂与真基线之间另有一条**桥**（判据 ③b，文本一致 + 秒级量化内），
# 桥过了，参照臂才代表得了「改造前」——**这一步不过，③ 就是对着没接上的线在量**。
#
# 五条判据：
#   ② 正向：跳过率 / CPU 秒 / 段数 / 总字数 / 幻觉丢弃（含「真的解了 == 取窗 - 跳过」恒等式）
#   ③ 反向：改造后每一段**定稿**文本在**参照臂**里找得到对应，且起止偏差 ≤ 重叠量
#   ③b 桥：参照臂复现了真基线（段数 / 字数 / 逐段文本 / 起点在秒级量化内）
#   ④ 开关：门控关掉时 **一窗都不跳**（跳过 == 0 且 真的解了 == 取窗）
#   ① 门控自检：`--speech-gate-selftest` 全绿（纯函数，与模型无关）
#
# 为什么这个探针不在 `exit_codes.sh` 里：它要**另编一份基线二进制**（十几分钟）
# 并且每条录音要跑四趟模型。那条快扫描的规矩是「分钟级、确定性」，
# 所以这里单独放，跟 `retranscribe.sh` 同一个理由。
#
# 用法：
#   ./tools/probes/p12_2_speech_gate.sh
#   CLASSROOM_BIN=build-verify/…/ClassroomTranscriber ./tools/probes/p12_2_speech_gate.sh
#   P12_2_HEAD=60        # 每条只跑前 N 秒（默认 120；音频越长越慢）
#   P12_2_OUT=/tmp/xx    # 输出目录（默认 /tmp/p12_2_gate）
#   CLASSROOM_P12_2_BASELINE_BIN=<已编好的基线二进制>   # 跳过 worktree 编译
#
# 退出码 0 = 判据 ①②③③b④ 全部通过。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN="${CLASSROOM_BIN:-build-verify/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}"
OUT="${P12_2_OUT:-/tmp/p12_2_gate}"
HEAD="${P12_2_HEAD:-120}"
# 判据 ③ 的容差 = **实际**取窗重叠量。
#
# 生产步长 3 秒（P12-2 试过 9.6 秒、没上：见交付报告「重叠压缩」一节），
# 而取窗落在**喂入块的边界**上（`chunkSeconds = 0.5`），所以真实窗起点是
# 「喂入时刻往回 10 秒」——实测 0 / 0 / 0 / 2 / 5 / 8 / 11 … / 110，前面
# 那几个重复起点被「同一窗不重转」挡掉，之后就每 3 秒一窗 → **相邻重叠 7 秒**。
# 容差取 7 秒和这个网格对得上；换成别的步长跑时用 `P12_2_OVERLAP_MS` 改。
#
# ⚠️ 这个容差很松（7 秒），所以它**只能证明「没有整段内容消失」**，证明不了
# 「每个词的边界都没挪」——压缩重叠的代价要靠灵敏度表（3.0/5.0/7.0/9.6）
# 才看得出来，那一节在交付报告里。
OVERLAP_MS="${P12_2_OVERLAP_MS:-7000}"
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
BASELINE_COMMIT="6f664e8"

# 两段录音的选择**看的是实测分布**（`swift tools/audio_health.swift <录音>`，
# 2026-10-15 复测），不是随手挑一条：
#   · 长静音那条：227.9 秒里只有 0–30 秒有说话（语音帧占比 19.3%），
#     之后每 30 秒依次 3.9 / 9.5 / 4.5 / 2.2 / 2.3 / 1.9%——翻页、写字、课间都在里面
#   · 有说话那条：368.2 秒，前 150 秒语音帧占比 38.7–65.7%（p90 0.039–0.077），
#     是**真人连续说话 + 停顿**，用来判「不许丢真人说话」
SILENT_REC="$REC/课堂-20260921-084403.wav"
SPEECH_REC="$REC/课堂-20260921-194730.wav"

echo "BIN=${BIN}"
echo "  只跑前 ${HEAD} 秒（P12_2_HEAD 可改）· 输出落 ${OUT}"
[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 CLASSROOM_BUILD_DIR=build-verify ./build.sh"; exit 1; }
for path in "$SILENT_REC" "$SPEECH_REC"; do
  [ -f "$path" ] || { echo "❌ 找不到录音：$path"; echo "   （这条探针按名字用用户库里那两条录音；换机器要先确认它们在）"; exit 1; }
done
mkdir -p "$OUT"

step() { echo; echo "════ $(date '+%H:%M:%S')  $* ════"; }

FAIL=0
PASS=0
note() { printf '  %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*"; }

# ── ① 门控自检（纯函数；先跑，红了后面都不用看）──
step "① 门控自检（纯函数／合成波形，不加载模型）"
SELFTEST_OUT="$OUT/speech-gate-selftest.txt"
"$BIN" --speech-gate-selftest > "$SELFTEST_OUT" 2>&1
if [ $? -eq 0 ] && grep -qF "✅ 静音门控自检通过" "$SELFTEST_OUT"; then
  ok "$(grep -F '✅ 静音门控自检通过' "$SELFTEST_OUT" | head -1 | sed 's/^ *//')"
else
  bad "自检没过，输出见 $SELFTEST_OUT"
  tail -20 "$SELFTEST_OUT"
fi

# ── 基线二进制：临时 worktree 里编 ──
BASE_BIN="${CLASSROOM_P12_2_BASELINE_BIN:-}"
WORKTREE=""
if [ -z "$BASE_BIN" ]; then
  step "编基线（${BASELINE_COMMIT}）——临时 worktree，不动工作区、不动你的 build/"
  WORKTREE="$(mktemp -d)/p12_2_base"
  if ! git worktree add --detach "$WORKTREE" "$BASELINE_COMMIT" > "$OUT/worktree.log" 2>&1; then
    echo "❌ git worktree add 失败，见 $OUT/worktree.log"; cat "$OUT/worktree.log"; exit 1
  fi
  # ⚠️ worktree 里 **submodule 是空的**（`git worktree` 不检出 submodule），
  # 而 `build.sh` 见到空的 `Vendor/FluidAudio` 会**响亮拒绝**（这是对的：
  # 少那一块「识别说话人」就不该能跑）。补法是从**本仓库那份已经检出的副本**
  # 离线克隆，而不是去上游拉：
  #   · `insteadOf` 把 submodule 的 URL 换成本地路径 → 不走网络
  #   · `protocol.file.allow=always`：新版 git 默认禁止 file 传输的 submodule 克隆
  #     （`transport 'file' not allowed`），不显式打开就静默走到「Retry scheduled」再失败
  #   · 克隆而不是 `cp -R`：submodule 的 `.git` 是个指向 **主仓库** `.git/modules/…`
  #     的 gitfile，拷过去那份相对路径在 worktree 里解不开，而 `build.sh` 第 ③ 步
  #     要 `git -C Vendor/FluidAudio rev-parse HEAD` 对钉版 sha——拷过去会让它报
  #     「HEAD 是空」（实测踩过）
  if [ ! -f "$WORKTREE/Vendor/FluidAudio/Package.swift" ]; then
    git -C "$WORKTREE" -c protocol.file.allow=always \
      -c url."$PWD/Vendor/FluidAudio".insteadOf="https://github.com/FluidInference/FluidAudio" \
      submodule update --init Vendor/FluidAudio > "$OUT/submodule.log" 2>&1 \
      || { echo "❌ worktree 里 submodule 没检出，见 $OUT/submodule.log"; tail -5 "$OUT/submodule.log"; exit 1; }
    note "worktree 的 submodule 从本仓库离线克隆：$(git -C "$WORKTREE/Vendor/FluidAudio" rev-parse HEAD | cut -c1-12)"
  fi
  # 基线自己编一份：`CLASSROOM_BUILD_DIR` 指进 worktree，绝不碰仓库里的 build/
  ( cd "$WORKTREE" && CLASSROOM_BUILD_DIR=build-base ./build.sh ) > "$OUT/baseline-build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "❌ 基线编译失败，见 $OUT/baseline-build.log"; tail -20 "$OUT/baseline-build.log"; exit 1
  fi
  BASE_BIN="$WORKTREE/build-base/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber"
  [ -x "$BASE_BIN" ] || { echo "❌ 基线二进制没编出来：$BASE_BIN"; exit 1; }
  note "基线二进制：$BASE_BIN"
else
  note "用现成的基线二进制：$BASE_BIN"
fi
# 收尾要清掉 worktree（**留着一个注册在 .git 里的 worktree 会干扰后面的会话**）
cleanup() {
  if [ -n "$WORKTREE" ]; then
    git worktree remove --force "$WORKTREE" >/dev/null 2>&1
    rm -rf "$(dirname "$WORKTREE")"
  fi
}
trap cleanup EXIT

# ── 跑一臂。`/usr/bin/time -l` 拿**整个进程**的 CPU 秒（user+sys），
#    它和进程内自己记的「转写耗时合计」是两个口径，两个都留着：
#    前者含引擎加载与收尾，后者只含真解码的那几窗 ──
# ⚠️ 「用哪个二进制」与「带不带环境变量」是**两个**参数，别合并成一个。
# 第一版把「envspec = -」当成「这一臂用基线二进制」，结果**改造后·门控开**那一臂
# 跑的是基线——输出与被测臂逐字节相同、没有门控账，判据 ② 变成拿基线跟基线比
# （两臂都报 38 窗、段 8、字数 82，「省了 -14.8 秒」），看上去像「门控没用」。
run_arm() { # run_arm <输出名> <base|new> <env 赋值|-> <录音> <标签> [附加参数…]
  local name="$1"; shift
  local which="$1"; shift
  local envspec="$1"; shift
  local audio="$1"; shift
  local label="$1"; shift
  local out="$OUT/$name.txt"
  local timing="$OUT/$name.time"
  local exe="$BIN"
  [ "$which" = base ] && exe="$BASE_BIN"
  if [ "$envspec" = "-" ]; then
    /usr/bin/time -l "$exe" --whisper-window-file "$audio" --head "$HEAD" \
      --dump-all --label "$label" "$@" > "$out" 2> "$timing"
  else
    /usr/bin/time -l env "$envspec" "$exe" --whisper-window-file "$audio" --head "$HEAD" \
      --dump-all --label "$label" "$@" > "$out" 2> "$timing"
  fi
  local code=$?
  # 「用户 CPU 秒」= 进程真的花在计算上的时间（不含等待）。
  # `/usr/bin/time -l` 的输出落在 stderr，正好和程序自己的 stderr 合流到
  # 同一个文件里——取**最后一条** real 行，避免程序自己往 stderr 说话时抓错
  USER_CPU="$(awk '/ real .*user/ {print $3}' "$timing" | tail -1)"
  note "$name → $out （exit=${code}，进程用户 CPU ${USER_CPU:-?} 秒）"
  return $code
}

for case in silent speech; do
  case "$case" in
    silent) AUDIO="$SILENT_REC"; NOTE="长静音（翻页/写字/课间）" ;;
    speech) AUDIO="$SPEECH_REC"; NOTE="有真人连续说话" ;;
  esac
  step "跑四臂：$case —— $(basename "$AUDIO")（${NOTE}）"
  run_arm "$case-before"   base -                              "$AUDIO" "改造前（${BASELINE_COMMIT}）" || bad "$case 改造前那一臂 exit≠0"
  # 参照臂 = 老取窗 + 门控关。**门控必须关**：这一步要复现的是「改造前的取窗」，
  # 混进跳过就不成其为参照了（判据 ③ 要比的就是「同样这些话，换个取窗法还在不在」）
  run_arm "$case-ref"      new "CLASSROOM_SPEECH_GATE=off"         "$AUDIO" "改造前取窗·参照（--step 3.0）" --step 3.0 || bad "$case 参照臂 exit≠0"
  run_arm "$case-off"      new "CLASSROOM_SPEECH_GATE=off"         "$AUDIO" "改造后·门控关"            || bad "$case 门控关那一臂 exit≠0"
  run_arm "$case-on"       new -                                   "$AUDIO" "改造后·门控开"            || bad "$case 门控开那一臂 exit≠0"
done

# ── ② 正向：跳过率与代价 ──
step "② 正向判据：跳过率 / CPU / 段数 / 字数 / 幻觉丢弃"
python3 tools/probes/p12_2_gate_compare.py "$OUT/silent-before.txt" "$OUT/silent-on.txt" \
  --overlap-ms "$OVERLAP_MS" > "$OUT/compare-silent.txt"
cat "$OUT/compare-silent.txt"

# 跳过率判据：长静音那条录音上必须**真的跳了**（否则这道门控等于没接），
# 且恒等式成立（「跳过解码」与「解完再丢」的分水岭）
GATE_LINE="$(grep -F '取窗 ' "$OUT/silent-on.txt" | head -1 | sed 's/^ *//')"
if [ -z "$GATE_LINE" ]; then
  bad "改造后那一臂没有门控账（门控没接上？）"
else
  note "门控账：$GATE_LINE"
  TAKEN="$(printf '%s' "$GATE_LINE" | sed -n 's/取窗 \([0-9]*\).*/\1/p')"
  SKIPPED="$(printf '%s' "$GATE_LINE" | sed -n 's/.*跳过 \([0-9]*\)（.*/\1/p')"
  DECODED="$(printf '%s' "$GATE_LINE" | sed -n 's/.*真的解了 \([0-9]*\) 窗.*/\1/p')"
  if [ "${SKIPPED:-0}" -gt 0 ]; then ok "长静音录音上真的跳了 ${SKIPPED} 窗"; else bad "一窗都没跳——门控没起作用"; fi
  if [ "${DECODED:-0}" = "$(( ${TAKEN:-0} - ${SKIPPED:-0} ))" ]; then
    ok "恒等式：真的解了 ${DECODED} == 取窗 ${TAKEN} - 跳过 ${SKIPPED}（跳过的是**解码**，不是解完再丢）"
  else
    bad "恒等式不成立：真的解了 ${DECODED} ≠ 取窗 ${TAKEN} - 跳过 ${SKIPPED}"
  fi
fi

# ── ③b 桥：参照臂真的复现了基线吗（**先跑，它不过 ③ 就没有意义**）──
step "③b 桥：参照臂（同代码 + --step 3.0 + 门控关）复现了真基线吗"
python3 tools/probes/p12_2_gate_compare.py "$OUT/speech-before.txt" "$OUT/speech-ref.txt" \
  --bridge > "$OUT/bridge-speech.txt"
cat "$OUT/bridge-speech.txt"
if grep -qF "判据 ③b 结论：✅ 通过" "$OUT/bridge-speech.txt"; then
  ok "桥接上：参照臂与基线段数/字数/逐段文本一致、起点在秒级量化内"
else
  bad "桥没接上——判据 ③ 的参照臂代表不了改造前，先看 $OUT/bridge-speech.txt"
fi

# ── ③ 反向：不许丢真人说话 ──
step "③ 反向判据：有说话的录音上，逐段定稿文本对账（对参照臂）"
python3 tools/probes/p12_2_gate_compare.py "$OUT/speech-ref.txt" "$OUT/speech-on.txt" \
  --overlap-ms "$OVERLAP_MS" > "$OUT/compare-speech.txt"
cat "$OUT/compare-speech.txt"
if grep -qF "判据 ③ 结论：✅ 通过" "$OUT/compare-speech.txt"; then
  ok "判据 ③ 通过（每一段定稿文本都在参照臂里找得到，且起止偏差 ≤ ${OVERLAP_MS}ms = 实际重叠量）"
else
  bad "判据 ③ 红——改造后有定稿文本在参照臂里找不到对应，或起止偏差超过重叠量（${OVERLAP_MS}ms）"
fi

# ── ④ 开关：关掉之后一窗都不跳 ──
step "④ 开关判据：门控关掉时，行为与「没有这道门」一致"
if grep -qF "跳过 0（0.0%）" "$OUT/silent-off.txt"; then
  OFF_LINE="$(grep -F '取窗 ' "$OUT/silent-off.txt" | head -1 | sed 's/^ *//')"
  OFF_TAKEN="$(printf '%s' "$OFF_LINE" | sed -n 's/取窗 \([0-9]*\).*/\1/p')"
  OFF_DECODED="$(printf '%s' "$OFF_LINE" | sed -n 's/.*真的解了 \([0-9]*\) 窗.*/\1/p')"
  if [ "${OFF_DECODED:-0}" = "${OFF_TAKEN:-0}" ] && [ "${OFF_TAKEN:-0}" -gt 0 ]; then
    ok "门控关：跳过 0，${OFF_TAKEN} 窗全部送进模型（同一个开关、同一条取窗路径）"
  else
    bad "门控关：跳过是 0，但真的解了 ${OFF_DECODED} ≠ 取窗 ${OFF_TAKEN}"
  fi
else
  bad "门控关那一臂的账不是「跳过 0」——关掉开关没有还原成「没有门」的行为"
  grep -F '取窗 ' "$OUT/silent-off.txt" | head -1
fi

step "汇总"
echo "  通过 $PASS 条 · 红 $FAIL 条 · 明细在 $OUT/"
[ "$FAIL" -eq 0 ] && echo "✅ P12-2 门控探针全部通过" || echo "❌ P12-2 门控探针有红"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
