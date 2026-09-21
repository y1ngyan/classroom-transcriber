#!/bin/bash
# 独立探针的统一编译/运行入口。
#
# 为什么要有这个脚本：把项目模块编译成独立可执行文件的那串 swiftc 参数
# （modulemap、-I、-L、-rpath、-parse-as-library、排除 App.swift/Views）
# 又长又容易记错，每次现敲必然出错。这里固化一次。
#
# 这些探针**故意不用** App 里的 --xxx-selftest 入口：自检是纯本地的，
# 真实链路的验证必须走一条**独立**的路径，否则又变成「用被测代码验证自己」。
#
# 用法:
#   ./tools/probe.sh                    # 列出可用探针
#   ./tools/probe.sh e2e     <wav> [cli_output.txt]   # 端到端转录 + 覆盖率/对齐/分布
#   ./tools/probe.sh bench   <wav> [窗口秒] [轮数]     # 滑窗单次耗时与占用率
#   ./tools/probe.sh tokens  <wav> [段数]              # 原始 token 流（查置信度/对齐问题）
#
# 模型路径默认取 $CLASSROOM_WHISPER_MODEL，未设置则依次尝试
# ~/Library/Application Support/ClassroomTranscriber/models/ggml-medium-q5_0.bin
# 和 /tmp/ggml-medium-q5_0.bin。

set -euo pipefail
cd "$(dirname "$0")/.."

PROBE_DIR="tools/probes"
OUT_DIR="build/probes"

usage() {
  echo "用法: ./tools/probe.sh <探针名> <wav> [附加参数]"
  echo
  echo "可用探针:"
  for f in "$PROBE_DIR"/*.swift; do
    name=$(basename "$f" .swift)
    desc=$(grep -m1 '^// ' "$f" | sed 's|^// *||')
    printf "  %-14s %s\n" "$name" "$desc"
  done
  echo
  echo "环境变量 CLASSROOM_WHISPER_MODEL 可指定模型路径"
  exit 1
}

[ $# -ge 1 ] || usage
NAME="$1"; shift
SRC="$PROBE_DIR/$NAME.swift"
[ -f "$SRC" ] || { echo "❌ 没有这个探针: $NAME"; echo; usage; }

# 模型路径
if [ -z "${CLASSROOM_WHISPER_MODEL:-}" ]; then
  for candidate in \
    "$HOME/Library/Application Support/ClassroomTranscriber/models/ggml-medium-q5_0.bin" \
    "/tmp/ggml-medium-q5_0.bin"; do
    [ -f "$candidate" ] && CLASSROOM_WHISPER_MODEL="$candidate" && break
  done
fi
[ -n "${CLASSROOM_WHISPER_MODEL:-}" ] || {
  echo "❌ 找不到 Whisper 模型。用 CLASSROOM_WHISPER_MODEL=<路径> 指定，或先下载："
  echo "   curl -sL -o /tmp/ggml-medium-q5_0.bin \\"
  echo "     https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"
  exit 1
}

# whisper 的 modulemap 由 build.sh 生成，缺了就先生成
if [ ! -f "build/whisper.modulemap" ]; then
  echo "▶ 先生成 build/whisper.modulemap（跑一次 build.sh，跳过打包）…"
  ./build.sh >/dev/null 2>&1 || true
fi

mkdir -p "$OUT_DIR" "$OUT_DIR/probe_sources"
# 探针需要项目的非 UI 源码；把 App.swift 和 Views/ 排除（@main 冲突 + 省编译时间）
# 注意：macOS 自带 bash 3.2，没有 mapfile，这里用 while read 填数组
SOURCES=()
while IFS= read -r f; do
  SOURCES+=("$f")
done < <(find Sources -name '*.swift' ! -name 'App.swift' ! -name '*View.swift' | sort)

SDK=$(xcrun --show-sdk-path)
BIN="$OUT_DIR/$NAME"

# 注意：中文紧跟 $变量 时会被 bash 当成变量名的一部分（多字节字符），必须用 ${} 括起来
echo "▶ 编译 ${NAME}（链接 ${#SOURCES[@]} 个源码文件）…"
# 把输出落到日志再判退出码。
# 不要写成 `swiftc ... | grep -E "error:" && { 失败 }`——grep 没匹配到就以 1 退出，
# 而它在 && 列表里，set -e 不会中止，脚本会继续去跑一个根本没生成的二进制，
# 报出来的错是 "No such file or directory"，把真正的编译错误盖掉（踩过）。
LOG="$OUT_DIR/$NAME.build.log"
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

echo "▶ 模型: $CLASSROOM_WHISPER_MODEL"
echo "▶ 运行…"
echo
# 附加参数里如果第一个是 wav，就直接用；否则拼在 wav 之前
if [ $# -ge 1 ]; then
  "$BIN" "$1" "$CLASSROOM_WHISPER_MODEL" "${@:2}" 2>&1 | grep -vE "^ggml_metal_library_compile_all|^load_backend|^ggml_metal_|^whisper_(init|model|backend)|^read_audio"
else
  usage
fi
