# C-1 helper 原型 · 交付报告

> 本轮**只写代码，未构建、未跑任何推理**（按派单要求，避免污染机器上另一个 agent
> 的并发缺陷重复验证）。以下「怎么验」全部是**下一轮**的动作。

## 1. 做了什么

按 `C-接线设计稿.md` §2.2/§2.4/§2.5/§2.6/§2.7 与 `C-拍板结论.md` 实现：

- **多 `--input` + `--offset-ms`**：`CompositeAudioSource` 把每个片段解码到
  16 kHz/Float32/mono，按 offset 摆到会话时间轴，空洞补零；不拼成一个巨型
  `[Float]`（67 min ≈ 257 MB），每片段仍是 FluidAudio 的 mmap `DiskBackedAudioSampleSource`。
- **JSON 信封** `schemaVersion: 1`：`status` 权威；成功带 `result`/`timings`/`inputs`，
  失败带 `error.code`/`message`；**默认不落 embedding**（拍板第 4 条），
  `--embeddings-out` 才写旁路。
- **退出码 0/2–9**：`badInvocation/audioUnreadable/audioUnsupported/modelMissing/
  modelLoadFailed/inferenceFailed/outputWriteFailed/timeout`；SIGTERM 归 timeout，
  其它信号/未知退出码归「崩溃」（`nil`）。
- **超时公式**：`max(300, 90 + audioSeconds/5)`，5s kill 宽限（App 侧 watchdog 用）。
- **5 条校验**（§2.6）：非 0 退出、信封形状、audioSeconds 容差 `max(2s,1%)`、
  segment 边界、`有 ≥1s 转录段则 speakerCount ≥ 1`。**校验不过回退 nil，不伪装 S1**。
  显式把「`speakerCount == 1` 且 5 条全过」当**阳性**。
- **`--selftest`** 一条命令跑完：信封编解码（含设计稿 §2.4 字面样例）、退出码映射、
  5 条校验、§3.4 10 条映射用例 + 纯函数确定性、超时公式。退出码 0/1。
- **映射纯函数**（§3.3）：重叠按 speaker 累加、三级决胜、`Σov<200ms → nil`、
  `ratio<0.5 → nil`、`isMixed`、越界夹紧、零长不计。
- **`probe` 不加载模型**；**`download` 是唯一联网子命令且只下载不加载/不推理**
  （走 `ModelHub.download`，避开 `prepareModels` 失败时的 purge）。

## 2. 我打算怎么验证（下一轮，按顺序）

| # | 动作 | 判据 | 需不需要模型/推理 |
|---|---|---|---|
| 0 | `swift build -c release --package-path .` | 0 error（FluidAudio 的 `NemoTextProcessing.xcframework` binary target **已在本机 SwiftPM cache**：`~/Library/Caches/org.swift.swiftpm/artifacts/...NemoTextProcessing_xcframework_zip`，所以这一步预计**不需要网络**） | 否 |
| 1 | `diarize-helper --help` | exit 0，打印用法 | 否 |
| 2 | `diarize-helper --selftest` | 全 ✅，exit 0 | 否 |
| 3 | `probe --models-dir $(mktemp -d) --no-network` | 打印 `modelMissing`，exit 5 | 否 |
| 4 | `probe --models-dir <真模型目录> --no-network` | exit 0（模型未下载则先 `download`） | 否 |
| 5 | `download --models-dir <App 自有目录>` | 落盘 + revision marker，随后 probe exit 0 | **联网、不推理** |
| 6 | 真实录音 `diarize ... --output /tmp/c.json` | `jq`：`status=="ok"`、schemaVersion 1、segments 时间单调不减、`audioSeconds` 与 `afinfo` 差 ≤1%、`speakerCount == Set(segments[].speakerId).count` | 是 |
| 7 | `课堂-20260923-155813.wav`（67 min 单人） | `speakerCount == 1`（阳性，不是失败） | 是 |
| 8 | 失败注入：空模型目录 `diarize` | exit 5、error 信封存在；App 侧校验后 `diarization=nil`、**不是全员 S1** | 否（模型本就缺） |
| 9 | 多片段会话（若有「接着录」样本） | S1/S2 跨片段一致；偏移错位量记录（§8 第 9 条） | 是 |

第 6–9 步全部是**真实推理**，必须等机器空了、你给「go」才跑。

## 3. 哪几步还没验

- 全部。本轮没有 `swift build`、没有 `--selftest`、没有 probe、没有 download、没有推理。
- 因此**编译通过性本身未验**；所有 FluidAudio/主树符号是我读源码 + `grep` 核对的（见 §4），
  不是编译器的结论。第一件该做的事就是步骤 0。

## 4. 引用接口的核验证据（grep，只读）

**FluidAudio**（`~/ClassroomTranscriber-spike/FluidAudio` @ `5c51c5c`）：

| 用到的符号 | 位置 | 用途 |
|---|---|---|
| `OfflineDiarizerManager` / `init(config:)` / `initialize(models:)` / `process(audioSource:audioLoadingSeconds:)` | `Diarizer/Offline/Core/OfflineDiarizerManager.swift:13,20,24,171` | 离线推理 |
| `OfflineDiarizerModels.load(from:configuration:)` | `Diarizer/Offline/Core/OfflineDiarizerModels.swift:74` | 加载（不走 prepareModels） |
| `OfflineDiarizerConfig.default` / `.segmentation.sampleRate` | `Diarizer/Offline/Core/OfflineDiarizerTypes.swift:551,39` | 16 kHz |
| `DiarizationResult` / `TimedSpeakerSegment.speakerId/startTimeSeconds/endTimeSeconds/qualityScore/embedding` | `Diarizer/Core/DiarizerTypes.swift:164,191` | 物化 span |
| `PipelineTimings.segmentationSeconds/embeddingExtractionSeconds/speakerClusteringSeconds` | `Diarizer/Core/DiarizerTypes.swift:60` | 信封 timings |
| `OfflineDiarizationError.noSpeechDetected` | `Diarizer/Offline/Core/OfflineDiarizerTypes.swift:9` | 空结果处理 |
| `AudioSourceFactory.makeDiskBackedSource(from:targetSampleRate:)` | `Shared/AudioSourceFactory.swift:11` | 片段解码/mmap |
| `AudioSampleSource.copySamples` / `DiskBackedAudioSampleSource` | `Shared/AudioSampleSource.swift:3,47` | 复合源 |
| `Repo.diarizer.folderName/revision` / `ModelNames.OfflineDiarizer.requiredModels` | `ModelNames.swift:301,213,428` | probe 路径与文件集 |
| `ModelHub.offlineMode` / `ModelHub.download` / `DownloadError` | `Shared/Download/ModelHub.swift:31,401`、`DownloadTypes.swift:8` | 离线钉死 + 下载 |

**主树**（`/Users/you/ClassroomTranscriber`，只读）：

| 符号 | 位置 | 本次是否直接引用 |
|---|---|---|
| `RecordingPart.offsetMillis` | `Sources/Models/RecordingSession.swift:111` | 契约语义来源（本包不 import） |
| `RecordingSession.absoluteRange(of:in:)` | `Sources/Models/RecordingSession.swift:88` | 映射时间轴语义来源 |
| `TranscriptSegment`（`questionLevel:20`/`coreQuestion:22`/`qualityGrade:29`） | `Sources/Models/TranscriptSegment.swift:8` | 信封/映射语义来源 |
| `RecordingsStore.retranscribe` / `isRetranscribing` | `Sources/Stores/RecordingsStore.swift:174,160` | 并发形态参照（C-3） |

## 5. 拿不准的点（两个选项 + 推荐）

1. **`overlapRatio` 在「不标」时到底是 0 还是原始 winner 覆盖？**
   - A（**推荐，已按此实现**）：§3.2 明写「未标时为 0」，App 的
     `speakerOverlapRatio` 也是「仅 `speakerId != nil` 时有值」。§3.4 用例 8 表格里的
     `ratio 1/3 → nil` 我理解为「原始值」，自检只断言 `nil + mixed true`。
   - B：不标时保留 1/3 供诊断。代价：违反 §3.2，且 App 侧字段语义含混。
   - 若你要 B，改 `SpeakerMapper` 一处 + 自检一行即可。

2. **`noSpeechDetected`（FluidAudio 抛「无语音」）怎么归类？**
   - A（**推荐，已按此实现**）：产出 `status:"ok"` + 空 `segments` + `speakerCount:0`。
     理由：§2.6 第 5 条本身就是「有字没语音才判失败」，说明 helper *可以* 返回 0 人；
     由 App 用「转录里有没有 ≥1s 的段」来判矛盾。
   - B：直接 exit 7 `inferenceFailed`。代价：明明只是安静，却被报成推理失败。
   - 这条影响真实录音端到端行为，建议步骤 6 时专门用一个「几乎全静音」的样本确认。

3. **probe 必须复刻 FluidAudio 的 revision marker 判定。**
   - `.diarizer` 的 revision 是**钉死**的；`ModelCache.matchesRevision` 在 marker
     缺失时返回 false，`loadModels` 离线就会把**全部** required 当 missing。
   - 我用常量 `.fluidaudio-revision` 复刻（`ModelCache` 是 internal，拿不到）。
   - A（**推荐，已实现**）：复刻；probe 与 diarize 一致，不会「probe 说过、diarize 说缺」。
   - B：probe 只看 `.mlmodelc` 在不在。代价：marker 缺失时 probe 骗人。
   - 风险：FluidAudio 升级若改这个 internal 文件名，要跟改。已写进代码注释。

4. **`prepareModels` vs `OfflineDiarizerModels.load` + `initialize`。**
   - A（**推荐，已实现**）：后者。因为 `prepareModels` 一旦 load 失败会
     `purgeDiarizerRepo` **删缓存**再重试；离线场景下这等于把用户模型删掉。
   - B：用 `prepareModels`，代码少一点。代价：恰恰在最需要保住模型的失败路径上删模型。

5. **单 `--input` 是否允许省略 `--offset-ms`？**
   - A（**推荐，已实现**）：严格一一配对，缺就 usage error(2)。契约清楚，App 永远会传。
   - B：单片段缺省 0。代价：多一条隐式规则。

## 6. 硬约束遵守情况

- ⚠️ **产物当前在 `~/ClassroomTranscriber-design/_stage_c_helper/`（暂存）**，还没能落到
  派单指定的 `~/ClassroomTranscriber-spike/C-helper/`：本会话文件策略只允许写
  `/Users/you/ClassroomTranscriber-design`，目标在主树外，`mkdir` 被沙箱拒绝，
  提权 `danger-full-access` 又因「没有可用的批准通道」失败。**没有绕路**。
  移动命令（请在允许的 shell 里跑一次）：
  ```bash
  rsync -a --delete ~/ClassroomTranscriber-design/_stage_c_helper/ ~/ClassroomTranscriber-spike/C-helper/
  chmod +x ~/ClassroomTranscriber-spike/C-helper/Scripts/verify-next-round.sh
  ```
- ✅ 未写/改/删 `/Users/you/ClassroomTranscriber`（只 grep/读）。
- ✅ 本轮**没有构建、没有推理、没有播放音频、没有改音量/设备**。
- ✅ 未改 whisper 默认后端/模型（本包无关）。
