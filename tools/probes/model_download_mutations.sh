#!/bin/bash
# P7-1：两个**变异自证**——判据必须能红。
#
# 为什么要这一步：一条判据如果永远不会红，它就不是判据，是装饰。做法是
# 把「被验的那条行为」反着改一次，看自检是不是**当场变红**；然后**逐字节**
# 还原（`sha256` 比对 + `git diff` 为空），证明工作树回到了原样。
#
# 四个变异：
#   ① 「校验失败也照样改名」        —— 打掉「校验不过就不许落地」
#   ② 「缺模型时回落到 Apple」      —— 打掉「不静默降级」这条本包最硬的规矩
#   ③ 「续传前不比 revision」        —— 打掉「源更新了就从 0 重下」
#   ④ 「收不够字节也放行」          —— 打掉「宣告的长度对不上就不许改名」
#
# ③④ 是派单「补充要求」里点名要的两条：**把 revision 比较去掉 → 必须红**；
# **假目录里放一份伪造的 `.part` → 它必须在占用清单里出现**（后一条由
# `exit_codes.sh` 的 `--model-cache` 那条断言钉，不在这里）。
#
# 每个变异都先断言**注入真的改到了文件**（否则「没改到 → 自检仍绿」会被
# 误读成「这条判据验不出来」——那是最贵的假绿：它会让一条真判据被删掉）。
#
# 「红在哪一条」按**小节**判（【二】/【七】里出现了 ❌），不按某句具体文案：
# 同一个缺陷会在该小节里触发好几条断言，先红哪条取决于断言顺序，钉死文案
# 等于把脚本绑在断言顺序上。第一版就是这么写的，结果变异 ① 明明红了却被
# 判成「没红在预期位置」——**判据自己假红**，一样是坏判据。
#
# 用法：./tools/probes/model_download_mutations.sh      （退出码即成败）
# ⚠️ 会临时改源码再还原。跑的时候别让别的会话同时在编。
set -u

cd "$(dirname "$0")/../.." || exit 2
BIN=${BIN:-build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber}
DOWNLOADER=Sources/Services/ModelDownloader.swift
REQUIREMENT=Sources/Transcription/ModelRequirement.swift
MANIFEST=Sources/Services/ModelManifest.swift

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }

BACKUP=$(mktemp -d)
cp -p "$DOWNLOADER" "$BACKUP/ModelDownloader.swift"
cp -p "$REQUIREMENT" "$BACKUP/ModelRequirement.swift"
cp -p "$MANIFEST" "$BACKUP/ModelManifest.swift"
BEFORE_DL=$(shasum -a 256 "$DOWNLOADER" | awk '{print $1}')
BEFORE_RQ=$(shasum -a 256 "$REQUIREMENT" | awk '{print $1}')
BEFORE_MF=$(shasum -a 256 "$MANIFEST" | awk '{print $1}')

# 还原 = 从备份拷回来。**备份一直留到最后**才删——第一版在两次变异中间
# 就把它删了，于是第二次变异结束时还原不了，把注入留在了工作树里
revert_sources() {
  cp -p "$BACKUP/ModelDownloader.swift" "$DOWNLOADER"
  cp -p "$BACKUP/ModelRequirement.swift" "$REQUIREMENT"
  cp -p "$BACKUP/ModelManifest.swift" "$MANIFEST"
}
cleanup() { revert_sources; rm -rf "$BACKUP"; }
trap cleanup EXIT

echo "P7-1 变异自证：判据必须能红（跑完逐字节还原）"
echo ""

run_selftest() { # run_selftest <输出文件> → echo 退出码
  CLASSROOM_MODELS_DIR=$(mktemp -d) "$BIN" --model-download-selftest > "$1" 2>&1
  echo $?
}

build() { ./build.sh > /tmp/p71-mutation-build.log 2>&1; }

# 判「某个小节里出现了 ❌」。$1=输出文件 $2=起始标记 $3=结束标记 $4=小节名
red_in_section() {
  local section
  section=$(sed -n "/$2/,/$3/p" "$1")
  if printf '%s' "$section" | grep -q '❌'; then
    printf '%s' "$section" | grep '❌' | head -1
    return 0
  fi
  return 1
}

# ══════════════════════════════════════════════════════════════
echo "【变异 ①】校验失败也照样改名"
# ══════════════════════════════════════════════════════════════
python3 - "$DOWNLOADER" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """        // ── 校验：**先校验，通过了才改名** ──
        if let reason = ModelFile.validationFailure(at: partURL, minimumBytes: minimumBytes,
                                                    pin: pin) {
            throw Failure.validationFailed(reason: reason)
        }
"""
new = """        // ── MUTATION ①：校验失败也照样改名 ──
        _ = ModelFile.validationFailure(at: partURL, minimumBytes: minimumBytes, pin: pin)
"""
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
    OUT=$(mktemp); CODE=$(run_selftest "$OUT")
    if [ "$CODE" != "0" ]; then ok "自检变红了（exit=${CODE}）"; else bad "自检**没有**变红 —— 「校验不过不许落地」这条判据是假的"; fi
    if LINE=$(red_in_section "$OUT" '【二】' '【三】' '二'); then
      ok "红在预期的小节：【二】校验失败　　　$(printf '%s' "$LINE" | sed 's/^ *//')"
    else
      bad "【二】那一节里没有 ❌ —— 变异没被那条判据抓住"
    fi
    if sed -n '/【一】/,/【二】/p' "$OUT" | grep -q '✅ 内容与源逐字节相同'; then
      ok "【一】正常路径仍然是绿的（变异只打掉了该打掉的那条）"
    fi
    rm -f "$OUT"
  else
    bad "变异 ① 编不过（注入太重，不是判据的红）"
  fi
fi
revert_sources

# ══════════════════════════════════════════════════════════════
echo ""
echo "【变异 ②】缺模型时回落到 Apple"
# ══════════════════════════════════════════════════════════════
python3 - "$REQUIREMENT" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """        guard model.exists else {
            return .blocked(reason: blockMessage(model: model, downloadEntry: downloadEntry,
                                                 why: "模型文件不在"))
        }
"""
new = """        guard model.exists else {
            return .apple   // MUTATION ②：缺模型时回落到 Apple
        }
"""
if old not in s:
    sys.exit(3)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
if [ "$?" != "0" ]; then
  bad "变异 ② 注入失败（注入点没匹配上）"
else
  if grep -q 'MUTATION ②' "$REQUIREMENT"; then
    ok "变异 ② 已注入（文件里出现了 MUTATION ② 标记）"
  else
    bad "变异 ② 声称注入成功，但文件里找不到标记"
  fi
  if build; then
    OUT=$(mktemp); CODE=$(run_selftest "$OUT")
    if [ "$CODE" != "0" ]; then ok "自检变红了（exit=${CODE}）"; else bad "自检**没有**变红 —— 「不静默降级」这条判据是假的"; fi
    if LINE=$(red_in_section "$OUT" '【七】' '【八】' '七'); then
      ok "红在预期的小节：【七】不静默降级　　$(printf '%s' "$LINE" | sed 's/^ *//')"
    else
      bad "【七】那一节里没有 ❌ —— 变异没被那条判据抓住"
    fi
    rm -f "$OUT"
  else
    bad "变异 ② 编不过（注入太重，不是判据的红）"
  fi
fi
revert_sources

# ══════════════════════════════════════════════════════════════
echo ""
echo "【变异 ③】续传前不比 revision（源更新了也拿旧字节接着写）"
# ══════════════════════════════════════════════════════════════
# 注入点选 `RemoteIdentity.conflicts` 里的 **revision 那一行**，而不是整段。
# 整段打掉会把「没有版本记录 → 不敢接着写」那条（【三之三】）一起打掉，
# 那样红的位置就分不清是变异 ③ 该管的那条还是隔壁那条——**一个变异只该
# 打掉一条判据**，否则红了也说不清是判据在起作用还是它在替别人背锅。
# 这里两个夹具的 body 完全相同，etag(sha256) 和 size 都一样，**只有 revision
# 不同**——所以把 revision 那一行去掉，就等于「源更新了却看不出来」
python3 - "$MANIFEST" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "        if let a = revision, let b = meta.revision, a != b { return true }\n"
new = "        // MUTATION ③：不比 revision（源更新了也接着续）\n"
if old not in s:
    sys.exit(3)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
if [ "$?" != "0" ]; then
  bad "变异 ③ 注入失败（注入点没匹配上）"
else
  if grep -q 'MUTATION ③' "$MANIFEST"; then
    ok "变异 ③ 已注入（ModelManifest.swift 里出现了 MUTATION ③ 标记）"
  else
    bad "变异 ③ 声称注入成功，但文件里找不到标记"
  fi
  if build; then
    OUT=$(mktemp); CODE=$(run_selftest "$OUT")
    if [ "$CODE" != "0" ]; then ok "自检变红了（exit=${CODE}）"; else bad "自检**没有**变红 —— 「源更新就从 0 重下」这条判据是假的"; fi
    if LINE=$(red_in_section "$OUT" '【三之二】' '【三之三】' '三之二'); then
      ok "红在预期的小节：【三之二】源已更新　$(printf '%s' "$LINE" | sed 's/^ *//')"
    else
      bad "【三之二】那一节里没有 ❌ —— 变异没被那条判据抓住"
    fi
    # 隔壁那条（【三之三】「没有版本记录」）不该跟着红：它走的是
    # `existingMeta == nil` 那一支，和 revision 比较无关
    if sed -n '/【三之三】/,/【三之四】/p' "$OUT" | grep -q '❌'; then
      bad "【三之三】跟着红了 —— 变异打过了头，红的不是 ③ 该管的那条判据"
    else
      ok "【三之三】仍然是绿的（变异只打掉了该打掉的那条）"
    fi
    rm -f "$OUT"
  else
    bad "变异 ③ 编不过（注入太重，不是判据的红）"
  fi
fi
revert_sources

# ══════════════════════════════════════════════════════════════
echo ""
echo "【变异 ④】收不够字节也放行"
# ══════════════════════════════════════════════════════════════
# `incompletenessFailure` 是「这次收够了没有」的**唯一**出口。派单第 5 条
# 要的就是「不许静默返回残缺」——把它改成恒 nil，等于宣告的长度和实收
# 字节对不上也照样改名落地
python3 - "$DOWNLOADER" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """    static func incompletenessFailure(written: Int64, expected: Int64?) -> Failure? {
        guard let expected, written < expected else { return nil }
        return .incomplete(received: written, expected: expected)
    }
"""
new = """    static func incompletenessFailure(written: Int64, expected: Int64?) -> Failure? {
        // MUTATION ④：收不够也放行
        _ = written; _ = expected
        return nil
    }
"""
if old not in s:
    sys.exit(3)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
if [ "$?" != "0" ]; then
  bad "变异 ④ 注入失败（注入点没匹配上）"
else
  if grep -q 'MUTATION ④' "$DOWNLOADER"; then
    ok "变异 ④ 已注入（ModelDownloader.swift 里出现了 MUTATION ④ 标记）"
  else
    bad "变异 ④ 声称注入成功，但文件里找不到标记"
  fi
  if build; then
    OUT=$(mktemp); CODE=$(run_selftest "$OUT")
    if [ "$CODE" != "0" ]; then ok "自检变红了（exit=${CODE}）"; else bad "自检**没有**变红 —— 「收不够就不许改名」这条判据是假的"; fi
    if LINE=$(red_in_section "$OUT" '【三之五】' '【四】' '三之五'); then
      ok "红在预期的小节：【三之五】残缺判据　$(printf '%s' "$LINE" | sed 's/^ *//')"
    else
      bad "【三之五】那一节里没有 ❌ —— 变异没被那条判据抓住"
    fi
    rm -f "$OUT"
  else
    bad "变异 ④ 编不过（注入太重，不是判据的红）"
  fi
fi
revert_sources

# ══════════════════════════════════════════════════════════════
echo ""
echo "【还原】逐字节回到原样"
# ══════════════════════════════════════════════════════════════
AFTER_DL=$(shasum -a 256 "$DOWNLOADER" | awk '{print $1}')
AFTER_RQ=$(shasum -a 256 "$REQUIREMENT" | awk '{print $1}')
AFTER_MF=$(shasum -a 256 "$MANIFEST" | awk '{print $1}')
[ "$AFTER_DL" = "$BEFORE_DL" ] && ok "ModelDownloader.swift sha256 一致（${BEFORE_DL:0:12}…）" \
                               || bad "ModelDownloader.swift 没还原（$BEFORE_DL → $AFTER_DL）"
[ "$AFTER_RQ" = "$BEFORE_RQ" ] && ok "ModelRequirement.swift sha256 一致（${BEFORE_RQ:0:12}…）" \
                               || bad "ModelRequirement.swift 没还原（$BEFORE_RQ → $AFTER_RQ）"
[ "$AFTER_MF" = "$BEFORE_MF" ] && ok "ModelManifest.swift sha256 一致（${BEFORE_MF:0:12}…）" \
                               || bad "ModelManifest.swift 没还原（$BEFORE_MF → $AFTER_MF）"

if grep -q 'MUTATION' "$DOWNLOADER" "$REQUIREMENT" "$MANIFEST"; then
  bad "文件里还留着 MUTATION 标记"
else
  ok "三个文件里都不再有 MUTATION 标记"
fi

# `git diff` 只对**已跟踪**的文件说话。这两个文件要是还没提交（首次引入那
# 一次就是这样），`git diff` 天然为空——那不算证据，只是一条空转的断言
# （本项目在别处栽过「空转的注入」这个跟头）。所以分开说
UNTRACKED=0
for f in "$DOWNLOADER" "$REQUIREMENT" "$MANIFEST"; do
  git ls-files --error-unmatch "$f" > /dev/null 2>&1 || UNTRACKED=1
done
if [ "$UNTRACKED" = "1" ]; then
  ok "这三个文件还没进 git（未跟踪），git diff 不适用 —— 还原由上面的 sha256 承担"
else
  DIRTY=$(git diff --name-only -- "$DOWNLOADER" "$REQUIREMENT" "$MANIFEST")
  [ -z "$DIRTY" ] && ok "git diff 对这两个文件为空（工作树是干净的）" \
                  || bad "git diff 还有改动：$DIRTY"
fi

if build; then ok "还原后重新构建通过"; else bad "还原后构建失败"; fi

echo ""
echo "──── 过的有 ${PASS} 条，没过 ${FAIL} 条 ────"
[ "$FAIL" = "0" ] && echo "✅ 四个变异都验过了（注入 → 红 → 逐字节还原）" \
                  || echo "❌ 变异自证有不过的，逐条见上"
exit "$([ "$FAIL" = "0" ] && echo 0 || echo 1)"
