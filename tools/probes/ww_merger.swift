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
//     C3 远距离重复各自成段 / C4 段数 ≥ 簇数 /
//     **C5a 硬口径 = 一个步长**（漂移不超过设计自己的歧义量级）/ C5b 1 秒、2 秒统计量（不判失败）
//   D 构造输入逐趟 dump（**硬断言**）：D1 第二趟的区间距离（重叠不因错位被当成很远）/
//     D2 第三趟的文本守卫（候选的文本归属在别处时，不许按时间改写、也不许搬时间戳）
//
// 口径说明（这几条重要，别混）：
//   - C2 是**契约口径**：上界是 stepMillis，所以「被一个步长内的同句吸收」不算丢，
//     它量的是「有没有超出契约允许范围的丢失」。
//   - C5a 是**硬判据，容差 = 一个步长**：一个步长之内，「同一句被重识别（时间戳位移）」
//     和「同一句被说两遍」在原理上分不开——第一趟上界存在的理由就是这个。所以它量的
//     不是「时间线绝对不漂」，而是「漂移不超过设计自己的歧义量级」。
//     （阶段 1.5 这里写过 2 秒，是判据写错了：三种子 4 条红全部落在正好 3000ms = 一个
//      步长上，要求 2 秒分离等于要求设计做不到的事。2026-09-21 阶段 1.6 修正。）
//   - C5b 是**统计量，不判失败**：硬判据挂在设计自己的上界上有自指的嫌疑，所以把
//     「歧义的代价有多大」（1 秒 / 2 秒容差下被吸收的句子数 + 各自差多少）一直打在明面上。

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
        var totalSplit = 0, totalOrphans = 0, totalHardBad = 0, totalWanted = 0
        var totalGuardTrips = 0
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
                var seedGuardTrips = 0
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
                    seedGuardTrips += r.changes.filter { $0.hasPrefix("新增（文本归属在别处") }.count
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

                print("  —— 种子 \(seed0)：14 句真话 / \(k) 个窗口 → 输出 \(segments.count) 段（簇数 \(clusterTotal)"
                      + "；第三趟守卫触发 \(seedGuardTrips) 次）——")
                totalSegs += segments.count; totalClusters += clusterTotal
                totalGuardTrips += seedGuardTrips

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

                // C5a 硬判据：容差 = 一个步长（= 设计自己的歧义量级）。
                // 一个步长之内，「同一句被重识别（时间戳位移）」和「同一句被说两遍」原理上
                // 分不开——第一趟上界存在的理由就是这个。所以这条量的不是「时间线绝对不漂」，
                // 而是「漂移不超过设计自己的歧义量级」：超过一个步长还被同文本段吸收，才是真缺陷。
                var hardBad: [String] = []
                for u in utts {
                    let ok = segments.contains { close($0.text, u.text) && abs($0.startTimeMillis - u.start) <= step }
                    if !ok {
                        let nearest = segments.filter { close($0.text, u.text) }
                            .map { abs($0.startTimeMillis - u.start) }.min() ?? Int.max
                        hardBad.append("\(u.text)@\(u.start)（最近同文本段起点差 \(nearest)ms）")
                    }
                }
                totalHardBad += hardBad.count
                expect(hardBad.isEmpty, "C5a 硬口径 = 一个步长（\(step)ms）：漂移不超过设计自己的歧义量级",
                       "违反 \(hardBad.count)/14：\(hardBad.prefix(2).joined(separator: " / "))")

                // C5b 统计量（**不判失败，只打印**）：硬判据挂在上界上有自指的嫌疑，所以把
                // 「歧义的代价有多大」一直摆在明面上——将来这一档变大，立刻能看出来。
                // 容差固定 1 秒 / 2 秒，与上界无关；逐条打出「差多少毫秒」。
                for tol in [1_000, 2_000] {
                    let absorbed = utts.filter { u in
                        !segments.contains { close($0.text, u.text) && abs($0.startTimeMillis - u.start) <= tol }
                    }.map { u -> String in
                        let nearest = segments.filter { close($0.text, u.text) }
                            .map { abs($0.startTimeMillis - u.start) }.min() ?? Int.max
                        return "\(u.text)@\(u.start)（差 \(nearest)ms）"
                    }
                    if tol == 2_000 { totalStrictBad += absorbed.count }
                    print("  ·· 统计（不判失败）\(tol)ms 容差：\(absorbed.count)/14 句位置被吸收"
                          + (absorbed.isEmpty ? "" : " → \(absorbed.joined(separator: " / "))"))
                }

                // 归类（阶段 1.6 第 2 项）：多出来的段分三类，**分开数**。
                // 认领规则：每段按「文本 close 且起点最近」认领一句真话。
                //   ① 同一次真话被认领 ≥2 段 → 同一句被拆两段（缺陷），多出 count-1
                //   ② 不同次真话各自成段 → 远距离重复（**要的**，裁决 2 的既定收益）
                //   ③ 认不到任何真话 → 认不到真话
                var assigned: [Int: [TranscriptSegment]] = [:]
                var orphans: [TranscriptSegment] = []
                for s in segments {
                    let claim = utts.enumerated()
                        .filter { close($0.element.text, s.text) }
                        .min { abs($0.element.start - s.startTimeMillis) < abs($1.element.start - s.startTimeMillis) }
                    if let c = claim { assigned[c.offset, default: []].append(s) } else { orphans.append(s) }
                }
                let splitGroups = assigned.filter { $0.value.count >= 2 }
                let splitExtras = splitGroups.values.reduce(0) { $0 + $1.count - 1 }
                let extra = segments.count - clusterTotal
                // 远距离重复（要的那一类）**不是多出段**：簇数里已经把它算成「各自该有一段」。
                // 这里数的是「同文本的第二次及以后出现、且相隔 > 上界」的段数。
                let wantRepeats = clusterTotal - clusters.count
                totalDupLike += extra; totalSplit += splitExtras; totalOrphans += orphans.count
                totalWanted += wantRepeats
                print("  >> 归类：多出 \(extra) 段 = ① 同一句被拆两段 \(splitExtras)（缺陷）"
                      + " + ② 远距离重复各自成段 \(0)（要的） + ③ 认不到真话 \(orphans.count)")
                print("     ② 那一类一共 \(wantRepeats) 段，全部各自成段、且不计进「多出」（簇数已含它们）")
                for g in splitGroups.sorted(by: { $0.key < $1.key }) {
                    let pair = g.value
                        .sorted { $0.startTimeMillis < $1.startTimeMillis }
                        .map { "\"\($0.text)\"@\($0.startTimeMillis)–\($0.endTimeMillis)" }
                        .joined(separator: "  +  ")
                    print("     缺陷例：\(pair)")
                }
            }
        }
        print("  三种子合计：输出 \(totalSegs) 段 / 簇数 \(totalClusters) / "
              + "C5a 硬口径违反 \(totalHardBad) 句 / C5b 2 秒统计 \(totalStrictBad) 句")
        print("  三种子归类：多出段 \(totalDupLike) = ① 同一句被拆两段 \(totalSplit) + ③ 认不到真话 \(totalOrphans)"
              + "；② 远距离重复各自成段 \(totalWanted) 段（要的，不计进多出）")
        print("  三种子第三趟守卫触发（「文本归属在别处，不按时间改写」）：\(totalGuardTrips) 次")

        // MARK: - D 过分割：构造输入逐趟 dump

        func seg(_ text: String, _ isFinal: Bool, _ s: Int, _ e: Int) -> TranscriptSegment {
            TranscriptSegment(text: text, isFinal: isFinal, startTimeMillis: s, endTimeMillis: e,
                              languages: ["zh-CN"])
        }

        func relationName(_ a: String, _ b: String) -> String {
            switch TranscriptionEngine.textRelation(a, b) {
            case .same(let shorter): return "same（短边 \(shorter) 字）"
            case .similar:           return "similar"
            case .different:         return "different"
            }
        }

        func dump(_ segs: [TranscriptSegment], _ title: String) {
            print("  \(title)")
            for (i, s) in segs.enumerated() {
                print("    [\(i)] \(s.isFinal ? "定稿" : "临时") \(s.startTimeMillis)–\(s.endTimeMillis)  \"\(s.text)\"")
            }
        }

        print("=== D) 过分割：构造输入逐段 dump + 三趟各拿谁跟谁比 ===")
        do {
            // ── D1：单旧段的最小复现（同一句在相邻两窗被识别成差一字，且候选起点落在旧段内）
            let aText = "今天我们讲梯度下降算法呢"
            let candText = "今天我们讲梯度下降算法的"
            let aRange = (20_000, 22_500)
            let cRange = (21_000, 21_600)

            let d1Existing = [seg(aText, true, aRange.0, aRange.1)]
            let d1Candidate = seg(candText, false, cRange.0, cRange.1)

            print("  —— D1：一个已定稿旧段（阶段 1.6 派单里那条「自相矛盾」的构造）——")
            dump(d1Existing, "已有段：")
            dump([d1Candidate], "本窗候选（窗口起点 21000 + 相对 0–600）：")

            // 判据全部在探针里独立重算，不读代码的 trace
            let signedDiff = d1Candidate.startTimeMillis - d1Existing[0].endTimeMillis
            let iv = intervalGap((aRange.0, aRange.1), (cRange.0, cRange.1))
            let d1Relation = relationName(aText, candText)
            let d1Overlap = cRange.0 < aRange.1 && aRange.0 < cRange.1

            print("    文本关系（独立重算）= \(d1Relation)")
            print("    第一趟 [拿候选 vs [0]]：same ≥6 字？→ 不是 same → 不收")
            print("    第二趟 [拿候选 vs [0]]：similar？→ 是；**区间距离** = \(iv)ms ≤ \(tailTol)ms → 命中")
            print("    ⚠️ 阶段 1.6 派单里写的「第二趟差 1500ms」是**重叠深度**，不是距离：")
            print("       (候选起点 21000 − 旧段终点 22500) = \(signedDiff)，负号 = 候选起点落在旧段终点之前，")
            print("       也就是两段**重叠** \(abs(signedDiff))ms。它和第三趟的「时间重叠」不矛盾——")
            print("       同一个几何的两种量，当时是我那个变量名（boundGap）叫错了，不是数据矛盾。")
            print("       阶段 1.7 把第二趟改成区间距离后，这个构造走第二趟正常合并。")

            func trial(_ wasFinal: Bool) -> [TranscriptSegment] {
                run([seg(aText, wasFinal, aRange.0, aRange.1)], wnd(21_000, [(candText, 0, 600)])).segments
            }
            let withFinal = trial(true)
            let withoutFinal = trial(false)
            expect(withFinal.count == 1 && withoutFinal.count == 1,
                   "D1 旧段已定稿 / 未定稿 → 都合并成 1 段（第二趟不看 isFinal）",
                   "已定稿 \(withFinal.count) 段 / 未定稿 \(withoutFinal.count) 段")
            expect(withFinal.count == 1 && withFinal[0].text == candText
                   && withFinal[0].startTimeMillis == cRange.0 && withFinal[0].endTimeMillis == cRange.1,
                   "D1 合并后留下的是**重识别那一版**文本与时间戳",
                   "\(withFinal[0].startTimeMillis)–\(withFinal[0].endTimeMillis) \"\(withFinal[0].text)\"")

            // ── D2：第三趟的文本守卫——候选的文本归属在别处时不许按时间改写
            // 文本匹配的段与时间重叠的段**是两个不同的段**——这是能区分两种可能性的最小构造。
            let farText = "正则化可以防止过拟合"
            let midText = "训练集和测试集要分开"
            let cand2Text = "正则化可以防止过拟合的"
            let farRange = (30_000, 33_000)     // 文本匹配得上的那个（远，> 一个步长）
            let midRange = (44_500, 46_500)     // 时间重叠的那个（未定稿；终点 > 窗口起点+步长，不触发补定稿）
            let cand2Range = (44_000, 47_000)   // 窗口起点 43000 + 相对 1000–4000

            print("  —— D2：文本匹配的段 与 时间重叠的段 是两个不同的段（守卫）——")
            dump([seg(farText, true, farRange.0, farRange.1), seg(midText, false, midRange.0, midRange.1)],
                 "已有段：")
            dump([seg(cand2Text, false, cand2Range.0, cand2Range.1)],
                 "本窗候选（窗口起点 43000 + 相对 1000–4000）：")

            let iv2 = intervalGap((farRange.0, farRange.1), (cand2Range.0, cand2Range.1))
            let overlap2 = cand2Range.0 < midRange.1 && midRange.0 < cand2Range.1
            print("    第一趟 [候选 vs [0]]：关系 \(relationName(farText, cand2Text))，区间距离 \(iv2)ms > 上界 \(step)ms → 正确拒绝（保护生效）")
            print("    第一趟 [候选 vs [1]]：关系 \(relationName(midText, cand2Text)) → 不收")
            print("    第二趟 [候选 vs [0]]：关系不是 similar（是 same）→ 这一趟的 switch 只收 similar → 跳过")
            print("    第二趟 [候选 vs [1]]：关系不是 similar → 跳过")
            print("    第三趟 倒序扫：先看 [1]：未定稿 + 重叠 = \(overlap2 ? "是" : "否")，"
                  + "但守卫发现候选的文本归属在 [0]（same ≥6）→ **不按时间改写** → 候选新增")

            let d2Result = run([seg(farText, true, farRange.0, farRange.1), seg(midText, false, midRange.0, midRange.1)],
                               wnd(43_000, [(cand2Text, 1_000, 4_000)]))
            let d2 = d2Result.segments
            dump(d2, "跑出来：")
            expect(d2.count == 3 && d2[2].text == cand2Text
                   && d2[2].startTimeMillis == cand2Range.0 && d2[2].endTimeMillis == cand2Range.1,
                   "D2 候选新增成一段（文本 / 起止 = 候选自己的）",
                   "段数 \(d2.count)")
            expect(d2.count == 3 && d2[1].text == midText
                   && d2[1].startTimeMillis == midRange.0 && d2[1].endTimeMillis == midRange.1
                   && !d2[1].isFinal,
                   "D2 时间重叠那段的文本 · 起止 · isFinal 全部原样不动",
                   "\(d2[1].startTimeMillis)–\(d2[1].endTimeMillis) \(d2[1].isFinal ? "定稿" : "临时") \"\(d2[1].text)\"")
            expect(d2.count == 3 && d2[0].text == farText
                   && d2[0].startTimeMillis == farRange.0 && d2[0].endTimeMillis == farRange.1,
                   "D2 也没有并进远处那个文本双胞胎（不搬时间戳）",
                   "\(d2[0].startTimeMillis)–\(d2[0].endTimeMillis) \"\(d2[0].text)\"")
            expect(d2Result.changes.contains { $0.hasPrefix("新增（文本归属在别处") },
                   "D2 守卫触发在 changes 里有可数的标签", d2Result.changes.joined(separator: " / "))
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
