#!/bin/bash
# 无头入口的**退出码判据**：每个入口跑完必须 `exit=0`。
#
# 为什么单独有一条判据：whisper 的 ggml Metal 后端在进程静态析构时断言
# `[rsets->data count] == 0`，只要还有一个活着的 context，进程就以 **abort**
# 结束——**exit=134，而 stdout 完全正常**。所以「看输出都对」这件事证明不了
# 「这个入口是好的」，唯一的判据是退出码本身。2026-09-22 就是靠它发现
# `--whisper-prewarm` / `--mic-selftest` 三个入口都在 134。
#
# **七个入口另外还断言输出里的一行**（`run_assert`，见那里的注释）：
#   · `--whisper-prewarm`：`构造 ggml context 次数: 1`——133 的正面判据
#   · `--whisper-selftest`：自检总结行——里面有「构造锁·两条线程不重叠」，
#     而自检失败**不改退出码**，不看输出就等于没测
#   · `--speaker-mapping-selftest`：C 包的映射规则总结行——同一种情形（见那里的注释）
#   · `--export-notes-selftest`：笔记导出总结行——同一种情形，而且那边**验过会红**
#     （把「无内容静默返回」或「写失败被 try? 吞掉」注回去，这条自检立刻红）
#   · `--study-notes-selftest`：学习笔记总结行——同一种情形（离线打桩，
#     不联网、不花钱）。**数一数它报了几条**：这个入口最容易出的问题是
#     「用例一条都没跑，进程也是 0 退出」
#   · `--study-notes-ui-selftest`：课后笔记界面档位总结行——同上。这一条覆盖的
#     是**界面判断**，那条路没有窗口可点，只能靠纯函数 + 这条断言
#   · `--diarize-selftest`：说话人识别总结行——同上。这一条**离线**（helper 是
#     临时目录里的桩脚本）。它里面有五组「注入一个缺陷 → 判据必须变红」的对照，
#     所以「用例一条都没跑」在这里的表现同样是「进程 0 退出、什么都没测」
#
# 用法：
#   ./tools/probes/exit_codes.sh            # 不碰麦克风的入口（默认）
#   WITH_MIC=1 ./tools/probes/exit_codes.sh # 加上麦克风入口（会独占麦克风）
#   WITH_NET=1 ./tools/probes/exit_codes.sh # 加上要联网/要密钥的入口
#
# 退出码 0 = 跑到的入口全部 exit=0、且七个断言都命中。

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
    # **根治已落码**（2026-09-24 第二版，两处）：
    #   ① 无头入口不预热 `AppState`（`HeadlessEntry.isActive`）；
    #   ② ggml context 的**构造与销毁**串行化在一把进程级锁上（`GgmlTeardown.lock`）。
    # 所以现在再出 133 **不再是「已知假红」，按真 bug 查**：
    #   · 先看这一条留下的「构造 ggml context 次数 / 同时在造的峰值」（那两行是
    #     为 133 加的）。**次数 ≥ 2** 说明又冒出了一个构造来源（新的预热点、新的
    #     直构点），那正是要修的地方，别去怪 whisper。但**次数 0 不是这个意思**：
    #     那是模型没就位、一次构造都没开始（`WhisperRuntime.warmUp` 在更早的 guard
    #     就返回了），跟并发无关——先去看模型在不在，别去翻构造点；
    #   · 次数是 1 还出 133，看**峰值**：峰值 ≥ 2 说明真的有两条线程同时在造，
    #     那是锁没兜住（或绕过锁的第 4 个构造点，见核验报告 §F）；峰值是 1 才是
    #     「损坏来自锁没盖到的地方」（推理期？别的库？）。两种都去
    #     `~/Library/Logs/DiagnosticReports/` 翻现场，按栈查，别猜。
    [ "$code" = "133" ] && printf '       ↑ SIGTRAP：并发写坏堆那一类（根治已落码，见本文件注释）——按**真 bug** 查，先看 context 计数是不是 1\n'
    printf '       %s\n' "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  fi
}

# 同 `run`，但**额外断言输出里有这么一行**。给两类情况用：
#   · `--whisper-prewarm` 的「构造 ggml context 次数: 1」——133 的**正面**判据：
#     「这次没崩」是运气，「只造了一份」才是结论（根因就是同一个进程里两份并发
#     初始化，见上面 133 分支）。
#   · `--whisper-selftest` 的总结行——那条自检里有「构造锁·两条线程不重叠」，
#     它是锁还在不在的**确定性**判据（连跑入口压不到 17 秒冷启动那个窗口，
#     而这条一撞就抓）。自检**失败不改退出码**，所以只有断言输出才看得见它。
#
# 两个断言都用 `grep -F`（固定串）而不是正则：要断言的串里有 `:` `（` 这些字符，
# 正则下要转义，而这条脚本要在 macOS 的 bash 3.2 上跑
#
# 为什么只在这六处断言（别处仍是普通 `run`）：**没验过会红的守卫不配当守卫**。
# 这几个都验过——把 fix ① 拿掉重编，prewarm 那条立刻报「计数不是 1 ⇐ 次数: 2」；
# 把 `construct` 里的锁拿掉重编，selftest 那条立刻报 ❌。而
# `--whisper-window-file --head 20` **验不过**：它照样打 1（那条入口把主线程堵在
# semaphore 上，`AppState` 那条预热是 MainActor 上的 Task，根本没机会跑），
# 所以那边保持普通的 `run`，只用退出码当判据。
#
# 后一条「同时在造的峰值」（`--whisper-prewarm` / `--whisper-window-file` 都打）
# 也**不**断言，理由同上一段：它抓不到「顺序发生两个来源」那种形状（那时峰值是 1）。
# 打出来是给「次数是 1 却仍然 133」那种现场用的，见上面 133 分支的读法
run_assert() { # run_assert <名字> <输出里必须出现的行> <参数…>
  local name="$1"; shift
  local want="$1"; shift
  local out code
  out="$("$BIN" "$@" 2>&1)"
  code=$?
  if [ "$code" != "0" ]; then
    printf '  ❌ %-34s exit=%s\n' "$name" "$code"
    [ "$code" = "134" ] && printf '       ↑ abort：几乎一定是 ggml/whisper context 没释放\n'
    [ "$code" = "133" ] && printf '       ↑ SIGTRAP：见上面 133 分支的读法（先看 context 计数）\n'
    printf '       %s\n' "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
    return
  fi
  if printf '%s' "$out" | grep -qF "$want"; then
    printf '  ✅ %-34s exit=0 · 断言命中\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-34s exit=0，但输出里没有「%s」\n' "$name" "$want"
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
# C 包的映射规则（人物归属 + 旧会话缺键兜底）全在这条自检里。夹具是内存里造的，
# 不碰真会话——真会话那条要人手动带 --session-file，不进这个自动扫（它依赖
# Application Support 里的现存文件，换台机器就没有了）。
# 退出码跟着红绿走，所以本来 run 就够；再钉一句总结行，是为了防「退出码对了、
# 用例根本没跑」——判据一条都没执行时进程也是 0 退出
run_assert "--speaker-mapping-selftest" "✅ 说话人映射自检通过" --speaker-mapping-selftest
# 导出笔记这条路径一直没有判据（面板挡住了无头入口），2026-09-24 用户报
# 「点导出生成不了文件」时只能靠读代码猜。这条自检钉的是「写没写成、失败说没说」
run_assert "--export-notes-selftest" "✅ 笔记导出自检通过" --export-notes-selftest
# 学习笔记（6a-1）：离线打桩，不联网、不花钱。它内部 44 条断言全在**输出**上，
# 退出码只反映最后那个 failed 计数——所以和上面两条同理，必须钉总结行。
# 注：断言串里带「（44 条）」这个数字，是**故意的**——用例数掉到 0 也照样 exit=0，
# 钉住条数才拦得住「判据一条没跑」。数字变了就要跟着改，改的时候先确认是加了用例
run_assert "--study-notes-selftest" "✅ 学习笔记自检通过（44 条）" --study-notes-selftest
# 课后笔记的界面档位（6a-2）。**同样是离线打桩**：一条模型调用都不发生。
# 界面本身点不了（无头进程没有窗口），所以这一包把「显示哪一档」抽成了纯函数
# （`StudyNotesPanelState`），判据钉的就是那个函数——包括那条不变量
# 「16 种输入组合里没有一种禁用了却不说为什么」+ 自动跑那三条闸（不覆盖、
# 不并发、没 key 不跑）。条数照样要钉，理由同上
run_assert "--study-notes-ui-selftest" "✅ 课后笔记界面自检通过（53 条）" --study-notes-ui-selftest
# 说话人识别（C-3-1）。**离线**：helper 是临时目录里的桩脚本，不加载模型、
# 不联网、不碰麦克风。五条校验各有一组「注入一个缺陷 → 对应判据必须变红」的
# 对照（另外还有对照信封与不变量扫描），所以这里最容易出的问题同样是
# 「一条用例都没跑、进程照样 0 退出」——条数必须钉住
run_assert "--diarize-selftest" "✅ 说话人识别自检通过（82 条）" --diarize-selftest
run "--manual-check-selftest"       --manual-check-selftest
run "--config-selftest"             --config-selftest
run "--conv-probe"                  --conv-probe
run "--wav-selftest"                --wav-selftest
run "--terms-parser"                --terms-parser
run "--glossary-suggest-selftest"   --glossary-suggest-selftest
run "--question-selftest"           --question-selftest
run "--preamp-selftest"             --preamp-selftest
run "--hp-selftest"                 --hp-selftest
# 这条自检里有「构造锁·两条线程不重叠」（133 那个并发缺陷的确定性判据）。
# 自检失败**不改退出码**，所以只看退出码等于没看这条判据——断言总结行
run_assert "--whisper-selftest" "✅ Whisper 引擎自检通过" --whisper-selftest
run "--whisper-window-selftest"     --whisper-window-selftest
run "--whisper-buffer-selftest"     --whisper-buffer-selftest

echo
echo "════ 要真模型的入口（会加载 539MB 模型）════"
run_assert "--whisper-prewarm" "构造 ggml context 次数: 1（" --whisper-prewarm
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
echo "──── 合计：过的有 $PASS 个，没过 $FAIL 个 ────"
# 这句要说全两种失败，不能只说退出码：加了 `run_assert` 之后，**exit=0 但断言没命中**
# 也是一条不过（核验者 2026-09-24 指出：那种情况下原话「退出码不为 0」是错的）
[ "$FAIL" = "0" ] && echo "✅ 退出码判据全过（含七个断言）" \
                  || echo "❌ 有入口没过：要么退出码非 0（134 就是 ggml 静态析构 abort），要么 exit=0 但断言没命中——看上面逐条"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
