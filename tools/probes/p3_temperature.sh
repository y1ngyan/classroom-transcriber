#!/bin/bash
# §3 temperature 重试链的消融：同一条录音、同一判据，三个档位各跑一遍。
#
# 为什么要有它：whisper.cpp 在 GREEDY 下有一条 temperature fallback 链（默认
# `temperature_inc = 0.2` → 最多 6 趟完整解码）。闸一响就重跑整窗，代价立刻翻倍：
# 实测 9/18 那条，旧版最大单窗 16.64 秒 / 占用 111%（同一条录音中位只有 2.33 秒）。
# 改参数之前得先证明「改的确实是那条链」，改完之后得证明「停顿没了、而且内容没跟着
# 一起少」。
#
# 注意**别把它读成「纯空转」**：关掉链（候选B）在 9/20 上让置信均从 0.744 掉到
# 0.531、可信段 5 → 0。有录音上它确实在做搜索，不是白跑——这也正是不能一刀切
# 关掉的原因。参数链上没免费午餐，见 WhisperEngine.swift 的 §3 doc block。
#
# 三个档位（都走 `WhisperEngine` 上的环境变量阀门，默认值不因此改变：
# **当前产品默认 = 旧版这一档**，即 whisper 出厂参数）：
#   旧版     logprob −1.0 + inc 0.2  → whisper 出厂，链最多 6 趟 ← 产品默认
#   候选 B   logprob −10  + inc 0.2  → 只关掉那道闸，熵闸保留
#   候选 C   logprob −1.0 + inc 0.35 → 闸开着，链截到 3 趟（[0, .35, .70]）
#
# **每个档位两个参数都写死**，没有「跟随产品默认」的档位。产品默认一动，跟随
# 默认的档位就悄悄变成别的档位——上一版这里就有这么一档，跑出来的「旧版」
# 其实是候选B，三档输出逐字相同而标签还在说 logprob −1.0。对照实验里不许有
# 这种档位：它让历史数字无法复现，而且不报错。
#
# **日志复用有两条闸，别只留 mtime 那条**：判据①依赖的档位（`FRESH_FOR`，默认
# 「旧版」）一律现跑，因为它是判据本身的锚；其余档位复用一个比二进制新的日志时，
# 还要先过 `SANE_RATIO` 的干净性检查，现跑完也一样要过。原因见 log_total_ratio()
# 上面那段——挂钟计时会把机器休眠算进去，脏日志不报错、会被静默复用，判据①就
# 变成「看起来验了、其实没有」。宁可表里缺一行（明摆着），不要一行假数字。
#
# **退出码即成败**，判据四条：
#   ① 旧版必须**复现停顿**（最大单窗 ≥ STALL 秒）。复现不了说明这台机器此刻
#      不适合判这件事，先别改参数；
#   ② 每个候选都必须把最大单窗压到 STALL 以下；
#   ③ 候选的总字数不得比旧版少 KEEP 倍以上——**关掉重试链不能把内容也关掉**；
#   ④ 候选的逐字符置信均不得比旧版低 CONF_DROP 以上。**③ 单独用是不够的**：
#      实测候选B 在 9/18 上字数反而**多了** 10%（539/490），却把置信均从 0.763
#      压到 0.627、段数从 68 涨到 80——③ 判它过。字数多不等于内容多，碎片化
#      和重复也会让字数变多。CONF_DROP 用绝对差而不是比例，锚点是 CLAUDE.md 里
#      「转录准确 0.96 / 崩坏 0.58」那个量程（0.38 宽），0.10 约是它的四分之一。
#
# 铁律：不放声、不改系统音量/音频设备、不改默认模型与默认后端。全程只读 wav。
#
# ⚠️ macOS 自带的 bash 3.2 有个坑，这个脚本踩过：**`$var` 后面紧跟一个多字节字符时，
# 变量名会把那个字符的第一个字节吞进去**（`echo "$cand："` → `cand?: unbound variable`）。
# 所以凡是变量后面直接接中文/全角标点的地方，一律写成 `${var}`。加花括号就够了
#
# 用法:
#   ./tools/probes/p3_temperature.sh                    # 约 18 分钟
#   OUT=/tmp/x STALL=10 KEEP=0.9 CONF_DROP=0.10 ./tools/probes/p3_temperature.sh
#   FRESH_FOR= SANE_RATIO=999 ./tools/probes/p3_temperature.sh   # 想复用全部日志时
#
# ⚠️ 要拿判据① 的结论，就别设 FRESH_FOR=（空）。它存在的意义就是不许 ─

set -uo pipefail
# 自检要读自己，所以路径必须在 `cd` **之前**取成绝对的——cd 之后 `$0` 那
# 个相对路径就悬空了（这个自检的第一版正是这么写的，于是 python3 报
# FileNotFoundError、扫描静默通过，等于没守）
SELF="$0"
[ "${SELF#/}" = "$SELF" ] && SELF="$PWD/$SELF"
cd "$(dirname "$0")/../.."

# 自检：本脚本里不许出现 `$var` 紧跟多字节字符（上面那个 bash 3.2 的坑）。
#
# 这条守的是**下一次**，不是这一次——同一个缺陷在这个脚本里出现过三次
# （`$conf（` ×2、`$drop）` ×1），每次的表现都是「跑到那一段突然
# unbound variable」，而那时**前面的判据已经判过了**：退出码 1 于是分不清
# 是「判据没过」还是「脚本崩了」，判据的权威就打了折。靠记性守不住，用扫描守。
# 注释里的反例是故意写的，跳过。
if command -v python3 >/dev/null 2>&1; then
  if bad="$(python3 - "$SELF" <<'PY'
import re, sys
for i, line in enumerate(open(sys.argv[1], encoding='utf-8').read().split('\n'), 1):
    if line.lstrip().startswith('#'):
        continue
    for m in re.finditer(r'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])', line):
        print(f'   行 {i}: ${m.group(1)}')
PY
)"; then
    if [ -n "$bad" ]; then
      echo "❌ 本脚本里有 \`\$var\` 紧跟多字节字符的写法（bash 3.2 会把那个字节吞进变量名）："
      printf '%s\n' "$bad"
      echo "   改成 \${var}，否则跑到那一段会 unbound variable 崩掉。"
      exit 1
    fi
  else
    # 不静默降级：扫描没跑成就说出来，别让它变成「看起来守住了」
    echo "⚠️  多字节自检没跑成（python3 非 0 退出）——这一条没验，先手工确认脚本里"
    echo "   没有 \`\$var\` 紧跟中文/全角标点的地方"
  fi
else
  echo "⚠️  没有 python3，跳过多字节自检（那个坑见文件头）"
fi

BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
REC="$HOME/Library/Application Support/ClassroomTranscriber/recordings"
OUT="${OUT:-/tmp/p3_temperature}"
STALL="${STALL:-10}"          # 单窗超过它就算「停顿」
KEEP="${KEEP:-0.9}"           # 候选字数 / 旧版字数 的下限
CONF_DROP="${CONF_DROP:-0.10}" # 候选置信均 允许比旧版低多少（绝对差）
FRESH_FOR="${FRESH_FOR:-旧版}" # **必须现跑、不许复用日志**的档位（见下面缺陷 1 的注释）
SANE_RATIO="${SANE_RATIO:-20}" # 总耗时/音频时长 的上限，超过就认定这一趟不干净

[ -x "$BIN" ] || { echo "❌ 没有 ${BIN}，先跑 ./build.sh"; exit 1; }

# 「安静段能复现 17.82 秒」那条是 9/18；第二条挑一条非语音段多的做交叉
WAVS=(
  "$REC/课堂-20260918-101340.wav"
  "$REC/课堂-20260920-143738.wav"
)
for wav in "${WAVS[@]}"; do
  [ -f "$wav" ] || { echo "❌ 找不到录音 $wav"; exit 1; }
done

mkdir -p "$OUT"
: > "$OUT/summary.tsv"

# 并发会把单窗拖到 1034 秒（实测过），均值/最大值全都不可用。这里先挡一道
RUNNING="$(pgrep -f 'ClassroomTranscriber' | wc -l | tr -d ' ')"
if [ "$RUNNING" != "0" ]; then
  echo "⚠️  机器上还有 $RUNNING 个 ClassroomTranscriber 进程；本脚本的数字"
  echo "    （尤其均值/最大值）会被污染，先停掉别的负载再跑。"
fi

# 判据①只对**第一条**录音成立：它的任务就是复现那个 17.82 秒的停顿。
# 其余录音是交叉验证用的，复现不出来只是信号弱，不算失败——把它们也判成 ❌
# 会让「这条录音不适合判这件事」淹没「候选真的没压住停顿」，两件事得分开
STALL_WAV="${WAVS[0]}"

# 档位表：名字 | 环境变量赋值（**两个参数都写死**，不留空跟随产品默认）
VARIANTS=(
  "旧版|CLASSROOM_WHISPER_LOGPROB_THOLD=-1 CLASSROOM_WHISPER_TEMPERATURE_INC=0.2"
  "候选B|CLASSROOM_WHISPER_LOGPROB_THOLD=-10 CLASSROOM_WHISPER_TEMPERATURE_INC=0.2"
  "候选C|CLASSROOM_WHISPER_LOGPROB_THOLD=-1 CLASSROOM_WHISPER_TEMPERATURE_INC=0.35"
)

FAIL=0

echo "════ §3 temperature 重试链消融 ════"
echo "  判据：旧版最大单窗 ≥ ${STALL}s；候选都 < ${STALL}s；候选字数 ≥ 旧版 ${KEEP} 倍"
echo

run_one() { # $1=环境赋值（空格分隔的多个 VAR=VALUE）$2=wav $3=日志
  # $1 故意不加引号：要的就是按空格拆成多个 VAR=VALUE 交给 env。
  # 一律走 env（哪怕只有一个），好让「档位参数」只有 VARIANTS 一处定义
  env $1 "$BIN" --whisper-window-file "$2" --timing > "$3" 2>&1
}

# 从一行里抠一个数。逐个写死 sed 表达式，比「取第 N 个数」稳——
# 那一行的数字个数和顺序都会随格式变，按序号取迟早错位
grab() { # $1=文件 $2=grep 模式 $3=sed -E 表达式
  grep -m1 "$2" "$1" | sed -E "$3" | head -1 | tr -d ' '
}

# 一趟跑得「干净」吗？看「离线全程 X 秒（音频 Y 秒）」的比值 X/Y。
#
# 为什么需要它：计时基准是**挂钟**，机器休眠会被算进去。实测跨一次 9.9 小时休眠
# 的日志里出现「单窗 35561.43 秒」「离线全程 36136.1 秒（音频 191.6 秒）」——
# 那些数字不是「慢」，是**没在跑**，拿它做判据等于用假数据。
#
# 更要命的是它**不报错**：mtime 守卫只问「日志比二进制新吗」，于是这样一份
# 跨休眠的脏日志会被当成有效结果**静默复用**，判据①（旧版必须复现停顿）就
# 从来没有被验过，而表面上一切正常。所以这里对**每一份日志**都要问一句
# 「这个总耗时量级合理吗」，无论它是复用的还是刚跑出来的。
log_total_ratio() { # 打印 总耗时/音频时长（如 188.6）；抽不到就什么都不打印
  local total audio
  total="$(grab "$1" '离线全程' 's/.*离线全程 ([0-9.]+) 秒.*/\1/')"
  audio="$(grab "$1" '离线全程' 's/.*音频 ([0-9.]+) 秒.*/\1/')"
  [ -n "$total" ] && [ -n "$audio" ] && [ "$audio" != "0" ] || return 0
  echo "$total $audio" | awk '{printf "%.1f", $1/$2}'
}

printf '%-21s %-6s %7s %7s %8s %7s %6s %7s %7s %6s\n' \
  录音 档位 中位 均 最大 占用% 段数 总字数 置信均 重复处
printf '%s\n' "────────────────────────────────────────────────────────────────────────────────────────────"

for wav in "${WAVS[@]}"; do
  name="$(basename "$wav" .wav)"
  for entry in "${VARIANTS[@]}"; do
    label="${entry%%|*}"
    envspec="${entry#*|}"
    log="$OUT/${name}_${label}.log"
    # 复用日志的前提是**它比二进制新**（同 p4_hallucination.sh 的道理）：
    # 判据参数改了之后，旧日志里的数字是上一次跑出来的，直接复用会拿过期数
    # 当「改后」。比 mtime 而不是「文件在不在」。
    #
    # **但 mtime 守卫单独用是不够的**：一份跨机器休眠的脏日志照样「比二进制新」，
    # 于是被判据①依赖的那一档会**静默复用**它——判据①看起来跑了、其实没验过
    # （实测踩到：复用了跨 9.9 小时休眠那份日志，表里整行是 `-`，只报一句
    # 「没抽到最大耗时」，而判据①就此作废且看不出来）。所以这里加两道：
    # FRESH_FOR 那一档一律现跑；其余档位复用时先过干净性检查。
    reuse=0
    if [ -f "$log" ] && [ "$BIN" -ot "$log" ] && [ "$label" != "$FRESH_FOR" ]; then
      r="$(log_total_ratio "$log")"
      if [ -n "$r" ] && [ "$(echo "$r <= $SANE_RATIO" | bc)" = "1" ]; then
        reuse=1
      else
        printf '  ⚠️  %s · %s：旧日志不干净（总耗时/音频 = %s，上限 %s），拒绝复用，重跑\n' \
          "$label" "$name" "${r:-抽不到}" "$SANE_RATIO"
      fi
    fi
    if [ "$reuse" = "1" ]; then
      printf '  ▸ %s · %s … 复用日志（比二进制新且过了干净性检查）\n' "$label" "$name"
    else
      printf '  ▸ %s · %s … ' "$label" "$name"
      run_one "$envspec" "$wav" "$log"
      printf 'exit=%s\n' "$?"
    fi

    med="$(grab "$log"  '单次转写' 's/.*中位 ([0-9.]+) \/.*/\1/')"
    mean="$(grab "$log" '单次转写' 's/.*均 ([0-9.]+) \/.*/\1/')"
    mx="$(grab "$log"   '单次转写' 's/.*最大 ([0-9.]+) 秒.*/\1/')"
    occ="$(grab "$log"  '单次转写' 's/.*占用 ([0-9]+)%.*/\1/')"
    segs="$(grab "$log" '段数 '   's/.*段数 ([0-9]+)（.*/\1/')"
    chars="$(grab "$log" '总字数'  's/.*总字数 ([0-9]+)（.*/\1/')"
    conf="$(grab "$log" '逐字符置信度（含重叠' 's/.*均 ([0-9.]+).*/\1/')"
    rep="$(grab "$log"  '同句多版本相邻' 's/.*：([0-9]+) 处.*/\1/')"
    trad="$(grab "$log" '繁体残留' 's/.*繁体残留: ([0-9]+) 段.*/\1/')"

    # 现跑出来的也可能是脏的（跑的过程中机器休眠了），而且同样不报错。所以干净性
    # 检查对**每一份日志**都要过，不论复用还是现跑；不过就把这一档整行丢掉——
    # 宁可比对表缺一行（明摆着），也不要一行假的数字混进 ③④ 的比值里。
    r="$(log_total_ratio "$log")"
    if [ -z "$r" ] || [ "$(echo "$r > $SANE_RATIO" | bc)" = "1" ]; then
      echo "    ❌ $label 这一档作废：总耗时/音频 = ${r:-抽不到}（上限 ${SANE_RATIO}）"
      echo "       多半是跑的过程中机器休眠/挂起过——计时基准是挂钟，休眠会被算进去。"
      echo "       这一趟不是「慢」，是**没在跑**，任何判据都不能踩在它上面。换空闲机器重跑。"
      FAIL=1
      continue
    fi

    printf '%-21s %-6s %7s %7s %8s %7s %6s %7s %7s %6s\n' \
      "$name" "$label" "${med:--}" "${mean:--}" "${mx:--}" "${occ:--}" \
      "${segs:--}" "${chars:--}" "${conf:--}" "${rep:--}"

    # 记进 TSV，供报告与复核直接引用（繁体残留也记，虽然引擎出口必然把它转掉）
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$label" "$med" "$mean" "$mx" "$occ" "$segs" "$chars" "$conf" "$rep" "$trad" \
      >> "$OUT/summary.tsv"

    if [ -z "$mx" ]; then
      echo "    ❌ 没抽到最大耗时——这一趟没跑成，看 $log 末尾"
      FAIL=1
      continue
    fi
    case "$label" in
      旧版)
        if [ "$(echo "$mx < $STALL" | bc)" = "1" ]; then
          if [ "$wav" = "$STALL_WAV" ]; then
            echo "    ❌ 旧版**没有**复现停顿（最大 ${mx}s < ${STALL}s）——"
            echo "       这条录音此刻不适合判这件事，先别改参数"
            FAIL=1
          else
            echo "    ⚠️  这条录音没复现停顿（最大 ${mx}s）——信号弱，只作交叉参考"
          fi
        fi
        ;;
      候选B|候选C)
        if [ "$(echo "$mx >= $STALL" | bc)" = "1" ]; then
          echo "    ❌ $label 仍有停顿（最大 ${mx}s ≥ ${STALL}s）"
          FAIL=1
        fi
        ;;
    esac
  done
  echo
done
FAIL="${FAIL:-0}"

# ③④ 内容与质量都不能跟着一起少。按录音拿「候选」对「旧版」比
echo "──── 内容与质量守恒（③ 字数比 / ④ 置信均差）────"
for rlabel in $(awk -F'\t' '{print $1}' "$OUT/summary.tsv" | sort -u); do
  base="$(awk -F'\t' -v r="$rlabel" '$1==r && $2=="旧版"{print $8}' "$OUT/summary.tsv")"
  baseconf="$(awk -F'\t' -v r="$rlabel" '$1==r && $2=="旧版"{print $9}' "$OUT/summary.tsv")"
  [ -n "$base" ] && [ "$base" != "0" ] || continue
  for cand in 候选B 候选C; do
    v="$(awk -F'\t' -v r="$rlabel" -v c="$cand" '$1==r && $2==c{print $8}' "$OUT/summary.tsv")"
    conf="$(awk -F'\t' -v r="$rlabel" -v c="$cand" '$1==r && $2==c{print $9}' "$OUT/summary.tsv")"
    [ -n "$v" ] || continue
    ratio="$(echo "$v $base" | awk '{printf "%.3f", $1/$2}')"
    if [ "$(echo "$ratio < $KEEP" | bc)" = "1" ]; then
      echo "  ❌ $rlabel · ${cand} ③字数：$v / $base = $ratio < ${KEEP}（内容掉了）"
      FAIL=1
    else
      echo "  ✅ $rlabel · ${cand} ③字数：$v / $base = $ratio"
    fi
    # ④ 置信均：绝对差。字数多而置信低是「碎」不是「多」，③ 看不见这个
    [ -n "$conf" ] && [ -n "$baseconf" ] || continue
    drop="$(echo "$baseconf $conf" | awk '{printf "%.3f", $1-$2}')"
    if [ "$(echo "$drop > $CONF_DROP" | bc)" = "1" ]; then
      echo "  ❌ $rlabel · ${cand} ④置信：$baseconf → ${conf}（低了 ${drop} > ${CONF_DROP}）"
      FAIL=1
    else
      echo "  ✅ $rlabel · ${cand} ④置信：$baseconf → ${conf}（低了 ${drop}）"
    fi
  done
done

echo
echo "  逐条日志：$OUT/ · 汇总：$OUT/summary.tsv"
if [ "$FAIL" = "0" ]; then
  echo "✅ §3 判据全过：旧版复现了停顿，两个候选都压住了，且内容没掉"
  exit 0
fi
echo "❌ §3 判据未过——先看上面标 ❌ 的那几行，别急着改参数"
exit 1
