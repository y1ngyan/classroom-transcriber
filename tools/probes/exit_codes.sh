#!/bin/bash
# 无头入口的**退出码判据**：每个入口跑完必须 `exit=0`。
#
# 为什么单独有一条判据：whisper 的 ggml Metal 后端在进程静态析构时断言
# `[rsets->data count] == 0`，只要还有一个活着的 context，进程就以 **abort**
# 结束——**exit=134，而 stdout 完全正常**。所以「看输出都对」这件事证明不了
# 「这个入口是好的」，唯一的判据是退出码本身。2026-09-22 就是靠它发现
# `--whisper-prewarm` / `--mic-selftest` 三个入口都在 134。
#
# **十五个入口另外还断言输出里的一行**（`run_assert`，见那里的注释）。
#
# ⚠️ 计数说明（P9-2 逐条数过，P7-1 加二）：这段原先写「十四个入口」，而文件里实际
# 只有 **13** 条 `run_assert` 调用——`grep -c run_assert` 得到的 14 把上面那行函数
# 定义 `run_assert() {` 也数进去了。P9-2 补上第 14 条断言，但**它不是 `run_assert`
# 的形状**（期望的退出码是 124 而不是 0，见 `--whisper-window-file 超时不 abort`），
# 所以那时是 **13 条 `run_assert` + 1 条退出码断言 = 14 条**；P7-1 又加了
# `--model-download-selftest` 与 `--model-cache` 两条，现在是
# **15 条 `run_assert` + 1 条 = 16 条**。
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
#   · `--diarize-ui-selftest`：说话人识别的界面档位 + store 三条闸（C-3-2）。
#     同一种情形，同一个理由
#   · `--recovery-selftest`：崩溃恢复（P9-1 / P9-1b）。里面有几条**否定式**判据
#     （正常 wav 不许被报、空录音不算可修、干净库零误报、扫描只读、探针目录闸门），
#     不测就等于没有；条数同理。**分类层那两条是 P9-1b 补的**：`isRepairable` 是
#     三个生产调用点决定「给不给用户修」的属性，只钉执行层钉不住它——把
#     `.foreign` 也改成 true，之前那条自检照样全绿（apply 抛的错被 `try?` 吞了）
#
# 用法：
#   ./tools/probes/exit_codes.sh            # 不碰麦克风的入口（默认）
#   WITH_MIC=1 ./tools/probes/exit_codes.sh # 加上麦克风入口（会独占麦克风）
#   WITH_NET=1 ./tools/probes/exit_codes.sh # 加上要联网/要密钥的入口
#
# 退出码 0 = 跑到的入口全部 exit=0、且十六条断言都命中（15 条 `run_assert` +
# 1 条「超时的退出码必须是 124」——后者期望的本来就不是 0）。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 ./build.sh"; exit 1; }

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
    #     那是锁没兜住（或出现了绕过锁的第 4 个构造点）；峰值是 1 才是
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
# 为什么只在**验过会红**的地方断言（别处仍是普通 `run`）：**没验过会红的守卫不配当守卫**。
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
# 反向转录段（C-4）。离线：内存夹具 + 只读扫真实会话报数。这条修的是
# `absoluteRange` 对 `end < start` 的 `..<` trap——那个 trap 的表现是
# **进程直接 SIGTRAP（133）且一个字都不打印**，所以「看输出都对」在这里
# 完全失效，退出码本身才是判据。条数照样钉住，理由同上
run_assert "--reverse-selftest" "✅ 反向段自检通过（19 条）" --reverse-selftest
# 说话人识别的界面档位 + store 三条闸（C-3-2）。**离线**：helper 打桩、不写盘、
# 不联网、不加载模型、不碰音频。这一条覆盖的是**界面判断**（详情页那条路没有窗口
# 可点，只能靠纯函数 + 这条断言）和三条否定式闸（手动触发 / 不并发 / 失败不落盘）
# ——否定式判据不测的话，把 guard 删掉界面上一点异常都看不出来。
# 条数照样钉住：这个入口最容易出的形状是「用例一条都没跑、进程照样 0 退出」。
# 这些判据**验过会红**：注入「正在跑判成已跑过」/「删掉并发闸」/「失败也落盘」
# 三个变异，对应的判据各自变红（两个记在
# `~/ClassroomTranscriber-design/C-3-2核验记录.md` §三「我自己跑的两个变异」）
run_assert "--diarize-ui-selftest" "全部通过 ✅ 65 条" --diarize-ui-selftest
# 本地诊断日志（P6-1）。**离线**：全部写在临时目录里，真实 logs/ 一个字都不碰
# （自检里有一条判据专门钉这件事——无头进程的全局出口必须是丢弃出口）。
# 它覆盖级别过滤 · 环形轮转 · 上限不增长 · 脱敏 · 崩溃前最后 N 条可读。
# 条数照样钉住，理由同上。
# 「环形」那几条**验过会红**：把 `LogRingPolicy.shouldRotate` 改成恒 false
# （＝关掉轮转），对应判据立刻红
# （见 `~/ClassroomTranscriber-design/P6-1核验记录.md` §四「我自己跑的两个变异」①）。
# 另：「强杀恢复」那条判据要真打死一个进程（`kill -9`），不适合放进这个
# 一次跑完的扫描里——它单独在 `tools/probes/log_crash.sh`，退出码同样即成败
run_assert "--log-selftest" "✅ 日志自检通过（58 条）" --log-selftest
# P6-3：`--wav-repair` 此前**一个判据都没有**（连 `run` 都没进过），而它是唯一
# 会改用户录音文件的入口。这里钉住它**默认只报不改**：真回归成默认 --apply，
# 输出会变成「（**已加 --apply：会真的改文件**）」，这句断言立刻红。
# 夹具是临时目录里一个「零头 + 有 PCM」的 wav（内存里造，**不碰真实库**）。
# 「可修几个」那套分类计数由 `--recovery-selftest` 钉（那边有四档真值表）
WAVFIX="$(mktemp -d)"
dd if=/dev/zero of="$WAVFIX/zero.wav" bs=9644 count=1 2>/dev/null
run_assert "--wav-repair（夹具·默认只报不改）" "WAV 头体检（只报不改）" --wav-repair --dir "$WAVFIX"
rm -rf "$WAVFIX"
#
# P6-2：whisper 段落时间戳守卫 + 全库脏数据体检。同样离线、零花费。
# 条数钉住，「反向段」那几条**验过会红**：把 `WhisperSegmentTiming.resolve`
# 里 `raw1 < raw0` 那一支删掉（＝不做反向判定），对应判据立刻红。
# 体检那边「只读」是一条机器判据（扫描前后每个文件 sha256 逐个一致），
# 不是靠人记得别写
run_assert "--integrity-selftest" "✅ 脏数据自检通过（26 条）" --integrity-selftest
#
# P9-1：崩溃恢复（WAV 头修复 · 草稿 → 强杀 → 恢复 · 误报为零）。**离线**：
# 夹具音频全部由 `WAVRecorder` 写进临时目录的静音缓冲——不录音、不发声，
# 用户真实的 sessions/ recordings/ 一个字节都不碰。
# 条数钉住，理由同上面几条（用例掉到 0 时进程照样 exit=0）。
# 这条里有几处**否定式**判据，不测就等于没有：
#   · 正常 wav「一条都不报」+ 修完 sha256 前后一致
#   · 干净库零误报（把正常录音标成「未完成」比漏报更糟——用户会点恢复，然后拿到重复会话）
#   · 恢复扫描只读（扫前扫后逐文件 sha256 一致）
# 「恢复顺带修过期头」那句断言是**验过会红**的：把 `RecordingsStore.recover` 里
# 那次 `WAVHeaderRepair.apply` 拿掉，时长断言立刻从 2.300 掉回 2.000（一行注入即可自证）。
# 那两个读数记在 `~/ClassroomTranscriber-design/P9-1核验记录.md` §三 #2a
# ——注意该记录记的是**测量**（2.000s → 修后 2.300s），没有记这个「拿掉 apply」的变异
run_assert "--recovery-selftest" "✅ 崩溃恢复自检通过（55 条）" --recovery-selftest
# 模型下载（P7-1）。这条自检**必须**带 `CLASSROOM_MODELS_DIR` 跑——它会反复
# 写盘、改名、删 `.part`，不重定向的话动的就是用户真实的 `models/`（约 1.5GB）。
# 没设这个变量时它**直接拒绝运行**（红），这本身就是一条硬闸。
#
# ⚠️ 用完立刻 `unset`，**不能让它漏到后面**：`--whisper-prewarm` 要加载真模型，
# 一个漏出去的重定向会让它去空目录里找模型，然后以一种和本条完全无关的方式红掉
export CLASSROOM_MODELS_DIR="$(mktemp -d)"
run_assert "--model-download-selftest" "✅ 模型下载自检通过（91 条）" --model-download-selftest
unset CLASSROOM_MODELS_DIR
#
# 模型目录占用/清理（P7-1 补充要求 4）。**假目录里放一份伪造的 `.part`**——
# 它必须在「占用」清单里出现、并且被算进将释放的字节数里。断言抓的就是
# 那两行（HF 的措辞，刻意没翻译）：`Found 1 incomplete download(s)` 与
# `About to delete 2 item(s)`（`.part` 自己 + 它的版本记录，**版本记录也占字节**）。
#
# 这条**不删任何东西**：`--model-cache` 是只读的 dry-run（要真删得再加
# `-clean`），所以可以放心地对着临时目录跑。但目录重定向**必须一起设**——
# `--model-cache` 读的同样是 `WhisperEngine.modelDirectory`，漏了 export
# 就是把夹具写进用户真实的 `models/`，而这条断言照样会绿（扫描器会读到
# 假目录里没有、真目录里也没有的那个 `.part`，报 `Found 0`）→ 断言红，
# 但**夹具已经落在用户库上了**。顺序只能是：先建目录、再放夹具、再 export
CACHEFIX="$(mktemp -d)"
printf 'lmgg-part' > "$CACHEFIX/ggml-medium-q5_0.bin.part"
printf '{"revision":"5359861c739e955e79d9a303bcbc70fb988958b1","size":539212467,"url":"x"}' \
  > "$CACHEFIX/ggml-medium-q5_0.bin.part.meta.json"
export CLASSROOM_MODELS_DIR="$CACHEFIX"
run_assert "--model-cache（夹具·只报不改）" "Found 1 incomplete download(s)" \
  --model-cache
unset CLASSROOM_MODELS_DIR
rm -rf "$CACHEFIX"
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

  # ── 第 14 条断言（P9-2）：超时的那一刻**不许 abort** ──
  #
  # 这条入口的超时分支原先无条件走 `exitReleasingGgml()`，而那一刻
  # `Task.detached` 里的 `whisper_full` **还在算**——释放把 ggml 后端从正在计算的
  # 图底下抽走，C 层当场 `src/ggml-backend.cpp:426: GGML_ASSERT(backend) failed`，
  # 进程 **exit=134**。它和本文件开头讲的是同一类缺陷：**输出看着对、进程 abort**，
  # 所以判据也只能是退出码本身（栈与复现见 `exitWithoutReleasingGgml` 的注释）。
  #
  # 期望的退出码是 **124**（`timeout(1)` 的约定值），所以它没法用 `run_assert`
  # ——那个函数要求 exit=0。
  #
  # **怎么保证超时落在「正在转写」而不是「引擎还在构造」**：引擎构造期释放是安全的
  # （构造与销毁有同一把锁），那一刻不会红，判据就变成了空转。样本本身只有 3 秒，
  # 单趟转写也就三四秒，所以用 `--repeat 20` 把同一段音频连转 20 遍（约 70 秒），
  # 15 秒的上限必然落在 `whisper_full` 里面（实测：那 16 秒里引擎已经构造完，
  # `whisper_init_state` 四行都打出来了，超时落在转写中）。
  #
  # **注入验过（3/3 全红）**：把这一支改回 `exitReleasingGgml()` 重编，三次
  # 分别是 **134 / 139 / 139**。竞态决定「抽后端」和「用后端」谁先发生，所以
  # 落地信号不止 134——139 是 SIGSEGV，后端起指针在断言之前就被解了。判据因此
  # 写成「退出码必须**等于 124**」（不是「不等于 0」）：既挡住 134，也挡住 139，
  # 还挡住将来某种「0 但没跑到」的假绿。
  local_out="$("$BIN" --whisper-window-file "$SAMPLE" --repeat 20 --window-timeout 15 2>&1)"
  local_code=$?
  if [ "$local_code" = "124" ] && printf '%s' "$local_out" | grep -qF "离线跑超时"; then
    printf '  ✅ %-34s exit=124 · 断言命中\n' "--whisper-window-file 超时不 abort"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-34s exit=%s（期望 124；134/139 = 释放撞上正在算的图）\n' \
      "--whisper-window-file 超时不 abort" "$local_code"
    printf '       %s\n' "$(printf '%s' "$local_out" | tail -3 | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  fi
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
[ "$FAIL" = "0" ] && echo "✅ 退出码判据全过（含十六条断言：15 条 run_assert + 超时退出码 124）" \
                  || echo "❌ 有入口没过：要么退出码非 0（134 就是 ggml 静态析构 abort），要么 exit=0 但断言没命中——看上面逐条"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
