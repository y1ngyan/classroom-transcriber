import Foundation

/// `--retranscribe-selftest`：课后重转这条路的**离线**判据（P11-1）。
///
/// 为什么单独一条自检：这一包真正要防的是**「你以为是 large 转的，其实是 medium」**
/// 那类谎，而它有两种落地方式，两种都只在**特定输入**下才现形：
///   · 引擎被写死回 medium——跑真模型才看得出来（那是 `--retranscribe` 的判据）；
///   · 缺 large 时静默回落——**只有模型缺失那一支会走到**，而本机的 large
///     可能是就位的。等它真缺了才发现「回落了」，正是这条要防的顺序。
/// 所以裁决做成纯函数（`RetranscribeRequirement.decide`），这里把「缺 / 残 /
/// 张冠李戴」三种快照直接构造出来喂给它，不依赖磁盘上此刻有没有那个文件。
///
/// 全部离线：不加载模型、不联网、不碰麦克风、不发声，夹具在内存里造。
enum RetranscribeSelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    static func run() -> SelfTestResult {
        var lines: [String] = ["课后重转自检（离线 · 纯函数与内存夹具 · 不加载模型、不碰麦克风）"]
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        let stamp = Date(timeIntervalSince1970: 1_858_464_000)
        // 清单里钉的那两条（`Sources/Resources/model-manifest.json` 的真值）
        let largeBytes: Int64 = 1_081_140_203
        let mediumBytes: Int64 = 539_212_467
        let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"

        func pin(_ file: String, size: Int64) -> ModelPin {
            ModelPin(file: file, repo: "ggerganov/whisper.cpp", revision: revision,
                     size: size, sha256: String(repeating: "a", count: 64),
                     isDefault: false, url: URL(string: "https://example.invalid/\(file)")!)
        }

        let largePin = pin(RetranscribeEngine.large.fileName, size: largeBytes)
        let mediumPin = pin(RetranscribeEngine.medium.fileName, size: mediumBytes)
        // 下面「张冠李戴」那条判据靠的是两档的大小**不一样**。
        // 万一哪天清单把两档钉成同一个大小，那条判据会变成永远放行的假绿
        // ——所以先在这里把「它们本来就不同」这条前提也钉住
        let pinSizesDiffer = largePin.size != mediumPin.size

        func availability(_ path: String, exists: Bool, bytes: Int64?) -> ModelAvailability {
            ModelAvailability(path: path, exists: exists, sizeBytes: bytes, minimumBytes: 500_000_000)
        }

        // ── 一、档位与解析 ──

        lines.append("")
        lines.append("── 一、档位与解析 ──")
        check(RetranscribeEngine.preferred == .large, "默认档是 large（用户拍板 1a）")
        check(RetranscribeEngine.preferred.fileName == "ggml-large-v3-q5_0.bin",
              "默认档的文件名是 large-v3 那份", RetranscribeEngine.preferred.fileName)
        // **实时链路不许跟着变**：这两条是「不许把 large 设成全默认」的机器判据。
        // 谁把实时那个常量改成 large，这里立刻红
        check(WhisperEngine.modelFileName == "ggml-medium-q5_0.bin",
              "实时链路的模型仍是 medium", WhisperEngine.modelFileName)
        check(WhisperEngine.modelPath.lastPathComponent == "ggml-medium-q5_0.bin",
              "实时链路解析出来的路径仍是 medium", WhisperEngine.modelPath.lastPathComponent)

        check(RetranscribeEngine.parse("large") == .large, "parse(\"large\")")
        check(RetranscribeEngine.parse("large-v3") == .large, "parse(\"large-v3\")——同一个档")
        check(RetranscribeEngine.parse("  LARGE_v3 ") == .large, "parse 去空白、不区分大小写")
        check(RetranscribeEngine.parse("medium") == .medium, "parse(\"medium\")")
        // 认不出来返回 nil：猜一个的结果就是「以为跑的是 large，其实是别的」
        check(RetranscribeEngine.parse("huge") == nil, "parse(\"huge\") 返回 nil，不猜")
        check(RetranscribeEngine.parse("") == nil, "parse(\"\") 返回 nil")
        check(RetranscribeEngine.parse(nil) == nil, "parse(nil) 返回 nil")

        // ── 二、预计时长（倍率是常量，出处见 realtimeRate 的注释） ──

        lines.append("")
        lines.append("── 二、预计时长 ──")
        let large90 = RetranscribeEngine.large.estimatedSeconds(audioSeconds: 90)
        let medium90 = RetranscribeEngine.medium.estimatedSeconds(audioSeconds: 90)
        check(abs(large90 - 90 / 0.49) < 0.001, "large 90 秒音频 → 183.7 秒",
              String(format: "%.2f", large90))
        check(abs(medium90 - 90 / 0.89) < 0.001, "medium 90 秒音频 → 101.1 秒",
              String(format: "%.2f", medium90))
        check(large90 > medium90, "同一段音频 large 的预计时长比 medium 长")
        check(RetranscribeEngine.large.estimatedSeconds(audioSeconds: 0) == 0,
              "音频时长为 0 时预计为 0（不除出 inf）")
        // 措辞：这是**一段 90 秒录音的中位数**推出来的，课堂量级会偏乐观，
        // 所以只能说「预计约」。断言里钉住这个词，防止有人把它写成确定值
        let estimateText = RetranscribeEngine.large.estimatedText(audioSeconds: 90)
        check(estimateText.contains("预计约"), "措辞是「预计约」而不是「将耗时」", estimateText)
        check(estimateText.contains("0.49"), "预计那句里带着实测倍率")

        // ── 三、裁决：缺 / 残 / 张冠李戴 ──

        lines.append("")
        lines.append("── 三、裁决 ──")
        let largePath = "/tmp/models/ggml-large-v3-q5_0.bin"

        let missing = RetranscribeRequirement.decide(
            engine: .large, model: availability(largePath, exists: false, bytes: nil), pin: largePin
        )
        if case .blocked(let reason) = missing {
            check(true, "缺 large → 拦住")
            check(reason.contains(largePath), "拦截文案里带着模型路径")
            check(reason.contains("不会静默回落到 medium"),
                  "拦截文案明说不会回落 medium——这行是这份文案存在的理由")
            check(reason.contains("下载重转模型"), "拦截文案说清了怎么补（下载入口）",
                  RetranscribeRequirement.downloadEntryDescription)
        } else {
            check(false, "缺 large → 拦住", "拿到的是 \(missing)")
            check(false, "拦截文案里带着模型路径")
            check(false, "拦截文案明说不会回落 medium")
            check(false, "拦截文案说清了怎么补")
        }

        // 张冠李戴：文件名写着 large，内容其实是 medium（539MB）。
        // 这一条是「拿清单钉的字节数当判据」而不是「拿一个差不多大的门槛」的理由：
        // 门槛（≥500MB）拦不住它，而它正是本包最该拦的那一个
        let masquerade = RetranscribeRequirement.decide(
            engine: .large,
            model: availability(largePath, exists: true, bytes: mediumBytes),
            pin: largePin
        )
        if case .blocked(let reason) = masquerade {
            check(pinSizesDiffer, "前提：清单里 large 与 medium 钉的大小不同")
            check(true, "文件名是 large、内容只有 \(ModelAvailability.mbText(mediumBytes))（medium 的大小）→ 拦住")
            check(reason.contains("不到清单钉的"),
                  "拦截文案说明了「不到清单钉的 \(ModelAvailability.mbText(largeBytes))」")
        } else {
            check(false, "文件名是 large、内容是 medium 大小 → 拦住", "拿到的是 \(masquerade)")
            check(false, "拦截文案说明了它不到清单钉的大小")
        }

        // 下了一半的残file（1.08GB 只下到 500MB）
        let partial = RetranscribeRequirement.decide(
            engine: .large, model: availability(largePath, exists: true, bytes: 500_000_001),
            pin: largePin
        )
        if case .blocked = partial { check(true, "下了一半的残file → 拦住") }
        else { check(false, "下了一半的残file → 拦住", "拿到的是 \(partial)") }

        // **比清单钉的字节数，不是比一个「差不多大」的门槛**：两档差着 542MB，
        // 所以「够大」和「是那一份」是两件事。下面是这两件事分开的证明——
        // 同一个 900MB 的文件：比门槛（500MB）是「够大」，比清单钉的 1.08GB 是「不够」
        let thresholdAndPin = RetranscribeRequirement.decide(
            engine: .large, model: availability(largePath, exists: true, bytes: 900_000_000),
            pin: largePin
        )
        if case .blocked = thresholdAndPin {
            check(true, "900MB「够门槛但不是那一份」→ 拦住（判据是清单的真值，不是门槛）")
        } else {
            check(false, "900MB「够门槛但不是那一份」→ 拦住", "拿到的是 \(thresholdAndPin)")
        }

        // 齐全 → 放行，并且把「这次实际用的是哪一份」的三个数带出来
        let ready = RetranscribeRequirement.decide(
            engine: .large, model: availability(largePath, exists: true, bytes: largeBytes),
            pin: largePin
        )
        if case .ready(let path, let bytes, let rev) = ready {
            check(true, "齐全 → 放行")
            check(path == largePath && bytes == largeBytes, "放行时带着实际的路径与字节数",
                  "\(path) · \(bytes)")
            check(rev == revision, "放行时带着上游 revision")
        } else {
            check(false, "齐全 → 放行", "拿到的是 \(ready)")
            check(false, "放行时带着实际的路径与字节数")
            check(false, "放行时带着上游 revision")
        }

        // 清单里没有这一条时拦住（而不是「那就随便跑吧」）
        let noPin = RetranscribeRequirement.decide(
            engine: .large, model: availability(largePath, exists: true, bytes: largeBytes), pin: nil
        )
        if case .blocked(let reason) = noPin {
            check(true, "清单里没有这一条 → 拦住")
            check(reason.contains("model-manifest"), "拦截文案指出了清单的位置")
        } else {
            check(false, "清单里没有这一条 → 拦住", "拿到的是 \(noPin)")
            check(false, "拦截文案指出了清单的位置")
        }

        // ── 四、出处（provenance）与向后兼容 ──

        lines.append("")
        lines.append("── 四、出处与向后兼容 ──")
        let provenance = TranscriptionProvenance(
            modelFile: RetranscribeEngine.large.fileName, revision: revision,
            bytes: largeBytes, retranscribedAt: stamp
        )
        check(provenance.engine == .large, "出处能反查出是哪一档")
        check(provenance.summary.contains("ggml-large-v3-q5_0.bin"), "出处那句里有模型文件名")
        check(provenance.summary.contains("5359861c739e"), "出处那句里有短版 revision")

        // **旧存档必须能读**。磁盘上现存的那几条会话 JSON 里没有这个键，
        // 而合成解码会为缺失的新字段抛 keyNotFound、把**整条会话**读废
        // ——那不是「新字段是空的」，是「用户录的这节课消失了」
        let oldPartJSON = """
        {"id":"\(UUID().uuidString)","fileName":"a.wav","startedAt":0,
         "durationMillis":60000,"offsetMillis":0,"segments":[]}
        """
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(RecordingPart.self, from: Data(oldPartJSON.utf8)) {
            check(true, "旧存档（没有 transcriptionProvenance 键）能解码")
            check(decoded.transcriptionProvenance == nil, "旧存档解出来的出处是 nil")
            // 不许回写老存档：把解出来的旧片段再编码一遍，**不该多出这个键**。
            // 多出来就意味着「打开一次旧会话」会把它改成新形状，
            // 而 514MB 的模型出处是「这次重转」的事实，不是旧数据能补出来的
            let encoder = JSONEncoder()
            let reencoded = (try? encoder.encode(decoded)).flatMap { String(data: $0, encoding: .utf8) }
            check(reencoded?.contains("transcriptionProvenance") == false,
                  "旧片段重新编码后不会凭空多出出处键")
        } else {
            check(false, "旧存档（没有 transcriptionProvenance 键）能解码")
            check(false, "旧存档解出来的出处是 nil")
            check(false, "旧片段重新编码后不会凭空多出出处键")
        }

        // 新形状：带了出处的片段要能读回来，且四个值一个不差
        let newPartJSON = """
        {"id":"\(UUID().uuidString)","fileName":"b.wav","startedAt":0,
         "durationMillis":60000,"offsetMillis":0,"segments":[],
         "transcriptionProvenance":{"modelFile":"\(provenance.modelFile)",
         "revision":"\(revision)","bytes":\(largeBytes),"retranscribedAt":\(stamp.timeIntervalSinceReferenceDate)}}
        """
        if let decoded = try? decoder.decode(RecordingPart.self, from: Data(newPartJSON.utf8)),
           let read = decoded.transcriptionProvenance {
            check(read.modelFile == provenance.modelFile, "新存档的 modelFile 读回来了")
            check(read.bytes == largeBytes, "新存档的字节数读回来了", "\(read.bytes)")
            check(read.revision == revision, "新存档的 revision 读回来了")
            check(abs(read.retranscribedAt.timeIntervalSince(stamp)) < 0.001,
                  "新存档的重转时间读回来了")
        } else {
            check(false, "新存档能解码")
            check(false, "新存档的 modelFile 读回来了")
            check(false, "新存档的字节数读回来了")
            check(false, "新存档的 revision 读回来了")
            check(false, "新存档的重转时间读回来了")
        }

        // 认不出来的模型文件名不硬凑成某一档（同 `parse` 的「不猜」）
        let stranger = TranscriptionProvenance(
            modelFile: "ggml-something-else.bin", revision: revision, bytes: 1,
            retranscribedAt: stamp
        )
        check(stranger.engine == nil, "认不出来的模型文件名 → engine 是 nil，不硬凑")

        // ── 五、无头入口的参数解析 ──

        lines.append("")
        lines.append("── 五、无头入口参数 ──")
        func args(_ extra: [String]) -> [String] {
            ["--retranscribe", "/tmp/会话.json", "--out", "/tmp/out"] + extra
        }
        if case .success(let parsed) = RetranscribeRun.parse(args([])) {
            check(parsed.engine == .large, "不给 --engine 时默认 large（和界面同一处默认值）")
            check(parsed.allowPartial == false, "默认不许落半成品")
            check(parsed.onlyPart == nil, "默认跑全部片段")
        } else {
            check(false, "不给 --engine 时默认 large")
            check(false, "默认不许落半成品")
            check(false, "默认跑全部片段")
        }
        if case .success(let parsed) = RetranscribeRun.parse(args(["--engine", "medium"])) {
            check(parsed.engine == .medium, "--engine medium 认出来了")
        } else {
            check(false, "--engine medium 认出来了")
        }
        // 拼错的档位名必须拒绝：悄悄当成默认档跑就是这一包最忌的那种谎
        if case .failure = RetranscribeRun.parse(args(["--engine", "lg"])) {
            check(true, "--engine lg（拼错）→ 拒绝，不悄悄按默认档跑")
        } else {
            check(false, "--engine lg（拼错）→ 拒绝")
        }
        if case .failure = RetranscribeRun.parse(["--retranscribe", "/tmp/x.json"]) {
            check(true, "缺 --out → 拒绝")
        } else {
            check(false, "缺 --out → 拒绝")
        }
        if case .success(let parsed) = RetranscribeRun.parse(args(["--head", "20", "--allow-partial"])) {
            check(parsed.headSeconds == 20 && parsed.allowPartial, "--head 与 --allow-partial 都记下来了")
        } else {
            check(false, "--head 与 --allow-partial 都记下来了")
        }
        if case .success(let parsed) = RetranscribeRun.parse(args(["--head", "20"])) {
            check(parsed.headSeconds == 20 && !parsed.allowPartial,
                  "--head 不给 --allow-partial 时：参数记下，落盘那一步才拒（见入口里的闸）")
        } else {
            check(false, "--head 不给 --allow-partial 时参数记下")
        }
        if case .success(let parsed) = RetranscribeRun.parse(args(["--part", "2"])) {
            check(parsed.onlyPart == 2, "--part 2 认出来了")
        } else {
            check(false, "--part 2 认出来了")
        }

        lines.append("")
        lines.append(failed == 0
            ? "✅ 课后重转自检通过（\(passed) 条）"
            : "❌ 课后重转自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }
}
