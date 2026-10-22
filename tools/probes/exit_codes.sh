#!/bin/bash
# 无头入口的**退出码判据**：每个入口跑完必须 `exit=0`。
#
# 为什么单独有一条判据：whisper 的 ggml Metal 后端在进程静态析构时断言
# `[rsets->data count] == 0`，只要还有一个活着的 context，进程就以 **abort**
# 结束——**exit=134，而 stdout 完全正常**。所以「看输出都对」这件事证明不了
# 「这个入口是好的」，唯一的判据是退出码本身。2026-09-22 就是靠它发现
# `--whisper-prewarm` / `--mic-selftest` 三个入口都在 134。
#
# **二十个入口另外还断言输出里的一行**（`run_assert`，见那里的注释）。
#
# ⚠️ 计数说明（P9-2 逐条数过，P7-1 加二）：这段原先写「十四个入口」，而文件里实际
# 只有 **13** 条 `run_assert` 调用——`grep -c run_assert` 得到的 14 把上面那行函数
# 定义 `run_assert() {` 也数进去了。P9-2 补上第 14 条断言，但**它不是 `run_assert`
# 的形状**（期望的退出码是 124 而不是 0，见 `--whisper-window-file 超时不 abort`），
# 所以那时是 **13 条 `run_assert` + 1 条退出码断言 = 14 条**；P7-1 又加了
# `--model-download-selftest` 与 `--model-cache` 两条；B-1 加了
# `--questions-selftest`，现在是 17 条；P0-1 又加了 `--audio-devices` 与
# `--mic-device-selftest` 两条 `run_assert`，所以是 **18 条 `run_assert`
# + 2 条「期望的退出码不是 0」的断言 = 20 条**（后两条见下面 `--mic-level`
# 那一段的注释：它们验的是「该拒绝的时候真的拒绝了」）。
# P11-1 又加了 **3 条**：`--retranscribe-selftest`（`run_assert`）、
# `--retranscribe 缺 large 必须响亮拒绝`（`refuse`，期望非 0 且说出理由）、
# 以及「被拦住时不落盘」（普通断言，不是 `run_assert`——它查的是输出目录为空，
# 没有「输出里的一行」可断言）。所以现在是 **19 条 `run_assert` + 3 条期望
# 非 0 的 refuse + 1 条不落盘 + 1 条「超时必须是 124」= 24 条**。
# P12-1 又加了 **1 条**：`--glossary-prompt-selftest`（术语表前移的离线边界判据）。
# P12-2 又加了 **2 条**：`--speech-gate-selftest`，以及「静音窗不进模型」
# （合成夹具，跑真管线；同时判开门跳得动、关门一窗不跳）。
# P12-2 收尾又把 `--config-selftest` 从 `run` 升成 `run_assert_env`（**第 3 条**）：
# 那一节唯一的底线判据「真实配置全程未被触碰」红了进程也是 exit=0，
# 原先只看退出码等于没测；现在断言在字样上，并单独套隔离 HOME。
# P12-3 又加了 **2 条**：①`--config-selftest` 的「静音窗跳过·老配置没有该字段 →
# 读出来是开」（变异①把缺省改成 false 就是靠它红的；那一节红不红进程照样 exit=0，
# 所以必须断言在字样上）；②同一段合成夹具再跑一遍、**只改用户设置**
# （`speechGate=false`，不设环境变量）也必须一窗不跳——证明开关是从设置页那条
# 持久化链走到生产取窗的，而不是只有环境变量那一层。
# 所以现在是 **26 条输出断言（25 条 `run_assert`/`run_assert_env` + 1 条手工断言的
# 设置页路径） + 3 条 refuse + 1 条不落盘 + 1 条超时 = 31 条**。
#
# P12-2 那两条**为什么必须在这里**：门控的判据（跳过率 / 不许丢真人说话）
# 在真实录音上验，量级是十几分钟，归 `tools/probes/p12_2_speech_gate.sh`；
# 但「这道门接上了没有」本身是**分钟的、确定性的**（一段 24 秒的合成音频，
# 3 个窗里该跳几个是算得出来的），那就该进这条快扫描——否则门控哪天掉了线，
# 要等有人想起来跑那条重探针才发现。
# 真实模型那一段的 A/B（large 与 medium 各跑一遍）**不在这个文件里**，
# 见 `tools/probes/retranscribe.sh`：六七分钟的量级不该进这条快扫描。

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
# 退出码 0 = 跑到的入口全部 exit=0、且三十一条断言都命中（26 条输出断言 +
# 3 条「必须拒绝」+ 1 条「被拦住时不落盘」+ 1 条「超时的退出码必须是 124」——
# 后五条期望的本来就不是 0）。逐条计数见文件开头那段。
#
# ⚠️ **必须带 `CLASSROOM_BIN=<你那份构建>`**：
#   CLASSROOM_BIN=build-verify/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber \
#     ./tools/probes/exit_codes.sh
#   不给就走默认的 `build/`——**那是用户那份（可能是旧的）二进制**。2026-10-14
#   实测过：拿那份旧二进制跑一个**它不认识的参数**（当时是 `--audio-devices`），
#   它会当成「没给参数」**直接起 GUI、永远等事件**，整轮套件挂死 **9 小时 28 分**，
#   日志停在「已完成 1 条」。现在每条入口都有墙钟上限（`ENTRY_TIMEOUT`，见
#   `with_limit`），超时记「挂死」并继续下一条——但别拿这条兜底当许可：
#   看不出「这次跑的是谁」就等于白跑，所以**输出第一行永远是实际用的 BIN**。

set -uo pipefail
cd "$(dirname "$0")/../.."

# 二进制路径可重定向（P0-1 补充要求 ⑧）。
#
# 默认仍是 `build/`，行为不变。存在的理由：App 是 **ad-hoc 签名**的，系统的
# 麦克风授权（TCC）按**二进制指纹 cdhash** 记；谁重编一次 `build/`，用户之前
# 授过的那次授权就作废，表现为「点开始录制就崩」（2026-09-30 真的发生了两次）。
# 所以验证这一侧要能在**别的目录**里编、在别的目录里跑判据：
#   CLASSROOM_BUILD_DIR=build-verify ./build.sh
#   CLASSROOM_BIN=build-verify/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber \
#     ./tools/probes/exit_codes.sh
BIN="${CLASSROOM_BIN:-build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}"
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 ./build.sh"; exit 1; }

# 每条入口的墙钟上限（秒）。`ENTRY_TIMEOUT=5 ./tools/probes/exit_codes.sh` 可以压小
# ——验「挂死真的会被自己走出来」时用得上（见文件末尾那段注释）
ENTRY_TIMEOUT="${ENTRY_TIMEOUT:-300}"

# macOS 没有 `timeout(1)`。这里用 perl 给每条入口套墙钟上限，超时**返回 142**
# （= 128 + SIGALRM(14)，下面三条函数各自只认这一个码）。
#
# 为什么不是一行 `perl -e 'alarm shift; exec @ARGV'`：那一版验不过下面那条判据。
# 它在**最近的**那个进程上生效，而入口 fork 出来的**孙子**不在覆盖范围内——孙子
# 继承着命令替换的那根管子不放手，`$( )` 就永远等不到 EOF，套件照样挂死。
# 2026-10-14 用假「必挂」入口实测：条目本身确实被 3 秒掐掉、打印了「挂死」，
# 但**套件停在第一条不动了**（`sleep` 孙子吊着管子，父进程死了也没用）。
# 所以这里 fork 一份、让子进程 `setpgrp` 自成**进程组**，超时就 `kill -TERM -$pid`
# 打整组（1 秒后补 `-KILL`）。实测：`bash -c 'sleep 600'` 加 2 秒上限 → 3.0 秒
# 退出、码 142、**零残留**；正常退出时码（如 7）和 stdout/stderr 原样穿过。
#
# 为什么每条都得套一个上限：一个**不认识参数的入口**会当成「没给参数」起 GUI
# 并永远等事件——2026-10-14 拿用户那份旧 `build/` 跑 `--audio-devices` 就是这个
# 形状，整轮套件挂死 9 小时 28 分（见文件头的警告）
#
# 这条兜底自己也是**验过会红**的（注入一条只会 `sleep 600` 的假 BIN）：
# `ENTRY_TIMEOUT=3` 下整轮 **138 秒**走完 44 条、每条记「挂死」、`ps` 零残留
# （理论下界 44×3=132 秒）。别把 138 秒当成「快」——它随入口条数和上限线性走，
# 真要跑得快就把 `ENTRY_TIMEOUT` 压小，**不是**把这条兜底拿掉
with_limit() { # with_limit <命令…>
  perl -e '
    my $t = shift;
    my $pid = fork();
    die "fork 失败" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
    $SIG{ALRM} = sub {
      kill "-TERM", $pid;
      # 等它自己收尾，**不再无条件睡满 1 秒**：44 条挂死 × 1 秒 = 44 秒白等。
      # 2026-10-15 核验者量到假入口整轮 178 秒，而理论最小是 44×3=132 秒。
      # 改成一探 0.1 秒、最多 1 秒（收到 TERM 就死的进程通常第一探就走了）
      my $waited = 0;
      while ($waited < 10) { last if waitpid($pid, 1) == $pid; select(undef, undef, undef, 0.1); $waited++; }
      kill "-KILL", $pid;   # 组长收掉了也要补一刀：孙子可能还赖在这一组里
      waitpid($pid, 0);
      exit 142;
    };
    alarm $t;
    waitpid($pid, 0);
    my $st = $?;
    alarm 0;
    exit($st >> 8) if ($st & 127) == 0;
    exit(128 + ($st & 127));
  ' -- "$ENTRY_TIMEOUT" "$@"
}

# 挂死那一条的统一说法，`run` / `run_assert` / `refuse` 共用，免得三处各说各话
hung_note() {
  printf '       ↑ 挂死：%s 秒没退出，已强杀。多半是这个入口不认识这个参数、当成没给参数起了 GUI（别拿旧 build/ 跑）\n' \
    "$ENTRY_TIMEOUT"
}

# 挑一条真实录音给 --whisper-window-file 用（它需要 wav）
SAMPLE="$(ls "$REC"/*.wav 2>/dev/null | head -1)"

FAIL=0
PASS=0
# 「输出断言」的条数**数出来**，不写死：写死的那句汇总在 P12-2 已经和实际
# 差了两轮（先是二十五条，后来文件头改成 28 条），而它恰恰是给人看总数的
ASSERTS=0
run() { # run <名字> <参数…>
  local name="$1"; shift
  local out
  out="$(with_limit "$BIN" "$@" 2>&1)"
  local code=$?
  if [ "$code" = "0" ]; then
    printf '  ✅ %-34s exit=0\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-34s exit=%s\n' "$name" "$code"
    # 142 = 128 + SIGALRM：**只有** `with_limit` 掐超时时才回这个码（它自己
    # 造的，不是被掐进程的退出码）。先认它，免得把「挂死」误读成「入口返回了 142」
    [ "$code" = "142" ] && hung_note
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
  ASSERTS=$((ASSERTS + 1))
  local name="$1"; shift
  local want="$1"; shift
  local out code
  out="$(with_limit "$BIN" "$@" 2>&1)"
  code=$?
  if [ "$code" != "0" ]; then
    printf '  ❌ %-34s exit=%s\n' "$name" "$code"
    [ "$code" = "142" ] && hung_note
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

# 同 `run_assert`，但**给这一条单独套一组环境变量**。
#
# 给「这条入口本身碰不得真东西」那一类用：`--config-selftest` 要验的是
# 「真实配置文件全程未被触碰」,可是它验的那份「真文件」是 `configURL`——
# 万一哪天有人把往返改回直接动真文件，跑这条断言就等于拿用户的真钥匙去陪跑。
# 套上 `CFFIXED_USER_HOME=<临时目录>` 之后，同一份代码解析到的「真文件」落在
# 临时目录里：**判据照样能红**（指纹仍会从不存在的变成存在），
# 但真文件连被误伤的机会都没有。
run_assert_env() { # run_assert_env <名字> <输出里必须出现的行> <env 赋值> <参数…>
  ASSERTS=$((ASSERTS + 1))
  local name="$1"; shift
  local want="$1"; shift
  local envspec="$1"; shift
  local out code
  out="$(with_limit env "$envspec" "$BIN" "$@" 2>&1)"
  code=$?
  if [ "$code" != "0" ]; then
    printf '  ❌ %-34s exit=%s\n' "$name" "$code"
    [ "$code" = "142" ] && hung_note
    [ "$code" = "134" ] && printf '       ↑ abort：几乎一定是 ggml/whisper context 没释放\n'
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

# 同 `run`，但**期望的退出码不是 0**、并且输出里要说出理由。
#
# 给「该拒绝的时候真的拒绝了」这一类用。只看退出码是不够的：一个直接崩掉的
# 实现（133/134）退出码也非 0，而那不是「拒绝」，是没有守住闸
refuse() { # refuse <名字> <输出里必须出现的行> <env 赋值|-> <参数…>
  local name="$1"; shift
  local want="$1"; shift
  local envspec="$1"; shift
  local out code
  if [ "$envspec" = "-" ]; then
    out="$(with_limit "$BIN" "$@" 2>&1)"
  else
    out="$(with_limit env "$envspec" "$BIN" "$@" 2>&1)"
  fi
  code=$?
  if [ "$code" != "0" ] && printf '%s' "$out" | grep -qF "$want"; then
    printf '  ✅ %-34s exit=%s · 断言命中\n' "$name" "$code"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-34s exit=%s（期望非 0 **且**说出理由）\n' "$name" "$code"
    [ "$code" = "142" ] && hung_note
    printf '       %s\n' "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  fi
}

# **整个套件的第一行输出就是实际用的那个二进制**。挂死现场（9 小时 28 分那次）
# 里日志可能只剩开头几行，所以这一行必须在**任何小节标题之前**：拿错二进制
# 正是那次挂死的成因，「这次跑的到底是谁」得比「跑到哪一节了」先看见。
#
# 变量一律写 `${X}`：紧跟全角括号时 `$X（` 会被 bash 当变量名的一部分
# （UTF-8 locale 下多字节字符算标识符字符），表现是 `set -u` 下的
# 「BIN（…: unbound variable」——提示信息本身没了，只剩退出码非 0（实测踩过）
echo "BIN=${BIN}（每条入口上限 ${ENTRY_TIMEOUT}s，超时记「挂死」并继续）"
echo "════ 纯本地入口（不需要模型 / 网络 / 麦克风）════"
run "--selftest"                    --selftest
# 输入设备清单（P0-1）。**只读**：走 CoreAudio 的 HAL 属性读取，一次都不碰
# `AVAudioEngine` 的输入节点——不录音、不发声、不改任何系统音频设置、
# 不弹授权框。所以它可以放在这个「不需要麦克风」的一段里。
#
# 断言取的是「系统默认输入设备：」这一行：设备一只都列不出来时，代码会在
# 那行**之前**就返回（并打印为什么），所以这行命中 = 设备表真读到了。
# 未授权**不影响**这一条（枚举设备不需要授权），所以它在哪种授权状态下都该绿。
# 这也是它和 `--mic-level` 的分工：那个要真开麦，只能在 WITH_MIC 里跑
run_assert "--audio-devices" "系统默认输入设备：" --audio-devices
# 采集设备自检（P0-1）：该记哪只设备 / 中途换设备 / 存档读写与旧格式兼容 /
# 电平判据。**全程离线、不开麦**——真设备那一段靠上面的 `--audio-devices` 和
# 用户上课录一段来确认，这条自检不假装验过它。
# 条数钉住，理由同下面几条（用例掉到 0 时进程照样 exit=0）。
# 这条里的判据**验过会红**（两个变异，注入后对应断言立刻红、还原后逐字节一致，
# 记录见 `~/ClassroomTranscriber-design/P0-1核验记录.md`）：
#   · 不写 capture 字段 → 「会话 JSON 字节里有 capture 键」等 4 条红
#   · 改成读系统默认设备（`resolve` 里不看引擎报的那个）→ 「取的是引擎的」那两条红
run_assert "--mic-device-selftest" "✅ 采集设备自检通过（53 条）" --mic-device-selftest
#
# ── `--mic-level` 的**拒绝**路径（P0-1 补充要求 ①/⑩）──
#
# 这是本仓库**唯一会真的开麦录音**的入口，所以它默认必须拒绝运行：没把输出
# 重定向出去，它要写的就是用户真实的 `recordings/`。
#
# **这一条能放进这个自动段，是因为它在碰麦克风之前就退出了**（闸在构造
# `AVAudioEngine` 之前）。真录那一段在下面的 `WITH_MIC=1` 里，由人显式触发。
#
# 两种拒绝都要：
#   ① 完全没有重定向；
#   ② 重定向到真实库里面去（`CLASSROOM_MIC_OUT` 指过去）——「带了重定向」
#      不等于「重定向到安全的地方」，只验①的话，把②那条闸删掉照样全绿。
#
# **显式 `unset`**：前面若有人 export 过这个变量，①会退化成一个空转的假绿
unset CLASSROOM_MIC_OUT
refuse "--mic-level 无重定向必须拒绝" "拒绝运行：没有指定输出目录" - --mic-level
refuse "--mic-level 指向真实库必须拒绝" "拒绝运行：目录落在真实库里" \
  "CLASSROOM_MIC_OUT=$REC" --mic-level
run "--quality-selftest"            --quality-selftest
# ── `--retranscribe` 的**拒绝**路径（P11-1 目标 2 / 验收 ②④）──
#
# 模型缺失时**必须响亮失败**，而它最容易在这次改动里退化成「那就用 medium 跑吧」。
# 这一条把那个退化按死在闸上：模型目录里**只有 medium、没有 large**，退出码必须
# 非 0，且输出里要出现「不会静默回落到 medium」。
#
# ⚠️ **medium 必须真的在那边**（下面用 `cp -c` 做 APFS 克隆，不复制 539MB 的实体）。
# 这是这条判据能不能红的全部关键：目录**全空**时，一个「缺 large 就换 medium」的
# 实现照样会走到「medium 也不在」，于是照样 exit=3——**判据全绿，而回落已经写进
# 去了**。那种假绿本仓库吃过亏（见 CLAUDE.md「判据必须能红」），所以这里刻意造出
# 「回落真的能成功」的现场，回落一旦落码就当场变红。把 large 那一条注回
# `RetranscribeRun` 里验过：exit=0 → 这条断言红。
#
# 也**不能用符号链接**（试过，不行）：`ModelAvailability.probe` 走的是
# `FileManager.attributesOfItem(atPath:)`，它**不跟随符号链接**，拿到的是链接
# 自身的大小（实测 89 字节 = 目标路径的长度），于是裁决报「只有 89 字节」——
# 夹具就变成了「medium 也不在」那种假绿。`cp -c` 在 APFS 上是写时复制，
# 不占第二份空间，而且是一个真的普通文件。
#
# **它秒级、且不加载任何模型**：模型的裁决发生在读音频之前，所以夹具会话不需要
# 真音频——一条把 segments 清空的会话就够走到那一支。夹具在临时目录里造，
# **用户真实的 sessions/ 一个字节都不碰**。
#
# 真音频那一段（两个引擎各跑一遍、比段数字数、比输入文件 sha256）在
# `tools/probes/retranscribe.sh`——large 跑 120 秒样本要六七分钟，
# 不该塞进这条「快、确定性」的扫描里
RTRFIX="$(mktemp -d)"
RTRIN="$(mktemp -d)"
RTROUT="$(mktemp -d)"
cat > "$RTRIN/fixture.json" <<'JSON'
{"id":"00000000-0000-0000-0000-0000000000AA","startedAt":0,"updatedAt":0,
 "parts":[{"id":"00000000-0000-0000-0000-0000000000BB","fileName":"fixture.wav",
 "startedAt":0,"durationMillis":120000,"offsetMillis":0,"segments":[]}]}
JSON
RTRMED="$HOME/Library/Application Support/ClassroomTranscriber/models/ggml-medium-q5_0.bin"
if [ -f "$RTRMED" ]; then
  cp -c "$RTRMED" "$RTRFIX/ggml-medium-q5_0.bin"
  # 目录重定向必须在**这一句里**（`refuse` 的 env 参数），不 export：漏出去会让
  # 后面的 `--whisper-prewarm` 去空目录里找模型，以一条完全无关的方式红掉
  refuse "--retranscribe 缺 large 必须响亮拒绝" "不会静默回落到 medium" \
    "CLASSROOM_MODELS_DIR=$RTRFIX" \
    --retranscribe "$RTRIN/fixture.json" --out "$RTROUT" --engine large
  # 被拦住了却往 --out 里写了半份 = 把拦截变成一个更隐蔽的假绿。
  #
  # ⚠️ 它是**否定式**的，所以一头什么都不写的假二进制也会让它假绿——测超时那次
  # （BIN 指向一个只会 sleep 的脚本）它就是这么过的：44 条挂死里它一条绿。
  # 它必须和上面那条 `refuse` 成对读（那条才证明「拦是拦了」），单独看没有意义
  if [ -z "$(ls -A "$RTROUT" 2>/dev/null)" ]; then
    printf '  ✅ %-34s %s\n' "--retranscribe 被拦住时不落盘" "输出目录是空的"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-34s 被拦住了却写了：%s\n' "--retranscribe 被拦住时不落盘" \
      "$(ls -A "$RTROUT" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  ⏭  --retranscribe 缺 large 必须响亮拒绝：本机没有 medium 模型，"
  echo "      「回落能不能成功」这个现场造不出来（造一个假文件不是这个现场）——跳过"
fi
rm -rf "$RTRFIX" "$RTRIN" "$RTROUT"
run "--hallucination-selftest"      --hallucination-selftest
# 离线重算入口用固定夹具跑（夹具说明见 tools/probes/fixtures/hallucination_replay.log）。
# 它值得覆盖：这个入口要读文件、解析、再走一遍判据，正是「输出看着对但进程 abort」
# 那类缺陷的高发形状
run "--hallucination-replay（夹具）"   --hallucination-replay tools/probes/fixtures/hallucination_replay.log
run "--split-selftest"              --split-selftest
run "--punct-selftest"              --punct-selftest
run "--dedup-selftest"              --dedup-selftest
run "--session-selftest"            --session-selftest
# 提问数据层（B-1）：模型 / 向后兼容 / 归一化 / 入列去重 / 按需回填 / 摘要计数。
# **离线**：夹具全在临时目录里造，不联网、不调模型、不发声、不读用户真实库。
# 名字与上面那条 `--question-selftest` **只差一个 s**，别混：那条验「这句话算不算
# 提问」，这条验「提问存下来之后怎么活」（缺键兜底、僵尸 searching 改写、
# 回填幂等、去重保留最早那次）。
# 条数钉住，理由同下面几条：用例掉到 0 时进程照样 exit=0。
# 这条里的判据**验过会红**（两个变异，各自注入后对应断言立刻红、还原后 sha256
# 逐字节一致）：把 §6.2 的 n5 拿掉 → 「n5 去尾随「呢」」等 8 条红；
# 把僵尸 searching 的改写拿掉 → 僵尸那 3 条红
run_assert "--questions-selftest" "✅ 提问数据层自检通过（63 条）" --questions-selftest
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
# 课后重转（P11-1）。**离线**：纯函数 + 内存夹具，不加载模型、不联网、不碰音频。
# 它守两条本包最要紧的判据，而两条都**只在特定输入下才现形**：
#   · 实时链路的模型仍是 medium——谁把 large 改成全默认，这里立刻红；
#   · 缺 / 残 / 张冠李戴（文件名写着 large、内容其实是 medium 的 539MB）→
#     拦住，且文案里明说**不会静默回落**。
# 条数照样钉住，理由同上（用例掉到 0 时进程照样 exit=0）。
# 「实际加载的是哪一个模型」那条判据不在这里——它要真模型，在
# `tools/probes/retranscribe.sh` 里（large 与 medium 各跑一遍、两套数字都打出来）
run_assert "--retranscribe-selftest" "✅ 课后重转自检通过（51 条）" --retranscribe-selftest
# 术语表前移（P12-1）。**离线纯函数**：不加载模型、不联网、不碰音频、不发声。
# 它守的三件事在真实数据上**都不出现**：真实词表 100 多条，既不空、也不卡在上限上
# ——而「空词表」「超限截断」「开关关掉」只在特定输入下现形，错了的话转录照样出结果、
# 什么都不报。所以这条自检喂的是边界值（正好装下 / 差一个字 / 引导语都放不下 /
# 重复词 / 关掉开关但词表又短又非空）。
# 条数照样钉住，理由同上（用例掉到 0 时进程照样 exit=0）。
# 第八节钉的是**缺省值本身（关）**：它决定「明天照常录课」时 whisper 收到什么参数，
# 而缺省值是 2026-10-13 被 A/B 从「开」翻过来的——翻默认必须是一次看得见红的改动。
# 真模型那两个变异（构造时把词丢掉 / 超限不截断）不在这条扫描里——它们要重编
# 二进制，记录见 `~/ClassroomTranscriber-design/P12-1核验记录.md`
run_assert "--glossary-prompt-selftest" "✅ 术语表前移自检通过（30 条）" --glossary-prompt-selftest
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
# P12-1b 又加了 30 条（【九】取件形状回落）：镜像对清单那个 commit 的 40 位 sha
# 一律 404，所以 404 时要换同一个 commit 的 12 位前缀再试一次，别的一律不换。
# 那些判据**离线**——夹具 `/resolve/<全sha>/…` 复刻 404、`/resolve/<12位>/…` 给件、
# `/resolve/<全sha>/denied` 复刻 403。真网络那条不在这里：它要联网，单独在
# `tools/probes/model_download_url.sh`（**故意不进这个文件**——这条要快、要确定性）。
#
# ⚠️ 用完立刻 `unset`，**不能让它漏到后面**：`--whisper-prewarm` 要加载真模型，
# 一个漏出去的重定向会让它去空目录里找模型，然后以一种和本条完全无关的方式红掉
export CLASSROOM_MODELS_DIR="$(mktemp -d)"
# 条数从 121 → 131 → 143，每一步都是**独立核验者抓出来的假绿**换来的：
#   121：删 `attempt -= 1`、删 `?? resolveRef(of: url)` 当时全绿 → 补【九之七】等
#   131：把 `fromEnvironment` 改成无条件 `.off` 当时全绿（探针也绿），而它的谎话
#        是当场可见的——探针没设变量却打印「回落：关」 → 补开关契约 + 对调优先级
# **这个数字是判据的总数**：它掉下来就说明有人删判据，比任何一条具体断言都先报警
#
# P12-2 清理时加了【九之零】4 条（「没认 LocalizedError 才说天书」落成行为判据：
# 两个只差一个 conformance 的类型对同一句），所以总数 143 → **147**。
# 数字是当场跑出来的，不是照旧抄的
run_assert "--model-download-selftest" "✅ 模型下载自检通过（147 条）" --model-download-selftest
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
# 配置读写往返（P12-2 收尾）。原先只是 `run`（只看退出码），而这一节**唯一
# 的底线判据**是末条「真实配置全程未被触碰」——它红了**进程照样 exit=0**
# （自检是打印式的）。所以那条判据必须断言在字样上，否则等于没测。
#
# 断言抓 ✅ 那一版：注入实验（把 `Store(url: tmpDir…)` 改回 `Store(url: configURL)`，
# 让这一节重新去动真文件）实测末条变成「❌ 真实配置全程未被触碰（指纹变了：
# 不存在，现在 存在 · 432 字节 · mtime …）」——同一个字样位，换成 ❌ 这条就红。
#
# 套 `CFFIXED_USER_HOME`（**不是 `HOME=`**，见 `AppConfig.selfTest` 里那段：
# macOS 上 Foundation 的 `.applicationSupportDirectory` 根本不看 `$HOME`）。
# 注入那次真文件没被碰：实测 `config.json` 的 sha256 前后一致。
#
# ⚠️ 临时目录**用完就删**：`CFFIXED_USER_HOME` 一漏到后面各条入口，
# 那些要读模型/录音的会去空目录里找、以和本条无关的方式红掉
CFGFIX="$(mktemp -d)"
run_assert_env "--config-selftest" "✅ 真实配置全程未被触碰（指纹一致" \
  "CFFIXED_USER_HOME=$CFGFIX" --config-selftest
# P12-3：静音窗跳过在**老配置**（没有该字段）上必须读成「开」。这一条是
# 变异①（把缺省改成 false）的落点——自检红不红进程都 exit=0，所以只能断言字样。
# 它同时钉住「缺省开」这个决定：哪天有人觉得「关掉更省事」顺手翻默认，
# 这条会红，而不是等用户的静音段重新长出幻觉句才发现
run_assert_env "--config-selftest 静音窗跳过缺省" \
  "✅ 静音窗跳过·老配置没有该字段 → 读出来是开" \
  "CFFIXED_USER_HOME=$CFGFIX" --config-selftest
rm -rf "$CFGFIX"
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
# 门控的**判据本体**（纯函数／合成波形）：阈值上下、同一段音频的窗口边界、
# 以及那条已知误判（连续 0.006 平音被当成静音）。不加载模型、不碰麦克风，
# 所以放在这一段。断言抓「N 条」——用例掉到 0 也照样 exit=0
run_assert "--speech-gate-selftest" "✅ 静音门控自检通过（33 条）" --speech-gate-selftest

echo
echo "════ 要真模型的入口（会加载 539MB 模型）════"
run_assert "--whisper-prewarm" "构造 ggml context 次数: 1（" --whisper-prewarm

# ── P12-2：静音窗不进模型（合成夹具，走真管线）──
#
# **为什么这里自己造一段**（而真实录音那条留给了另一支探针）：这一段要判的是
# 「门控接上了没有」——该跳的窗跳了、关掉开关一窗不跳。这件事必须**确定性**：
# 真实录音上「哪一窗算静音」会随着阈值调参而变，把它钉进这条快扫描，
# 等于把一处调参变成两处维护。真实录音上的跳过率与「不许丢真人说话」
# 在 `tools/probes/p12_2_speech_gate.sh`（十几分钟那一档）。
#
# 夹具 = 8 秒 300Hz 正弦（0.05 幅度，判据认它「有声」）+ 16 秒**数字零**，
# 共 24 秒。生产步长 3 秒，取窗必然是 6 个，每个都是算得出来的：
#   fed 3.0  → [0, 3)   全正弦                → 有声
#   fed 6.0  → [0, 6)   起点与上一窗相同      → 被「同一窗不重转」挡掉
#   fed 9.0  → [0, 9)   同上                  → 挡掉
#   fed 12.0 → [2, 12)  2–8 秒正弦（6/10）    → 有声（占比 0.6）
#   fed 15.0 → [5, 15)  5–8 秒正弦（3/10）    → 有声（占比 0.3）
#   fed 18.0 → [8, 18)  全零                  → 静音·跳
#   fed 21.0 → [11, 21) 全零                  → 静音·跳
#   fed 24.0 → [14, 24) 全零                  → 静音·跳
#   （收尾窗起点也是 14.0，与最后一窗相同 → 同样被挡掉）
# 所以四个数都不是「跑出来多少算多少」：取窗 6 / 跳过 3 / 真的解了 3。
#
# ⚠️ 取窗起点是「喂入时刻往回 10 秒」，不是「按步长累加的游标」：游标只决定
# **什么时候**取，起点永远是 `fed - 10 秒`（缓冲不够长时从 0 开始）。这就是
# 前三次取窗起点全是 0 的原因——和真实录音上量到的起点序列（0 / 0 / 0 /
# 2 / 5 / 8 …/ 110）是同一个道理。判据只数个数，写实际值是为了让人拿这条
# 去核 `--gate-scan` 时不会以为自己看错了。
# 「跳过音频」是**按窗长累加**的（三个 10 秒的窗互相重叠），所以是 30.0 秒
# 而不是「24 秒里静音的 16 秒」——这条断言顺带钉住了那个口径。
GATEFIX="$(mktemp -d)"
python3 - "$GATEFIX/gate.wav" <<'PY'
import math, struct, sys, wave
rate, tone_seconds, silent_seconds = 16000, 8, 16
tone = [int(0.05 * 32767 * math.sin(2 * math.pi * 300 * i / rate))
        for i in range(rate * tone_seconds)]
with wave.open(sys.argv[1], "wb") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(rate)
    out.writeframes(b"".join(struct.pack("<h", value) for value in tone + [0] * (rate * silent_seconds)))
PY
run_assert "--whisper-window-file 静音窗不进模型" \
  "取窗 6 · 跳过 3（50.0%）· 跳过音频 30.0 秒 · 真的解了 3 窗" \
  --whisper-window-file "$GATEFIX/gate.wav" --head 24
# 同一条入口、同一条取窗路径，只把开关关掉 → 一窗都不许跳
export CLASSROOM_SPEECH_GATE=off
run_assert "--whisper-window-file 门控关掉一窗不跳" \
  "取窗 6 · 跳过 0（0.0%）· 跳过音频 0.0 秒 · 真的解了 6 窗" \
  --whisper-window-file "$GATEFIX/gate.wav" --head 24
unset CLASSROOM_SPEECH_GATE

# ── P12-3：设置页那条路（**不设环境变量**）──
#
# 上一条证明的是「环境变量能把门关上」；这一条证明的是「**用户在设置页里关**
# 也能关」——那是 P12-3 存在的理由。判据必须走**持久化链**：把
# `speechGate: false` 写进用户配置（设置页保存后文件就长这样），不设
# `CLASSROOM_SPEECH_GATE`，同一段夹具必须一窗都不跳。
#
# 隔离用 `CFFIXED_USER_HOME`（**不是 `HOME=`**：macOS 上 Foundation 的
# `.applicationSupportDirectory` 根本不看 `$HOME`，见 `AppConfig.selfTest`）。
# 它同时把模型目录挪走了，所以 `CLASSROOM_MODELS_DIR` 单独指回真目录——
# 不指回的话这里会以「模型缺失」退出，而那和门控无关，红得没有意义。
GATECFG="$(mktemp -d)"
mkdir -p "$GATECFG/Library/Application Support/ClassroomTranscriber"
printf '{"speechGate": false}' \
  > "$GATECFG/Library/Application Support/ClassroomTranscriber/config.json"
GATE_MODELS="${CLASSROOM_MODELS_DIR:-$HOME/Library/Application Support/ClassroomTranscriber/models}"
ASSERTS=$((ASSERTS + 1))
out="$(CFFIXED_USER_HOME="$GATECFG" CLASSROOM_MODELS_DIR="$GATE_MODELS" \
  with_limit "$BIN" --whisper-window-file "$GATEFIX/gate.wav" --head 24 2>&1)"
code=$?
if [ "$code" = "0" ] && printf '%s' "$out" | grep -qF "取窗 6 · 跳过 0（0.0%）· 跳过音频 0.0 秒 · 真的解了 6 窗"; then
  printf '  ✅ %-34s exit=0 · 断言命中（设置页关 → 一窗不跳）\n' "--whisper-window-file 设置页关闭门控"
  PASS=$((PASS + 1))
else
  printf '  ❌ %-34s exit=%s，或输出里没有「设置页关 → 一窗不跳」的读数\n' "--whisper-window-file 设置页关闭门控" "$code"
  printf '       %s\n' "$(printf '%s' "$out" | grep -F '取窗 ' | head -1 | sed 's/^ *//')"
  FAIL=$((FAIL + 1))
fi
rm -rf "$GATECFG"
rm -rf "$GATEFIX"

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
  #
  # P12-2 补：这一条**必须把门控关掉**。它要的是「超时落在 `whisper_full` 里」，
  # 而门控开着时那 3 秒样本可能整窗被判静音 → 一个 `whisper_full` 都不跑，
  # 20 遍也就几毫秒，15 秒上限永远落不到转写中——判据变成空转（照样 124 吗？
  # 不会：那样进程会正常 exit=0，这条会红得很响，但红的原因与它要测的东西无关）。
  # 关掉门控 = 回到这一条写下时的行为，它测的还是「超时那一刻不许 abort」。
  export CLASSROOM_SPEECH_GATE=off
  local_out="$(with_limit "$BIN" --whisper-window-file "$SAMPLE" --repeat 20 --window-timeout 15 2>&1)"
  local_code=$?
  unset CLASSROOM_SPEECH_GATE
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

  # 真录一段并打印电平判据（P0-1 ①）。**必须重定向**——重定向到临时目录，
  # 用户真实的 `recordings/` 一个字都不许写进去。
  #
  # 默认 5 秒。这一段量的是**设备本身的电平**（不走增益、不走语音处理），
  # 所以「对着麦说几句话」是这一步唯一有意义的做法：全程不说话的话，
  # 逐秒那几张表会全是「几乎没人说话」，动态范围量不出来
  MICOUT="$(mktemp -d)"
  run "--mic-level（真录 5 秒）" --mic-level --out "$MICOUT"
  echo "     ↳ 落盘：$(ls -1 "$MICOUT" 2>/dev/null | tr '\n' ' ')"
  rm -rf "$MICOUT"
fi

echo
echo "──── 合计：过的有 $PASS 个，没过 $FAIL 个 ────"
# 这句要说全两种失败，不能只说退出码：加了 `run_assert` 之后，**exit=0 但断言没命中**
# 也是一条不过（核验者 2026-09-24 指出：那种情况下原话「退出码不为 0」是错的）
[ "$FAIL" = "0" ] && echo "✅ 退出码判据全过（含 ${ASSERTS} 条输出断言 + 必须拒绝 / 被拦住不落盘 / 超时退出码 124 等退出码断言；逐条 $((PASS + FAIL)) 个）" \
                  || echo "❌ 有入口没过：要么退出码非 0（134 就是 ggml 静态析构 abort），要么 exit=0 但断言没命中——看上面逐条"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
