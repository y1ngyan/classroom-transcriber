#!/bin/bash
# P12-3 验收探针 · 一次跑出全部读数
#
# 验的是「静音门控的开关从**设置页那一层**也走得通」，而不是只有环境变量。
#
# 七节：
#   ⓪ 前置：二进制 / 模型 / 两段真实录音都在；记下用户真实库的指纹
#   ① 门控自检（纯函数）：含 P12-3 新增的「设置页 / 环境变量」优先级边界
#   ② 配置往返自检：老配置没有该字段 → 开；写 false/true → 重读 false/true
#   ③ 四臂 × 两条真实录音（全部走用户设置目录的**副本**，真 config.json 不碰）：
#        设置页·开 / 设置页·关 / 环境变量·关（文件写开） / 环境变量·开（文件写关）
#      判据：静音那条 开=38 取窗/28 跳过、关=38 全解；说话那条四臂逐项相同
#   ④ 两条路读数一致：设置页关 == 环境变量关，设置页开 == 环境变量开
#   ⑤ 现有快扫描 `tools/probes/exit_codes.sh`（不含麦克风、不含联网那两段）
#   ⑥ 收尾：用户真实 config.json 与 recordings/ 逐文件 sha256 前后一致、
#      用户那份 `build/` 一个文件都没被动过
#
# **这个脚本只跑项目自己的二进制和只读命令**：不重编、不写 `build/`、不碰
# 麦克风、不发声。写盘只有两处，都在临时目录：`$P12_3_OUT`（默认 /tmp/p12_3_verify）
# 和给 `CFFIXED_USER_HOME` 造的假 home。
#
# 用法：
#   CLASSROOM_BUILD_DIR=build-verify ./build.sh
#   CLASSROOM_BIN=build-verify/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber \
#     ./tools/probes/p12_3_verify.sh
#
#   P12_3_HEAD=120    # 每条录音只跑前 N 秒（默认 120，与 P12-2 的背景数字同口径）
#   P12_3_OUT=/tmp/x  # 输出目录
#
# 退出码 0 = 七节全部通过。约 15–20 分钟（八臂真模型 + 快扫描），
# 耗时大头是「静音那条·关门」与「说话那条」每臂 100–180 秒。

set -uo pipefail
cd "$(dirname "$0")/../.."

# 调用者 shell 里若恰好导出了这个变量，「设置页」两臂会被静默强制覆盖，
# 读数看起来全绿却根本没走设置页。本脚本要验的正是设置页那条路
unset CLASSROOM_SPEECH_GATE

BIN="${CLASSROOM_BIN:-build-verify/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}"
OUT="${P12_3_OUT:-/tmp/p12_3_verify}"
HEAD="${P12_3_HEAD:-120}"
MODELS="${CLASSROOM_MODELS_DIR:-$HOME/Library/Application Support/ClassroomTranscriber/models}"
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
CONFIG="$HOME/Library/Application Support/ClassroomTranscriber/config.json"
SILENT_REC="$REC/课堂-20260921-084403.wav"
SPEECH_REC="$REC/课堂-20260921-194730.wav"

mkdir -p "$OUT"
# 先清掉上一次的臂输出：哪一臂这次没跑成，绝不许拿旧文件冒充这次的读数
rm -f "$OUT"/silent-*.txt "$OUT"/silent-*.time "$OUT"/speech-*.txt "$OUT"/speech-*.time
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*"; }
step() { echo; echo "════ $(date '+%H:%M:%S')  $* ════"; }

# ── ⓪ 前置 ──
step "⓪ 前置检查"
echo "BIN=${BIN}"
echo "  只跑前 ${HEAD} 秒 · 输出落 ${OUT} · 模型目录 ${MODELS}"
[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}；先 CLASSROOM_BUILD_DIR=build-verify ./build.sh"; exit 1; }
[ -f "$MODELS/ggml-medium-q5_0.bin" ] || { echo "❌ 缺模型：$MODELS/ggml-medium-q5_0.bin"; exit 1; }
for path in "$SILENT_REC" "$SPEECH_REC"; do
  [ -f "$path" ] || { echo "❌ 找不到录音：$path"; exit 1; }
done

# 用户真实库的指纹。**只取哈希，不把内容打印出来**（config.json 里有密钥）
fingerprint_recordings() {
  find "$REC" -type f -print0 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null | sort
}
fingerprint_config() {
  if [ -f "$CONFIG" ]; then shasum -a 256 "$CONFIG" | awk '{print $1}'; else echo "不存在"; fi
}
fingerprint_build() {
  [ -d build ] || { echo "不存在"; return; }
  find build -type f -print0 2>/dev/null | xargs -0 stat -f '%N|%m|%z' 2>/dev/null | sort \
    | shasum -a 256 | awk '{print $1}'
}
REC_BEFORE="$(fingerprint_recordings)"
CONFIG_BEFORE="$(fingerprint_config)"
BUILD_BEFORE="$(fingerprint_build)"
echo "  录音库：$(printf '%s\n' "$REC_BEFORE" | grep -c . ) 个文件 · config.json sha256 ${CONFIG_BEFORE:0:16}… · build/ ${BUILD_BEFORE:0:16}…"

# 两个假 home：设置页「开」与「关」各一份配置。**不动真 config.json**
HOME_ON="$OUT/home-on"
HOME_OFF="$OUT/home-off"
for pair in "on:true" "off:false"; do
  suffix="${pair%%:*}"; value="${pair##*:}"
  dir="$OUT/home-$suffix/Library/Application Support/ClassroomTranscriber"
  mkdir -p "$dir"
  printf '{"speechGate": %s}\n' "$value" > "$dir/config.json"
done

# ── ① 门控自检 ──
step "① 门控自检（纯函数／合成波形）"
"$BIN" --speech-gate-selftest > "$OUT/speech-gate-selftest.txt" 2>&1
if [ $? -eq 0 ] && grep -qF "✅ 静音门控自检通过（33 条）" "$OUT/speech-gate-selftest.txt"; then
  ok "$(grep -F '✅ 静音门控自检通过' "$OUT/speech-gate-selftest.txt" | head -1 | sed 's/^ *//')"
else
  bad "门控自检没过（或条数变了），见 $OUT/speech-gate-selftest.txt"
  grep -F '❌' "$OUT/speech-gate-selftest.txt" | head -5
fi

# ── ② 配置往返自检 ──
step "② 配置往返自检（临时目录；真 config.json 不碰）"
# CFFIXED_USER_HOME 把「真文件」也挪进临时目录（`HOME=` 对 Foundation 无效，
# 见 AppConfig.selfTest 里那段）。这里另造一个空临时目录，与假 home 分开
CFGFIX="$(mktemp -d)"
CFFIXED_USER_HOME="$CFGFIX" "$BIN" --config-selftest > "$OUT/config-selftest.txt" 2>&1
rm -rf "$CFGFIX"
for want in \
  "✅ 静音窗跳过·老配置没有该字段 → 读出来是开" \
  "✅ 静音窗跳过·落盘往返：写 false → 重读 false，写 true → 重读 true" \
  "✅ 静音窗跳过·优先级：环境变量 off 盖过文件 true → 关，环境变量 1 盖过文件 false → 开"; do
  if grep -qF "$want" "$OUT/config-selftest.txt"; then
    ok "${want#✅ }"
  else
    bad "配置自检缺这一行：${want}"
  fi
done
grep -qF "✅ 真实配置全程未被触碰（指纹一致" "$OUT/config-selftest.txt" \
  && ok "配置自检：真实配置全程未被触碰（指纹一致）" \
  || bad "配置自检：真实配置指纹变了"

# ── 跑一臂 ──
# run_arm <名字> <假 home> <环境变量值|-> <录音> <标签>
# home 是**用户设置的副本**；envspec 非 - 时再叠一层 CLASSROOM_SPEECH_GATE。
run_arm() {
  local name="$1" home="$2" envspec="$3" audio="$4" label="$5"
  local out="$OUT/$name.txt" timing="$OUT/$name.time"
  if [ "$envspec" = "-" ]; then
    CFFIXED_USER_HOME="$home" CLASSROOM_MODELS_DIR="$MODELS" \
      /usr/bin/time -l "$BIN" --whisper-window-file "$audio" --head "$HEAD" \
      --label "$label" > "$out" 2> "$timing"
  else
    CFFIXED_USER_HOME="$home" CLASSROOM_MODELS_DIR="$MODELS" CLASSROOM_SPEECH_GATE="$envspec" \
      /usr/bin/time -l "$BIN" --whisper-window-file "$audio" --head "$HEAD" \
      --label "$label" > "$out" 2> "$timing"
  fi
  local code=$?
  [ "$code" = "0" ] || { bad "$name exit=${code}（见 ${out}）"; return 1; }
  printf '  · %-14s %s\n' "$name" "$(gate_line "$out")"
  printf '  %-16s %s\n' "" "$(qual_line "$out")"
  return 0
}

gate_line() { grep -F '取窗 ' "$1" | head -1 | sed 's/^ *//'; }
qual_line() {
  local seg chars cov
  seg="$(grep -F '段数 ' "$1" | head -1 | sed 's/^ *//')"
  chars="$(grep -F '总字数 ' "$1" | head -1 | sed 's/^ *//')"
  cov="$(grep -F '覆盖率:' "$1" | head -1 | sed 's/^ *//')"
  printf '%s；%s；%s' "${seg:-段数?}" "${chars:-总字数?}" "${cov:-覆盖率?}"
}
decode_cpu() { grep -F '转写耗时合计' "$1" | head -1 | sed 's/^ *//'; }

expect_line() { # expect_line <名字> <输出文件> <必须出现的固定串>
  if grep -qF "$3" "$2"; then
    ok "$1：$3"
  else
    bad "$1 缺「$3」——实际：$(gate_line "$2")"
  fi
}

# ── ③ 四臂 × 两条录音 ──
step "③ 长静音那条（课堂-20260921-084403，前 ${HEAD} 秒）"
run_arm silent-settings-on  "$HOME_ON"  -     "$SILENT_REC" "设置页·开" \
  && expect_line "静音·设置页开" "$OUT/silent-settings-on.txt" \
       "取窗 38 · 跳过 28（73.7%）· 跳过音频 280.0 秒 · 真的解了 10 窗"
run_arm silent-settings-off "$HOME_OFF" -     "$SILENT_REC" "设置页·关" \
  && expect_line "静音·设置页关" "$OUT/silent-settings-off.txt" \
       "取窗 38 · 跳过 0（0.0%）· 跳过音频 0.0 秒 · 真的解了 38 窗"
run_arm silent-env-off      "$HOME_ON"  off   "$SILENT_REC" "环境变量·关（文件开着）" \
  && expect_line "静音·环境变量关" "$OUT/silent-env-off.txt" \
       "取窗 38 · 跳过 0（0.0%）· 跳过音频 0.0 秒 · 真的解了 38 窗"
run_arm silent-env-on       "$HOME_OFF" 1     "$SILENT_REC" "环境变量·开（文件关着）" \
  && expect_line "静音·环境变量开" "$OUT/silent-env-on.txt" \
       "取窗 38 · 跳过 28（73.7%）· 跳过音频 280.0 秒 · 真的解了 10 窗"

step "③ 连续说话那条（课堂-20260921-194730，前 ${HEAD} 秒）"
for arm in "speech-settings-on:$HOME_ON:-:设置页·开" \
           "speech-settings-off:$HOME_OFF:-:设置页·关" \
           "speech-env-off:$HOME_ON:off:环境变量·关（文件开着）" \
           "speech-env-on:$HOME_OFF:1:环境变量·开（文件关着）"; do
  name="${arm%%:*}"; rest="${arm#*:}"
  home="${rest%%:*}"; rest="${rest#*:}"
  envspec="${rest%%:*}"; label="${rest#*:}"
  run_arm "$name" "$home" "$envspec" "$SPEECH_REC" "$label" || continue
  f="$OUT/$name.txt"
  expect_line "${name}·取窗" "$f" "取窗 38 · 跳过 0（0.0%）· 跳过音频 0.0 秒 · 真的解了 38 窗"
  expect_line "${name}·结果" "$f" "段数 24（定稿 24）"
  expect_line "${name}·字数" "$f" "总字数 218（最终输出）"
  expect_line "${name}·覆盖" "$f" "覆盖率: 最晚段结束 117.0 秒 / 音频 120.0 秒 = 97.5%"
done

# ── ④ 两条路读数一致 ──
step "④ 两条路读数一致（设置页 vs 环境变量）"
pair_equal() { # pair_equal <说明> <文件A> <文件B>
  local a b
  a="$(gate_line "$2")"; b="$(gate_line "$3")"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then
    ok "$1 一致：$a"
  else
    bad "$1 不一致：A「${a}」 B「${b}」"
  fi
}
pair_equal "静音·关（设置页 vs 环境变量）" "$OUT/silent-settings-off.txt" "$OUT/silent-env-off.txt"
pair_equal "静音·开（设置页 vs 环境变量）" "$OUT/silent-settings-on.txt"  "$OUT/silent-env-on.txt"
pair_equal "说话·关（设置页 vs 环境变量）" "$OUT/speech-settings-off.txt" "$OUT/speech-env-off.txt"
pair_equal "说话·开（设置页 vs 环境变量）" "$OUT/speech-settings-on.txt"  "$OUT/speech-env-on.txt"

# ── ⑤ 现有快扫描 ──
step "⑤ exit_codes.sh（不含麦克风 / 联网）"
CLASSROOM_BIN="$BIN" ./tools/probes/exit_codes.sh > "$OUT/exit-codes.txt" 2>&1
code=$?
if [ "$code" = "0" ] && grep -qF "✅ 退出码判据全过" "$OUT/exit-codes.txt"; then
  ok "$(grep -F '✅ 退出码判据全过' "$OUT/exit-codes.txt" | tail -1 | sed 's/^ *//')"
else
  bad "exit_codes.sh exit=${code}；见 $OUT/exit-codes.txt"
  grep -E "^  ❌" "$OUT/exit-codes.txt" | head -10
fi

# ── ⑥ 收尾指纹 ──
step "⑥ 收尾指纹（用户真实库前后一致）"
REC_AFTER="$(fingerprint_recordings)"
CONFIG_AFTER="$(fingerprint_config)"
BUILD_AFTER="$(fingerprint_build)"
if [ "$REC_BEFORE" = "$REC_AFTER" ]; then
  ok "录音库逐文件 sha256 前后一致（$(printf '%s\n' "$REC_AFTER" | grep -c .) 个文件）"
else
  bad "录音库变了！"
  diff <(printf '%s\n' "$REC_BEFORE") <(printf '%s\n' "$REC_AFTER") | head -10
fi
if [ "$CONFIG_BEFORE" = "$CONFIG_AFTER" ]; then
  ok "config.json sha256 前后一致：${CONFIG_AFTER:0:16}…"
else
  bad "config.json 变了！${CONFIG_BEFORE:0:16}… → ${CONFIG_AFTER:0:16}…"
fi
if [ "$BUILD_BEFORE" = "$BUILD_AFTER" ]; then
  ok "用户那份 build/ 一个文件都没被动过"
else
  bad "build/ 被动了！"
fi

# ── 汇总 ──
step "汇总"
printf '%-20s %s\n' "臂" "取窗读数 / 解码"
for f in "$OUT"/silent-*.txt "$OUT"/speech-*.txt; do
  [ -f "$f" ] || continue
  printf '%-20s %s · %s\n' "$(basename "$f" .txt)" "$(gate_line "$f")" "$(decode_cpu "$f")"
done
echo
echo "──── 过的有 $PASS 条，没过 $FAIL 条 ────"
[ "$FAIL" = "0" ] && echo "✅ P12-3 验收全过" || echo "❌ 有判据没过，见上面逐条"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
