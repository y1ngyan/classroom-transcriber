#!/bin/bash
# P7-1：断点续传的**真 `kill -9`** 实验。
#
# 为什么 `--model-download-selftest` 里那条不够：
# 那条验的是**续传的读路径**——它手工把 `.part` 铺成「上次下到 60000 字节」
# 的样子，然后让下载器接着下。它没有验过「进程被强杀之后，磁盘上**真的**
# 还剩多少」。这两件事不是一回事：`.part` 要是被用户态缓冲着，或者清理路径
# 顺手把它删了，读路径那条照样全绿。
#
# `kill -9` 不走任何清理路径——没有 `atexit`、没有 `defer`、没有 flush 回调。
# 所以它是唯一能同时钉住两件事的办法：
#   ① 每一刻的 `.part` 都是完整的（已经落盘的那些字节真的在盘上）；
#   ② 接管的那一次真的从那里接上，而不是从头重来。
#
# **不联网、不下真模型、不碰用户真实 `models/`**：源是本机回环上的
# `--model-fixture-server`，出货是几百 KB 的假模型。
#
# 用法：./tools/probes/model_resume.sh      （退出码即成败）
set -u

cd "$(dirname "$0")/../.." || exit 2
BIN=${BIN:-build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}

if [ ! -x "$BIN" ]; then
  echo "❌ 找不到 ${BIN}，先跑 ./build.sh"
  exit 2
fi

TMP=$(mktemp -d)
SERVER_PID=""
FETCH_PID=""
cleanup() {
  [ -n "$FETCH_PID" ] && kill -9 "$FETCH_PID" 2>/dev/null
  [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

DEST="$TMP/m.bin"
PART="$DEST.part"
FRESH="$TMP/fresh.bin"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }

size_of() { stat -f%z "$1" 2>/dev/null || echo 0; }

echo "断点续传 · 真 kill -9（本机夹具 · 不联网 · 不碰真实 models/）"
echo ""

# ── 起夹具服务器 ──
"$BIN" --model-fixture-server --port-file "$TMP/port" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 50); do
  [ -s "$TMP/port" ] && PORT=$(cat "$TMP/port") && break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "❌ 夹具服务器没起来（5 秒内没写出端口）"
  cat "$TMP/server.log"
  exit 1
fi
echo "夹具服务器：http://127.0.0.1:${PORT}（pid ${SERVER_PID}）"
echo ""

# ── 第一次：下到一半掐死 ──
echo "【一】下到一半 kill -9"
"$BIN" --model-fetch "http://127.0.0.1:$PORT/veryslow" --to "$DEST" --min-bytes 200000 \
  > "$TMP/fetch1.log" 2>&1 &
FETCH_PID=$!

# 等它真的下了几万字节再动手——「刚开始就掐」验不到东西
MID=0
for _ in $(seq 1 100); do
  MID=$(size_of "$PART")
  [ "$MID" -ge 30000 ] && break
  sleep 0.1
done
kill -9 "$FETCH_PID" 2>/dev/null
wait "$FETCH_PID" 2>/dev/null
FETCH_PID=""

AFTER_KILL=$(size_of "$PART")
if [ "$MID" -ge 30000 ]; then
  ok "掐之前已下载 $MID 字节"
else
  bad "等了 10 秒也只下了 $MID 字节（夹具没跑起来？）"
fi
if [ "$AFTER_KILL" -ge 30000 ]; then
  ok "kill -9 之后 .part 还在，且有 $AFTER_KILL 字节落到了盘上"
else
  bad "kill -9 之后 .part 只剩 $AFTER_KILL 字节（缓冲没落盘，或者被清理路径删了）"
fi
if [ ! -f "$DEST" ]; then
  ok "没有半成品被当成正式文件"
else
  bad "正式文件竟然 already 存在了（${DEST}）"
fi
echo ""

# ── 第二次：接管，必须从 AFTER_KILL 接上 ──
echo "【二】重进：从已有字节继续"
"$BIN" --model-fetch "http://127.0.0.1:$PORT/veryslow" --to "$DEST" --min-bytes 200000 \
  > "$TMP/fetch2.log" 2>&1
CODE=$?
if [ "$CODE" = "0" ]; then
  ok "第二次下载 exit=0"
else
  bad "第二次下载 exit=$CODE"
fi

RESUMED=$(sed -n 's/.*（从 \([0-9]*\) 接上）.*/\1/p' "$TMP/fetch2.log")
if [ -n "$RESUMED" ] && [ "$RESUMED" -gt 0 ]; then
  ok "第二次是从第 $RESUMED 字节接上的（不是 0）"
else
  bad "第二次没有从已有字节接上（日志里没报出来，或者报的是 0）"
fi
# 接管点必须是**掐死时盘上那个数**。它对不上就说明中间有人动过 .part，
# 那正是「假装在续传」的形态
if [ -n "$RESUMED" ] && [ "$RESUMED" -ge "$AFTER_KILL" ]; then
  ok "接管点 $RESUMED ≥ 掐死时的 ${AFTER_KILL}（字节数单调增，没有重下）"
else
  bad "接管点 ${RESUMED:-（没有）} < 掐死时的 $AFTER_KILL —— .part 被人动过"
fi

# 前面的行里不该出现「服务器被打了 2 次」那种从头来的痕迹
if grep -q '请求 2 次\|请求 3 次' "$TMP/fetch2.log"; then
  bad "第二次发起过多次请求（$(grep -o '请求 . 次' "$TMP/fetch2.log" | tail -1)）"
else
  ok "第二次只发了 1 次请求（$(grep -o '请求 . 次' "$TMP/fetch2.log" | tail -1)）"
fi
echo ""

# ── 第三次：一份全新的，和续出来的逐字节比 ──
echo "【三】续出来的文件必须是完好的"
"$BIN" --model-fetch "http://127.0.0.1:$PORT/model" --to "$FRESH" --min-bytes 200000 \
  > "$TMP/fetch3.log" 2>&1
if [ "$?" = "0" ]; then
  ok "另下一份完整的作对照 exit=0"
else
  bad "对照那份没下成"
fi

if [ -f "$DEST" ]; then
  ok "续传那一份已改名为正式文件（$(size_of "$DEST") 字节）"
else
  bad "正式文件不在（${DEST}）"
fi
if [ -f "$PART" ]; then
  bad "「.part」还留着（改名应当是原子的移动，不该留副本）"
else
  ok "「.part」已被改名，没有残留"
fi

if [ -f "$DEST" ] && [ -f "$FRESH" ]; then
  if cmp -s "$DEST" "$FRESH"; then
    ok "续出来的这份与全新下载的那份 **逐字节相同**（cmp 无声）"
  else
    bad "续出来的这份与全新下载的那份不同 —— 中间拼错了位"
  fi
  HEAD=$(head -c 4 "$DEST" | xxd -p)
  if [ "$HEAD" = "6c6d6767" ]; then
    ok "文件头是 ggml 魔数（${HEAD}）"
  else
    bad "文件头不是 ggml 魔数（读到 ${HEAD}）"
  fi
fi

echo ""
echo "──── 过的有 $PASS 条，没过 $FAIL 条 ────"
[ "$FAIL" = "0" ] && echo "✅ 真 kill -9 续传判据全过" || echo "❌ 有判据没过，逐条见上"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
