#!/bin/bash
# 「崩溃后仍能读到崩溃前最后 N 条」——**本包的核心判据**。
#
# 为什么必须真的把进程打死：在同一个进程里「写完再读」证明不了任何事。
# 那时进程还活着，攒在内存里的东西（要是有的话）当然读得到。只有
# `kill -9`（收不到任何信号回调、没有 `atexit`、没有 `deinit`）之后
# 盘上还有东西，才说明写入路径**没有用户态缓冲**——而「不做用户态缓冲」
# 正是 `LogRingWriter` 存在的理由。
#
# 为什么是 `kill -9` 而不是 `kill`（SIGTERM）：SIGTERM 默认也可以被接住、
# 可以用来做一次 flush，于是它就答不了「缓冲有没有」这个问题。
#
# 用法：
#   ./tools/probes/log_crash.sh            # 无参数，退出码即成败
#   LINES=200 ./tools/probes/log_crash.sh  # 换一个条数（连带验环形边界）
#
# 退出码 0 = 写进去的每一条都读得回来，且顺序对。
#
# **不发声、不碰音频、不联网、不加载模型**：全程只碰临时目录里的文本文件。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 ./build.sh"; exit 1; }

LINES="${LINES:-120}"
DIR="$(mktemp -d)/ct-log-crash"
mkdir -p "$DIR"

FAIL=0
step() { printf '  %s\n' "$1"; }
ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; FAIL=1; }

echo "════ 强杀恢复实测（kill -9）════"
step "日志目录：$DIR"
step "先写 $LINES 条，然后被打死"

# 探针自己会打印 PID 然后睡死。**用文件把 stdout 捡回来**，
# 不要用 `$(...)`：那会一直等到进程退出，而这个进程永远不会退出
OUT="$DIR/probe.out"
"$BIN" --log-crash-probe --dir "$DIR" --lines "$LINES" > "$OUT" 2>&1 &
PROBE_PID=$!

# 等它把 PID 打出来（同时意味着那 N 条已经写完了）
for _ in $(seq 1 100); do
  grep -q '^PID=' "$OUT" 2>/dev/null && break
  sleep 0.05
done
if ! grep -q '^PID=' "$OUT" 2>/dev/null; then
  bad "探针没起来（输出：$(cat "$OUT" 2>/dev/null | tr '\n' ' '))"
  kill -9 "$PROBE_PID" 2>/dev/null
  exit 1
fi
ok "探针起来了：$(grep '^PID=' "$OUT")"

# 强杀。等一小会儿确认它真的死了——进程还活着的话下面那次读就没有意义
kill -9 "$PROBE_PID" 2>/dev/null
wait "$PROBE_PID" 2>/dev/null
CODE=$?
if [ "$CODE" = "137" ] || [ "$CODE" = "9" ]; then
  ok "进程被 SIGKILL 收掉（wait 退出码 ${CODE}）"
else
  bad "进程不是被 SIGKILL 收掉的（wait 退出码 ${CODE}）——这次测的不是崩溃路径"
fi

# ── 读回来 ──
step ""
step "重新起一个进程读回来（读的那个进程和写那个没有任何关系）"
READ="$DIR/export.txt"
# `--tail` 给足：读的是「盘上还剩的全部」，不是最近 200 条——
# 这条判据问的是「崩溃前的现场还在不在」，不是「最近 200 条在不在」
"$BIN" --log-export --dir "$DIR" --tail 1000000 --out "$READ" > "$DIR/export.log" 2>&1
grep -q '^✅' "$DIR/export.log" \
  && ok "$(sed 's/^✅ //' "$DIR/export.log")" \
  || bad "导出失败：$(cat "$DIR/export.log")"

# 把读回来的编号抽成一行一个数字
NUMBERS="$DIR/numbers.txt"
grep -o '崩溃探针第 [0-9]* 条' "$READ" | sed 's/[^0-9]//g' > "$NUMBERS"
BODY=$(wc -l < "$NUMBERS" | tr -d ' ')
BODY=${BODY:-0}
step "读回正文条数：${BODY}（写进去 ${LINES}）"

# 判据一：**最后一条必须是第 N 条**——「最后 N 条」的「最后」是重点。
# 只验「有内容」的话，一个把文件从头截断的实现也能过
LAST=$(tail -1 "$NUMBERS")
[ "$LAST" = "$LINES" ] \
  && ok "最后一条是第 ${LINES} 条（被打死前写的最后那条就在盘上）" \
  || bad "最后一条是第「${LAST}」条，期望第 ${LINES} 条"

# 判据二：**读回来必须是连续的一段**。写满上限时最老的会被环形丢掉，
# 所以「全在」不是不变量——「中间不缺口、末尾正好是最后一条」才是。
# 编号跳号意味着有整条日志在轮转里被吃了，那是**数据丢失**而不是「上限」
if awk 'NR > 1 && $1 != prev + 1 { exit 1 } { prev = $1 }' "$NUMBERS"; then
  ok "读回来是连续的一段（老→新，中间不缺口）· 第 $(head -1 "$NUMBERS")…${LAST} 条"
else
  bad "读回来的编号有跳号——有整条日志在轮转里丢了（不是「上限」，是丢数据）"
fi

if [ "$BODY" -lt "$LINES" ] 2>/dev/null; then
  step "（本次被环形丢掉了 $((LINES - BODY)) 条最老的——正常，上限就是干这个的）"
fi

# 上限：这一跑写进去的字节数和文件数
step "文件：$(ls -1 "$DIR"/*.log 2>/dev/null | wc -l | tr -d ' ') 个 · 共 $(du -sk "$DIR" 2>/dev/null | awk '{print $1}') KB（含探针输出）"

echo ""
rm -rf "$(dirname "$DIR")"
[ "$FAIL" = "0" ] && echo "✅ 强杀恢复判据全过" || echo "❌ 有判据没过，看上面逐条"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
