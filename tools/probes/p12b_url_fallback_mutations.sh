#!/bin/bash
# P12-1b：四个**变异自证**——回落那几条判据必须能红。
#
# 为什么不能只在真网络上验：探针跑在**当天**的镜像上。2026-10-14 那天 40 位形状
# **又好了**（探针自己会打印「回落没被执行到」）——那种日子你就算把回落整段删掉，
# 真网络那条臂照样绿。所以「回落真的会救 404」这件事**只有离线夹具能确定性地验**
# （夹具对 40 位一律 404、对 12 位给件，这正是 2026-10-13 镜像的症状复刻）。
# 变异就打在这两条上：
#   ① 「404 不换形状」      —— 打掉回落本身（行为）
#   ② 「回落用别的 ref」    —— 打掉「退的是**同一个 commit** 的缩写，不是另一个版本」
#
# 每个变异都先断言**注入真的改到了文件**（找不到 MUTATION 标记就是没改到；
# 那时「自检仍绿」会被误读成「这条判据验不出来」——那是最贵的假绿）。
# 红的**位置**按小节判，不钉具体文案：同一个缺陷会在该小节里连红几条，
# 先红哪条取决于断言顺序（这条教训 P7-1 的变异脚本里写过一次）。
#
# ⚠️ 这条脚本会临时改源码再还原。跑的时候别让别的会话同时在编。
# ⚠️ 构建目录固定 build-verify：**绝不动用户那份 build/**（ad-hoc 签名，
#    重编一次就把用户的麦克风授权作废，表现为「点录制就崩」）。
#
# 用法：./tools/probes/p12b_url_fallback_mutations.sh
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2

BIN="${CLASSROOM_BIN:-build-verify/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}"
PLAN=Sources/Services/ModelURLPlan.swift
DOWNLOADER=Sources/Services/ModelDownloader.swift
BUILD_DIR=build-verify

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }

BACKUP=$(mktemp -d)
cp -p "$PLAN" "$BACKUP/ModelURLPlan.swift"
cp -p "$DOWNLOADER" "$BACKUP/ModelDownloader.swift"
BEFORE_PLAN=$(shasum -a 256 "$PLAN" | awk '{print $1}')
BEFORE_DL=$(shasum -a 256 "$DOWNLOADER" | awk '{print $1}')
BEFORE_HEAD=$(git rev-parse HEAD)

revert_sources() {
  cp -p "$BACKUP/ModelURLPlan.swift" "$PLAN"
  cp -p "$BACKUP/ModelDownloader.swift" "$DOWNLOADER"
}
cleanup() { revert_sources; rm -rf "$BACKUP"; }
trap cleanup EXIT

build() { CLASSROOM_BUILD_DIR="$BUILD_DIR" ./build.sh > /tmp/p12b-mutation-build.log 2>&1; }

# 自检在**临时模型目录**里跑（默认那份会去用户的 models/ 找模型）
run_selftest() { # run_selftest <输出文件>；退出码从 stdout 之外取
  local models
  models=$(mktemp -d)
  CLASSROOM_MODELS_DIR="$models" "$BIN" --model-download-selftest > "$1" 2>&1
  local code=$?
  rm -rf "$models"
  return $code
}

# 打印某一段里所有的 ❌（$1=输出文件 $2=起始标记 [$3=结束标记，不给就到文件末尾]）
red_lines() {
  if [ -n "${3:-}" ]; then
    sed -n "/$2/,/$3/p" "$1" | grep '❌' | sed 's/^ */       /'
  else
    sed -n "/$2/,\$p" "$1" | grep '❌' | sed 's/^ */       /'
  fi
}

echo "P12-1b 变异自证：回落那几条判据必须能红（构建目录 ${BUILD_DIR}）"
echo "HEAD=${BEFORE_HEAD:0:12} · 基线二进制 ${BIN}"
echo ""

# ══════════════════════════════════════════════════════════════
echo "【变异 ①】404 不换形状（把回落整段打掉）"
# ══════════════════════════════════════════════════════════════
#
# 注入点选在**行为**上（下载循环里那个 `where` 条件），不选 `shouldFallBack`
# 那张纯函数表：表里那 8 行是「认不认这个响应」的判据，打掉它只会让**表自己**
# 变红——那证明的是表还在，不是回落还在
python3 - "$DOWNLOADER" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "                case .httpStatus(let code) where urlFallback == .on\n                    && ModelURLPlan.shouldFallBack(statusCode: code)\n                    && shapeIndex + 1 < shapes.count:"
new = "                case .httpStatus(let code) where false:  // MUTATION ①：404 也不换形状\n                    _ = code"
if old not in s:
    sys.exit(3)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
if [ "$?" != "0" ]; then
  bad "变异 ① 注入失败（注入点没匹配上）"
else
  if grep -q 'MUTATION ①' "$DOWNLOADER"; then
    ok "变异 ① 已注入（文件里出现了 MUTATION ① 标记）"
  else
    bad "变异 ① 声称注入成功，但文件里找不到标记"
  fi
  if build; then
    OUT=$(mktemp)
    if run_selftest "$OUT"; then
      bad "自检**没有**变红（exit=0）—— 「404 会换形状」这条判据是假的"
    else
      ok "自检变红了（exit≠0）"
    fi
    # 预期：九之三（端到端回落）红。九之一/九之二 是纯函数与形状生成那两条，
    # 这次注入没碰它们，它们**应该仍然全绿**——那说明红光来自行为那条判据
    LINES=$(red_lines "$OUT" '【九】' '【九之四】')
    if [ -n "$LINES" ]; then
      ok "红在预期的小节（【九】→【九之四】，即九之一/二/三 那一段）："
      printf '%s\n' "$LINES"
    else
      bad "【九】那一段里没有 ❌ —— 变异没被回落这条判据抓住"
    fi
    if printf '%s' "$LINES" | grep -qF '回落这条路本该成功'; then
      ok "红的正是**行为**那条（九之三：端到端回落没能取到件）"
    else
      bad "红的不是九之三那条行为判据 —— 要么注入打偏，要么判据长歪了"
    fi
    if sed -n '/【九】/,/【九之四】/p' "$OUT" | grep -q 'HTTP 404 → 回落'; then
      ok "九之一的状态码表仍然是绿的（注入只打在行为上，没打在纯函数表上）"
    else
      bad "九之一的状态码表也红了 —— 注入打偏了（该打行为，不该打表）"
    fi
    # 红**不该**扩散到这两条对照组上：九之四（回落关掉→必须失败）和
    # 九之五（403 不许回落）都不依赖「404 会换形状」这件事
    if sed -n '/【九之四】/,/【九之五】/p' "$OUT" | grep -q '❌'; then
      bad "【九之四】（回落关掉的对照组）被牵连了 —— 它和回落开不开无关"
    else
      ok "【九之四】对照组仍是绿的（回落关掉那条路没被牵连）"
    fi
    if sed -n '/【九之五】/,/【九之六】/p' "$OUT" | grep -q '❌'; then
      bad "【九之五】（403 不许回落）被牵连了 —— 403 从来不走回落"
    else
      ok "【九之五】仍是绿的（403 不回落那条没被牵连）"
    fi
    # 九之六 是**走回落那条路**取件来验 sha256 的，回落被删掉它必然红——
    # 这是合理的红（同一个缺陷的另一个受害者），不是「判据长歪了」
    if sed -n '/【九之六】/,$p' "$OUT" | grep -qF '回落那条路上 sha256 照样在判'; then
      ok "【九之六】也红了，且红在那条 sha256 判据上——那是**同一个**回落缺失的另一面"
    else
      bad "【九之六】没红（它是靠回落取件的，回落没了它也该红）"
    fi
    rm -f "$OUT"
  else
    bad "变异 ① 编不过（注入太重，不是判据的红）"
  fi
fi
revert_sources

# ══════════════════════════════════════════════════════════════
echo ""
echo "【变异 ②】回落退到别的 ref（不是同一 commit 的缩写）"
# ══════════════════════════════════════════════════════════════
#
# 这条打的是「缩写的**出处**」：回落必须由清单那个 commit 切出来。用别的 ref
# 意味着「取的可能是另一版字节」——那正是内容身份要拦的事。夹具上它取不到件
# （那个 ref 谁都不认识），于是**下载失败**；派单说得明白：失败也算抓住
python3 - "$PLAN" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "        guard let short = shortened(ref), let shortURL = replacingRef(of: url, with: short) else {"
new = "        // MUTATION ②：退到一个**不属于这个 commit** 的 ref\n        guard let shortURL = replacingRef(of: url, with: \"000000000000\") else {"
if old not in s:
    sys.exit(3)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
if [ "$?" != "0" ]; then
  bad "变异 ② 注入失败（注入点没匹配上）"
else
  if grep -q 'MUTATION ②' "$PLAN"; then
    ok "变异 ② 已注入（文件里出现了 MUTATION ② 标记）"
  else
    bad "变异 ② 声称注入成功，但文件里找不到标记"
  fi
  if build; then
    OUT=$(mktemp)
    if run_selftest "$OUT"; then
      bad "自检**没有**变红 —— 「退的是同一 commit 的缩写」这条判据是假的"
    else
      ok "自检变红了（exit≠0）"
    fi
    LINES=$(red_lines "$OUT" '【九】' '【九之四】')
    if [ -n "$LINES" ]; then
      ok "红在预期的小节（【九】→【九之四】）："
      printf '%s\n' "$LINES"
    else
      bad "【九】那一段里没有 ❌ —— 变异没被抓住"
    fi
    if printf '%s' "$LINES" | grep -qF 'ref 是 12 位前缀'; then
      ok "红的包含**形状生成**那条（第二种的 ref 不再是清单 commit 的缩写）"
    else
      bad "形状生成那条没红 —— 「缩写出自哪个 commit」这件事没人管"
    fi
    rm -f "$OUT"
  else
    bad "变异 ② 编不过（注入太重，不是判据的红）"
  fi
fi
revert_sources

# ══════════════════════════════════════════════════════════════
echo ""
echo "【变异 ③】换形状也占重试预算（删掉 attempt -= 1 那句）"
# ══════════════════════════════════════════════════════════════
#
# 这一条是 2026-10-15 核验者补的洞，也是**最值得留下的一条**：他删掉这一句之后
# 121 条**全绿**——「换形状不占重试预算」这条派单里写明的性质，当时没有任何判据
# 兜底。补了【九之七】之后它必须红，而且红在**请求次数**上（结构事实），
# 不是红在文案措辞上
python3 - "$DOWNLOADER" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "                attempt -= 1\n                continue"
new = "                // MUTATION ③：换形状**占**重试预算（少了 attempt -= 1）\n                continue"
if old not in s:
    sys.exit(3)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
if [ "$?" != "0" ]; then
  bad "变异 ③ 注入失败（注入点没匹配上）"
else
  if grep -q 'MUTATION ③' "$DOWNLOADER"; then
    ok "变异 ③ 已注入（文件里出现了 MUTATION ③ 标记）"
  else
    bad "变异 ③ 声称注入成功，但文件里找不到标记"
  fi
  if build; then
    OUT=$(mktemp)
    if run_selftest "$OUT"; then
      bad "自检**没有**变红 —— 「换形状不占重试预算」这条判据是假的"
    else
      ok "自检变红了（exit≠0）"
    fi
    LINES=$(red_lines "$OUT" '【九之七】')
    if [ -n "$LINES" ]; then
      ok "红在预期的小节【九之七】："
      printf '%s\n' "$LINES"
    else
      bad "【九之七】里没有 ❌ —— 这条缺口没被补上"
    fi
    if printf '%s' "$LINES" | grep -qF '第二种形状拿满重试预算'; then
      ok "红的正是**请求次数**那条（结构事实，不是文案措辞）"
    else
      bad "红的不是请求次数那条"
    fi
    rm -f "$OUT"
  else
    bad "变异 ③ 编不过（注入太重，不是判据的红）"
  fi
fi
revert_sources

# ══════════════════════════════════════════════════════════════
echo ""
echo "【变异 ④】开关契约与 ref 优先级（核验者的注入 F 与 G）"
# ══════════════════════════════════════════════════════════════
#
# 两处注入打在**同一个文件的两个互不相干的函数**上，所以合成一次构建、各自断言
# 各自的那条判据（各自都点名，红在哪条不含糊）：
#   F：`fromEnvironment` 无视环境变量、永远 `.off`。核验者注入它时**离线 131 条
#      全绿、真网络探针也 8 过 0 红**——而臂①没设变量却打印「回落：关」，
#      自己打自己的脸，没人看那一行。
#   G：`variants` 里让 URL 段压过 `pin.revision`。夹具里两者恒等，所以也全绿。
python3 - "$PLAN" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old_prio = "        let ref = revision.flatMap { $0.isEmpty ? nil : $0 } ?? resolveRef(of: url) ?? \"\""
new_prio = "        // MUTATION ④G：让 URL 那段压过清单钉的 revision\n        let ref = resolveRef(of: url) ?? revision.flatMap { $0.isEmpty ? nil : $0 } ?? \"\""
old_env = "        guard let raw = environment[environmentKey]?\n            .trimmingCharacters(in: .whitespaces).lowercased() else { return .on }"
new_env = "        // MUTATION ④F：无视环境变量，永远关\n        let raw = \"0\""
if old_prio not in s or old_env not in s:
    sys.exit(3)
s = s.replace(old_prio, new_prio, 1).replace(old_env, new_env, 1)
open(p, 'w', encoding='utf-8').write(s)
PY
if [ "$?" != "0" ]; then
  bad "变异 ④ 注入失败（注入点没匹配上）"
else
  if grep -q 'MUTATION ④F' "$PLAN" && grep -q 'MUTATION ④G' "$PLAN"; then
    ok "变异 ④ 两处都已注入（F：开关契约 / G：ref 优先级）"
  else
    bad "变异 ④ 声称注入成功，但文件里找不到标记"
  fi
  if build; then
    OUT=$(mktemp)
    if run_selftest "$OUT"; then
      bad "自检**没有**变红 —— 开关契约与 ref 优先级这两条判据是假的"
    else
      ok "自检变红了（exit≠0）"
    fi
    LINES=$(red_lines "$OUT" '【九】' '【九之四】')
    if [ -n "$LINES" ]; then
      ok "红在预期的小节（【九】→【九之四】）："
      printf '%s\n' "$LINES"
    else
      bad "【九】那一段里没有 ❌ —— 这两条判据没抓住"
    fi
    if printf '%s' "$LINES" | grep -qF '没给环境变量 → 默认开'; then
      ok "红的包含 F 那条（没给变量时必须是「开」）"
    else
      bad "F 那条没红 —— 探针打印「回落：开」仍然只是嘴上说说"
    fi
    if printf '%s' "$LINES" | grep -qF '缩写按**清单**那版切'; then
      ok "红的包含 G 那条（URL 与清单不同源时，清单说了算）"
    else
      bad "G 那条没红 —— 「清单是权威」仍然只是一句注释"
    fi
    rm -f "$OUT"
  else
    bad "变异 ④ 编不过（注入太重，不是判据的红）"
  fi
fi
revert_sources

# ══════════════════════════════════════════════════════════════
echo ""
echo "【还原】逐字节回到原样，并重编"
# ══════════════════════════════════════════════════════════════
AFTER_PLAN=$(shasum -a 256 "$PLAN" | awk '{print $1}')
AFTER_DL=$(shasum -a 256 "$DOWNLOADER" | awk '{print $1}')
[ "$AFTER_PLAN" = "$BEFORE_PLAN" ] && ok "ModelURLPlan.swift sha256 一致（${BEFORE_PLAN:0:12}…）" \
                                  || bad "ModelURLPlan.swift 没还原（$BEFORE_PLAN → $AFTER_PLAN）"
[ "$AFTER_DL" = "$BEFORE_DL" ] && ok "ModelDownloader.swift sha256 一致（${BEFORE_DL:0:12}…）" \
                              || bad "ModelDownloader.swift 没还原（$BEFORE_DL → $AFTER_DL）"

if grep -q 'MUTATION' "$PLAN" "$DOWNLOADER"; then
  bad "文件里还留着 MUTATION 标记"
else
  ok "两个文件里都不再有 MUTATION 标记"
fi

DIRTY=$(git diff --name-only -- "$PLAN" "$DOWNLOADER")
if [ -z "$DIRTY" ]; then
  ok "git diff 对这两个文件为空（工作树是干净的）"
else
  # 这两个文件是本包新加的/新改的，未提交时 diff 天然为空——那时只靠 sha256
  ok "git diff 报出改动：${DIRTY}（若这是本包尚未提交的改动，看上面的 sha256）"
fi

if build; then
  ok "还原后重新构建通过"
  OUT=$(mktemp)
  if run_selftest "$OUT"; then
    ok "还原后自检全绿（判断力还在）"
  else
    bad "还原后自检不绿 —— 还原不干净"
    tail -5 "$OUT" | sed 's/^/       /'
  fi
  rm -f "$OUT"
else
  bad "还原后构建失败"
fi

echo ""
echo "──── 过的有 ${PASS} 条，没过 ${FAIL} 条 ────"
if [ "$FAIL" = "0" ]; then
  echo "✅ 四个变异都验过了（注入 → 红在预期的小节 → 逐字节还原 → 自检重新全绿）"
else
  echo "❌ 变异自证有不过的，逐条见上"
fi
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
