#!/bin/bash
# 「录制中被强杀 → 重启后恢复」——P9-1 的核心判据，**用真的 `kill -9`**。
#
# 为什么必须真把进程打死：在同一个进程里「写完草稿再读回来」证明不了任何事。
# 那时录制循环还活着、落盘路径从没被中断过，而 P9-1 要答的问题恰恰是
# 「**进程没了**之后，盘上还剩什么」。只有 `kill -9`（收不到信号回调、
# 没有 `atexit`、没有 `deinit`）之后另起一个进程还能把草稿和音频捡回来，
# 才说明那条恢复路径是真的。
#
# 为什么不用 `kill`（SIGTERM）：SIGTERM 可以被接住、可以用来做一次收尾落盘，
# 于是它答不了「中途死掉会怎样」这个问题——那正是崩溃的形状。
#
# 用法：
#   ./tools/probes/recovery_crash.sh     # 无参数，退出码即成败
#
# 退出码 0 = 强杀后草稿还在、音频读得出来、恢复之后段数与草稿**逐条一致**、且
#            恢复顺带把崩溃留下的过期音频头修好了（时长从 2.000 变回 2.300）。
#
# **不录音、不发声、不碰系统音量、不联网、不加载模型**：音频是 `WAVRecorder`
# 写进临时目录的**静音**缓冲。用户真实的 sessions/ recordings/ 一个字节都不碰。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 ./build.sh"; exit 1; }

DIR="$(mktemp -d)/ct-recovery-crash"
mkdir -p "$DIR"

FAIL=0
step() { printf '  %s\n' "$1"; }
ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; FAIL=1; }

echo "════ 崩溃恢复实测（真的 kill -9）════"

# ── 第一个进程：造现场，然后等死 ──
# 用文件把 stdout 捡回来，不要用 `$(...)`：那会等到进程退出，而这个进程永远不退出
OUT="$DIR/probe.out"
"$BIN" --recovery-crash-probe --dir "$DIR" > "$OUT" 2>&1 &
PROBE_PID=$!

for _ in $(seq 1 200); do
  grep -q '^PID=' "$OUT" 2>/dev/null && break
  sleep 0.05
done
if ! grep -q '^PID=' "$OUT" 2>/dev/null; then
  bad "探针没起来（输出：$(cat "$OUT" 2>/dev/null | tr '\n' ' '))"
  kill -9 "$PROBE_PID" 2>/dev/null
  rm -rf "$(dirname "$DIR")"
  exit 1
fi

WAV="$DIR/recordings/课堂-20260928-090000.wav"
DRAFT_COUNT=$(grep '^  草稿段数' "$OUT" | awk '{print $2}')
step ""
sed 's/^/  /' "$OUT"
step ""

# 强杀之前先记下盘上的样子：这么比才说明「恢复改的是崩溃现场」
WAV_SHA_BEFORE=$(shasum -a 256 "$WAV" 2>/dev/null | awk '{print $1}')
WAV_BYTES_BEFORE=$(stat -f %z "$WAV" 2>/dev/null)
# 第 44 字节之后的 PCM。恢复只许动头里的两个长度字段，**这一段必须逐字节不变**——
# 所以「前」要在强杀之前取，那才是崩溃现场的原文
PAYLOAD_BEFORE=$(tail -c +45 "$WAV" 2>/dev/null | shasum -a 256 | awk '{print $1}')

kill -9 "$PROBE_PID" 2>/dev/null
wait "$PROBE_PID" 2>/dev/null
CODE=$?
if [ "$CODE" = "137" ] || [ "$CODE" = "9" ]; then
  ok "第一个进程被 SIGKILL 收掉（wait 退出码 ${CODE}）"
else
  bad "第一个进程不是被 SIGKILL 收掉的（wait 退出码 ${CODE}）——这次测的不是崩溃路径"
fi

# ── 盘上留下了什么（**这部分正是「崩溃现场的磁盘状态」**）──
step ""
step "崩溃后盘上的现场："
[ -f "$WAV" ] && ok "音频还在 · $WAV" || bad "音频不见了"
[ -n "$DRAFT_COUNT" ] && ok "草稿段数（被杀前最后一秒写的）：$DRAFT_COUNT" || bad "探针没报草稿段数"
step "  音频字节 ${WAV_BYTES_BEFORE} · sha256 ${WAV_SHA_BEFORE}"

# 崩溃留下的头是**过期**的：进程在头回填之前就死了。用系统读取器从外面看一遍
AF_BEFORE=$(afinfo "$WAV" 2>&1 | grep -i 'estimated duration' | head -1)
if printf '%s' "$AF_BEFORE" | grep -q '2\.0'; then
  ok "afinfo 读到的时长是**短的**（崩溃留下的过期头）：${AF_BEFORE##*: }"
else
  bad "afinfo 没读到预期的 2.0 秒过期时长：「${AF_BEFORE}」"
fi

# ── 第二个进程：重启，走恢复 ──
step ""
step '第二个进程（和写那个没有任何关系）——走界面上那条 RecordingsStore.recover'
REC_OUT="$DIR/recover.out"
"$BIN" --recovery-crash-probe --dir "$DIR" --recover > "$REC_OUT" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "恢复进程 exit=0" || bad "恢复进程 exit=${RC}"
sed 's/^/  /' "$REC_OUT"

grep -q '未完成' "$REC_OUT" \
  && ok "重启后被认成「未完成」（不是「无会话的录音」——草稿确实被捡回来了）" \
  || bad "重启后没认成「未完成」"

# 段数：恢复出来的必须和草稿一模一样
RECOVERED=$(grep -o '· [0-9]* 段' "$REC_OUT" | head -1 | grep -o '[0-9]*')
[ -n "$RECOVERED" ] && [ "$RECOVERED" = "$DRAFT_COUNT" ] \
  && ok "恢复出来的段数与草稿一致（${RECOVERED} 段）" \
  || bad "段数对不上：恢复 ${RECOVERED:-?} · 草稿 ${DRAFT_COUNT:-?}"

# 音频：**恢复顺带把过期头修好了**，所以现在读到的是真实时长
AF_AFTER=$(afinfo "$WAV" 2>&1 | grep -i 'estimated duration' | head -1)
if printf '%s' "$AF_AFTER" | grep -q '2\.3'; then
  ok "afinfo 现在读到 2.3 秒（过期头在恢复时被修好了）：${AF_AFTER##*: }"
else
  bad "afinfo 没读到 2.3 秒：「${AF_AFTER}」"
fi

WAV_SHA_AFTER=$(shasum -a 256 "$WAV" 2>/dev/null | awk '{print $1}')
WAV_BYTES_AFTER=$(stat -f %z "$WAV" 2>/dev/null)
step "  恢复后字节 ${WAV_BYTES_AFTER}（恢复前 ${WAV_BYTES_BEFORE}）· sha256 ${WAV_SHA_AFTER}"

# 音频长度不许变——恢复只重写头里的两个长度字段
[ "$WAV_BYTES_AFTER" = "$WAV_BYTES_BEFORE" ] \
  && ok "音频字节数不变（只重写了头，PCM 一个字节没动）" \
  || bad "音频字节数变了：${WAV_BYTES_BEFORE} → ${WAV_BYTES_AFTER}"
[ "$WAV_SHA_AFTER" != "$WAV_SHA_BEFORE" ] \
  && ok "sha256 变了（头确实被改了——不是「什么都没发生」的假绿）" \
  || bad "sha256 没变：头根本没被修，上面那条时长对得上就存疑了"

# 第 44 字节之后的 PCM 必须**逐字节不变**。这一条是「只改头」的机器判据：
# 拿它和上面那条「时长从 2.0 变 2.3」合起来看——头改了、音频没动，
# 两件事同时成立才叫「修复」而不是「重写」
PAYLOAD_AFTER=$(tail -c +45 "$WAV" 2>/dev/null | shasum -a 256 | awk '{print $1}')
[ -n "$PAYLOAD_BEFORE" ] && [ "$PAYLOAD_AFTER" = "$PAYLOAD_BEFORE" ] \
  && ok "第 44 字节之后的 PCM 逐字节未变（只重写了头）· ${PAYLOAD_AFTER}" \
  || bad "PCM 被动了：${PAYLOAD_BEFORE:-?} → ${PAYLOAD_AFTER:-?}"

# 草稿必须被移除——否则下次启动又会冒出一条重复的「未完成」
DRAFT_LEFT=$(ls -1 "$DIR/sessions/drafts"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$DRAFT_LEFT" = "0" ] \
  && ok "扶正之后草稿被移除（不留重复入口）" \
  || bad "草稿还在（${DRAFT_LEFT} 个）——下次启动会重复冒出「未完成」"

# 会话真的落盘了。**排除 index.json**——那个索引本来就在，
# 不排掉的话「恢复没写会话」这件事也照样能数出 1 来
SESSIONS=$(ls -1 "$DIR/sessions"/*.json 2>/dev/null | grep -v '/index\.json$' | wc -l | tr -d ' ')
[ "$SESSIONS" = "1" ] \
  && ok "正式会话落盘（$DIR/sessions/ 下 1 个会话 json，不含 index.json）" \
  || bad "会话数不对：${SESSIONS}（期望 1，不含 index.json）"

echo ""
rm -rf "$(dirname "$DIR")"
[ "$FAIL" = "0" ] && echo "✅ 崩溃恢复实测全过" || echo "❌ 有判据没过，看上面逐条"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
