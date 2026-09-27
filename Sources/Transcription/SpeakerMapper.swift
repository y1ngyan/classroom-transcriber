import Foundation

/// 一条转录段的说话人归属判定结果。**纯数据，不落盘**——落盘的只有
/// `TranscriptSegment` 上那三个字段，这个类型是判定的中间产物。
struct SpeakerAssignment: Equatable {
    /// `nil` = 不标。**「没标」只由它表达**，别拿 `overlapRatio == 0` 或
    /// `isMixed` 反推（C-1 裁决 1 定的规矩）。
    var speakerId: String?
    /// winner 覆盖率 = `ov[winner] / (b−a)`。
    ///
    /// **没标时这里是占位的 0，不代表「覆盖率低」**——0 是一个合法读数，
    /// 拿它兼职「没有值」就分不开了。物化到 `TranscriptSegment` 时按
    /// `speakerId == nil ? nil : overlapRatio` 转成 `Double?`，判据永远是
    /// `speakerId`。这条形状照 C-1 已冻结的实现（`overlapRatio` 非可选），
    /// 没有改成 Optional 是为了不偏离那份契约
    var overlapRatio: Double
    /// 本段内第二个人也占了可观时长（见 `isMixed` 的判定）
    var isMixed: Bool

    /// 未标注。`overlapRatio` 是随之而来的占位值，**不是判据**
    static let unlabeled = SpeakerAssignment(speakerId: nil, overlapRatio: 0, isMixed: false)

    /// 是否标了。全项目统一用这个（它只等价于 `speakerId != nil`）
    var isLabeled: Bool { speakerId != nil }
}

/// 把转录段和 diar 段对起来：转录段 × 会话轴的说话人区间 → 每段的归属。
///
/// **纯函数**：无 IO、不看时钟、不用随机数，同输入两次调用结果必然相等。
/// 这一条是刻意的——判据必须能在无头自检里断言，而任何一点环境依赖都会让
/// 「这次过了」和「这台机器上过了」变成两件事。
///
/// 语义**照 C-1 已冻结的实现**（`~/ClassroomTranscriber-spike/C-helper`
/// 的 `SpeakerMapper.swift`），不在这里另发明一套：那是真机跑通过的版本。
enum SpeakerMapper {

    /// 重叠门限：`Σov < 200ms` 就不标（设计稿 §3.3 第 3 条）
    static let defaultMinOverlapMillis = 200
    /// 多数派门限：winner 覆盖率不到一半就不认（§3.3 第 4 条）
    static let defaultMinOverlapRatio = 0.5
    /// 「多人」门限：第二个人占到这个比例（或 200ms）以上（§3.3 第 5 条）
    static let defaultMixedShare = 0.25

    /// 判定入口。
    ///
    /// - Parameters:
    ///   - transcript: 本片段的转录段（时间是**片段内相对值**，与引擎吐出来的一致）
    ///   - part: 该片段。**只需要它拿 `offsetMillis`**，换算走
    ///     `RecordingSession.absoluteRange`——全项目「片段轴 → 会话轴」的换算只有那一处，
    ///     这里再写一遍 `+ offsetMillis` 就是第二套基准，两边一旦不一致就是静默错位
    ///   - diarization: 会话轴的说话人区间
    ///   - sessionAudioMillis: **会话**音频总长（不是本片段的）。用来把 diar 段夹紧到
    ///     `[0, sessionAudioMillis + 1000]`。这个参数是 C-1 裁决 2 特别点名的坑：
    ///     传小了会把合法的 diar 段夹成零长、判定成「这里没人说话」，而且**不报错**
    static func assign(
        transcript: [TranscriptSegment],
        part: RecordingPart,
        diarization: SpeakerDiarization,
        sessionAudioMillis: Int,
        minOverlapMillis: Int = defaultMinOverlapMillis,
        minOverlapRatio: Double = defaultMinOverlapRatio,
        mixedShare: Double = defaultMixedShare
    ) -> [UUID: SpeakerAssignment] {
        // 夹紧 + 丢掉夹完变零长/反向的 diar 段（§3.3 第 6 条）。
        // 这一步必须在循环外做一次：它只跟 diar 有关，跟转录段无关
        let clampedUpperBound = sessionAudioMillis + 1000
        let usableSpans = diarization.segments.compactMap { span -> SpeakerSpan? in
            let start = max(0, span.startMillis)
            let end = min(span.endMillis, clampedUpperBound)
            guard end > start else { return nil }
            return SpeakerSpan(
                speakerId: span.speakerId, startMillis: start, endMillis: end,
                qualityScore: span.qualityScore
            )
        }

        var output: [UUID: SpeakerAssignment] = [:]

        for segment in transcript {
            let range = RecordingSession.absoluteRange(of: segment, in: part)
            let segmentStart = range.lowerBound
            let segmentEnd = range.upperBound

            // 零长/反向的转录段直接不标。下面算 ratio 要除以 (b−a)，这里不拦住就是除零。
            //
            // **这个 guard 曾经是死代码**：反向段在上一行的 `absoluteRange` 里就被
            // `..<` 的运行时检查 SIGTRAP 掉了（exit 133），根本走不到这里。
            // C-4 修好 `absoluteRange`（反向返回空区间）之后它才真的可达——
            // 也就是说这条「不标」的规则现在由它独自承担，别再让它变成装饰
            guard segmentEnd > segmentStart else {
                output[segment.id] = .unlabeled
                continue
            }

            var overlapBySpeaker: [String: Int] = [:]
            // 每个 speaker 与 T 重叠最大的那个 diar 段的中点，用于决胜②（等重叠时取近的）
            var representativeMidpointBySpeaker: [String: Double] = [:]
            var bestSingleSpanOverlapBySpeaker: [String: Int] = [:]

            for span in usableSpans {
                let overlap = max(0, min(segmentEnd, span.endMillis) - max(segmentStart, span.startMillis))
                guard overlap > 0 else { continue }
                // **按 speakerId 求和**，不是取最大：同一个人在一个转录段里可能被切成
                // 好几个 diar 段，它们该算成一个人的总覆盖（§3.3 第 1 条）
                overlapBySpeaker[span.speakerId, default: 0] += overlap

                let previousBest = bestSingleSpanOverlapBySpeaker[span.speakerId] ?? -1
                if overlap > previousBest {
                    bestSingleSpanOverlapBySpeaker[span.speakerId] = overlap
                    representativeMidpointBySpeaker[span.speakerId] =
                        Double(span.startMillis + span.endMillis) / 2
                }
            }

            let totalOverlap = overlapBySpeaker.values.reduce(0, +)
            // 总重叠不足门限 → 不标。**绝不回退到「最近的人」**（§3.3 第 3 条）：
            // 转录段理应有语音，diar 说这里没人，是两个系统打架；贴一个最近的说话人
            // 等于编。少标一段只是没显示标签，标错一段是在误导
            guard totalOverlap >= minOverlapMillis else {
                output[segment.id] = .unlabeled
                continue
            }

            let segmentMidpoint = Double(segmentStart + segmentEnd) / 2
            // 三级决胜：① 重叠大者 ② diar 段中点离段中点近者 ③ speakerId 字典序小者。
            // 三级都定死是为了**纯函数**：只要还有一级靠「遍历顺序」这种隐含状态，
            // 同输入就可能出不同结果，判据也就断言不了
            let winner = overlapBySpeaker.keys.min { lhs, rhs in
                let lhsOverlap = overlapBySpeaker[lhs] ?? 0
                let rhsOverlap = overlapBySpeaker[rhs] ?? 0
                if lhsOverlap != rhsOverlap { return lhsOverlap > rhsOverlap }
                let lhsDistance = abs((representativeMidpointBySpeaker[lhs] ?? segmentMidpoint) - segmentMidpoint)
                let rhsDistance = abs((representativeMidpointBySpeaker[rhs] ?? segmentMidpoint) - segmentMidpoint)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs < rhs
            }

            guard let winner else {
                output[segment.id] = .unlabeled
                continue
            }

            let winnerOverlap = overlapBySpeaker[winner] ?? 0
            let duration = Double(segmentEnd - segmentStart)
            let ratio = Double(winnerOverlap) / duration
            // 「另一个人也占了可观时长」：第二人的总覆盖 ≥ max(200ms, 25%×时长)。
            // 与归属分档**相互独立**——可以「有归属 + 多人」，也可以「无归属 + 多人」
            let secondSpeakerOverlap = totalOverlap - winnerOverlap
            let mixedThreshold = max(Double(minOverlapMillis), mixedShare * duration)
            let isMixed = Double(secondSpeakerOverlap) >= mixedThreshold

            if ratio < minOverlapRatio {
                // 没有多数派就不认（§3.3 第 4 条）。但 `isMixed` 照实留着：
                // 「两人在说话，只是分不出主次」和「没人说话」对界面是两回事
                output[segment.id] = SpeakerAssignment(speakerId: nil, overlapRatio: 0, isMixed: isMixed)
            } else {
                output[segment.id] = SpeakerAssignment(speakerId: winner, overlapRatio: ratio, isMixed: isMixed)
            }
        }

        return output
    }
}

// MARK: - 无头自检

extension SpeakerMapper {

    /// 自检结果。**分开报「过了几条 / 红了几条」而不是只管打印**：退出码要按它定。
    ///
    /// 为什么退出码必须跟着红绿走：`--whisper-selftest` 那边踩过——自检失败不改
    /// 退出码，于是 `tools/probes/exit_codes.sh` 只看退出码，**红的自检在它眼里
    /// 和绿的一模一样**，只能靠另外断言输出行才发现。新写的入口不重复这个坑
    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// 离线自检：10 个映射用例 + 旧会话兼容用例 + 纯函数/契约不变量。
    ///
    /// 不联网、不加载模型、不碰麦克风、**不发声**（判据靠打印，不靠听）。
    /// `sessionFile` 非空时**额外**拿一条真实会话文件解码一遍（只读，不写回）。
    static func selfTest(sessionFile: String? = nil) -> SelfTestResult {
        var lines: [String] = ["说话人映射自检（纯函数 · 离线 · 不加载模型、不碰音频）"]
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        // ── 测试脚手架 ──
        //
        // 会话轴用例要**显式传会话总长**：C-1 裁决 2 的红 2 就是用例自己声明了
        // 10 秒音频、却摆了一个 60–63 秒的 span，被夹成零长后判成「没重叠」——
        // 红的是用例的入参，不是实现。默认值只给「短用例」，跨片段用例必须自己传
        func segment(_ start: Int, _ end: Int) -> TranscriptSegment {
            TranscriptSegment(
                text: "t", isFinal: true,
                startTimeMillis: start, endTimeMillis: end,
                languages: ["zh-CN"]
            )
        }

        func span(_ speakerId: String, _ start: Int, _ end: Int) -> SpeakerSpan {
            SpeakerSpan(speakerId: speakerId, startMillis: start, endMillis: end, qualityScore: 0.9)
        }

        func diarization(_ spans: [SpeakerSpan]) -> SpeakerDiarization {
            SpeakerDiarization(
                schemaVersion: 1, helperBuild: "selftest", ranAt: Date(timeIntervalSince1970: 0),
                audioSeconds: 0, speakerCount: Set(spans.map(\.speakerId)).count,
                speakerOrder: [], segments: spans, partFingerprint: "selftest"
            )
        }

        func part(offset: Int = 0, segments: [TranscriptSegment] = []) -> RecordingPart {
            RecordingPart(
                id: UUID(), fileName: "selftest.wav", startedAt: Date(timeIntervalSince1970: 0),
                durationMillis: 10_000, offsetMillis: offset, segments: segments
            )
        }

        func assignment(
            _ segment: TranscriptSegment,
            _ spans: [SpeakerSpan],
            offset: Int = 0,
            audioMillis: Int = 10_000
        ) -> SpeakerAssignment {
            let result = SpeakerMapper.assign(
                transcript: [segment],
                part: part(offset: offset, segments: [segment]),
                diarization: diarization(spans),
                sessionAudioMillis: audioMillis
            )
            return result[segment.id] ?? .unlabeled
        }

        func nearlyEqual(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-9 }

        // ── 一、10 条映射用例（设计稿 §3.4 的表，逐条钉住）──

        let t1 = segment(0, 2000)
        let a1 = assignment(t1, [span("S1", 0, 2000)])
        check(a1.speakerId == "S1" && nearlyEqual(a1.overlapRatio, 1.0) && a1.isMixed == false,
              "映射 1：单段全覆盖 → S1", "ratio \(a1.overlapRatio) mixed \(a1.isMixed)")

        let t2 = segment(0, 2000)
        let a2 = assignment(t2, [span("S1", 0, 1200), span("S2", 1200, 2000)])
        check(a2.speakerId == "S1" && nearlyEqual(a2.overlapRatio, 0.6) && a2.isMixed == true,
              "映射 2：多数派 0.6 → S1 且 mixed", "ratio \(a2.overlapRatio) mixed \(a2.isMixed)")

        // 等重叠等距 → 决胜③ 字典序 S1
        let t3 = segment(0, 2000)
        let a3 = assignment(t3, [span("S1", 0, 1000), span("S2", 1000, 2000)])
        check(a3.speakerId == "S1" && nearlyEqual(a3.overlapRatio, 0.5) && a3.isMixed == true,
              "映射 3：等量等距 → 字典序决胜 S1", "ratio \(a3.overlapRatio)")

        let t4 = segment(0, 2000)
        let a4 = assignment(t4, [span("S1", 0, 90)])
        check(a4 == .unlabeled, "映射 4：覆盖 <200ms → 不标（不回退最近的人）",
              "speakerId \(a4.speakerId ?? "nil")")

        let t5 = segment(0, 2000)
        let a5 = assignment(t5, [])
        check(a5 == .unlabeled, "映射 5：空 diar → 不标")

        // 跨切换点、等重叠**等距** → 决胜② 判不出高下，落到决胜③ 字典序，取 S1。
        // （注意：这条**没有**在验决胜②，见下面 6b 的说明）
        let t6 = segment(500, 1500)
        let a6 = assignment(t6, [span("S1", 0, 1000), span("S2", 1000, 2000)])
        check(a6.speakerId == "S1" && nearlyEqual(a6.overlapRatio, 0.5),
              "映射 6：跨切换点、等重叠 → S1", "ratio \(a6.overlapRatio)")

        // diar 段彼此重叠是允许的：S1 占 1200，S2 占 1000，重叠区间 1000–1200 两边都算
        let t7 = segment(0, 2000)
        let a7 = assignment(t7, [span("S1", 0, 1200), span("S2", 1000, 2000)])
        check(a7.speakerId == "S1" && nearlyEqual(a7.overlapRatio, 0.6) && a7.isMixed == true,
              "映射 7：diar 段彼此重叠 → S1 且 mixed", "ratio \(a7.overlapRatio)")

        // 三人均分 → 谁都不到 0.5 → 不标，但 mixed = true（界面仍能提示「多人」）
        let t8 = segment(0, 3000)
        let a8 = assignment(t8, [span("S1", 0, 1000), span("S2", 1000, 2000), span("S3", 2000, 3000)])
        check(a8.speakerId == nil && a8.isMixed == true,
              "映射 8：无多数派（1/3）→ 不标且 mixed", "mixed \(a8.isMixed)")

        // 多片段：T 在片段内是 [0,3000)，片段 offset 60000，diar 已在会话轴。
        // **显式传会话总长 63000**（见上面脚手架处的说明）
        let t9 = segment(0, 3000)
        let a9 = assignment(t9, [span("S2", 60_000, 63_000)], offset: 60_000, audioMillis: 63_000)
        check(a9.speakerId == "S2" && nearlyEqual(a9.overlapRatio, 1.0),
              "映射 9：多片段 offset 摆到会话轴 → S2", "speakerId \(a9.speakerId ?? "nil")")

        let t10 = segment(0, 2000)
        let a10 = assignment(t10, [span("S1", 0, 0)])
        check(a10 == .unlabeled, "映射 10：零长 diar 段不计 → 不标")

        // ── 一·补：设计稿那 10 条之外的一条**补强用例**（注入实验逼出来的）──
        //
        // 为什么非补不可：把 `totalOverlap >= minOverlapMillis` 换成 `>= 0` 重编，
        // **上面 4 号照样是绿的**——T=[0,2000) 配 S1[0,90)，ratio 只有 0.045，
        // 就算不拦，也会因为「没有多数派」落到同一个 `unlabeled` 上。也就是说
        // 4 号从头到尾没在验 200ms 那条规则（它验的是比例规则）。
        //
        // 要让它可分辨，得构造「重叠不足 200ms、但占比过半」的段——短段配短 span：
        // 门限在时判不标，门限不在时会标成 S1，两种实现给出**不同**结果
        let t4b = segment(0, 300)
        let a4b = assignment(t4b, [span("S1", 0, 150)])
        check(a4b == .unlabeled,
              "映射 4b：重叠 150ms（<200）但占比 50% → 仍不标",
              "speakerId \(a4b.speakerId ?? "nil") ratio \(a4b.overlapRatio)")

        // ── 二·补：决胜②（等重叠时取中点更近者）也没有用例覆盖 ──
        //
        // 上面 4b 是同一种病、第二次犯：**判据看着有、其实没在验那条规则**。
        // 这次是核验者找出来的——3 号和 6 号都是**严格等距**（两人中点离转录段
        // 中点一样远），决胜② 根本不触发；把那段落中点比较整段删掉重编，
        // 14 条自检**照样全绿**。
        //
        // 要让它可分辨，得构造「等重叠、但**不等距**」的两个 diar 段。
        // 等距时字典序与距离指向同一个人，只有不等距才能把两条规则分开——
        // 而且要让更近的那个**字典序更大**，否则两条规则又给出同一个答案：
        //
        //   T  = [0,2000)   中点 1000
        //   S1 = [1000,2000) 与 T 重叠 1000，中点 1500（距 500）· 字典序更小
        //   S2 = [500,1500)  与 T 重叠 1000，中点 1000（距   0）· 字典序更大
        //
        // 正确实现取 S2（决胜②），拿掉决胜② 则落回决胜③ 取 S1
        let t6b = segment(0, 2000)
        let a6b = assignment(t6b, [span("S1", 1000, 2000), span("S2", 500, 1500)])
        check(a6b.speakerId == "S2" && nearlyEqual(a6b.overlapRatio, 0.5) && a6b.isMixed == true,
              "映射 6b：等重叠不等距 → 中点更近者 S2（字典序更大也照赢）",
              "speakerId \(a6b.speakerId ?? "nil") ratio \(a6b.overlapRatio)")

        // ── 二、纯函数：同输入两次调用必须相等 ──
        let pureSpans = [span("S1", 0, 1000), span("S2", 1000, 2000)]
        let firstRun = SpeakerMapper.assign(
            transcript: [t3], part: part(segments: [t3]),
            diarization: diarization(pureSpans), sessionAudioMillis: 10_000)
        let secondRun = SpeakerMapper.assign(
            transcript: [t3], part: part(segments: [t3]),
            diarization: diarization(pureSpans), sessionAudioMillis: 10_000)
        check(firstRun == secondRun, "纯函数：同输入两次调用结果相等")

        // ── 三、契约（C-1 裁决 1）：没标 ⟺ speakerId == nil；没标时 ratio 是占位 0、标了必 >0 ──
        // 补强用例（4b/6b）也一起过契约检查：它们同样是产物，没理由豁免
        let all = [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a4b, a6b]
        let unlabeledAreZero = all.filter { $0.speakerId == nil }.allSatisfy { $0.overlapRatio == 0 }
        let labeledArePositive = all.filter { $0.speakerId != nil }.allSatisfy { $0.overlapRatio > 0 }
        let flagAgrees = all.allSatisfy { $0.isLabeled == ($0.speakerId != nil) }
        check(unlabeledAreZero && labeledArePositive && flagAgrees,
              "契约：没标 ⟺ speakerId == nil，没标时 ratio 恒为占位 0",
              "没标 \(all.filter { $0.speakerId == nil }.count) 条 / 标了 \(all.filter { $0.speakerId != nil }.count) 条")

        // ── 四、旧会话兼容 ──
        //
        // 造法：**先编码一份新格式，再把新字段的键删掉**，而不是手写一份 JSON。
        // 手写的 JSON 只证明「我写的这段能解」，删键的证明的是「磁盘上那些真的
        // 旧文件（少的就是这几个键、日期是 deferredToDate 那种数字）能解」——
        // 后者才是要验的东西
        check(legacySessionDecodes(&lines), "旧会话兼容：删掉新键的会话仍解得出、段数不变")

        // 真实文件（可选）：只读解码一条现存会话，把文件名与段数打出来
        if let sessionFile {
            lines.append(contentsOf: SelfTestSessionFile.decodeAndReport(path: sessionFile, check: check))
        }

        lines.append(failed == 0
            ? "✅ 说话人映射自检通过（\(passed) 条）"
            : "❌ 说话人映射自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }

    /// 旧会话兼容用例：编码 → 删掉新加的那些键 → 解码，断言段数与字段回落。
    ///
    /// 断言的是三件事，缺一不可：
    /// ① **读得出来**（不是抛 keyNotFound——那表现为「那条录音从列表里消失」）；
    /// ② **段数不变**（读出来了但丢了几段，是更隐蔽的坏）；
    /// ③ 缺的字段回落到「还没做」而不是别的（`nil` / `false` / `0`）。
    private static func legacySessionDecodes(_ lines: inout [String]) -> Bool {
        let stamp = Date(timeIntervalSince1970: 1_858_464_000.123)
        let session = RecordingSession(
            id: UUID(), startedAt: stamp, updatedAt: stamp,
            parts: [
                RecordingPart(
                    id: UUID(), fileName: "legacy-1.wav", startedAt: stamp,
                    durationMillis: 8100, offsetMillis: 0,
                    segments: [
                        TranscriptSegment(
                            text: "今天我们讲梯度下降。", isFinal: true,
                            startTimeMillis: 0, endTimeMillis: 2600,
                            timestamp: stamp, languages: ["zh-CN"]
                        ),
                        TranscriptSegment(
                            text: "谁来回答一下？", isFinal: true,
                            startTimeMillis: 2600, endTimeMillis: 5400,
                            timestamp: stamp, languages: ["zh-CN"]
                        ),
                    ]
                ),
                RecordingPart(
                    id: UUID(), fileName: nil, startedAt: stamp,
                    durationMillis: 5400, offsetMillis: 8100,
                    segments: [
                        TranscriptSegment(
                            text: "接着讲正则化。", isFinal: true,
                            startTimeMillis: 0, endTimeMillis: 2700,
                            timestamp: stamp, languages: ["zh-CN"]
                        ),
                    ]
                ),
            ],
            title: "旧会话", course: "机器学习"
        )

        let encoder = JSONEncoder()
        guard let encoded = try? encoder.encode(session),
              var root = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any],
              var parts = root["parts"] as? [[String: Any]] else {
            lines.append("  ❌ 旧会话兼容：造不出夹具（编码失败）")
            return false
        }

        // 「旧」= 没有这 6 个键：3 个新字段 + C 包之前就后加的 3 个
        let addedKeys = ["speakerId", "speakerOverlapRatio", "speakerMixed",
                         "questionLevel", "coreQuestion", "qualityGrade"]
        for index in parts.indices {
            guard var segments = parts[index]["segments"] as? [[String: Any]] else { continue }
            for segmentIndex in segments.indices {
                for key in addedKeys { segments[segmentIndex].removeValue(forKey: key) }
            }
            parts[index]["segments"] = segments
        }
        root["parts"] = parts
        guard let legacyData = try? JSONSerialization.data(withJSONObject: root) else {
            lines.append("  ❌ 旧会话兼容：造不出夹具（重序列化失败）")
            return false
        }

        guard let decoded = try? JSONDecoder().decode(RecordingSession.self, from: legacyData) else {
            lines.append("  ❌ 旧会话兼容：旧格式解不出来（正是「那条录音从列表里消失」那个故障）")
            return false
        }

        let countPreserved = decoded.segmentCount == session.segmentCount
        let partsPreserved = decoded.parts.count == session.parts.count
        let fellBack = decoded.parts.flatMap(\.segments).allSatisfy {
            $0.speakerId == nil && $0.speakerOverlapRatio == nil && $0.speakerMixed == false
                && $0.questionLevel == 0 && $0.coreQuestion == nil && $0.qualityGrade == nil
        }
        // 必须存在的字段一个都不能在往返里变形
        let corePreserved = decoded.parts.flatMap(\.segments).map(\.text)
            == session.parts.flatMap(\.segments).map(\.text)
            && decoded.title == "旧会话" && decoded.course == "机器学习"

        lines.append("     旧会话夹具：\(decoded.parts.count) 段录音 · \(decoded.segmentCount) 段转录（缺 \(addedKeys.count) 个键）")
        return countPreserved && partsPreserved && fellBack && corePreserved
    }
}

/// 真实会话文件的只读解码（`--speaker-mapping-selftest --session-file <路径>`）。
///
/// 为什么单独一条路径而不是只靠上面的夹具：夹具是「我自己造的旧格式」，
/// 真实文件是「App 实际写在磁盘上的东西」。两者能同时过，才说明兼容性成立
enum SelfTestSessionFile {

    /// 返回要追加的信息行；断言走 `check`。
    ///
    /// 为什么不让它直接写 `lines`：`check` 已经捕获了那份 `lines`，再传一次
    /// `inout` 就是同一个变量上的重叠访问（Swift 的排他性检查不允许）。
    /// 分成「断言走闭包、信息行返回」最省事，也不会漏打印
    static func decodeAndReport(
        path: String,
        check: (Bool, String, String) -> Void
    ) -> [String] {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            check(false, "真实会话：读得到 \(name)", "读不了这个路径")
            return []
        }
        guard let session = try? JSONDecoder().decode(RecordingSession.self, from: data) else {
            check(false, "真实会话：解得出 \(name)", "解码失败——旧文件读不出来就是「从列表消失」")
            return []
        }

        let segments = session.parts.flatMap(\.segments)
        let labeled = segments.filter { $0.speakerId != nil }.count
        // 段数还要跟 JSON 里实际的段对象个数对一遍：解出来了但丢了几段，
        // 只看 `segments.count` 是看不出来的（那正是「静默丢内容」那个失败形状）
        let jsonSegmentCount = SelfTestSessionFile.segmentObjectCount(in: data)

        let info = [
            "     真实会话 \(name)：\(session.parts.count) 段录音 · 文件里 \(jsonSegmentCount) 段 · 解出 \(segments.count) 段",
            "     已带说话人标签 \(labeled) 段（C 包之前落盘的应当是 0）· 标题「\(session.displayTitle)」",
        ]
        check(jsonSegmentCount == segments.count,
              "真实会话：解出的段数与文件里的一致",
              "文件 \(jsonSegmentCount) / 解出 \(segments.count)")
        // 这条判据是**有条件的**，条件本身也要先证明，不能假定。
        //
        // 写死 `labeled == 0` 是错的：它把「文件里没有 speakerId 这个键」当成
        // 永远成立的前提，而那个前提 C-3 一落地就不成立了——标签会被物化进
        // 现存会话，这条随即变红，且红得没有道理（文件已经不是「旧文件」了）。
        // 核验者 2026-09-24 点出过这一点。
        //
        // 所以判据改成「**文件里真的没有这个键** ⇒ 必须回落到 nil」。这不是放宽：
        // 对缺键的文件断言一字未松，而且现在**多验了一条**——「这个文件确实缺键」
        // 从假定变成了被证明的事实。条件不成立时打印出来，不装作验过了
        let fileHasSpeakerKeys = SelfTestSessionFile.hasSpeakerKeys(in: data)
        check(fileHasSpeakerKeys || labeled == 0,
              "真实会话：旧文件（缺 speakerId 键）的说话人字段回落到「还没做」",
              fileHasSpeakerKeys
                ? "跳过：这个文件已经有 speakerId 键（C-3 之后落盘的）· 带标签 \(labeled) 段"
                : "带标签 \(labeled) 段")
        return info
    }

    /// 这个文件的 segments 里有没有 `speakerId` 这个键。
    /// **看的是原始 JSON，不是解码后的对象**——解码后 nil 既可能是「键不在」也可能是
    /// 「键在但值是 null」，而这两件事对「旧文件」这个判断不是一回事。
    ///
    /// 读不出来时返回 `true`（= 认定为「有键」）。方向是刻意的：证明不了「这是旧文件」
    /// 就不去断言旧文件的回落行为，宁可跳过也不假装验过。读失败本身会在段数那条
    /// 判据上现形（`segmentObjectCount` 返回 -1）
    private static func hasSpeakerKeys(in data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let parts = root["parts"] as? [[String: Any]] else { return true }
        return parts.contains { part in
            ((part["segments"] as? [[String: Any]]) ?? []).contains { $0["speakerId"] != nil }
        }
    }

    /// 数一数 JSON 里 `parts[*].segments[*]` 有多少个元素。取不到返回 -1（好过静默当成 0）
    private static func segmentObjectCount(in data: Data) -> Int {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let parts = root["parts"] as? [[String: Any]] else { return -1 }
        return parts.reduce(0) { total, part in
            total + ((part["segments"] as? [[String: Any]])?.count ?? 0)
        }
    }
}
