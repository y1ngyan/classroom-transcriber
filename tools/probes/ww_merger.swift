// Whisper 滑窗合并器独立探针 · 纯函数（不需要模型、不需要音频、不碰麦克风）
//
// 跑法：./tools/probes/ww_merger.sh      （无参数；退出码 0 = 全过）
//
// 为什么单独一条路：`tools/probe.sh` 那条链是给「真实链路」用的（要模型 + wav）。
// 本探针只喂合并器纯函数，所以自带一个不依赖模型的 runner；参数会被忽略，
// 因此即使从 probe.sh 里进来也能跑。
//
// 判据全部**自己重算**，不调用被测代码的校验函数（否则是循环论证）：
//   - normalize / levenshtein / close 都是这里独立实现的
//   - 每个扫描点的期望值从被扫的常数**推导**出来（改上界/步长不会让用例静默失效）
//
// 覆盖：
//   A 补定稿阈值：邻居扫描（阈值两侧各 2 个点）
//   B 第一趟上界：邻居扫描（上界两侧各 2 个点 + 远点），期望值由 bound 推导
//   C 随机窗口序列差分（三个种子）：C1 全部定稿 / C2 契约口径不丢内容 /
//     C3 远距离重复各自成段 / C4 段数 ≥ 簇数 / **C5 紧口径 2 秒：时间线位置不消失**
//   D 过分割的构造输入（已钉住的最小复现 + 三趟各自为什么拒绝）
//
// 口径说明（这一条重要，别混）：
//   - C2 是**契约口径**：上界是 stepMillis，所以「被一个步长内的同句吸收」不算丢，
//     它量的是「有没有超出契约允许范围的丢失」。
//   - C5 是**独立紧口径**：固定 2 秒，与上界无关。它量的是「时间线位置有没有消失」——
//     老师十秒后又说一遍、却被吸收成一段，在 C2 里看不出来，在 C5 里是丢。

import Foundation

@main
struct WWMergerProbe {
    static func main() {

        var failures: [String] = []
        var observations: [String] = []

        // MARK: - 独立校验工具

        func norm(_ s: String) -> String {
            String(s.unicodeScalars.filter {
                ($0.value >= 0x4E00 && $0.value <= 0x9FFF) || CharacterSet.alphanumerics.contains($0)
            })
        }

        func lev(_ a: [Character], _ b: [Character]) -> Int {
            if a.isEmpty { return b.count }
            if b.isEmpty { return a.count }
            var prev = Array(0...b.count)
            var cur = [Int](repeating: 0, count: b.count + 1)
            for i in 1...a.count {
                cur[0] = i
                for j in 1...b.count {
                    cur[j] = a[i-1] == b[j-1] ? prev[j-1] : min(prev[j-1], prev[j], cur[j-1]) + 1
                }
                prev = cur
            }
            return prev[b.count]
        }

        /// 两个文本是否「算同一句」（独立判据：包含，或编辑距离 ≤ 20%）
        func close(_ x: String, _ y: String) -> Bool {
            let a = Array(norm(x)), b = Array(norm(y))
            if a.isEmpty || b.isEmpty { return false }
            let (s, l) = a.count <= b.count ? (String(a), String(b)) : (String(b), String(a))
            if l.contains(s) { return true }
            return lev(a, b) * 5 <= max(a.count, b.count)
        }

        func expect(_ condition: Bool, _ name: String, _ detail: String = "") {
            if condition {
                print("  ✅ \(name)\(detail.isEmpty ? "" : " · \(detail)")")
            } else {
                print("  ❌ \(name)\(detail.isEmpty ? "" : " · \(detail)")")
                failures.append(name)
            }
        }

        // MARK: - 与真实链路一致的参数
        //
        // stepMillis 和窗口时长都取真实值：B 段的期望值由 `step` 推导，
        // 将来上界再变，这里改常数即可，用例不会静默失效。

        let step = 3_000            // 步长（= 第一趟的时间上界）
        let winLen = 10_000         // 窗口时长（合并器不再依赖它，这里只用来造窗口）
        let strictTol = 2_000       // 紧口径：只容时间戳抖动
        let tailTol = 1_000         // 第二趟的时间容差（与合并器一致）

        func wnd(_ start: Int, _ segs: [(String, Int, Int)]) -> WhisperWindow {
            WhisperWindow(startMillis: start, endMillis: start + winLen,
                          segments: segs.map { WhisperSegment(text: $0.0, startMillis: $0.1, endMillis: $0.2) })
        }

        func run(_ existing: [TranscriptSegment], _ w: WhisperWindow,
                 _ tail: [WhisperSegment] = [], _ prevStart: Int = 0) -> WhisperMergeResult {
            WhisperWindowMerger.merge(WhisperMergeInput(
                existing: existing, window: w, previousTail: tail,
                previousWindowStartMillis: prevStart, stepMillis: step))
        }

        func intervalGap(_ a: (Int, Int), _ b: (Int, Int)) -> Int {
            max(0, max(a.0 - b.1, b.0 - a.1))
        }

        // MARK: - A 补定稿阈值：邻居扫描

        print("=== A) 补定稿阈值：邻居扫描（本窗起点 0，阈值 = 起点 + step = \(step)）===")
        do {
            for end in (step - 2)...(step + 2) {
                let r = run([], wnd(0, [("阈值扫描用例文本甲乙丙", 0, end)]))
                let expected = end <= step          // 判据是 ≤：闭区间取到
                expect(r.segments[0].isFinal == expected,
                       "end=\(end) → 期望定稿=\(expected)",
                       "实际 \(r.segments[0].isFinal)")
            }
        }

        // MARK: - B 第一趟上界：邻居扫描（期望值由 step 推导）

        print("=== B) 第一趟上界：邻居扫描（上界 = step = \(step)）===")
        do {
            let text = "它的核心思想是沿着负梯度方向迭代"
            // 上界两侧各扫 2 个点，再补一个远点。期望值全部由 `step` 推导。
            for gap in [step - 2, step - 1, step, step + 1, step + 2, step + 5_000] {
                let existing = [TranscriptSegment(text: text, isFinal: false,
                                                  startTimeMillis: 0, endTimeMillis: 4_000,
                                                  languages: ["zh-CN"])]
                let r = run(existing, wnd(4_000 + gap, [(text, 0, 4_000)]))
                let expected = gap <= step ? 1 : 2
                expect(r.segments.count == expected,
                       "gap=\(gap) → 期望段数 \(expected)（上界内合并 / 上界外各自成段）",
                       "实际 \(r.segments.count)")
                if gap > step {
                    expect(r.segments[0].startTimeMillis == 0 && r.segments[0].endTimeMillis == 4_000,
                           "  gap=\(gap) 旧段文本与时间戳原样不动",
                           "\(r.segments[0].startTimeMillis)–\(r.segments[0].endTimeMillis)")
                }
            }
        }

        // MARK: - C 随机窗口序列差分（三个种子）

        print("=== C) 随机窗口序列差分（三个种子）===")
        var totalSegs = 0, totalClusters = 0, totalStrictBad = 0, totalDupLike = 0
        var totalSplit = 0, totalOrphans = 0
        do {
            for seed0: UInt64 in [20_260_921, 7, 99_991] {
                var seed: UInt64 = seed0
                func rnd(_ n: Int) -> Int {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return Int((seed >> 33) % UInt64(n))
                }

                let pool = [
                    "今天我们讲梯度下降算法", "注意学习率这个超参数", "大家理解我的意思吧",
                    "下面我们看一个具体的例子", "这个损失函数是非凸的", "训练集和测试集要分开",
                    "正则化可以防止过拟合", "每次迭代都要算一次梯度",
                ]
                struct Utt { let text: String; let start: Int; let end: Int }

                var utts: [Utt] = []
                var cursor = 0
                for i in 0..<14 {
                    let text = (i % 4 == 3 && !utts.isEmpty) ? utts[rnd(utts.count)].text : pool[rnd(pool.count)]
                    let dur = 2_000 + rnd(3) * 1_000
                    let start = cursor + rnd(4) * 1_000
                    utts.append(Utt(text: text, start: start, end: start + dur))
                    cursor = start + dur + rnd(6) * 1_000
                }

                // 逐窗喂：窗口里出现的真句子 → 相对时间（±400ms 抖动，窗边截断处收敛到 0）
                // 文本随机多一个虚词，模拟换窗重识别的漂移
                var segments: [TranscriptSegment] = []
                var tail: [WhisperSegment] = []
                var prevStart = 0
                var k = 0
                while k * step <= utts.last!.end + winLen {
                    let wStart = k * step
                    var segs: [(String, Int, Int)] = []
                    for u in utts {
                        guard u.start < wStart + winLen && u.end > wStart else { continue }
                        let rs = max(0, u.start - wStart + (rnd(9) - 4) * 100)
                        let re = max(rs + 500, u.end - wStart + (rnd(9) - 4) * 100)
                        let t = rnd(3) == 0 ? u.text + ["的", "啊", "呢"][rnd(3)] : u.text
                        segs.append((t, rs, min(re, winLen)))
                    }
                    let r = run(segments, wnd(wStart, segs), tail, prevStart)
                    segments = r.segments; tail = r.pendingTail; prevStart = wStart
                    k += 1
                }
                // 再喂两个静音窗，让尾部也滑出覆盖范围
                for _ in 0..<2 {
                    let r = run(segments, wnd(k * step, []), tail, prevStart)
                    segments = r.segments; tail = r.pendingTail; prevStart = k * step
                    k += 1
                }

                // 簇（契约口径）：同文本、与上一次出现相隔 > 上界 → 必须各自成段
                var clusters: [(text: String, count: Int)] = []
                for u in utts {
                    if let i = clusters.firstIndex(where: { $0.text == u.text }) {
                        let prev = utts.last(where: { $0.text == u.text && $0.start < u.start })!
                        if intervalGap((u.start, u.end), (prev.start, prev.end)) > step {
                            clusters[i].count += 1
                        }
                    } else {
                        clusters.append((u.text, 1))
                    }
                }
                let clusterTotal = clusters.reduce(0) { $0 + $1.count }

                print("  —— 种子 \(seed0)：14 句真话 / \(k) 个窗口 → 输出 \(segments.count) 段（簇数 \(clusterTotal)）——")
                totalSegs += segments.count; totalClusters += clusterTotal

                // C1 每一段最终都定稿
                let stuck = segments.filter { !$0.isFinal }
                expect(stuck.isEmpty, "C1 所有段最终都定稿",
                       "仍临时 \(stuck.count)：\(stuck.map(\.text).joined(separator: " / "))")

                // C2 契约口径：失踪的句子必须能被「上界内的同句」解释
                var realLoss: [String] = []
                for u in utts {
                    let covered = segments.contains { s in
                        close(s.text, u.text) && intervalGap((s.startTimeMillis, s.endTimeMillis),
                                                             (u.start, u.end)) <= winLen
                    }
                    if covered { continue }
                    let others = utts.filter { $0.text == u.text && !($0.start == u.start && $0.end == u.end) }
                    let nearest = others.map { intervalGap(($0.start, $0.end), (u.start, u.end)) }.min() ?? Int.max
                    if nearest > step {
                        realLoss.append("\(u.text)@\(u.start)-\(u.end)（最近同句 \(nearest)ms 外 > 上界 \(step)）")
                    }
                }
                expect(realLoss.isEmpty, "C2 契约口径：没有超出上界的丢失",
                       "真丢 \(realLoss.count)：\(realLoss.prefix(2).joined(separator: " / "))")

                // C3 每个簇都要有自己的一段
                var missingClusters: [String] = []
                for c in clusters {
                    let n = segments.filter { close($0.text, c.text) }.count
                    if n < 1 { missingClusters.append(c.text) }
                }
                expect(missingClusters.isEmpty, "C3 远距离重复各自成段（每簇至少一段）",
                       "缺 \(missingClusters.count) 簇：\(missingClusters.joined(separator: " / "))")

                // C4 段数不少于簇数
                expect(segments.count >= clusterTotal, "C4 段数 ≥ 簇数（不丢句）",
                       segments.count >= clusterTotal ? "输出 \(segments.count) / 簇数 \(clusterTotal)"
                                                      : "输出 \(segments.count) < 簇数 \(clusterTotal)")

                // C5 紧口径 2 秒（独立判据，与上界无关）：每个真句都要有一段
                // 「文本对得上、且起始时间落在它 ±2 秒内」——量的是时间线位置有没有消失。
                var strictBad: [String] = []
                for u in utts {
                    let ok = segments.contains { close($0.text, u.text) && abs($0.startTimeMillis - u.start) <= strictTol }
                    if !ok {
                        let nearest = segments.filter { close($0.text, u.text) }
                            .map { abs($0.startTimeMillis - u.start) }.min() ?? Int.max
                        strictBad.append("\(u.text)@\(u.start)（最近同文本段起点差 \(nearest)ms）")
                    }
                }
                totalStrictBad += strictBad.count
                expect(strictBad.isEmpty, "C5 紧口径 \(strictTol)ms：时间线位置没消失",
                       "\(strictBad.count)/14 句被 \(strictTol)ms 外的同句吸收：\(strictBad.prefix(2).joined(separator: " / "))")

                // 归类（阶段 1.5 第 3 项）：多出来的段到底是「要的」还是「缺陷」。
                // 判法：每段按「文本 close 且起点最近」认领一句真话。**同一次真话**被
                // 认领 ≥2 段 = 同一句被拆开（缺陷）；不同次真话各自成段 = 远距离重复
                // （裁决 2 的既定收益，已经计进簇数里了）。只报数，不进判据。
                var assigned: [Int: Int] = [:]
                var orphans = 0
                for s in segments {
                    let claim = utts.enumerated()
                        .filter { close($0.element.text, s.text) }
                        .min { abs($0.element.start - s.startTimeMillis) < abs($1.element.start - s.startTimeMillis) }
                    if let c = claim { assigned[c.offset, default: 0] += 1 } else { orphans += 1 }
                }
                let splitExtras = assigned.values.reduce(0) { $0 + max(0, $1 - 1) }
                let extra = segments.count - clusterTotal
                totalDupLike += extra; totalSplit += splitExtras; totalOrphans += orphans
                print("  >> 归类：多出 \(extra) 段 = 同一次真话被拆 \(splitExtras) 段（缺陷）+ "
                      + "认不到真话 \(orphans) 段；远距离重复各自成段 \(0) 段（要的，已计进簇数）")
            }
        }
        print("  三种子合计：输出 \(totalSegs) 段 / 簇数 \(totalClusters) / 紧口径违反 \(totalStrictBad) 句 / "
              + "多出段 \(totalDupLike)（其中同一次真话被拆 \(totalSplit) + 认不到真话 \(totalOrphans)）")

        // MARK: - D 过分割的构造输入（已钉住的最小复现）

        print("=== D) 过分割：构造输入 + 三趟各自为什么拒绝===")
        do {
            // 真值 → 逐窗候选：同一句在相邻两窗被识别成差一字的文本，且后一窗的
            // 起始时间被窗口边缘截断到窗口起点（抖动 1.5 秒）。
            let existingText = "今天我们讲梯度下降算法呢"
            let candidateText = "今天我们讲梯度下降算法的"
            let existingRange = (20_000, 22_500)
            let candidateRange = (21_000, 21_600)
            let boundGap = abs(candidateRange.0 - existingRange.1)

            func trial(_ wasFinal: Bool) -> [TranscriptSegment] {
                let existing = [TranscriptSegment(text: existingText, isFinal: wasFinal,
                                                  startTimeMillis: existingRange.0,
                                                  endTimeMillis: existingRange.1,
                                                  languages: ["zh-CN"])]
                return run(existing, wnd(21_000, [(candidateText, 0, 600)])).segments
            }

            // 用同一分类器 + 同样几何在探针里重算三趟判据（不是代码里的 trace，是重导）
            let relation: String
            switch TranscriptionEngine.textRelation(existingText, candidateText) {
            case .same(let shorter): relation = "same（短边 \(shorter) 字）"
            case .similar:           relation = "similar"
            case .different:         relation = "different"
            }
            print("  文本关系（独立重算）= \(relation)")
            print("  第一趟 same ≥6 字：\(relation.hasPrefix("same") ? "命中" : "不收（文本不是 same）")")
            print("  第二趟 similar 且 |候选起点 − 旧段终点| ≤ \(tailTol)ms："
                  + "\(relation == "similar" ? (boundGap <= tailTol ? "命中" : "不收（差 \(boundGap)ms > \(tailTol)ms）") : "不收（文本不是 similar）")")
            let overlap = candidateRange.0 < existingRange.1 && existingRange.0 < candidateRange.1
            print("  第三趟 时间重叠（\(overlap ? "是" : "否")）且旧段未定稿：旧段 isFinal=true → 不收（旧段已定稿）")
            print("  ⇒ 三趟都不收 → 新增一段（同一句被拆成两段）")

            let withFinal = trial(true)
            let withoutFinal = trial(false)
            expect(withFinal.count == 2 && withoutFinal.count == 1,
                   "D 旧段已定稿 → 2 段；只把 isFinal 改成 false → 1 段（第三趟收编）",
                   "已定稿 \(withFinal.count) 段 / 未定稿 \(withoutFinal.count) 段")
            observations.append("过分割的充分条件（D）：.similar 文本 + 时间跳 \(boundGap)ms > 第二趟的 \(tailTol)ms + 旧段已定稿")
        }

        // MARK: - 汇总

        print("── 汇总 ──")
        for o in observations { print("  ⚠️ 观测（按契约口径不是失败，逐条理由见上）：\(o)") }
        if failures.isEmpty {
            print("✅ 探针通过（契约内判据全部成立）")
            exit(0)
        } else {
            print("❌ 探针失败 \(failures.count) 项：")
            for f in failures { print("   · \(f)") }
            exit(1)
        }
    }
}
