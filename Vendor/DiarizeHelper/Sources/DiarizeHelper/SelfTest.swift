import Darwin
import FluidAudio
import Foundation

/// 离线自检：`diarize-helper --selftest` 一条命令跑完，退出码即成败（0/1）。
///
/// **不加载任何 CoreML 模型、不做任何推理**（C-1 派单 + 设计稿 §7 步骤 1）。
/// 覆盖：
/// 1. JSON 信封的编解码（含设计稿 §2.4 的字面样例）；
/// 2. 退出码映射（0 / 2–9 / SIGTERM / 其它信号 / 未知退出码）；
/// 3. §2.6 的 5 条校验；
/// 4. §3.4 的 10 条映射用例 + 纯函数确定性 + 裁决 1 的「未标注 ⟺ speakerId == nil」；
/// 5. §2.7 超时公式；
/// 6. 裁决 2：`noSpeechDetected`（近静音）→ `ok` + 空 segments + speakerCount 0；
/// 7. 裁决 3：probe 与 diarize 的模型就位判定必须是同一份实现、结论必须一致
///    （只造空目录占位，不 load 模型）。
final class SelfTestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private var failedNames: [String] = []

    func report(_ ok: Bool, _ name: String) {
        if ok {
            passed += 1
            print("✅ \(name)")
        } else {
            failed += 1
            failedNames.append(name)
            print("❌ \(name)")
        }
    }

    func summary() -> Bool {
        print("")
        print("\(passed) passed, \(failed) failed")
        if !failedNames.isEmpty {
            for name in failedNames { print("  ❌ \(name)") }
        }
        return failed == 0
    }
}

enum SelfTest {
    static func run() -> Bool {
        let runner = SelfTestRunner()
        runEnvelopeTests(runner)
        runExitCodeTests(runner)
        runValidationTests(runner)
        runMappingTests(runner)
        runTimeoutTests(runner)
        runNoSpeechTests(runner)
        runModelPresenceTests(runner)
        return runner.summary()
    }

    // MARK: - 1. JSON 信封编解码

    private static let designExampleJSON = #"""
        {
          "schemaVersion": 1,
          "status": "ok",
          "helperBuild": "fluidaudio-5c51c5c+helper-1",
          "mode": "offline",
          "inputs": [
            { "path": "课堂-20260921-194730.wav", "offsetMillis": 0, "audioSeconds": 368.2 }
          ],
          "result": {
            "audioSeconds": 368.2,
            "speakerCount": 2,
            "segments": [
              { "speakerId": "S1", "startMillis": 0, "endMillis": 18400, "qualityScore": 0.83 },
              { "speakerId": "S2", "startMillis": 18400, "endMillis": 21800, "qualityScore": 0.71 }
            ]
          },
          "timings": {
            "wallSeconds": 2.0, "loadSeconds": 0.4,
            "segmentationSeconds": 0.6, "embeddingSeconds": 0.9, "clusteringSeconds": 0.1
          }
        }
        """#

    private static let designFailureJSON = #"""
        { "schemaVersion": 1, "status": "error",
          "error": { "code": "modelMissing", "message": "no .mlmodelc under <dir>" } }
        """#

    private static func runEnvelopeTests(_ runner: SelfTestRunner) {
        if let envelope = try? Envelope.decode(Data(designExampleJSON.utf8)) {
            runner.report(
                envelope.schemaVersion == 1
                    && envelope.status == .ok
                    && envelope.result?.speakerCount == 2
                    && envelope.result?.segments.count == 2
                    && envelope.inputs?.count == 1
                    && envelope.result?.segments.first?.speakerId == "S1"
                    && envelope.timings?.clusteringSeconds == 0.1,
                "信封：能解设计稿 §2.4 的成功样例（键名不漂移）")
        } else {
            runner.report(false, "信封：能解设计稿 §2.4 的成功样例（键名不漂移）")
        }

        if let envelope = try? Envelope.decode(Data(designFailureJSON.utf8)) {
            runner.report(
                envelope.schemaVersion == 1
                    && envelope.status == .error
                    && envelope.error?.code == "modelMissing"
                    && envelope.result == nil,
                "信封：能解失败样例，error.code 原样")
        } else {
            runner.report(false, "信封：能解失败样例，error.code 原样")
        }

        let ok = Envelope.ok(
            inputs: [
                EnvelopeInput(path: "a.wav", offsetMillis: 0, audioSeconds: 12.5),
                EnvelopeInput(path: "b.wav", offsetMillis: 12500, audioSeconds: 3.25),
            ],
            result: EnvelopeResult(
                audioSeconds: 15.75,
                speakerCount: 2,
                segments: [
                    SpeakerSpanJSON(speakerId: "S1", startMillis: 0, endMillis: 9000, qualityScore: 0.9),
                    SpeakerSpanJSON(speakerId: "S2", startMillis: 9000, endMillis: 15750, qualityScore: 0.4),
                ]
            ),
            timings: EnvelopeTimings(
                wallSeconds: 2, loadSeconds: 0.3, segmentationSeconds: 0.4,
                embeddingSeconds: 0.5, clusteringSeconds: 0.1)
        )
        runner.report(roundTrips(ok), "信封：成功信封 encode→decode 往返相等")

        let failure = Envelope.failure(code: "inferenceFailed", message: "boom")
        runner.report(roundTrips(failure), "信封：失败信封 encode→decode 往返相等")

        // schemaVersion 不符：单测点（App 侧第 2 条校验会拒）。
        var wrong = ok
        wrong.schemaVersion = 2
        if let envelope = try? Envelope.decode(try! wrong.encoded()) {
            runner.report(envelope.schemaVersion == 2, "信封：schemaVersion 原样解出（不静默改 1）")
        } else {
            runner.report(false, "信封：schemaVersion 原样解出（不静默改 1）")
        }

        // embedding 旁路：主信封不含 embedding **向量**字段（拍板第 4 条）。
        // 不能对编码后的文本做子串匹配：合法的计时字段
        // `EnvelopeTimings.embeddingSeconds`（Envelope.swift:45）也含 "embedding"，
        // 子串匹配必然假红。改成解析 JSON 后判定：除计时标量 `embeddingSeconds`
        // 外，主信封里出现任何 embedding 相关键（`embedding` / `embeddings` / 其它，
        // 或 `embeddingSeconds` 的值是数组/对象而非标量）都算落下了向量字段。
        let mainEnvelopeHasNoEmbeddingVector: Bool
        if let data = try? ok.encoded(),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            mainEnvelopeHasNoEmbeddingVector = !containsEmbeddingVectorField(root)
        } else {
            mainEnvelopeHasNoEmbeddingVector = false
        }
        runner.report(
            mainEnvelopeHasNoEmbeddingVector,
            "信封：默认不落 embedding（拍板第 4 条）")
    }

    /// 递归判定解析后的 JSON 里是否存在 embedding **向量**字段。
    ///
    /// 唯一放行的 embedding 相关键是计时标量 `embeddingSeconds`；它必须是标量
    /// （数组/对象都算向量载荷）。其余任何含 "embedding" 的键一律判为向量字段。
    /// 这是原「编码文本不含 `embedding` 子串」判据的解析版等价物：原来禁的是
    /// 所有 embedding 字样，现在只豁免那个与向量无关的合法计时键。
    private static func containsEmbeddingVectorField(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let normalized = key.lowercased()
                if normalized.contains("embedding") {
                    let isLegalTimingScalar =
                        normalized == "embeddingseconds" && !isJSONContainer(child)
                    if !isLegalTimingScalar { return true }
                }
                if containsEmbeddingVectorField(child) { return true }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains { containsEmbeddingVectorField($0) }
        }
        return false
    }

    private static func isJSONContainer(_ value: Any) -> Bool {
        value is [String: Any] || value is [Any]
    }

    private static func roundTrips(_ envelope: Envelope) -> Bool {
        guard let data = try? envelope.encoded(), let decoded = try? Envelope.decode(data) else {
            return false
        }
        return decoded == envelope
    }

    // MARK: - 2. 退出码映射

    private static func runExitCodeTests(_ runner: SelfTestRunner) {
        runner.report(
            ExitCodeClassifier.classify(ProcessTermination(reason: .exit, status: 0)) == .success,
            "退出码：exit 0 → success")
        runner.report(
            ExitCodeClassifier.classify(ProcessTermination(reason: .exit, status: 2)) == .badInvocation,
            "退出码：exit 2 → badInvocation")
        runner.report(
            ExitCodeClassifier.classify(ProcessTermination(reason: .exit, status: 5)) == .modelMissing,
            "退出码：exit 5 → modelMissing")
        runner.report(
            ExitCodeClassifier.classify(ProcessTermination(reason: .exit, status: 9)) == .timeout,
            "退出码：exit 9 → timeout")
        runner.report(
            ExitCodeClassifier.classify(ProcessTermination(reason: .exit, status: 1)) == nil,
            "退出码：未知 exit 1 → nil（崩溃）")
        runner.report(
            ExitCodeClassifier.classify(ProcessTermination(reason: .uncaughtSignal, status: SIGTERM)) == .timeout,
            "退出码：SIGTERM → timeout")
        runner.report(
            ExitCodeClassifier.classify(ProcessTermination(reason: .uncaughtSignal, status: SIGKILL)) == nil,
            "退出码：SIGKILL → nil（崩溃）")

        // 每个 2–9 都有明确归类。
        var allClassified = true
        for raw in Int32(2)...Int32(9) {
            if ExitCodeClassifier.classify(ProcessTermination(reason: .exit, status: raw)) == nil {
                allClassified = false
            }
        }
        runner.report(allClassified, "退出码：2–9 全部有分类")
    }

    // MARK: - 3. §2.6 的 5 条校验

    private static func envelope(
        audioSeconds: Double,
        speakerCount: Int,
        segments: [(String, Int, Int)]
    ) -> Envelope {
        Envelope.ok(
            inputs: [EnvelopeInput(path: "a.wav", offsetMillis: 0, audioSeconds: audioSeconds)],
            result: EnvelopeResult(
                audioSeconds: audioSeconds,
                speakerCount: speakerCount,
                segments: segments.map {
                    SpeakerSpanJSON(speakerId: $0.0, startMillis: $0.1, endMillis: $0.2, qualityScore: 0.5)
                }
            ),
            timings: EnvelopeTimings(
                wallSeconds: 1, loadSeconds: 0, segmentationSeconds: 0, embeddingSeconds: 0,
                clusteringSeconds: 0)
        )
    }

    private static func validate(
        _ envelope: Envelope,
        termination: ProcessTermination? = ProcessTermination(reason: .exit, status: 0),
        sessionAudioSeconds: Double = 100,
        hasLongTranscriptSegment: Bool = true
    ) -> ValidationOutcome {
        OutputValidator.validate(
            termination: termination,
            envelopeData: try? envelope.encoded(),
            sessionAudioSeconds: sessionAudioSeconds,
            hasLongTranscriptSegment: hasLongTranscriptSegment)
    }

    private static func runValidationTests(_ runner: SelfTestRunner) {
        // 5 条全过 + speakerCount==1 是阳性结果，不是失败。
        let single = envelope(audioSeconds: 100, speakerCount: 1, segments: [("S1", 0, 90_000)])
        runner.report(
            validate(single).result == .ok,
            "校验：5 条全过且 speakerCount==1 → 阳性（不是失败）")

        // 第 3 条：时长对不上。
        runner.report(
            validate(envelope(audioSeconds: 100, speakerCount: 1, segments: [("S1", 0, 90_000)]),
                sessionAudioSeconds: 60).result == .failure(.audioSecondsMismatch),
            "校验：第 3 条 audioSeconds 差超容差 → audioSecondsMismatch")
        // 第 3 条容差边界：max(2s, 1%)。
        runner.report(
            OutputValidator.toleranceSeconds(sessionAudioSeconds: 100) == 2.0
                && OutputValidator.toleranceSeconds(sessionAudioSeconds: 1000) == 10.0,
            "校验：第 3 条容差 = max(2s, 1%)")

        // 第 1 条：非 0 退出。
        runner.report(
            validate(single, termination: ProcessTermination(reason: .exit, status: 5)).result
                == .failure(.processFailed),
            "校验：第 1 条 exit 5 → processFailed")
        runner.report(
            validate(single, termination: nil).result == .failure(.processFailed),
            "校验：第 1 条 没有 termination → processFailed")

        // 第 2 条：status=error / schemaVersion 不对。
        runner.report(
            validate(Envelope.failure(code: "modelMissing", message: "x")).result
                == .failure(.envelopeInvalid),
            "校验：第 2 条 status=error → envelopeInvalid")
        var wrongSchema = single
        wrongSchema.schemaVersion = 2
        runner.report(
            validate(wrongSchema).result == .failure(.envelopeInvalid),
            "校验：第 2 条 schemaVersion=2 → envelopeInvalid")

        // 第 4 条：越界 / 零长。
        runner.report(
            validate(envelope(audioSeconds: 100, speakerCount: 1, segments: [("S1", 0, 999_999)])).result
                == .failure(.segmentOutOfRange),
            "校验：第 4 条 segment 越界 → segmentOutOfRange")
        runner.report(
            validate(envelope(audioSeconds: 100, speakerCount: 1, segments: [("S1", 50_000, 50_000)])).result
                == .failure(.segmentOutOfRange),
            "校验：第 4 条 零长 segment → segmentOutOfRange")

        // 第 5 条：有长转录段却 0 说话人 = 前后矛盾。
        runner.report(
            validate(envelope(audioSeconds: 100, speakerCount: 0, segments: []), hasLongTranscriptSegment: true)
                .result == .failure(.speakerCountContradiction),
            "校验：第 5 条 有 ≥1s 转录段却说 0 人 → speakerCountContradiction")
        runner.report(
            validate(envelope(audioSeconds: 100, speakerCount: 0, segments: []), hasLongTranscriptSegment: false)
                .result == .ok,
            "校验：第 5 条 没有长转录段时 0 人是允许的")

        // speakerCount 与 segments 一致性（§7 步骤 2 验收）。
        runner.report(
            !OutputValidator.checkSpeakerCountConsistency(
                envelope(audioSeconds: 100, speakerCount: 2, segments: [("S1", 0, 90_000)])),
            "校验：speakerCount 与 segments 不一致会被抓出")
    }

    // MARK: - 4. §3.4 的 10 条映射用例

    private static func segment(_ start: Int, _ end: Int) -> MapTranscriptSegment {
        MapTranscriptSegment(startMillis: start, endMillis: end)
    }

    private static func span(_ speakerId: String, _ start: Int, _ end: Int) -> MapDiarSpan {
        MapDiarSpan(speakerId: speakerId, startMillis: start, endMillis: end)
    }

    private static func assignment(
        _ segment: MapTranscriptSegment,
        _ diarization: [MapDiarSpan],
        offset: Int = 0,
        audioMillis: Int = 10_000
    ) -> SpeakerMapper.Assignment {
        let result = SpeakerMapper.assign(
            transcript: [segment],
            partOffsetMillis: offset,
            diarization: diarization,
            audioMillis: audioMillis)
        return result[segment.id] ?? .unlabeled
    }

    private static func nearlyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }

    private static func runMappingTests(_ runner: SelfTestRunner) {
        // 1
        let t1 = segment(0, 2000)
        let a1 = assignment(t1, [span("S1", 0, 2000)])
        runner.report(
            a1.speakerId == "S1" && nearlyEqual(a1.overlapRatio, 1.0) && a1.isMixed == false,
            "映射 1：单段全覆盖 → S1 ratio 1.0 mixed false")

        // 2
        let t2 = segment(0, 2000)
        let a2 = assignment(t2, [span("S1", 0, 1200), span("S2", 1200, 2000)])
        runner.report(
            a2.speakerId == "S1" && nearlyEqual(a2.overlapRatio, 0.6) && a2.isMixed == true,
            "映射 2：多数派 0.6 → S1 mixed true")

        // 3：ov 并列 → 中点等距 → 字典序决胜 S1
        let t3 = segment(0, 2000)
        let a3 = assignment(t3, [span("S1", 0, 1000), span("S2", 1000, 2000)])
        runner.report(
            a3.speakerId == "S1" && nearlyEqual(a3.overlapRatio, 0.5) && a3.isMixed == true,
            "映射 3：等量等距 → 字典序 S1 ratio 0.5 mixed true")

        // 4：覆盖 <200ms → nil
        let t4 = segment(0, 2000)
        let a4 = assignment(t4, [span("S1", 0, 90)])
        runner.report(a4 == .unlabeled, "映射 4：覆盖 <200ms → nil（不回退最近的人）")

        // 5：空 diar → nil
        let t5 = segment(0, 2000)
        let a5 = assignment(t5, [])
        runner.report(a5 == .unlabeled, "映射 5：空 diar → nil")

        // 6：中点决胜（等距取字典序）
        let t6 = segment(500, 1500)
        let a6 = assignment(t6, [span("S1", 0, 1000), span("S2", 1000, 2000)])
        runner.report(
            a6.speakerId == "S1" && nearlyEqual(a6.overlapRatio, 0.5),
            "映射 6：跨切换点、等重叠 → 中点/字典序决胜 S1")

        // 7：允许 diar 重叠
        let t7 = segment(0, 2000)
        let a7 = assignment(t7, [span("S1", 0, 1200), span("S2", 1000, 2000)])
        runner.report(
            a7.speakerId == "S1" && nearlyEqual(a7.overlapRatio, 0.6) && a7.isMixed == true,
            "映射 7：diar 段彼此重叠 → S1 ratio 0.6 mixed true")

        // 8：ratio 1/3 < 0.5 → nil，但 mixed true
        let t8 = segment(0, 3000)
        let a8 = assignment(t8, [span("S1", 0, 1000), span("S2", 1000, 2000), span("S3", 2000, 3000)])
        runner.report(
            a8.speakerId == nil && a8.isMixed == true,
            "映射 8：无多数派（1/3）→ nil 且 mixed true")

        // 9：多片段 offset（T 局部 [0,3000)，offset 60000 → 会话轴 [60000,63000)）
        // 显式传会话总长 63000；默认 audioMillis 10000 会让 clampedUpperBound
        // 落到 11000，把合法 span 夹成零长（实现不做修改，缺的是用例入参）。
        let t9 = segment(0, 3000)
        let a9 = assignment(t9, [span("S2", 60_000, 63_000)], offset: 60_000, audioMillis: 63_000)
        runner.report(
            a9.speakerId == "S2" && nearlyEqual(a9.overlapRatio, 1.0),
            "映射 9：多片段 offset 摆到会话轴 → S2")

        // 10：零长 diar 段不计
        let t10 = segment(0, 2000)
        let a10 = assignment(t10, [span("S1", 0, 0)])
        runner.report(a10 == .unlabeled, "映射 10：零长 diar 段不计 → nil")

        // 纯函数确定性：同输入同输出。
        let first = SpeakerMapper.assign(
            transcript: [t3], partOffsetMillis: 0,
            diarization: [span("S1", 0, 1000), span("S2", 1000, 2000)], audioMillis: 10_000)
        let second = SpeakerMapper.assign(
            transcript: [t3], partOffsetMillis: 0,
            diarization: [span("S1", 0, 1000), span("S2", 1000, 2000)], audioMillis: 10_000)
        runner.report(first == second, "映射：同输入两次调用结果相等（纯函数）")

        // 裁决 1：未标注只由 speakerId == nil 表达；未标时 overlapRatio 恒为 0
        // （不是「保留原始 winner 覆盖率供诊断」），已标时 > 0。
        let allAssignments = [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10]
        let unlabeledAreZero = allAssignments
            .filter { $0.speakerId == nil }
            .allSatisfy { $0.overlapRatio == 0 }
        let labeledArePositive = allAssignments
            .filter { $0.speakerId != nil }
            .allSatisfy { $0.overlapRatio > 0 }
        let labeledFlagAgrees = allAssignments.allSatisfy { $0.isLabeled == ($0.speakerId != nil) }
        runner.report(
            unlabeledAreZero && labeledArePositive && labeledFlagAgrees,
            "映射（裁决 1）：未标注 ⟺ speakerId == nil，未标时 overlapRatio == 0")
    }

    // MARK: - 5. 超时公式

    private static func runTimeoutTests(_ runner: SelfTestRunner) {
        runner.report(
            TimeoutPolicy.timeoutSeconds(audioSeconds: 0) == 300,
            "超时：0s → 300（下限）")
        runner.report(
            TimeoutPolicy.timeoutSeconds(audioSeconds: 1000) == 300,
            "超时：1000s → 300（90+200=290，取 300）")
        runner.report(
            TimeoutPolicy.timeoutSeconds(audioSeconds: 2000) == 490,
            "超时：2000s → 490（90+400）")
        runner.report(
            TimeoutPolicy.timeoutSeconds(audioSeconds: 2700) == 630,
            "超时：45min → 630（90+540）")
    }

    // MARK: - 6. 裁决 2：noSpeechDetected（近静音）是正常结果

    /// 近静音样本 → helper 抛 `noSpeechDetected` → `result == nil` → 物化出
    /// `status=="ok"` + 空 `segments` + `speakerCount==0`。
    ///
    /// 这里不跑推理：直接调用 `DiarizeCommand.makeSuccessEnvelope`（生产路径用的
    /// 同一个纯函数）并传空 spans，等于走完 noSpeechDetected 之后的物化步骤。
    private static func runNoSpeechTests(_ runner: SelfTestRunner) {
        let envelope = DiarizeCommand.makeSuccessEnvelope(
            inputs: [EnvelopeInput(path: "near-silence.wav", offsetMillis: 0, audioSeconds: 5)],
            spans: [],
            audioSeconds: 5,
            timings: EnvelopeTimings(
                wallSeconds: 0.1, loadSeconds: 0, segmentationSeconds: 0, embeddingSeconds: 0,
                clusteringSeconds: 0)
        )
        runner.report(
            envelope.status == .ok
                && envelope.error == nil
                && envelope.result?.segments.isEmpty == true
                && envelope.result?.speakerCount == 0,
            "noSpeechDetected（裁决 2）：近静音 → status ok + 空 segments + speakerCount 0")

        // 该空结果在「没有 ≥1s 转录段」时必须被 App 判为合法（不重试、不贴 S1）。
        runner.report(
            validate(envelope, sessionAudioSeconds: 5, hasLongTranscriptSegment: false).result == .ok,
            "noSpeechDetected（裁决 2）：无长转录段 → 空结果是合法 ok（App 不回退成 S1）")

        // 而「有 ≥1s 转录段却说 0 人」仍然必须是失败（交给 App 第 5 条）。
        runner.report(
            validate(envelope, sessionAudioSeconds: 5, hasLongTranscriptSegment: true).result
                == .failure(.speakerCountContradiction),
            "noSpeechDetected（裁决 2）：有长转录段 → speakerCountContradiction（不伪装 S1）")
    }

    // MARK: - 7. 裁决 3：probe 与 diarize 的模型就位判定必须一致

    /// 在临时目录里造四种模型目录（**只建空目录/空 marker，不 load、不编译任何
    /// CoreML 模型**），对每个目录分别取：
    ///   - probe 面：`ModelProbe.inspect`（probe 子命令用的判定）
    ///   - diarize 面：`ModelPresence.evaluate`（diarize 预检用的判定）
    /// 断言两者结论**逐字段相同**，且与预期一致。这样任何一方将来被改成另一套
    /// 「文件在不在」的逻辑，自检立刻失败。
    private static func runModelPresenceTests(_ runner: SelfTestRunner) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "diarize-helper-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let required = ModelPresence.offlineDiarizerRequiredModels
        let correctRevision = Repo.diarizer.revision

        func makeModelsDir(
            _ name: String, files: Set<String>, marker: String?
        ) -> URL {
            let modelsDir = root.appendingPathComponent(name, isDirectory: true)
            let repoDir = modelsDir.appendingPathComponent(
                Repo.diarizer.folderName, isDirectory: true)
            try? fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
            for file in files {
                try? fm.createDirectory(
                    at: repoDir.appendingPathComponent(file, isDirectory: true),
                    withIntermediateDirectories: true)
            }
            if let marker {
                try? Data((marker + "\n").utf8).write(
                    to: repoDir.appendingPathComponent(ModelPresence.revisionMarkerName))
            }
            return modelsDir
        }

        let cases: [(name: String, files: Set<String>, marker: String?, expectedReady: Bool)] = [
            ("空目录", [], nil, false),
            ("文件齐但无 revision marker", required, nil, false),
            ("文件齐 + 正确 marker", required, correctRevision, true),
            ("文件齐 + 错误 marker", required, "0000000000000000000000000000000000000000", false),
        ]

        for testCase in cases {
            let modelsDir = makeModelsDir(
                testCase.name, files: testCase.files, marker: testCase.marker)
            let probeVerdict = ModelProbe.inspect(modelsDir: modelsDir)
            let diarizeVerdict = ModelPresence.evaluate(modelsDir: modelsDir)
            runner.report(
                probeVerdict == diarizeVerdict && diarizeVerdict.ready == testCase.expectedReady,
                "模型就位（裁决 3）：\(testCase.name) → probe/diarize 结论一致（ready="
                    + "\(testCase.expectedReady)）")
        }

        // 直接钉 `matchesRevision` 的语义 = FluidAudio `ModelCache.matchesRevision`：
        // marker 缺失时仅 "main" 通过；marker 有值时必须严格相等。
        let markerDir = root.appendingPathComponent("marker-semantics", isDirectory: true)
        try? fm.createDirectory(at: markerDir, withIntermediateDirectories: true)
        runner.report(
            ModelPresence.matchesRevision(at: markerDir, revision: "main") == true
                && ModelPresence.matchesRevision(at: markerDir, revision: correctRevision) == false,
            "模型就位（裁决 3）：无 marker → 仅 main 通过（对齐 ModelCache.matchesRevision）")
        try? Data((correctRevision + "\n").utf8).write(
            to: markerDir.appendingPathComponent(ModelPresence.revisionMarkerName))
        runner.report(
            ModelPresence.matchesRevision(at: markerDir, revision: correctRevision) == true
                && ModelPresence.matchesRevision(at: markerDir, revision: "main") == false,
            "模型就位（裁决 3）：marker 有值 → 必须严格相等")
    }
}
