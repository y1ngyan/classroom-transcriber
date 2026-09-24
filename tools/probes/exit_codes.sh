#!/bin/bash
# 无头入口的**退出码判据**：每个入口跑完必须 `exit=0`。
#
# 为什么单独有一条判据：whisper 的 ggml Metal 后端在进程静态析构时断言
# `[rsets->data count] == 0`，只要还有一个活着的 context，进程就以 **abort**
# 结束——**exit=134，而 stdout 完全正常**。所以「看输出都对」这件事证明不了
# 「这个入口是好的」，唯一的判据是退出码本身。2026-09-22 就是靠它发现
# `--whisper-prewarm` / `--mic-selftest` 三个入口都在 134。
#
# 用法：
#   ./tools/probes/exit_codes.sh            # 不碰麦克风的入口（默认）
#   WITH_MIC=1 ./tools/probes/exit_codes.sh # 加上麦克风入口（会独占麦克风）
#   WITH_NET=1 ./tools/probes/exit_codes.sh # 加上要联网/要密钥的入口
#
# 退出码 0 = 跑到的入口全部 exit=0。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
[ -x "$BIN" ] || { echo "❌ 没有 $BIN，先跑 ./build.sh"; exit 1; }

# 挑一条真实录音给 --whisper-window-file 用（它需要 wav）
SAMPLE="$(ls "$REC"/*.wav 2>/dev/null | head -1)"

FAIL=0
PASS=0
run() { # run <名字> <参数…>
  local name="$1"; shift
  local out
  out="$("$BIN" "$@" 2>&1)"
  local code=$?
  if [ "$code" = "0" ]; then
    printf '  ✅ %-34s exit=0\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-34s exit=%s\n' "$name" "$code"
    # 134 = SIGABRT（ggml 静态析构断言），单独点出来
    [ "$code" = "134" ] && printf '       ↑ abort：几乎一定是 ggml/whisper context 没释放\n'
    # 133 = SIGTRAP。**这不是「另一个 134」**，成因已经查到根，别再猜：
    #
    # 2026-09-24 核验者见过一次（`--whisper-prewarm` 首跑，重跑全 0）。当晚就从
    # `~/Library/Logs/DiagnosticReports/ClassroomTranscriber-2026-09-24-013855.ips`
    # 里挖到了现场：`EXC_BREAKPOINT / SIGTRAP`，libsystem_malloc 报
    # 「BUG IN CLIENT OF LIBMALLOC: memory corruption of free block」。
    # 出事的线程在 `WhisperRuntime.warmUp()` 的 inference 队列里、正走
    # `whisper_init_from_file_with_params` → `ggml_backend_alloc_ctx_tensors_from_buft`
    # → `alloc_tensor_range`；**同一份报告里另一条线程的栈是同一个形状，一直同到
    # `closure #1 in closure #1 in closure #1 in WhisperRuntime.warmUp()` 那个闭包名**
    # ——两条线程是两次独立的 `WhisperEngine.init`（inferenceQueue 是串行的，
    # 一条队列跑不出两条线程）。
    #
    # 两条并发的 `whisper_init` 从哪来：`AppState()` 是 `@main` App 的 `@State`
    # 属性，**属性默认值先于 `init()` 体求值**（实测确认），而无头开关全在
    # `init()` 里判——所以每个无头入口都先按配置（本机 `transcriptionBackend`
    # = whisper）起了一次后台预热，入口自己再构造一份。两个 context 并发初始化
    # 共用进程级的堆和 Metal residency set，堆被写坏，libmalloc 自检把它抓了。
    # 是**竞态**，所以偶发：冷启动那份 init 要 17 秒，窗口最宽，首跑最容易撞上。
    #
    # 怎么读这条判据（根治之前）：孤立的、只在会加载模型的入口出现、重跑即消失的
    # 133 = **已知假红**（成因确定，见上），重跑一次即可；重跑还出，或出现在不
    # 加载模型的入口、或伴随别的信号（134/139），按真 bug 处理。
    # 根治方案（两处，需真跑验证，未落地）：① 无头入口里别让 `AppState` 预热；
    # ② 把「ggml context 的构造与销毁」串行化在一把**进程级**锁上。
    [ "$code" = "133" ] && printf '       ↑ SIGTRAP：已知假红（两个 runtime 并发 whisper_init 写坏堆，竞态）——**先重跑一次再当 bug**；根因与读法见本文件注释\n'
    printf '       %s\n' "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  fi
}

echo "════ 纯本地入口（不需要模型 / 网络 / 麦克风）════"
run "--selftest"                    --selftest
run "--quality-selftest"            --quality-selftest
run "--hallucination-selftest"      --hallucination-selftest
# 离线重算入口用固定夹具跑（夹具说明见 tools/probes/fixtures/hallucination_replay.log）。
# 它值得覆盖：这个入口要读文件、解析、再走一遍判据，正是「输出看着对但进程 abort」
# 那类缺陷的高发形状
run "--hallucination-replay（夹具）"   --hallucination-replay tools/probes/fixtures/hallucination_replay.log
run "--split-selftest"              --split-selftest
run "--punct-selftest"              --punct-selftest
run "--dedup-selftest"              --dedup-selftest
run "--session-selftest"            --session-selftest
run "--manual-check-selftest"       --manual-check-selftest
run "--config-selftest"             --config-selftest
run "--conv-probe"                  --conv-probe
run "--wav-selftest"                --wav-selftest
run "--terms-parser"                --terms-parser
run "--glossary-suggest-selftest"   --glossary-suggest-selftest
run "--question-selftest"           --question-selftest
run "--preamp-selftest"             --preamp-selftest
run "--hp-selftest"                 --hp-selftest
run "--whisper-selftest"            --whisper-selftest
run "--whisper-window-selftest"     --whisper-window-selftest
run "--whisper-buffer-selftest"     --whisper-buffer-selftest

echo
echo "════ 要真模型的入口（会加载 539MB 模型）════"
run "--whisper-prewarm"             --whisper-prewarm
if [ -n "$SAMPLE" ]; then
  run "--whisper-window-file --head 20" --whisper-window-file "$SAMPLE" --head 20
else
  echo "  ⏭  --whisper-window-file：recordings/ 里没有 wav，跳过"
fi

if [ "${WITH_NET:-0}" = "1" ]; then
  echo
  echo "════ 要联网 / 要密钥的入口（WITH_NET=1）════"
  run "--cos-selftest"              --cos-selftest
  run "--glossary"                  --glossary
  run "--notes"                     --notes
  run "--factcheck"                 --factcheck
fi

if [ "${WITH_MIC:-0}" = "1" ]; then
  echo
  echo "════ 麦克风入口（WITH_MIC=1；会独占麦克风，需要真人说话）════"
  run "--mic-selftest（默认后端）"        --mic-selftest --seconds 3
  run "--mic-selftest --backend whisper"  --mic-selftest --backend whisper --seconds 3
fi

echo
echo "──── 合计：exit=0 的有 $PASS 个，非 0 的有 $FAIL 个 ────"
[ "$FAIL" = "0" ] && echo "✅ 退出码判据全过" || echo "❌ 有入口退出码不为 0（134 就是 ggml 静态析构 abort）"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
