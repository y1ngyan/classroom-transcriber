#!/bin/bash
# P12-2 两条相反方向的变异注入 —— 证明那两条判据**真的会红**
#
# 判据不红就不算判据（`criteria-must-be-able-to-fail`）。两条注入都打在
# `SpeechGate.isSilence` 这一个纯函数上（`Sources/Transcription/SpeechGate.swift`），
# 一个恒 true、一个恒 false：
#
#   变异①  阈值 = 全判静音  → **判据 ③（不许丢真人说话）**必须红
#   变异②  阈值 = 从不判静音 → **判据 ②（跳过率）**必须红
#
# 每一轮的动作是**固定四步**（派单验收 ⑤）：
#   注入 → 自证注入命中 → 重新构建 → 跑真判据（跑的就是验收探针本身，
#   不是这里另写一遍的复制品）→ 按内容还原 → 重新构建 → 二进制与干净树逐字节相同
#
# 关于「还原」：`SpeechGate.swift` 在基线 `6f664e8` 里**还不存在**（是新文件），
# 所以 `git checkout` 对它无效。这里改成「按内容还原」——注入前先存一份带 sha256
# 的原文，还原后核对源文件 sha256，再从还原后的源码重新构建、比对二进制 sha256。
# 这比 `git checkout` 还严一档：它同时证明了**源码**和**产物**都回到了原样。
#
# 前置：先跑一遍验收探针（它产出改造前那一臂的原始输出），
#       `./tools/probes/p12_2_speech_gate.sh`。
#       基线二进制可以用 `CLASSROOM_P12_2_BASELINE_BIN` 传进来省一次十几分钟的编译。
#
# 用法：
#   ./tools/probes/p12_2_gate_mutations.sh
#   CLASSROOM_P12_2_BASELINE_BIN=/tmp/.../ClassroomTranscriber ./tools/probes/p12_2_gate_mutations.sh
#   P12_2_MUT_HEAD=60   # 变异那两轮每条录音只跑前 N 秒（默认 60）
#
# 退出码 0 = 两条变异都**在预期的那一节**红了，且还原后逐字节复原。

set -uo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="${CLASSROOM_BUILD_DIR:-build-verify}"
BIN="$BUILD_DIR/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber"
OUT="${P12_2_OUT:-/tmp/p12_2_gate}"
GATE_SRC="Sources/Transcription/SpeechGate.swift"

echo "BIN=${BIN}"
echo "  变异注入点：${GATE_SRC} · 产物落 ${OUT}"

FAIL=0
ok()  { printf '  ✅ %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*"; }
step() { echo; echo "════ $(date '+%H:%M:%S')  $* ════"; }

for path in "$OUT/speech-before.txt" "$OUT/silent-before.txt"; do
  [ -f "$path" ] || {
    echo "❌ 缺 ${path}——先跑 ./tools/probes/p12_2_speech_gate.sh（判据要跟改造前那一臂对账）"
    exit 1
  }
done

# 原文备份（含 sha256）。**先备份再动文件**，中途被打断也能还原
mkdir -p "$OUT"
BACKUP="$OUT/SpeechGate.swift.orig"
cp "$GATE_SRC" "$BACKUP"
ORIG_SRC_SHA="$(shasum -a 256 "$BACKUP" | awk '{print $1}')"
echo "  原文备份 → ${BACKUP}（sha256 ${ORIG_SRC_SHA:0:16}…）"

restore_source() {
  cp "$BACKUP" "$GATE_SRC"
  local now
  now="$(shasum -a 256 "$GATE_SRC" | awk '{print $1}')"
  [ "$now" = "$ORIG_SRC_SHA" ] || { echo "❌ 还原失败：源码 sha256 对不上（${now:0:16}…）"; exit 1; }
}
# 任何异常退出都把源码还原回去——**留着注入过的源码是最坏的结果**
trap 'if [ -f "$BACKUP" ]; then restore_source >/dev/null 2>&1; fi' EXIT

build() { # build <日志名>
  CLASSROOM_BUILD_DIR="$BUILD_DIR" ./build.sh > "$OUT/$1" 2>&1
  local code=$?
  if [ $code -ne 0 ]; then
    echo "❌ 构建失败（$1）："; tail -15 "$OUT/$1"; return 1
  fi
  return 0
}

binary_sha() { [ -x "$BIN" ] && shasum -a 256 "$BIN" | awk '{print $1}'; }

step "干净树先构建一次，记下二进制 sha256（后面每一轮都拿它比）"
build "mut-build-clean.log" || exit 1
CLEAN_SHA="$(binary_sha)"
[ -n "$CLEAN_SHA" ] || { echo "❌ 没编出二进制：$BIN"; exit 1; }
echo "  干净树二进制 sha256 ${CLEAN_SHA:0:16}…"

# 注入函数：把 `isSilence` 的三行判据整体换成一行恒值
inject() { # inject true|false
  python3 - "$1" <<'PY'
import sys
value = sys.argv[1]
path = "Sources/Transcription/SpeechGate.swift"
body = """        guard reading.frameCount > 0 else { return false }
        guard reading.speechRatio < minSpeechRatio else { return false }
        return reading.speech < speechCeiling"""
injected = "        return %s   // P12-2 变异注入" % value
text = open(path, encoding="utf-8").read()
if text.count(body) != 1:
    print("❌ 注入点找不到唯一匹配（SpeechGate.swift 被改过？）")
    sys.exit(1)
open(path, "w", encoding="utf-8").write(text.replace(body, injected))
print("  注入成功：isSilence 恒 %s" % value)
PY
}

# ── 变异①：全判静音 → 判据 ③ 红 ──
# 单引号：双引号里的反引号会被当真命令执行（实测日志里刷出 isSilence: command not found）
step '变异①：阈值 = 全判静音（`isSilence` 恒 true）'
inject true || { bad "注入失败"; exit 1; }
grep -qF 'return true   // P12-2 变异注入' "$GATE_SRC" \
  && ok "自证注入命中：$(grep -F 'P12-2 变异注入' "$GATE_SRC" | sed 's/^ *//')" \
  || bad "注入没落到文件里"

build "mut1-build.log" || { bad "变异①构建失败"; exit 1; }
MUT1_SHA="$(binary_sha)"
[ "$MUT1_SHA" != "$CLEAN_SHA" ] && ok "产物确实变了（sha256 与干净树不同）" || bad "注入后二进制没变——注入没生效"

# 跑的就是验收探针本身。⚠️ 不传 `CLASSROOM_P12_2_BASELINE_BIN` 的话，探针会
# **自己另编一份基线**（十几分钟），并且这一个脚本里要跑两趟探针 —— 所以
# 强烈建议在命令行上传进来
# 变异这一轮**不需要**真实录音那套完整读数，只需要判据红在哪一节，所以
# 默认把每条录音压到 60 秒（`P12_2_MUT_HEAD` 可改）——省的是模型时间，
# 不是判据强度：60 秒里该跳的窗、该说的话都在
CLASSROOM_BIN="$BIN" P12_2_OUT="$OUT/mut1" P12_2_HEAD="${P12_2_MUT_HEAD:-60}" \
  bash tools/probes/p12_2_speech_gate.sh > "$OUT/mut1-probe.log" 2>&1
MUT1_CODE=$?
if [ $MUT1_CODE -ne 0 ] && grep -qF "⛔ 改造后一段定稿都没有" "$OUT/mut1-probe.log"; then
  ok "判据 ③ 在**预期的那一节**红了（探针 exit=${MUT1_CODE}）：$(grep -F '⛔ 改造后一段定稿都没有' "$OUT/mut1-probe.log" | head -1 | sed 's/^ *//')"
else
  bad "变异①没有让判据 ③ 红（探针 exit=${MUT1_CODE}），见 $OUT/mut1-probe.log"
fi

step "还原变异①并重新构建，比对二进制"
restore_source && ok "源码按内容还原，sha256 与原文一致"
build "mut1-restore-build.log" || { bad "还原后构建失败"; exit 1; }
RESTORED_SHA="$(binary_sha)"
[ "$RESTORED_SHA" = "$CLEAN_SHA" ] \
  && ok "还原后重新构建的二进制与干净树**逐字节相同**（${RESTORED_SHA:0:16}…）" \
  || bad "还原后二进制与干净树不同：${RESTORED_SHA:0:16}… ≠ ${CLEAN_SHA:0:16}…"

# ── 变异②：从不判静音 → 判据 ② 红 ──
step '变异②：阈值 = 从不判静音（`isSilence` 恒 false）'
inject false || { bad "注入失败"; exit 1; }
grep -qF 'return false   // P12-2 变异注入' "$GATE_SRC" \
  && ok "自证注入命中：$(grep -F 'P12-2 变异注入' "$GATE_SRC" | sed 's/^ *//')" \
  || bad "注入没落到文件里"

build "mut2-build.log" || { bad "变异②构建失败"; exit 1; }
MUT2_SHA="$(binary_sha)"
[ "$MUT2_SHA" != "$CLEAN_SHA" ] && ok "产物确实变了（sha256 与干净树不同）" || bad "注入后二进制没变——注入没生效"

CLASSROOM_BIN="$BIN" P12_2_OUT="$OUT/mut2" P12_2_HEAD="${P12_2_MUT_HEAD:-60}" \
  bash tools/probes/p12_2_speech_gate.sh > "$OUT/mut2-probe.log" 2>&1
MUT2_CODE=$?
if [ $MUT2_CODE -ne 0 ] && grep -qF "一窗都没跳——门控没起作用" "$OUT/mut2-probe.log"; then
  ok "判据 ② 在**预期的那一节**红了（探针 exit=${MUT2_CODE}）"
else
  bad "变异②没有让判据 ② 红（探针 exit=${MUT2_CODE}），见 $OUT/mut2-probe.log"
fi

step "还原变异②并重新构建，比对二进制"
restore_source && ok "源码按内容还原，sha256 与原文一致"
build "mut2-restore-build.log" || { bad "还原后构建失败"; exit 1; }
RESTORED2_SHA="$(binary_sha)"
[ "$RESTORED2_SHA" = "$CLEAN_SHA" ] \
  && ok "还原后重新构建的二进制与干净树**逐字节相同**（${RESTORED2_SHA:0:16}…）" \
  || bad "还原后二进制与干净树不同：${RESTORED2_SHA:0:16}… ≠ ${CLEAN_SHA:0:16}…"

step "汇总"
[ "$FAIL" -eq 0 ] && echo "✅ 两条变异都在预期的那一节红了，且都已逐字节还原" \
                  || echo "❌ 变异验证有红（$FAIL 条）"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
