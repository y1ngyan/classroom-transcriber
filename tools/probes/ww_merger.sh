#!/bin/bash
# 纯函数探针的 runner：滑窗合并器（不需要模型、不需要音频、不碰麦克风）。
#
# 为什么不走 tools/probe.sh：那条链是为「真实链路」准备的，它强制要求一个 wav 和
# 一个 514MB 的 Whisper 模型（找不到模型直接 exit 1）。本探针只喂纯函数，
# 把模型依赖挂上去就等于把「一条命令能跑」变成「先把模型找出来才能跑」。
# 但内核（swiftc 参数、排除 App.swift/Views、日志落盘、退出码）与 probe.sh 保持一致。
#
# 用法：./tools/probes/ww_merger.sh        # 无参数；退出码 0 = 全部判据通过

set -euo pipefail
cd "$(dirname "$0")/../.."

NAME="ww_merger"
SRC="tools/probes/$NAME.swift"
OUT_DIR="build/probes"
BIN="$OUT_DIR/$NAME"
LOG="$OUT_DIR/$NAME.build.log"

# modulemap 由 build.sh 生成（Sources 里有 WhisperEngine.swift，必须能 import whisper）
if [ ! -f "build/whisper.modulemap" ]; then
  echo "▶ 先生成 build/whisper.modulemap（跑一次 build.sh）…"
  ./build.sh >/dev/null 2>&1 || true
fi

mkdir -p "$OUT_DIR"
# 探针需要项目的非 UI 源码；注意 macOS 自带 bash 3.2 没有 mapfile（与 probe.sh 同款写法）
SOURCES=()
while IFS= read -r f; do
  SOURCES+=("$f")
done < <(find Sources -name '*.swift' ! -name 'App.swift' ! -name '*View.swift' | sort)

SDK=$(xcrun --show-sdk-path)
echo "▶ 编译 ${NAME}（链接 ${#SOURCES[@]} 个源码文件）…"
# 先把输出落盘再判退出码：`swiftc ... | grep error:` 那条写法在 grep 不匹配时以 1 退出，
# 会盖住真正的编译错误（probe.sh 里记过这个坑）
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

echo "▶ 运行…"
echo
# set -e 下直接跑，退出码原样透传（0 = 判据全过）
"$BIN"
