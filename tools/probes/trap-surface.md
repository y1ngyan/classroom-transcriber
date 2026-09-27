# 脏数据 → trap 面清单（P6-2）

**这份清单回答一个问题**：库里存着的那份数据（会话 JSON + wav），如果里面
有两个数对不上，全项目哪些写法会**直接崩掉进程**。

P6-2 的起点就是这一类的实例：C-4 查明 `WhisperEngine` 把 whisper 给的
`t0`/`t1` 原样乘 10 落字段，没有 `t1 ≥ t0` 判定；一个反向段一路喂到
`RecordingSession.absoluteRange` 的 `..<`，Swift 6 的带检查运算符
`lower > upper` 直接 SIGTRAP（实测退出码 133，release 下**一个字都不打印**）。

## 怎么保持这份清单不过期

一句命令重列全部候选面（`Sources/` 下，**实测 108 行**）：

```bash
cd ~/ClassroomTranscriber && \
grep -rEn '\.\.<|Range\(|try!|as!' Sources --include='*.swift' \
  | grep -v '/SelfTest\.swift:' | grep -v 'CommandLine\.arguments' | sort
```

剔除 `SelfTest`（自检自己造的夹具不算库里的数据）与 `CommandLine.arguments`
（命令行参数是操作者敲的，不是库里的数据——154 → 108 行）。

**它列的是候选，不是结论**——绝大多数命中是安全的（下节说明为什么）。
清单要的是「有人新增了一处**跨源**的区间构造时，能在这一眼里看出来」。
所以：改了任何**读会话/读 wav/读 diar 结果**的地方，跑一遍上面那句，
把新出现的候选行按下面的格式补结论。

## 判据：什么才算「脏数据能命中」

一个 trap 需要**两个来源不同的值**相遇，且它们之间没有不变式。于是：

- **构造式区间**（`0..<count`、`idx..<min(idx+137, n)`、`startIndex..<endIndex`
  同一根字符串上取的）——上下界出自**同一个**量，或其中一个是从同一个
  数组/字符串现取的。**不可能反向**，不单列。
- **跨源区间**（存下来的起点 vs 存下来的终点、声明的时长 vs 实际读到的
  帧数）——这才是面。下面逐条给结论。

---

## 一、必须盯住的两处

### 1. `RecordingSession.absoluteRange` —— **已加判定**

`Sources/Models/RecordingSession.swift:102`

```swift
let start = part.offsetMillis + segment.startTimeMillis
let end = part.offsetMillis + segment.endTimeMillis
guard end > start else { return start..<start }   // ← 就是这道
return start..<end
```

C-4 修的。两处跨源值：`segment.startTimeMillis` / `segment.endTimeMillis`
都从会话 JSON 里解出来，没有任何东西保证 `end ≥ start`。

**为什么是空区间不是 `min..<max`**：反向段的两个端点里没有一个能声称是
「它开始说话的时刻」，取谁都是编。空区间说的是实话，同时把 `start` 原样
留在 `lowerBound` 上——`StudyNotesService` 的两处锚点要的正是这个起点。
语义由 `--reverse-selftest` 的 19 条判据钉住。

### 2. `SpeakerMapper` 那道 overlap guard —— **已加判定**（且**曾经是死代码**）

`Sources/Transcription/SpeakerMapper.swift:70 / 99 / 111`

```swift
guard end > start else { return nil }        // :70  映射前的 span
guard segmentEnd > segmentStart else { ... } // :99  段自身
guard overlap > 0 else { continue }          // :111 区间相交
```

三处跨源值：段的时间戳来自会话 JSON，span 的时间戳来自 helper 的 diar 结果
——**两个进程、两次计算**，谁也没保证过它们有序。

⚠️ 记录一个事实以免重蹈：`:99` 那道 guard **在 C-4 之前是死代码**。反向段
在上游 `:80` 的 `absoluteRange` 里就被 `..<` 的运行时检查 SIGTRAP 掉了，
根本走不到它。C-4 修好 `absoluteRange` 之后它才真的可达。**「有 guard」
不等于「guard 在起作用」**——这也是本清单要求每条给「证据」而不是
「有写 guard」的原因。

---

## 二、其余逐条结论

| 位置 | 跨源值 | 结论 |
|---|---|---|
| `WhisperHallucination.level(of:in:sampleRate:)` `:496` | 段毫秒（whisper 输出）→ 样本下标 | **已加判定**：`:498` `guard end > start else { return 0 }`。`start` 被 `max(0,…)` 夹低、`end` 被 `min(samples.count,…)` 夹高，所以 `start > samples.count` 这种也会被这道挡掉 |
| `WhisperHallucination.speechFloor` `:517` | `sampleRate` → 帧长 | **已加判定**：`:519` `guard frame > 0, samples.count >= frame`，循环条件 `index + frame <= samples.count` |
| `WhisperEngine` `:589`（时间戳落字段） | whisper 的 `t0`/`t1` | **已加判定**（P6-2 新加）：`WhisperSegmentTiming.apply`，`t1 < t0` 或任一为负 → 落成零长 + 记诊断。见 `--integrity-selftest` A 组 |
| `WhisperWindowBuffer.windowWithOrigin` `:77` | `durationSeconds` → 缓冲长度 | **已加判定**：取 `suffix(count)`，`count` 由缓冲自身长度夹住 |
| `AppState.context(around:)` `:165` | `firstIndex` + `radius` → `segments[lower...upper]` | **不可能命中**：`lower = max(0, index-radius)`、`upper = min(count-1, index+radius)`，且 `index` 是 `firstIndex` 给的合法下标 → 恒有 `0 ≤ lower ≤ index ≤ upper ≤ count-1`；`count == 0` 时 `firstIndex` 返回 nil 已提前返回 |
| `TranscriptSplitter` 自检 `:358` `pieces.last!` | `split()` 的返回 | **不可能命中**：`split` 的四条 guard 全部 `return [segment]`，最后一条 `guard pieces.count > 1`——**任何路径都返回非空数组** |
| `StudyNotesMarkdown` 自检 `:111` `summaryAt!` | `String.range(of:)` | **不可能命中**：同一行的 `&&` 短路，`summaryAt != nil && keyPointAt != nil && summaryAt!…`，前一条件为假时后面不求值 |
| `PunctuationService` 自检 `:279` `chars[pos-1]` | 切点累计长度 → 字符数组下标 | **不可能命中（脏数据面）**：`cutsOnlyAtPunctuation` 默认 `false`，唯一传 `true` 的是它自己的自检（`:302`/`:312`），输入是夹具不是库里的数据 |
| `WAVRecorder` 自检 `:257` / `:336` `data.subdata(in: offset..<(offset+n))` | wav 文件长度 → 头字段偏移 | **不可能命中**：偏移是字面量（0/4/8），且 `WAVRecorder.init` 一开始就写满 44 字节的合法头（`:63` 注释 + `:74`），`--wav-selftest` 的「刚创建还未写入」一行实测报的就是 44 字节。**且只有自检调用 `describe`**（`:346`/`:377`） |
| `RecordingsStore` `:450` / `:466` | 段毫秒 → 区间 | **已加判定**：两处都走 `absoluteRange`，不自己写 `..<` |
| `StudyNotesService` `:263` / `:298` | 段毫秒 → 锚点 | **已加判定**：只取 `.lowerBound`，不构造区间 |
| `QuestionDetector.isSelfAnswered` `:150` | `String.Index` | **不可能命中**：`after` 与 `raw.endIndex` 取自同一根字符串，`after ≤ endIndex` 恒成立 |
| `MarkdownView` `:109` | `String.Index` | **不可能命中**：`dotIndex` 与 `line.startIndex` 同源 |
| `GlossaryService` `:73` | `String.Index` | **不可能命中**：`separator` 与 `rest.startIndex` 同源 |
| `DiagnosticLog` `:401` / `:411` / `COSService` `:477` | `String.Index` → `NSRange` | **不可能命中**：`NSRange(x.startIndex..., in: x)` 是 Cocoa 的标准换算，`Range(_:in:)` 由 `if let` 兜底 |
| `AudioPreamp` `:360` / `:409` / `:555` | `AVAudioFormat(...)!` | **不可能命中**：参数是 `pcmFormatFloat32` + 合法采样率/声道数，这几个组合不会返回 nil；`segment.frames` 是自检传的字面量（`:492` `frames: 300` 等） |
| `HighPassFilter` `:75` 等 5 处 | `count` → `0..<count` | **不可能命中**：构造式区间，`count > 0` 由调用方先判 |
| `TranscriptionEngine` `:1981` / `:1987` | `count` → `0..<count` | 同上 |
| `WhisperWindowFileRun` `:521` / `:709` / `:1055` / `:1130` | 喂样块 → `fed..<end` | **不可能命中**：`end = min(fed + chunk, samples.count)`，且 `:1055`/`:1130` 前面有 `guard endSamples > startSamples` |
| `WhisperWindowFileRun` `:1265` / `:1284` | 段数 → `0..<(count-1)` | **不可能命中**：前面已 `guard` 过段数 ≥ 2 |
| `TranscriptionEngine` `:1880` `cache!` | — | **不可能命中**：`cache == nil \|\|` 短路，右侧只在 `cache != nil` 时求值 |

**`try!` 与 `as!`：全项目 0 处**（`grep -rEn 'try!|as!' Sources` 无命中）。

## 三、数值转换这一类

会因**越界**而 trap 的转换（`Int(Double)` 超出 `Int` 表示范围时直接 trap，
不是回绕）：

| 位置 | 结论 |
|---|---|
| `WhisperHallucination.level` `:496` | 输入是 `Int` 字段，理论上一个 `startTimeMillis = Int.max` 的伪造 JSON 能让 `Double(...)×48000` 溢出 `Int`。**不可能命中**：这个函数只有两个调用点（`WhisperWindowFileRun:671` / `:738`），两处传的都是**本次转写当场产出**的 `WhisperSegment`，库里的持久化数据永远到不了它 |
| `Int(buffer.frameLength)` / `AVAudioFrameCount(n)` 一族 | **不可能命中**：来源是 `AVAudioPCMBuffer.frameLength`（`AVAudioFrameCount` = `UInt32`），进 `Int` 只可能变宽，进 `AVAudioFrameCount` 的值由 `frameCapacity` 现算 |
| `WhisperEngine` `:590` `Int(t0) * 10` | **已加判定**（P6-2）：`t0` 是 `Int64`（whisper 的 10ms 单位），乘 10 之前先过 `WhisperSegmentTiming.resolve`，负值先夹到 0 |

---

## 维护约定

1. 这份清单里的结论**不是从注释抄的**，每条都自己看了一遍调用点（C-4 的
   教训：注释里的机制断言可能过期，见 `SpeakerMapper` 那道死 guard）。
2. 给「不可能命中」时**必须附证据**（哪个不变式、哪些调用点、什么实测数字），
   只写「看起来没问题」不算。
3. 新增「读会话 / 读 wav / 读 diar 结果」的地方，跑一遍开头的 grep，
   新候选行按上表格式补一行。
