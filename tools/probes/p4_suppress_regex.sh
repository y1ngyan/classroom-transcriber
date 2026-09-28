#!/bin/bash
# §1 的第二条臂：whisper 原生的 `suppress_regex`。
#
# 结论（2026-09-23 实测，见脚本末尾的复现命令）：**不建议启用**。三条理由都是
# 量出来的，不是推的：
#   ① 命中不可预测——同一个模式在同一次跑里抑制了「收看」，却放过了「音效」。
#      原因是 whisper.cpp 的 `suppress_regex` 走 `std::regex_match`（**整词**匹配），
#      能不能命中完全取决于 whisper 的 BPE 把那个词切成几个 token，我们控制不了。
#   ② 它不消除幻觉，只把幻觉**换成另一个**：150 秒处 `谢谢大家收看,我们下一次
#      节目再见!` 变成 `谢谢大家的支持!`——两句都是 YouTube 收尾模板，
#      而且改后那句**逃过了文本层判据**（HALLU_SUMMARY 丢的段数 7 → 6）。
#   ③ 代价：合计约 53–62 秒 → 约 104–109 秒（**+70~105%**），最慢单窗
#      约 11 → 约 27 秒（约 +140%）。
#      ⚠️ 这里写的是**区间**不是单个数：同一条臂两次跑出 53.2/57.8→108.8 与
#      57.0/62.0→104.3，差 5~8%——计时是噪声，重跑一次就变。
#      原来我写死「60.4 → 108.4」，那两个数在两条臂里都不存在——写死会误导。
#      上界取 +105% 是**交叉配对**的结果（最快的基线 53.2 对最慢的 108.8，
#      = +105%）；原来写的 +90% 盖不住它。区间就该把两端都框住。
#
# ⚠️ 关于 §2 的实时性：这条录音的步长是 3 秒，所以**任何**单窗超过 3 秒就在积压。
# 基线最慢单窗已经 9~11 秒（这是既有问题，不是这条臂引入的），开到 27 秒后
# 积压速度快一倍多。45 分钟的课 = 900 窗，按均速算是 43 分钟 → 86 分钟，
# 从「勉强跟得上」掉到「明显跟不上」。
#
# 判据为什么不是「省了多少」：它没有省下任何东西（文本级判据在同一条录音上
# 丢掉 7 段、代价 0）。所以这条臂连「有效但有代价」都算不上。
#
# 用法：./tools/probes/p4_suppress_regex.sh
# 铁律：不放声、不改音量、不改默认后端。全程只读 wav。

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
WAV="${WAV:-$REC/课堂-20260918-101340.wav}"
OUT="${OUT:-/tmp/p4_suppress_regex}"
PAT="${PAT:-收看|观看|觀看|订阅|訂閱|按讚|点赞|點讚|音樂|音乐|音效|字幕|频道|頻道}"

[ -x "$BIN" ] || { echo "❌ 没有 $BIN，先跑 ./build.sh"; exit 1; }
[ -f "$WAV" ] || { echo "❌ 找不到 $WAV"; exit 1; }
mkdir -p "$OUT"

echo "════ suppress_regex 对照（$(basename "$WAV")）════"
echo "模式：$PAT"
echo

run() { # $1=标签 $2…=额外参数
  local tag="$1"; shift
  printf '  %-12s … ' "$tag"
  "$BIN" --whisper-window-file "$WAV" --probe-only --probe-step 10 "$@" \
    > "$OUT/$tag.log" 2>&1
  printf 'exit=%s\n' "$?"
}

# 基线跑两遍：whisper 在这条路径上是确定的（实测逐段完全相同），
# 但「确定」是**要先证明**的——不证明就没法把两版的差异归因给 suppress_regex
run base
run base2
run regex --suppress-regex "$PAT"

echo
echo "── 单窗耗时 ──"
for tag in base base2 regex; do
  printf '  %-8s ' "$tag"
  grep -m1 '单窗转写耗时' "$OUT/$tag.log" | sed 's/^ *//'
done

echo
echo "── 基线自己稳不稳（能不能把差异归因给 suppress_regex）──"
tsv() { awk -F'\t' '/^─── TSV（/{p=1;next} /^─── TSV 结束/{p=0} p && NF>=8 {print $1"\t"$5}' "$1"; }
tsv "$OUT/base.log" > "$OUT/a.txt"; tsv "$OUT/base2.log" > "$OUT/a2.txt"; tsv "$OUT/regex.log" > "$OUT/b.txt"
if diff -q "$OUT/a.txt" "$OUT/a2.txt" >/dev/null; then
  echo "  ✅ 基线两次逐段相同（$(wc -l < "$OUT/a.txt" | tr -d ' ') 段）→ 下面的差异归因给 suppress_regex"
else
  echo "  ⚠️ 基线两次自己就不一样 → **下面的差异不能归因给 suppress_regex**"; diff "$OUT/a.txt" "$OUT/a2.txt"
fi

echo
echo "── 带 flag 改了哪些段 ──"
if diff -q "$OUT/a.txt" "$OUT/b.txt" >/dev/null; then
  echo "  一个都没改"
else
  diff "$OUT/a.txt" "$OUT/b.txt" | sed 's/^/  /'
fi

echo
echo "── 同一批段在两次跑里的置信度（低置信占比是「模型在蒙」的原生指标）──"
for tag in base regex; do
  echo "  [$tag]"
  awk -F'\t' '/^─── TSV（/{p=1;next} /^─── TSV 结束/{p=0} p && NF>=8 && $1+0>=140000 && $1+0<=160000 {
    printf "    %6s 均值%s 低置信%s 「%s」\n", $1, $2, $3, $5}' "$OUT/$tag.log"
done

echo
echo "── 幻觉过滤效果（文本级判据的那一列）──"
for tag in base regex; do
  printf '  %-8s ' "$tag"
  grep -m1 'HALLU_SUMMARY' "$OUT/$tag.log" | tr -d '\r' | sed 's/^ *//'
done
echo "  （列序：原始段 留存 丢弃 模板 注释 有语音电平 留存）"
