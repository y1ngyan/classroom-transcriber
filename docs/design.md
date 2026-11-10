# 开发约定与设计取舍

这份文档写给要改这个仓库的人：构建怎么走、哪些顺序不能颠倒、哪些「看着不合理」的地方背后是一次真实故障。

macOS 原生桌面 App。实时转录中英混合的课堂内容,转录出的句子可以送去联网事实核查,
带时间戳记笔记、贴图,术语表校正,录音存档上传腾讯云 COS。

---

## 构建与运行

**构建不依赖完整 Xcode。** 只有一条路径：

```bash
./build.sh
open build/ClassroomTranscriber.app
```

`build.sh` 用 `swiftc` 直接编译(`-swift-version 6 -target arm64-apple-macos26.0`),
手工拼出 `.app` bundle 和 `Info.plist`,再 ad-hoc `codesign`。`build/` 每次都会被
`rm -rf` 重建,**不要把它当成源码目录**,也不要指望里面的东西能手工改。

有几个必须守住的顺序约束,动 `build.sh` 时注意:

- **图标要在 `codesign` 之前放进 bundle**,否则不在签名覆盖范围内;
- `LSMinimumSystemVersion` 是 26.0,和图标方案绑死(见下)。

### 自检

```bash
BIN=build/ClassroomTranscriber.app/Contents/MacOS/ClassroomTranscriber
$BIN --selftest          # 环境、模型、Markdown 渲染、密钥配置
$BIN --transcribe-file <音频> [--preset <名>]   # 文件转录,不需要麦克风
$BIN --mic-selftest      # 端到端跑「点开始录制」那条路径
$BIN --mic-ab --seconds 60   # 降噪三组 A/B
```

其余开关:`--conv-probe`(声道转换,纯计算)、`--conv-file`、`--wav-selftest`、
`--config-selftest`、`--glossary`、`--notes`、`--factcheck`、`--cos-selftest`。

### 工具

```bash
swift tools/audio_health.swift <录音.wav>    # 逐时间窗的底噪/动态范围,查「为什么转不准」
swift tools/audio_health.swift --spectrum <录音.wav>
swift tools/make_icon.swift [--variants]     # 图标
```

---

## 已实测的结论 —— 不要反着改

这一节是这个仓库最值钱的部分。下面每一条都是跑出来的,不是推测;下面每一个
「不要」都对应一次真实故障。**看着不合理的地方,先假设是有原因的。**

### 1. 系统语音处理默认关闭,不要「顺手打开」

`TranscriptionEngine.useVoiceProcessing` / `useAGC` 默认 `false`。

`setVoiceProcessingEnabled(true)` 会在约 20 秒后开始毁掉音频:自适应滤波器
(AEC / 噪声抑制)收敛之后开始往外吐噪声,底噪跳高 40 倍(+32 dB),动态范围
从 48 dB 塌到 17 dB,转录随之崩坏。短录音看不出来——**库里转录完美的两条录音
恰好是 5.6 秒和 10.9 秒,都短于收敛时间**,这就是它的指纹。

它还会让麦克风变成 4 声道,而那会引发下面第 2 条。**同一个开关在这个项目里
已经造成两次故障。**

注释里写了完整的实测数据,改之前先读。

### 2. 多声道 → 单声道不能交给 AVAudioConverter

4ch(Quadraphonic)→ 1ch 会返回**帧数完全正确、内容全 0** 的静音缓冲(RMS 恰好 0.0),
不报任何错。表现是「整场转录一个字都没有」。正确做法是先自己抽第 0 声道成真正的
单声道缓冲,再做 1ch → 1ch 转换。见 `firstChannelAsMono`。

排障要诀:电平是在 tap 的原始缓冲上算的,**看起来一切正常**;「送入 analyzer N 帧」
这个计数也完全正常——它数的是帧数,不是内容。

### 3. 预设按「实时」和「文件」分开选

- 实时必须用 `timeIndexedProgressiveTranscription`(代码里是 `PresetChoice.timeIndexed`);
- 文件转录用 `timeIndexedTranscriptionWithAlternatives`,精度最好。

不要为了「提高实时精度」把实时预设换成带 Alternatives 的——那两个**只在音频定稿时
才吐结果**,实测录 20 秒实时阶段 0 段,实时界面会长时间空屏。

「progressive 精度差」这句话**只对 `progressiveTranscription` 成立**(它开了
`fastResults`,拿精度换延迟),不要推广到 `timeIndexedProgressiveTranscription`。

### 4. 中英混合不要挂两个模块

同时挂 zh-CN + en-US 到同一个 SpeechAnalyzer,两路结果**不会融合,各说各话**。
中文为主的课堂挂单个 `zh-CN` 最优。英文术语的拼写偏差交给术语词表
(`AnalysisContext.contextualStrings`)和 LLM 校正。

### 5. `stop()` 的顺序会丢数据

`finalizeAndFinishThroughEndOfInput()` 之后**必须等结果消费任务把定稿内容吐完
再 cancel 它们**。反过来写会把定稿阶段的输出整个丢掉,表现为「录了半天一段都没有」,
而且不报任何错。

### 6. locale 匹配要指定优先地区

`SpeechTranscriber.supportedLocales` 的标识符是 `zh_CN` 这种下划线风格,和
`SFSpeechRecognizer` 那套完全不同。按语言码宽松匹配时**必须指定优先地区**,
否则「en」会按字母序匹配到 `en-ZA`(南非英语)。见 `FileTranscription.resolve`。

### 7. Swift 6 并发:ObjC 回调必须脱离主 actor

`installTap` 的 block、`SFSpeechRecognizer.requestAuthorization` 的回调都是
**非 Sendable 的 ObjC block**。在 `@MainActor` 上下文里构造它们,闭包会继承主 actor
隔离,而它们由后台线程调用 —— Swift 6 运行时随即在闭包入口做 executor 校验,
直接 `dispatch_assert_queue_fail` / SIGTRAP。

处理方式:把构造过程放进 `nonisolated` 的静态方法;不是 Sendable 的对象
(`AVAudioConverter`、`FileHandle`、`AVAudioPCMBuffer`)用显式承诺「只从音频线程访问」
的 `@unchecked Sendable` 包装类封起来(见 `MicTap`)。

### 8. 图标必须满幅不透明

macOS 26 对图标分两种处理:满幅不透明 → 系统自己套标准圆角遮罩 + 玻璃质感;
自带形状和留白 → 判定为「旧式图标」,**缩小后垫在一个灰色圆角托盘上**(双层圆角,
看着像坏了)。所以不要把背景画成 824×824 的圆角方块,直接铺满整张 1024 画布。

代价是形状完全交给系统,macOS 26 以前满幅就是一块方砖——所以
`LSMinimumSystemVersion` 卡在 26.0。

确诊方法:`NSWorkspace.shared.icon(forFile:)` 拿到的就是 Finder / Dock 走的那条
渲染路径,`draw(in:)` 到 bitmap rep 存成 PNG 就能看见系统实际合成的结果。
拿系统里已有的 App 对照最省事(Telegram、Steam 都是满幅)。

### 9. 排查「转录不准」的顺序

照这个顺序走,每一步都能排除掉一大类原因:

1. 合成一段干净语音跑 `--transcribe-file`:
   `say -v Tingting "…" -o x.aiff && afconvert -f WAVE -d LEI16@48000 -c 1 x.aiff x.wav`
   **转得准 → 模型和代码都没问题,别再怀疑它们**,去查音频。
2. `swift tools/audio_health.swift <录音.wav>` 看**逐时间窗**的动态范围。
   不要看整段平均——塌陷会被平均掉。判断基准是「和自身比」,同一场录音内部
   应该稳定;内部不稳就是采集链的问题。
3. 短录音正常、长录音坏 → 回去看第 1 条。

### 10. 转录质量评估用框架原生置信度,不要自己写启发式

`SpeechTranscriber.Result.text` 是 `AttributedString`,其 runs 上原生挂着
`AttributeScopes.SpeechAttributes.ConfidenceAttribute`(**逐字符** Double),
同 scope 下还有 `audioTimeRange`。构造 transcriber 时 `attributeOptions` 要传
`.transcriptionConfidence` 才会带上。读法:

```swift
for run in attr.runs {
    let conf = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
    for ch in attr[run.range].characters { ... }   // 注意不是 run.characters,那个编译不过
}
```

2026-09-20 实测(confprobe):转录准确的合成语音平均置信度 **0.96**,崩坏的课堂
录音 **0.58**,区分度极大;而且逐字符精确定位错误(「梯度下降」的「梯」被标 0.206)。
只有 2 个字的崩坏段(「我们」)置信度 0.266 也能判出来——这是文本统计量做不到的。

**为什么不能自己写**:先按「虚词密度」做了一版启发式(虚词占比 / 重复字密度 /
字符多样性 / 实词块长 / 复合规则),边界测试证明它是错的——真实课堂口语的虚词
密度天然就高(「那我们现在看一下这个概念它其实呢就是这么一个意思大家理解了吧」
虚词 46.7%),会被误判成「不可信」,而崩坏段反而只有 28%。**口语化 ≠ 崩坏**,
这两个用文本统计量分不开。识别器自己就知道每个字有多可信,去猜它已知的答案
是白费功夫。

分档用**两个**统计量:平均置信度(整体把握)+ 低置信(<0.5)字符占比(多少字在蒙)。
只看平均值会被崩坏段里大量高置信虚词拉偏。见 `TranscriptQuality.swift`。

---

## 设计规范

规格是苹果产品页那种:留白和层次。**卡片可以用**(P13-1 起,用户拍板破例),
但它是分组的边界,不是「什么都要框一下」的容器。

- **卡片走 `.cardStyle(elevation:)`**(0 / 1 / 2),不要手写圆角 + 底色 + 描边。
  圆角 `Theme.Radius.card`(18)、内边距 `Theme.Spacing.md`(16)、底色
  `Theme.Surface.card` / `cardElevated`、描边 `Theme.Surface.cardBorder`
  (0.5pt),这些值只在 `Theme.swift` 里定义。
- **阴影只在浅色用。** 深色页面是纯黑,阴影是「比背景更暗」——黑底上画不出来。
  所以深色下 `Theme.Shadow.layers(elevation:scheme:)` 返回空,层级改由
  **`cardElevated`(更亮一档的底)+ 0.5pt 描边**表达。谁把阴影加回深色,
  谁就是在往黑底上刷看不见的东西。
- **大段落之间仍用 `Theme.Spacing.xxl`(80)的留白**,`Separator()` 管页内分隔。
  卡片不替代这两件事:卡片框住的是「一个条目」,段落之间的层次还是靠留白。
- **所有颜色和字号走 `Theme.*`**,不要硬编码。颜色全部用
  `Theme.adaptive(light:dark:)` 做成随系统明暗切换的,页面背景纯白 / 纯黑。
- **状态用小图标 + 颜色表达**,用 `StatusMark`(`.ok` / `.warning` / `.error` /
  `.neutral` / `.live`),不要用色块。
- **悬停反馈优先用 `cardStyle(isHighlighted:)`**(浅色 4% 黑 / 深色 6% 白,
  叠在卡片底上,过渡 `easeOut 0.14`);不是卡片的地方仍是 2pt 左侧竖条。
- **一行只放一个 `PillButton`**,次要操作退化成文字链接。
- 进行中的按钮用 `PillButton(isLoading:)`,不要为了拿一个转圈而退回 AppKit 原生按钮。
- `TextStyle.lineSpacing` 是 SwiftUI 的**额外行距**,不等于 CSS/RN 的 `lineHeight`。
  换算见 `Theme.swift`。

字号只有五档(48 / 28 / 17 / 14 / 15mono),没有更小的档。卡片里的行标题用
`Theme.Text.rowTitle`(仍是 17,靠 medium 字重分层),不要为此新开字号。
密集读数被迫用 `caption`(14),行会显得高——需要 12pt 的话应该新加一个 token,
不要就地硬编码。

**卡片式目前只铺开到录音列表**(`RecordingsView` 的列表行)。其余屏还是旧的
「留白 + Separator」,两套暂时并存——下一包再统一,别在别的屏上顺手加卡片。

---

## 约定

- **注释写「为什么」,不写「是什么」。** 上面那些反直觉的写法,注释里都有原因;
  改代码时如果发现注释和代码对不上,先怀疑注释过期了——这个项目里出现过。
- `Sources/` 下按 `Transcription` / `Services` / `Stores` / `Models` / `Views` / `Theme` 分层。
- 状态用 `@Observable` store,统一挂在 `AppState` 上。

## 安全

密钥**不进仓库**。运行时配置在
`~/Library/Application Support/ClassroomTranscriber/config.json`(权限 600),
里面有腾讯云 COS 和 DeepSeek、Tavily 的真实密钥。不要把这个文件拷进仓库、
不要打印它的内容、不要提交。
