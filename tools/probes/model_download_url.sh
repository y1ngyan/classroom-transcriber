#!/bin/bash
# P12-1b：**真网络**——清单拼出来的那个取件 URL，今天还取不取得到。
#
# 要验的是一条回退链，不是一条固定写法：
#   2026-09-29 同形状(40 位 sha)的 URL 回 302、件能取；
#   2026-10-13 同形状**一律 404**（连 README.md 都 404），而**同一 commit 的
#   12 位缩写**回 302、件照给。镜像会变，所以修法只能是「先试清单的全 sha，
#   只在 404 时退到同一 commit 的 12 位缩写」——**不能**改成「一律用 12 位」，
#   因为下次变的可能就是它。
#
# **这条探针不能把「今天镜像坏着」写死**：2026-10-14 跑的时候，40 位形状**又好了**
# （1 次请求、0 回落，32MB 一轮取到）。所以写成「臂① 必须靠回落取件」的话，它会在
# 镜像正常的日子里红一条**假的**。真正稳的判据是这两条臂合起来：
#   臂②（回落关）：它在测「今天 40 位还灵不灵」——失败 ⟺ 今天真的 404（不用猜）；
#   臂①（回落开）：件必须取到、字节身份必须对；**并且**报告要如实说回落用没用上。
# 于是「绿的是不是回落那条路」由臂② 的状态决定，两个状态各断言各的：
#   臂② 失败（今天 404）→ 臂① 必须报「回落 1 次」且形状是 12 位 —— 回落真的救了它；
#   臂② 成功（今天正常）→ 臂① 必须报「回落 0 次」**并声明回落链这次没被执行到**
#     （不拿一次顺利的取件替「404 时能救回来」背书——那是另一件事，证据在离线夹具
#     自检 九之三/九之四 和 2026-10-13 那天的实测里）。
#
# **不碰用户真实 models/**：--to 指向 mktemp 出来的临时目录，跑完删。
# 用小的那份文件（`ggml-tiny-q5_1.bin`，32MB）而不是清单里的 539MB medium：
# URL 形状、回落判定、内容校验三件事它全都覆盖，代价却是 1/16 的流量。
# 它的 sha256/size 是 2026-10-13 在镜像上实测来的（见
# `发现-模型下载URL-404-20261013.md`），和清单里那三份一样钉死在这里。
#
# 用法：
#   ./tools/probes/model_download_url.sh
#   CLASSROOM_BIN=<那份构建> ./tools/probes/model_download_url.sh
# 退出码：0 = 两臂都符合预期；2 = 通道不通/构建缺失（**没验成，不是通过**）
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2

# ⚠️ 默认 **不是** `build/`：那是用户那份（可能过期的）二进制，一个它不认识的
# 参数会让它当「没给参数」直接起 GUI 挂死（2026-10-14 实测挂过 9 小时 28 分，
# 见 exit_codes.sh 文件头）。验证这一侧只在 build-verify 里跑
BIN=${CLASSROOM_BIN:-build-verify/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}
if [ ! -x "$BIN" ]; then
  echo "❌ 找不到 ${BIN}"
  echo "   先跑：CLASSROOM_BUILD_DIR=build-verify ./build.sh"
  exit 2
fi

MANIFEST=Sources/Resources/model-manifest.json
[ -f "$MANIFEST" ] || { echo "❌ 找不到 ${MANIFEST}"; exit 2; }

# repo / 全 sha **从清单里读**，不在这里重写一遍：
# 手抄一份就等于给「清单里钉的是哪一版」造了第二个真相，两处迟早对不上
MANIFEST_ANCHOR=$(python3 -I -c "
import json
m = json.load(open('$MANIFEST'))['models'][0]
print(m['repo'], m['revision'])
") || { echo "❌ 读清单失败（python3 不在？）"; exit 2; }
REPO=$(printf '%s' "$MANIFEST_ANCHOR" | awk '{print $1}')
FULLSHA=$(printf '%s' "$MANIFEST_ANCHOR" | awk '{print $2}')
if [ -z "${REPO:-}" ] || [ -z "${FULLSHA:-}" ]; then
  echo "❌ 从清单里读不出 repo/revision"; exit 2
fi

SHORT="${FULLSHA:0:12}"          # 12 位 = 同一 commit 的缩写（ModelURLPlan 的回落形状）
FILE="ggml-tiny-q5_1.bin"
URL="https://hf-mirror.com/${REPO}/resolve/${FULLSHA}/${FILE}"
WANT_SHA="818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
WANT_SIZE=32152673

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }

echo "模型取件 URL · 真网络（镜像 hf-mirror.com）"
echo "BIN=${BIN}"
echo "清单锚：repo=${REPO} · revision=${FULLSHA}（回落形状＝它的 12 位缩写 ${SHORT}）"
echo "取件 URL：${URL}"
echo "内容判据：sha256=${WANT_SHA:0:12}… · size=${WANT_SIZE}"
echo ""

# 内容身份**自己再算一遍**：不信 App 自己的校验行，落到盘上的字节才作数
check_content() { # check_content <文件> <臂名>
  local f="$1" arm="$2"
  [ -f "$f" ] || { bad "${arm}：没有落盘文件可验"; return; }
  local got_size got_sha
  got_size=$(stat -f%z "$f" 2>/dev/null || echo 0)
  got_sha=$(shasum -a 256 "$f" | awk '{print $1}')
  if [ "$got_size" = "$WANT_SIZE" ]; then
    ok "${arm}：落盘大小 ${got_size} 与实测值一致"
  else
    bad "${arm}：落盘大小 ${got_size}，期望 ${WANT_SIZE}"
  fi
  if [ "$got_sha" = "$WANT_SHA" ]; then
    ok "${arm}：落盘 sha256 与上游一致（${got_sha:0:12}…）"
  else
    bad "${arm}：落盘 sha256=${got_sha:0:12}…，期望 ${WANT_SHA:0:12}…"
  fi
}

# ── 先问一句：**今天的镜像是什么状态** ──
#
# 这一条不能写死。2026-09-29 同形状是好的、2026-10-13 一律 404、**2026-10-14
# 再跑又是好的**（本次实测：1 次请求、0 回落、32MB 一份取到）。所以「回落链
# 有没有被走到」取决于**当天**镜像的状况，而不是取决于代码：
#   40 位可用 → 回落根本轮不到执行，这一臂只能验「取件 + 内容身份」；
#   40 位 404 → 回落必须把它救回来，这一臂才验得到回落本身。
# 拿「回落关」当探针：它失败 ⟺ 今天 40 位真的 404（这是唯一不需要猜的判据）。
A2="$TMP/arm2.bin"
echo "【臂②·判定】回落关（CLASSROOM_MODEL_URL_FALLBACK=0）——它在测「今天 40 位还灵不灵」"
a2_out=$(CLASSROOM_MODEL_URL_FALLBACK=0 "$BIN" --model-fetch "$URL" --to "$A2" \
         --min-bytes 30000000 --expect-sha256 "$WANT_SHA" --expect-size "$WANT_SIZE" 2>&1)
a2_code=$?
printf '%s\n' "$a2_out" | sed 's/^/     │ /'
echo "     退出码=${a2_code}"

# 臂② 设了 `=0`，所以它必须报「回落：关」——这一臂的对照身份由**这一行**确认。
# 反过来说，一个无视环境变量的实现会在这里报「开」，那它就不是对照组了
if printf '%s' "$a2_out" | grep -qF "404 回落：关"; then
  ok "臂②：设了 =0 就报「回落：关」（对照组的身份是真的）"
else
  bad "臂②：设了 CLASSROOM_MODEL_URL_FALLBACK=0 却没报「回落：关」——这一臂不是对照组"
fi

MIRROR_NEEDS_FALLBACK=no
if [ "$a2_code" = "0" ]; then
  MIRROR_STATE="40 位 sha 今天可用（回落没被执行到）"
  ok "臂②：40 位形状今天**直接给件**——镜像这一侧今天是好的"
  check_content "$A2" "臂②"
  if printf '%s' "$a2_out" | grep -qF "回落 0 次"; then
    ok "臂②：报告如实写了「回落 0 次」（没把没发生的事说成发生了）"
  else
    bad "臂②：取件成功但报告的回落次数不是 0"
  fi
else
  # 失败：只有 HTTP 404 才是「镜像今天坏了」，别的形状是通道问题
  if printf '%s' "$a2_out" | grep -qF "HTTP 404"; then
    MIRROR_STATE="40 位 sha 今天一律 404（回落是必需品）"
    MIRROR_NEEDS_FALLBACK=yes
    ok "臂②：40 位形状今天 404，而关掉回落时它**响亮地失败**了（这正是回落要救的场景）"
    if printf '%s' "$a2_out" | grep -qF "自动重试已到上限"; then
      ok "臂②：说清了「自动重试已到上限」"
    else
      bad "臂②：没说重试到上限"
    fi
    if printf '%s' "$a2_out" | grep -qF "error 0"; then
      bad "臂②：文案又退回了 NSError 桥接的天书（error 0. 那种）"
    else
      ok "臂②：不是「error 0.」那种天书"
    fi
    if [ -f "$A2" ]; then
      bad "臂②：失败了却留下了正式文件（半份被当成成品）"
    else
      ok "臂②：失败后没有留下正式文件"
    fi
  else
    echo "  ⚠️ **通道不通**：失败原因不是 HTTP 404（见上面那一行），这次**没验成**"
    echo "     既不算通过、也不算「回落坏了」——网络恢复后重跑"
    echo ""
    echo "──── 合计：没验成（通道不通） ────"
    exit 2
  fi
fi
echo ""
echo "今天镜像的状态：${MIRROR_STATE}"
echo ""

# ── 臂①：回落开着（默认），件必须取到、字节身份必须对 ──
A1="$TMP/arm1.bin"
echo "【臂①】回落开（默认）——期望：取到件，且字节身份对得上"
a1_start=$(date +%s)
a1_out=$("$BIN" --model-fetch "$URL" --to "$A1" --min-bytes 30000000 \
         --expect-sha256 "$WANT_SHA" --expect-size "$WANT_SIZE" 2>&1)
a1_code=$?
a1_secs=$(( $(date +%s) - a1_start ))
printf '%s\n' "$a1_out" | sed 's/^/     │ /'
echo "     退出码=${a1_code} · 用时 ${a1_secs} 秒"

if [ "$a1_code" = "0" ]; then
  ok "臂①：取件成功（exit=0）"
  check_content "$A1" "臂①"
  # 臂①**没有**设那个环境变量，所以它必须报「回落：开」。
  # 这一条是 2026-10-15 核验者的注入 F 教出来的：把 `fromEnvironment` 改成
  # 无条件 `.off` 时，离线 131 条全绿、这条探针也 8 过 0 红，而臂① 的输出里
  # 明明写着「404 回落：关（CLASSROOM_MODEL_URL_FALLBACK=0）」——**自己打自己的脸**，
  # 却没有任何断言去看那一行。探针不检查自己刚打印的话，就等于没打印
  if printf '%s' "$a1_out" | grep -qF "404 回落：开"; then
    ok "臂①：没设环境变量就报「回落：开」（默认开这条契约本身有判据了）"
  else
    bad "臂①：没设 CLASSROOM_MODEL_URL_FALLBACK 却没报「回落：开」——默认值这条契约破了"
  fi
  if [ "$MIRROR_NEEDS_FALLBACK" = "yes" ]; then
    # 今天 404：这一臂绿了**只可能**是因为回落救了它
    if printf '%s' "$a1_out" | grep -qF "回落 1 次"; then
      ok "臂①：报告写明**回落了 1 次**——绿的是回落那条路"
    else
      bad "臂①：40 位今天 404 却报回落 0 次（或没报），说不通"
    fi
    if printf '%s' "$a1_out" | grep -qF "12 位"; then
      ok "臂①：报告写出了实际用的形状（12 位缩写）"
    else
      bad "臂①：报告没说出实际用的取件形状"
    fi
  else
    # 今天 40 位可用：回落**没被执行到**，所以「回落链能救 404」这句话
    # 这一臂没有资格替它背书——必须说出来，不能拿一次成功的取件冒充它
    if printf '%s' "$a1_out" | grep -qF "回落 0 次"; then
      ok "臂①：报告如实写了「回落 0 次」（今天用不上它）"
    else
      bad "臂①：今天 40 位可用却报了回落次数非 0"
    fi
    echo "  ⚠️ 今天镜像的 40 位形状是好的，**回落链本身在真网络上没有被执行到**。"
    echo "     所以「404 时回落能救回来」这句话，这次的证据是："
    echo "       · 离线夹具自检 九之三/九之四（404→回落取件；回落关→响亮失败）"
    echo "       · 2026-10-13 镜像真 404 那天，同一个 12 位前缀取到过同一份字节（32152673）"
    echo "     不拿今天这次「取件成功」替它背书——那不是一回事。"
  fi
else
  bad "臂①：没取到件（exit=${a1_code}）"
  if printf '%s' "$a1_out" | grep -qF "HTTP 404"; then
    bad "臂①：源回了 404 而回落没有救回来——回落链本身坏了"
  else
    echo "  ⚠️ **通道不通**：上面的错误不是 HTTP 404，这次**没验成**"
    echo "     既不算通过、也不算「回落坏了」——网络恢复后重跑"
  fi
fi

echo ""
echo "──── 合计：过的有 ${PASS} 个，没过 ${FAIL} 个 · 今天镜像：${MIRROR_STATE} ────"
if [ "$FAIL" != "0" ]; then
  echo "❌ 有判据没过"
  exit 1
fi
echo "✅ 清单形状的取件 URL 今天取到件、字节身份与上游一致；两臂对「回落有没有被用到」都说的是实话"
