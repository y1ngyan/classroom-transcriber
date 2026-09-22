#!/bin/bash
# 「录音中途被杀，文件不能废」的端到端判据 runner。
#
# 判据（缺一不可）：
#   ① 探针被 SIGKILL 打死 —— 退出码必须是 137（128+9），不是 0，也不是别的
#   ② 磁盘上那个文件 **afinfo 能打开**（exit=0）——全零头那个缺陷就是在这里红
#   ③ 声明时长落在 [杀点-1s, 杀点] —— 允许欠报（最多一个回填间隔），不许 0
#   ④ 磁盘上真的还有音频数据（不是只剩一个头）
#
# 不用麦克风、不发声、不动音量：样本是内存里合成的，直接进 WAVRecorder。
#
# 用法：
#   ./tools/probes/wav_kill.sh              # 正常判据
#   SRC_ROOT=/tmp/ct-mutate ./tools/probes/wav_kill.sh   # 变异测试：拿撤销了修复的源码跑
#
# 退出码 0 = 四条判据全过。

set -uo pipefail
cd "$(dirname "$0")/../.."

NAME="wav_kill"
SRC="tools/probes/$NAME.swift"
SRC_ROOT="${SRC_ROOT:-.}"
OUT_DIR="build/probes"
BIN="$OUT_DIR/$NAME"
LOG="$OUT_DIR/$NAME.build.log"

if [ ! -f "build/whisper.modulemap" ]; then
  echo "▶ 先生成 build/whisper.modulemap（跑一次 build.sh）…"
  ./build.sh >/dev/null 2>&1 || true
fi

mkdir -p "$OUT_DIR"
SOURCES=()
while IFS= read -r f; do
  SOURCES+=("$f")
done < <(find "$SRC_ROOT/Sources" -name '*.swift' ! -name 'App.swift' ! -name '*View.swift' | sort)

SDK=$(xcrun --show-sdk-path)
echo "▶ 编译 ${NAME}（源码根 ${SRC_ROOT}，链接 ${#SOURCES[@]} 个文件）…"
if ! swiftc -sdk "$SDK" -target arm64-apple-macos26.0 -swift-version 6 \
  -parse-as-library -O \
  -framework Speech -framework AVFoundation \
  -Xcc -fmodule-map-file=build/whisper.modulemap \
  -I /opt/homebrew/Cellar/whisper.cpp/1.9.4/include \
  -I /opt/homebrew/include \
  -L /opt/homebrew/lib -lwhisper -lggml -lggml-base \
  -Xlinker -rpath -Xlinker /opt/homebrew/lib \
  "$SRC" "${SOURCES[@]}" \
  -o "$BIN" > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20
  echo "❌ 编译失败（完整日志：${LOG}）"
  exit 1
fi

TOTAL_SECONDS="${TOTAL_SECONDS:-10}"
KILL_AFTER="${KILL_AFTER:-6}"
WAV="$(mktemp -t wavkill).wav"
rm -f "$WAV"

echo "▶ 跑探针（写 ${TOTAL_SECONDS} 秒，第 ${KILL_AFTER} 秒自杀）…"
echo
"$BIN" "$WAV" "$TOTAL_SECONDS" "$KILL_AFTER"
CODE=$?
echo
echo "─── 判据 ───"

FAIL=0
check() { # check <名字> <是否通过 0/1> <说明>
  if [ "$2" = "0" ]; then printf '  ✅ %s：%s\n' "$1" "$3"
  else printf '  ❌ %s：%s\n' "$1" "$3"; FAIL=1; fi
}

# ① 必须真的被 SIGKILL 打死
if [ "$CODE" = "137" ]; then check "被 SIGKILL 打死" 0 "退出码 137"
else check "被 SIGKILL 打死" 1 "退出码 $CODE（期望 137；若是 0 说明 SIGKILL 没生效，判据无效）"; fi

# ② afinfo 能打开
AFINFO="$(afinfo "$WAV" 2>&1)"
AFINFO_CODE=$?
if [ "$AFINFO_CODE" = "0" ]; then check "afinfo 能打开" 0 "exit=0"
else
  check "afinfo 能打开" 1 "exit=$AFINFO_CODE · $(printf '%s' "$AFINFO" | head -2 | tr '\n' ' ')"
fi

# ③ 声明时长 ∈ [杀点-1s, 杀点]
DURATION="$(printf '%s' "$AFINFO" | awk -F': ' '/estimated duration/ {print $2}' | awk '{print $1}')"
if [ -z "$DURATION" ]; then
  check "声明时长合理" 1 "afinfo 没报出时长（文件打不开时就是这条红）"
else
  OK=$(awk -v d="$DURATION" -v k="$KILL_AFTER" 'BEGIN { print (d >= k - 1.0 && d <= k + 0.05) ? 0 : 1 }')
  check "声明时长合理" "$OK" "${DURATION} 秒（期望 $((KILL_AFTER-1))–${KILL_AFTER} 秒；0 秒说明头从没回填过）"
fi

# ④ 磁盘上还有音频数据
SIZE=$(stat -f%z "$WAV" 2>/dev/null || echo 0)
OK=$(awk -v s="$SIZE" -v k="$KILL_AFTER" 'BEGIN { print (s > 44 + (k - 1.5) * 96000) ? 0 : 1 }')
check "磁盘上还有音频数据" "$OK" "${SIZE} 字节（44 字节头 + 约 $((KILL_AFTER)) 秒 × 96000）"

echo
if [ "$FAIL" = "0" ]; then
  echo "✅ 判据全过 —— 进程被强杀，录音文件仍然可打开、时长合理"
else
  echo "❌ 有判据未过 —— 见上面标红项"
fi
rm -f "$WAV"
exit "$FAIL"
