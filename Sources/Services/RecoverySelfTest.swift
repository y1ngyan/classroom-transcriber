import AVFoundation
import CryptoKit
import Foundation

/// `--recovery-selftest`：P9-1 三件事的离线自检——
/// ① WAV 头修复；② 录制草稿写入 → 模拟强杀 → 恢复；③ 误报为零。
///
/// **全程不录音、不发声**（用户明令：真麦克风必须真人）。音频全部由
/// `WAVRecorder` 写进临时目录的**静音**缓冲里——它写文件头和数据块，
/// 喇叭一动不动。所有读写都落在自己造的临时目录，**用户真实的
/// `sessions/`、`recordings/`、`drafts/` 一个字节都不碰**。
///
/// 「模拟强杀」的构造方式：`WAVRecorder.drainForTesting()` 把已入队的
/// 写块排空，但**不回填头、不关闭**——那正是进程被 kill 那一刻磁盘上的样子。
/// 走 `finish()` 就不是中途了。
@MainActor
enum RecoverySelfTest {

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    static func run() -> SelfTestResult {
        var lines: [String] = ["崩溃恢复自检（离线 · 临时目录 · 不录音、不发音）"]
        var passed = 0
        var failed = 0

        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-recovery-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        lines.append("")
        lines.append("─── A. WAV 头修复 ───")
        checkHeaderRepair(root: root, check: check)

        lines.append("")
        lines.append("─── B. 草稿 → 强杀 → 恢复 ───")
        checkDraftRecovery(root: root, check: check)

        lines.append("")
        lines.append("─── C. 误报为零 ───")
        checkNoFalsePositives(root: root, check: check)

        lines.append("")
        lines.append("─── D. 探针目录闸门 ───")
        checkProbeDirectoryGate(root: root, check: check)

        lines.append("")
        lines.append("总结：\(failed == 0 ? "✅ 全部通过" : "❌ 有失败")（\(passed) 过 / \(failed) 败）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }

    // MARK: - A. WAV 头修复

    private static func checkHeaderRepair(root: URL, check: (Bool, String, String) -> Void) {
        let dir = root.appendingPathComponent("wav", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ① 正常的：头是对的，修复工具**不该报它**
        let good = dir.appendingPathComponent("good.wav")
        writeSilentWav(good, seconds: 1.5, finish: true)

        // ② 过期头：写到 2.3 秒就不管了——正是进程在这一秒里被杀的样子
        let stale = dir.appendingPathComponent("stale.wav")
        writeSilentWav(stale, seconds: 2.3, finish: false)

        // ③ 零头：44 字节零 + PCM（旧版零占位遗留）
        let zero = dir.appendingPathComponent("zero.wav")
        writeZeroHeaderWav(zero, seconds: 1.0)

        // ④ 根本不是音频：UTF-8 文本被存成了 .wav（实测库里真有一个）
        let text = dir.appendingPathComponent("text.wav")
        try? Data("(词条名:梯度下降)\n(词条制作:Claude)\n".utf8).write(to: text)

        // ⑤ 空录音：44 字节全零，**一个字节的 PCM 都没有**（实测库里真有一个）。
        // 和 ③ 的区别只在后半段有没有 PCM——所以要单独摆一个文件把它钉住
        let empty = dir.appendingPathComponent("empty.wav")
        try? Data(repeating: 0, count: WAVHeaderRepair.headerSize).write(to: empty)

        let scans = WAVHeaderRepair.scan(directory: dir)
        let byName = Dictionary(uniqueKeysWithValues: scans.map { ($0.fileName, $0) })

        check(byName["good.wav"] == nil, "正常的 wav **一条都不报**（一个字节也不许动）",
              "报了 \(scans.count) 条：\(scans.map(\.fileName).sorted())")

        // 过期头的原值与实际值都要对得上：2.3 秒写了 220800 字节，
        // 头停在 2 秒（192000）——`headerRefreshBytes` = 96000 的整数倍
        if case let .staleSizes(declared, actual)? = byName["stale.wav"]?.defect {
            check(declared == 192_000 && actual == 220_800,
                  "过期头：原值 / 实际值都读出来了",
                  "头声明 \(declared)，实际 \(actual)")
        } else {
            check(false, "过期头：应当报 .staleSizes", "\(String(describing: byName["stale.wav"]?.defect))")
        }
        if case .zeroHeader? = byName["zero.wav"]?.defect {
            check(true, "零头：认出「前 44 字节全零」这个签名", "已认得")
        } else {
            check(false, "零头：应当报 .zeroHeader", "\(String(describing: byName["zero.wav"]?.defect))")
        }
        if case .foreign? = byName["text.wav"]?.defect {
            check(true, "文本文件：**拒绝修复**", "判成 foreign")
        } else {
            check(false, "文本文件：应当拒绝", "\(String(describing: byName["text.wav"]?.defect))")
        }
        if case .emptyRecording? = byName["empty.wav"]?.defect {
            check(true, "空录音：**单独一档**（不混进零头里）", "判成 emptyRecording")
        } else {
            check(false, "空录音：应当判成 emptyRecording",
                  "\(String(describing: byName["empty.wav"]?.defect))")
        }
        check(byName["empty.wav"] != nil,
              "空录音**仍然出现在报告里**（可见——用户有权看见，然后自己决定删不删）",
              "在 \(scans.count) 条报告里")
        check(byName["zero.wav"]?.defect.isRepairable == true,
              "有 PCM 的零头**不受影响**，照旧可修（不能一刀切）",
              "zero.wav 可修")

        // ── 分类层：`isRepairable` 自己必须被钉死 ──
        //
        // 三个生产调用点决定「给不给用户修」靠的就是这个属性
        // （`RecordingsStore.recover` 的两处 guard、`--wav-repair` 的可修计数、
        // `RecoveryScan` 的恢复前提示）。**只钉执行层是不够的**：P9-1b 之前，
        // 把 `.foreign` 也改成返回 true，自检照样全绿——因为下面那个
        // `where isRepairable` 会因为 apply 抛错（被 `try?` 吞掉）而计数不变。
        // 所以这里直接对着属性本身断言，任一档被翻转都必须变红
        let flags = [
            WAVHeaderRepair.Defect.staleSizes(declaredDataBytes: 1, actualDataBytes: 2).isRepairable,
            WAVHeaderRepair.Defect.zeroHeader(actualDataBytes: 96_000).isRepairable,
            WAVHeaderRepair.Defect.emptyRecording(actualDataBytes: 0).isRepairable,
            WAVHeaderRepair.Defect.foreign(reason: "x").isRepairable,
        ]
        check(flags == [true, true, false, false],
              "分类层：四档的 `isRepairable` 逐个钉死（任一档翻转都得变红）",
              "过期=\(flags[0]) 零头=\(flags[1]) 空录音=\(flags[2]) 非音频=\(flags[3])")

        // 而且要**能分辨**：四档的说法互不相同，改一档不会被另一档的文案盖住
        let notes = [
            WAVHeaderRepair.Defect.staleSizes(declaredDataBytes: 1, actualDataBytes: 2).userNote,
            WAVHeaderRepair.Defect.zeroHeader(actualDataBytes: 96_000).userNote,
            WAVHeaderRepair.Defect.emptyRecording(actualDataBytes: 0).userNote,
            WAVHeaderRepair.Defect.foreign(reason: "x").userNote,
        ]
        check(Set(notes).count == 4, "分类层：四档给用户看的说法互不相同",
              "\(Set(notes).count) 种")

        // ── 判据的牙齿：修之前读出来是错的，修之后是对的 ──
        let staleBefore = durationSeconds(stale)
        let goodDigestBefore = digest(good)
        let staleAudioBefore = payloadDigest(stale)
        let zeroAudioBefore = payloadDigest(zero)

        var outcomes: [WAVHeaderRepair.Outcome] = []
        for inspection in scans where inspection.defect.isRepairable {
            if let outcome = try? WAVHeaderRepair.apply(inspection) { outcomes.append(outcome) }
        }

        check(outcomes.count == 2, "只对**可修的**那条动手", "修了 \(outcomes.count) 条（期望 2）")
        check(outcomes.allSatisfy { $0.lines.contains { $0.contains("→") } },
              "每一处都打印了「原值 → 新值」",
              "\(outcomes.first?.lines.count ?? 0) 行输出")

        let staleAfter = durationSeconds(stale)
        check(abs((staleBefore ?? 0) - 2.0) < 0.01, "修之前：过期头让时长读错",
              "\(staleBefore.map { String(format: "%.3f", $0) } ?? "打不开") 秒（真实 2.300）")
        check(abs((staleAfter ?? 0) - 2.3) < 0.01, "修之后：时长对了",
              "\(staleAfter.map { String(format: "%.3f", $0) } ?? "打不开") 秒")

        check(durationSeconds(zero) != nil, "修之前：零头文件**根本打不开**",
              "\(durationSeconds(zero).map { String(format: "%.3f", $0) } ?? "打不开")")
        if let file = try? AVAudioFile(forReading: zero) {
            check(file.processingFormat.sampleRate == 48000,
                  "零头修完：假设的采样率如实生效（48000）",
                  "\(Int(file.processingFormat.sampleRate))Hz · \(Int(file.processingFormat.channelCount)) 声道")
        } else {
            check(false, "零头修完：应当能打开", "打不开")
        }

        // ── 音频一个字节都不许动 ──
        check(digest(good) == goodDigestBefore, "正常 wav 的 sha256 前后一致", "逐字节未变")
        check(payloadDigest(stale) == staleAudioBefore && payloadDigest(zero) == zeroAudioBefore,
              "修过的两条：**第 44 字节之后的 PCM 逐字节未变**",
              "只重写了头")

        // ── 拒绝的那两条必须**真的没被动过** ──
        let textBefore = digest(text)
        let emptyBefore = digest(empty)
        if let inspection = scans.first(where: { $0.fileName == "text.wav" }) {
            let threw = (try? WAVHeaderRepair.apply(inspection)) == nil
            check(threw, "对不可修的调用 apply **抛错**而不是照修", "拒绝")
        }
        if let inspection = scans.first(where: { $0.fileName == "empty.wav" }) {
            let threw = (try? WAVHeaderRepair.apply(inspection)) == nil
            check(threw, "对空录音 apply **抛错**（不是给它编一个 0 秒的头）", "拒绝")
        }
        check(digest(text) == textBefore, "被拒绝的文件一个字节没动", "逐字节未变")
        check(digest(empty) == emptyBefore, "空录音一个字节没动（可见 ≠ 可以动它）", "逐字节未变")
    }

    // MARK: - B. 草稿 → 强杀 → 恢复

    private static func checkDraftRecovery(root: URL, check: (Bool, String, String) -> Void) {
        let sessions = root.appendingPathComponent("b-sessions", isDirectory: true)
        let recordings = root.appendingPathComponent("b-recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)

        // 音频：写到 2.3 秒**不 finish**——强杀现场，头还是过期的
        let wav = recordings.appendingPathComponent("课堂-20260928-090000.wav")
        writeSilentWav(wav, seconds: 2.3, finish: false)

        let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let segments = [
            TranscriptSegment(text: "今天讲梯度下降。", isFinal: true,
                              startTimeMillis: 0, endTimeMillis: 1_200,
                              timestamp: startedAt, languages: ["zh-CN"]),
            TranscriptSegment(text: "学习率太大会震荡。", isFinal: true,
                              startTimeMillis: 1_200, endTimeMillis: 2_000,
                              timestamp: startedAt, languages: ["zh-CN"]),
            TranscriptSegment(text: "谁来回答一下？", isFinal: true,
                              startTimeMillis: 2_000, endTimeMillis: 2_300,
                              timestamp: startedAt, languages: ["zh-CN"]),
        ]
        let draft = RecordingDraft(
            id: UUID(), targetSessionID: nil,
            recordingFileName: wav.lastPathComponent,
            startedAt: startedAt, durationMillis: 2_300,
            segments: segments, savedAt: startedAt
        )

        // 写草稿 = 录制途中落的那一份。写完之后**什么都不做**，
        // 直接换一个 store 实例读同一批目录——那就是「进程没了、App 重启」
        let writer = RecordingsStore(directory: sessions, recordingsDirectory: recordings)
        writer.saveDraft(draft)
        let draftPath = writer.draftsDirectory.appendingPathComponent("\(draft.id.uuidString).json")
        check(FileManager.default.fileExists(atPath: draftPath.path),
              "草稿落在盘上（模拟强杀前的最后一秒）", draftPath.lastPathComponent)

        // ── 重启 ──
        let store = RecordingsStore(directory: sessions, recordingsDirectory: recordings)
        let found = store.recoveryItems
        check(found.count == 1, "重启后扫出 1 条「未完成」", "扫到 \(found.count) 条")
        guard let item = found.first else { return }
        check(item.kind == .recoverableDraft, "分类成「有草稿可恢复」", "\(item.kindLabel)")
        check(item.segmentCount == segments.count && item.durationMillis == 2_300,
              "草稿里的段数与时长都对得上",
              "\(item.segmentCount) 段 · \(item.durationMillis.map(String.init) ?? "nil")ms")
        check(item.startedAt == startedAt, "开录时间保住了", "\(item.startedAt ?? .distantPast)")
        // 崩溃留下的头是过期的。**这件事必须在用户点「恢复」之前就说出来**，
        // 不能等点了才发现音频被动过
        check(item.headerDefect != nil && item.headerRepairNote != nil,
              "过期头在**恢复之前**就告诉了用户",
              item.headerRepairNote ?? "（没说）")

        // ── 恢复 ──
        store.recover(item)

        let session = store.summaries.first.flatMap { store.session(id: $0.id) }
        check(session != nil, "恢复之后有了一条正式会话", "\(store.summaries.count) 条")
        guard let session else { return }
        check(session.parts.count == 1, "一个片段", "\(session.parts.count)")
        check(session.parts.first?.fileName == wav.lastPathComponent,
              "片段指着那段音频", session.parts.first?.fileName ?? "nil")
        // **逐字段相等**：恢复不许改内容（照 C-3-2 那条判据的范式）
        check(session.parts.first?.segments == segments,
              "段落**逐字段相等**（恢复不改内容）",
              "\(session.parts.first?.segments.count ?? 0) 段")
        check(session.parts.first?.durationMillis == 2_300,
              "片段时长等于草稿里记的", "\(session.parts.first?.durationMillis ?? -1)ms")

        // 音频真的能用，而且**整段都在**。不修头的话这里会读成 2.000 秒——
        // 崩溃留下的过期头会让尾部最多 1 秒对任何读者都不存在，
        // 而恢复正是用户明确说「把这段录音要回来」的那一刻
        check(abs((durationSeconds(wav) ?? 0) - 2.3) < 0.01,
              "音频读得出来、**时长与草稿一致**（恢复顺带修好了过期头）",
              "\(durationSeconds(wav).map { String(format: "%.3f", $0) } ?? "打不开") 秒")
        check(recordedBytes(wav) == 220_800, "音频字节数与时长自洽",
              "\(recordedBytes(wav)) 字节")
        check(store.recoveryNotes.contains { $0.contains("→") && $0.contains("data 长度") },
              "改了什么、原值是什么，**记账记下来了**",
              "\(store.recoveryNotes.filter { $0.contains("→") }.count) 行带原值")

        // 草稿文件必须消失，否则重启后又会冒出一条「未完成」
        check(!FileManager.default.fileExists(atPath: draftPath.path),
              "扶正之后草稿文件被移除", "不留重复入口")
        check(store.recoveryItems.isEmpty, "恢复完再扫：空了",
              "\(store.recoveryItems.count) 条")
    }

    // MARK: - C. 误报为零

    private static func checkNoFalsePositives(root: URL, check: (Bool, String, String) -> Void) {
        let sessions = root.appendingPathComponent("c-sessions", isDirectory: true)
        let recordings = root.appendingPathComponent("c-recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)

        // 一条**正常录完**的会话，音频也在
        writeSilentWav(recordings.appendingPathComponent("正常.wav"), seconds: 1.0, finish: true)
        let store = RecordingsStore(directory: sessions, recordingsDirectory: recordings)
        let normal = RecordingSession(
            id: UUID(), startedAt: Date(), updatedAt: Date(),
            parts: [RecordingPart(
                id: UUID(), fileName: "正常.wav", startedAt: Date(),
                durationMillis: 1_000, offsetMillis: 0,
                segments: [TranscriptSegment(text: "正常的一句", isFinal: true,
                                             startTimeMillis: 0, endTimeMillis: 900,
                                             timestamp: Date(), languages: ["zh-CN"])]
            )]
        )
        store.save(normal)
        store.refreshRecovery()
        check(store.recoveryItems.isEmpty,
              "干净库：**一条都不报**（把正常录音标成「未完成」比漏报更糟）",
              "报了 \(store.recoveryItems.count) 条")

        // 只剩音频的遗留（本机那 41 个的来源）：**要看得见，但不算「可恢复」**
        writeSilentWav(recordings.appendingPathComponent("孤儿.wav"), seconds: 1.0, finish: true)
        store.refreshRecovery()
        let orphans = store.recoveryItems
        check(orphans.count == 1 && orphans.first?.kind == .audioOnly,
              "孤儿音频：看得见，但分类成「无会话的录音」而不是「未完成」",
              "\(orphans.first?.kindLabel ?? "无") · \(orphans.count) 条")
        check(orphans.first?.isRecoverable == false,
              "孤儿音频**不给「恢复」这个动作**（没有草稿可扶正）",
              "isRecoverable=false")
        check(orphans.first?.durationMillis == 1_000,
              "孤儿音频的时长读得出来", "\(orphans.first?.durationMillis ?? -1)ms")

        // 上一条正常会话**依然不许出现在报告里**
        check(!orphans.contains { $0.fileName == "正常.wav" },
              "加了孤儿之后，正常会话仍然不被点名", "零误报")

        // ── 造过脏数据 → 报告点名；干净的一条都不许被冤枉（误报同样是 bug）──
        let before = digestTree(recordings)
        store.refreshRecovery()
        check(digestTree(recordings) == before,
              "恢复扫描是**只读**的：扫前扫后每个文件 sha256 一致",
              "\(before.count) 个文件")
        check(!store.recoveryItems.isEmpty, "扫描确实动了（不是空转）",
              "\(store.recoveryItems.count) 条")
    }

    // MARK: - D. 探针目录闸门

    /// `--recovery-crash-probe` 会**删掉** `--dir` 下的 `sessions/` 和
    /// `recordings/` 再往里写合成内容，所以它必须有闸。这条自检直接钉那个
    /// 纯函数——**闸门自己要是没人验过，那它就不算闸门**。
    ///
    /// 全程只做路径运算，**一个文件都不碰**（尤其不碰真实库）。
    private static func checkProbeDirectoryGate(root: URL, check: (Bool, String, String) -> Void) {
        let library = RecordingStorage.libraryRoot

        func rejects(_ url: URL, _ name: String) {
            let reason = RecordingStorage.probeDirectoryRejection(url)
            check(reason != nil, name, reason.map { "拒绝：\($0.prefix(40))…" } ?? "❌ 放行了")
        }
        func allows(_ url: URL, _ name: String) {
            let reason = RecordingStorage.probeDirectoryRejection(url)
            check(reason == nil, name, reason ?? "放行")
        }

        rejects(library, "真实库根被拒（探针会删掉它下面的 sessions/ 和 recordings/）")
        rejects(library.appendingPathComponent("recordings"), "真实库的 recordings/ 被拒")
        rejects(library.appendingPathComponent("sessions/drafts"), "真实库的深层子目录也被拒")
        // 带 `..` 的写法绕不过去：先标准化再比，不是字符串前缀匹配
        rejects(library.appendingPathComponent("../ClassroomTranscriber/recordings"),
                "带 `..` 的路径绕不过去")

        // **符号链接别名绕不过去**：这条才是真正钉住「先解析再比」的那条判据
        // ——上面那条 `..` 在两种实现下都会通过，钉不住任何东西。
        // 造一个指向真实库的软链（在自检自己的临时目录里，跑完随目录一起没），
        // 从别名调进去必须照样被拒；不解析符号链接的实现会在这里放行
        let alias = root.appendingPathComponent("d-alias", isDirectory: true)
        try? FileManager.default.removeItem(at: alias)
        try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: library)
        if (try? alias.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            rejects(alias, "指向真实库的符号链接别名被拒（闸门先解析再比，不是字符串前缀）")
            rejects(alias.appendingPathComponent("recordings"), "别名 + 子目录同样被拒")
        } else {
            check(false, "建不出符号链接别名，这条判据没跑成", "createSymbolicLink 失败")
        }
        // 反向包含：把真实库包在里面的祖先目录，同样拒绝
        rejects(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                "把真实库包在里面的祖先目录也被拒")

        let scratch = root.appendingPathComponent("d-gate", isDirectory: true)
        allows(scratch, "临时目录放行")
        allows(scratch.appendingPathComponent("deep/deeper"), "临时目录的深层也放行")
        // 临时目录真实路径在 `/private/var/...` 下。不解析符号链接的话，
        // `/var/...` 和 `/private/var/...` 会被当成两个地方——这里两种写法都要放行
        allows(URL(fileURLWithPath: "/private" + scratch.path), "符号链接的另一种写法同样放行")
        // 不该顺手把无辜的路也拒了：闸门只认「和真实库有包含关系」这一条
        allows(URL(fileURLWithPath: "/tmp"), "/tmp 放行（闸门不是「除白名单外全拒」）")
    }

    // MARK: - 夹具

    /// 写一段**静音**的 wav。`finish: false` = 模拟强杀（头不回填、文件不关闭）
    private static func writeSilentWav(_ url: URL, seconds: Double, finish: Bool) {
        guard let recorder = WAVRecorder(url: url, sampleRate: 48_000, channels: 1) else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(48_000 / 10)   // 每次 0.1 秒
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        var written = 0.0
        while written < seconds - 1e-9 {
            recorder.append(buffer)
            written += 0.1
        }
        if finish {
            recorder.finish()
        } else {
            recorder.drainForTesting()
        }
    }

    /// 44 字节零 + 静音 PCM——旧版 `WAVRecorder` 零占位的指纹
    private static func writeZeroHeaderWav(_ url: URL, seconds: Double) {
        var data = Data(repeating: 0, count: WAVHeaderRepair.headerSize)
        data.append(Data(repeating: 0, count: Int(96_000 * seconds)))
        try? data.write(to: url)
    }

    private static func durationSeconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    private static func recordedBytes(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0)
            - WAVHeaderRepair.headerSize
    }

    /// 第 44 字节之后的全部内容。**头之外一个字节都不许变**这条判据靠它
    private static func payloadDigest(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url), data.count > WAVHeaderRepair.headerSize else {
            return "?"
        }
        return SHA256.hash(data: data[WAVHeaderRepair.headerSize...])
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "?" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digestTree(_ dir: URL) -> [String: String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        var out: [String: String] = [:]
        for url in files { out[url.lastPathComponent] = digest(url) }
        return out
    }
}
