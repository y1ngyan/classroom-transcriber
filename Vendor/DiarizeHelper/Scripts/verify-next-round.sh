#!/usr/bin/env bash
# C-1 验收命令（**下一轮机器空了我确认「go」之后**才跑；本轮禁止构建/推理）。
#
# 用法：在 ~/ClassroomTranscriber-spike/C-helper 下执行
#   bash Scripts/verify-next-round.sh
#
# 铁律：不播放任何音频、不改系统音量/设备；不写 /Users/you/ClassroomTranscriber。
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$PKG/.build/release/diarize-helper"
MODELS_DIR="${MODELS_DIR:-$HOME/Library/Application Support/ClassroomTranscriber/diarization-models}"
REC_DIR="$HOME/Library/Application Support/ClassroomTranscriber/Recordings"

echo "== 0. 构建（唯一会花时间的步骤；FluidAudio 走本地 path 依赖）=="
swift build -c release --package-path "$PKG"

echo "== 1. --help 退出码应为 0 =="
"$BIN" --help >/dev/null
echo "help exit=$?"

echo "== 2. --selftest：纯函数，不加载模型；退出码即成败 =="
"$BIN" --selftest
echo "selftest exit=$?"

echo "== 3. probe：空目录 + --no-network → 退出码 5 =="
set +e
"$BIN" probe --models-dir "$(mktemp -d)" --no-network
echo "probe(empty) exit=$?"
set -e

echo "== 4. probe：真实模型目录 → 退出码 0（若模型未下载，先跑 download）=="
set +e
"$BIN" probe --models-dir "$MODELS_DIR" --no-network
echo "probe(models) exit=$?"
set -e

echo "== 5. 真实录音端到端（示例；文件名按实际改）=="
# W="$(find "$REC_DIR" -name '课堂-*.wav' | sort | tail -1)"
# "$BIN" diarize --input "$W" --offset-ms 0 --models-dir "$MODELS_DIR" --no-network --output /tmp/c.json
# echo "diarize exit=$?"; jq . /tmp/c.json

echo "== 6. 失败注入：空模型目录 → error 信封 + 信封内零个 speakerId（不伪装 S1）=="
# 裁决补充要求：这一步必须真的验证「不伪装成 S1」，结论写成「跑什么命令 + 看到什么」。
# 需要一条真实录音：W=/path/to/课堂-XXXX.wav bash Scripts/verify-next-round.sh
if [[ -n "${W:-}" ]]; then
  EMPTY_MODELS="$(mktemp -d)"
  set +e
  "$BIN" diarize --input "$W" --offset-ms 0 --models-dir "$EMPTY_MODELS" --no-network \
    --output /tmp/c-missing.json
  MISSING_EXIT=$?
  set -e
  echo "  命令: diarize --input W --models-dir <空目录> --no-network"
  echo "  看到: exit=$MISSING_EXIT（期望 5 = modelMissing）"
  echo "--- /tmp/c-missing.json ---"; cat /tmp/c-missing.json; echo
  echo "--- 机器校验（期望两条都 OK）---"
  if jq -e '.status == "error" and .error.code == "modelMissing" and (.result == null)' \
      /tmp/c-missing.json >/dev/null; then
    echo "  envelope.error: OK（status=error、error.code=modelMissing、result 缺失）"
  else
    echo "  envelope.error: FAIL"
  fi
  if jq -e '[.. | .speakerId? // empty] | length == 0' /tmp/c-missing.json >/dev/null; then
    echo "  no speakerId anywhere: OK（App 即使忽略 status 也没有 S1 可贴）"
  else
    echo "  no speakerId anywhere: FAIL"
  fi
  echo "  App 侧必须看到：diarization == nil、界面上零个说话人标签（不能出现 S1）"
  echo "  报告要写：上面这两条 jq 的实际输出，外加 App 侧截图/日志，不要只写「符合预期」。"
else
  echo "  （跳过：未设置 W=真实录音路径——失败注入也需要真实 --input 才能走到模型判定）"
fi

echo "DONE（本轮未执行任何推理）"
