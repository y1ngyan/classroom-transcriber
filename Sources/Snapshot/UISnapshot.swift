import SwiftUI
import AppKit

/// `--ui-snapshot <输出目录>`：无头把所有重点屏渲成 PNG（亮/暗各一张）。
///
/// **为什么要有这个入口**：这一轮 UI 改动（卡片化）的验收是「看图」——
/// 但看图的代价不该是「先点开 App、再手点六个标签页、再逐张截图」，那既不
/// 可复现，也没法交给核验侧独立跑。离屏 `NSHostingView` 能在**不起 GUI**
/// 的进程里把视图画进位图，于是快照可以是一条命令。
///
/// **为什么不按派单写的用 `ImageRenderer`**：它会静默吞掉 ScrollView 的内容
/// （只有 ScrollView 外面的部分会画出来，不报错）。实测现场见 `render(_:scheme:to:)`
/// 的注释——第一版快照里列表整片空白，就是这个原因。
///
/// **它不保证的事**（写在这里免得被当成全绿）：
///   · 不进 `NSApplicationMain`、不开窗口、不装 run loop——所以 hover、
///     点击、滚动这类**交互态**一张都拍不到（悬停态靠 token 的数值自检兜）；
///   · 是真机像素，但不是真机性能：滚动性能、Retina 下 0.5pt 边框的实际
///     观感、深色下「用亮一档的底代替阴影」在真实壁纸背景上的效果，
///     这三件只有人对着 App 看才算验过。
///
/// **夹具不碰用户数据**：会话库整个建在临时目录里（`AppState` 的
/// `sessionsDirectory` 参数就是为这件事加的），渲完即删。
@MainActor
enum UISnapshot {

    /// 画布尺寸。1100×760 是主窗口的常见内容区（最小 820×660，再给列表
    /// 一点余量）——快照要能代表真实窗口里的折行与留白
    static let canvas = CGSize(width: 1100, height: 760)
    /// @2x：验收要能看清 0.5pt 描边和阴影的过渡
    static let scale: CGFloat = 2

    struct Failure {
        var lines: [String] = []
        var count = 0
        mutating func check(_ ok: Bool, _ label: String, detail: String = "") {
            if !ok { count += 1 }
            lines.append("   \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  \(detail)")")
        }
    }

    static func run(outputDirectory path: String) -> Never {
        let output = URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                         isDirectory: true)
        var failure = Failure()

        print("界面快照（无头 · 不启动 GUI · 不碰用户录音库）")
        print("  输出目录：\(output.path)")
        print("  画布：\(Int(canvas.width))×\(Int(canvas.height)) @\(Int(scale))x "
              + "= \(Int(canvas.width * scale))×\(Int(canvas.height * scale)) 像素")
        print("")

        // ── 夹具 ──
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-snapshot-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let dataSessions = root.appendingPathComponent("data/sessions", isDirectory: true)
        let dataAudio = root.appendingPathComponent("data/recordings", isDirectory: true)
        let emptySessions = root.appendingPathComponent("empty/sessions", isDirectory: true)
        let emptyAudio = root.appendingPathComponent("empty/recordings", isDirectory: true)
        for dir in [dataSessions, dataAudio, emptySessions, emptyAudio] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        seedFixture(into: dataSessions)
        // 空状态那个 AppState 用空目录：一个文件都不写，index 读出来就是空的
        let populated = AppState(sessionsDirectory: dataSessions, audioDirectory: dataAudio)
        let empty = AppState(sessionsDirectory: emptySessions, audioDirectory: emptyAudio)

        failure.check(populated.recordings.summaries.count == 3,
                      "夹具读回来 3 条录音",
                      detail: "（实得 \(populated.recordings.summaries.count)）")
        // 「不可信 + 存疑」并存的那条：质量状态格必须两种数都报，
        // 这类回归只有夹具里真的有并存数据才看得见
        let mixedQuality = populated.recordings.summaries.filter {
            $0.poorCount > 0 && $0.fairCount > 0
        }
        failure.check(mixedQuality.count == 1,
                      "夹具里有一条「不可信 + 存疑」并存的录音",
                      detail: "（实得 \(mixedQuality.count) 条）")
        failure.check(empty.recordings.summaries.isEmpty && empty.recordings.recoveryItems.isEmpty,
                      "空状态夹具确实为空")

        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // ── 渲染 ──
        let screens: [(name: String, view: AnyView)] = [
            ("recordings", AnyView(RecordingsView().environment(populated))),
            ("recordings-empty", AnyView(RecordingsView().environment(empty))),
            ("settings", AnyView(SettingsView().environment(empty))),
        ]

        var written: [String: URL] = [:]
        for screen in screens {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                let name = "\(screen.name)-\(suffix).png"
                let url = output.appendingPathComponent(name)
                do {
                    try render(screen.view, scheme: scheme, to: url)
                    written[name] = url
                } catch {
                    failure.check(false, "渲染 \(name)", detail: "（\(error.localizedDescription)）")
                }
            }
        }

        // ── 自检 ①：产出文件 ──
        let expected = screens.flatMap { screen in ["light", "dark"].map { "\(screen.name)-\($0).png" } }
        var missing: [String] = []
        var undersized: [String] = []
        var wrongSize: [String] = []
        for name in expected {
            let url = output.appendingPathComponent(name)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? Int) ?? 0
            guard let rep = bitmap(at: url) else {
                missing.append(name)
                continue
            }
            if bytes <= 1024 { undersized.append("\(name)(\(bytes)B)") }
            let wantW = Int(canvas.width * scale), wantH = Int(canvas.height * scale)
            if rep.pixelsWide != wantW || rep.pixelsHigh != wantH {
                wrongSize.append("\(name)(\(rep.pixelsWide)×\(rep.pixelsHigh))")
            }
        }
        failure.check(missing.isEmpty, "6 张 PNG 全部落盘", detail: missing.isEmpty ? "" : "（缺 \(missing.joined(separator: "、"))）")
        failure.check(undersized.isEmpty, "每张 > 1KB", detail: undersized.isEmpty ? "" : "（\(undersized.joined(separator: "、"))）")
        failure.check(wrongSize.isEmpty, "尺寸 = \(Int(canvas.width * scale))×\(Int(canvas.height * scale))",
                      detail: wrongSize.isEmpty ? "" : "（\(wrongSize.joined(separator: "、"))）")

        // ── 自检 ②：token 值域 ──
        let allLayers = Theme.Shadow.card + Theme.Shadow.cardRaised
        let badOpacity = allLayers.filter { !(0.01...0.15).contains($0.opacity) }
        let badRadius = allLayers.filter { !(4...40).contains($0.radius) }
        let badY = allLayers.filter { !(0...20).contains($0.y) }
        failure.check(badOpacity.isEmpty, "阴影 opacity 都在 0.01–0.15",
                      detail: badOpacity.isEmpty ? "" : "（越界 \(badOpacity.map { "\($0.opacity)" }.joined(separator: "、"))）")
        failure.check(badRadius.isEmpty, "阴影半径都在 4–40pt",
                      detail: badRadius.isEmpty ? "" : "（越界 \(badRadius.map { "\($0.radius)" }.joined(separator: "、"))）")
        failure.check(badY.isEmpty, "阴影 y 偏移都在 0–20pt",
                      detail: badY.isEmpty ? "" : "（越界 \(badY.map { "\($0.y)" }.joined(separator: "、"))）")

        // ── 自检 ③：亮色必须有阴影（改 opacity 成 0 这条会红）──
        let lightLayers = (0...2).flatMap {
            Theme.cardTokens(elevation: $0, scheme: .light).shadow
        }
        let positive = Theme.cardTokens(elevation: 1, scheme: .light).shadow
        failure.check(!positive.isEmpty && positive.allSatisfy { $0.opacity > 0 },
                      "亮色卡片有阴影（层数 > 0 且每层 opacity > 0）",
                      detail: "（\(positive.map { "\($0.opacity)" }.joined(separator: " + "))）")
        failure.check(lightLayers.count >= 4, "亮色两级阴影共 ≥ 4 层",
                      detail: "（实得 \(lightLayers.count)）")

        // ── 自检 ④：深色不留阴影 ──
        let darkLayers = (0...2).flatMap {
            Theme.cardTokens(elevation: $0, scheme: .dark).shadow
        }
        failure.check(darkLayers.isEmpty, "深色一级/二级都不带阴影",
                      detail: darkLayers.isEmpty ? "" : "（多出 \(darkLayers.count) 层）")

        // ── 自检 ⑤：亮暗真的渲成了两套（色板没被忽略）──
        if let light = written["recordings-light.png"], let dark = written["recordings-dark.png"],
           let lightLum = cornerLuminance(light), let darkLum = cornerLuminance(dark) {
            failure.check(lightLum > 0.9 && darkLum < 0.1,
                          "亮/暗两张分别是白底和黑底",
                          detail: String(format: "（角落亮度 %.2f / %.2f）", lightLum, darkLum))
        } else {
            failure.check(false, "亮/暗两张能读出来做像素比对")
        }

        for line in failure.lines { print(line) }
        print("")
        print(failure.count == 0
              ? "✅ 界面快照通过（\(failure.lines.count) 条判据）"
              : "❌ 界面快照未通过（\(failure.count) 条红 / 共 \(failure.lines.count) 条）")
        exitReleasingGgml(failure.count == 0 ? 0 : 1)
    }

    // MARK: - 渲染

    enum RenderError: LocalizedError {
        case noBitmap
        case noPNG
        var errorDescription: String? {
            switch self {
            case .noBitmap: return "建不出位图缓冲"
            case .noPNG: return "位图转不出 PNG"
            }
        }
    }

    /// 把一张屏渲成 PNG。
    ///
    /// **为什么不用 `ImageRenderer`**：派单给的是那条路，但它**会静默吞掉
    /// ScrollView 的内容**——实测（2026-10-29，本入口第一版）：`ImageRenderer(...)`
    /// 能画出 ScrollView 外面的 header，ScrollView 里面一行都不画，不报错、
    /// 不返回 nil，`nsImage` 照样给你一张只有标题的白图。三张屏里有两张
    /// 整页内容都在 ScrollView 里，那样拍出来的快照等于没拍。
    /// 换成离屏 `NSHostingView` + `cacheDisplay` 之后内容正常——它是真做了一次
    /// 布局，而 `ImageRenderer` 的离屏渲染不走 scroll view 的布局路径。
    ///
    /// **仍然不起 GUI**：没有 `NSApplicationMain`、没有 `NSWindow`、不跑 run loop、
    /// 不注册菜单；`NSHostingView` 只是个离屏的视图宿主，画完就退出。
    ///
    /// 暗色靠两处同时给：`host.appearance`（`NSColor` 动态色按它解析，
    /// 这是 `Theme.adaptive` 实际读的东西）和环境里的 `colorScheme`
    /// （SwiftUI 自己的 `\.colorScheme` 读的那份）。只给一处会得到
    /// 「背景换了、文字没换」这种半套结果。
    static func render(_ view: AnyView, scheme: ColorScheme, to url: URL) throws {
        let size = NSSize(width: canvas.width, height: canvas.height)
        let host = NSHostingView(
            rootView: view
                .frame(width: canvas.width, height: canvas.height)
                .environment(\.colorScheme, scheme)
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()

        // 显式按 `scale` 建位图，而不是拿 `bitmapImageRepForCachingDisplay`：
        // 那个按「屏幕 backing scale」走，换台非 Retina 机器快照就变成 @1x，
        // 而「尺寸 = 2200×1520」是判据之一，不该随机器漂
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale),
            pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw RenderError.noBitmap }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.noPNG
        }
        try png.write(to: url, options: .atomic)
    }

    /// 读 PNG 成位图。`NSBitmapImageRep(contentsOf:)` 这个初始化器在 AppKit 里
    /// 不存在（实测编译错误「argument passed to call that takes no arguments」），
    /// 只能走「先读 Data 再解」这条
    static func bitmap(at url: URL) -> NSBitmapImageRep? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    /// 左上角一块 8×8 的平均亮度。取角落是因为三张屏在这个位置都是页面底
    /// （列表从 header 下方才开始；设置页是留白）
    static func cornerLuminance(_ url: URL) -> Double? {
        guard let rep = bitmap(at: url) else { return nil }
        var total = 0.0
        var n = 0
        for x in 0..<8 {
            for y in 0..<8 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(NSColorSpace.sRGB) else {
                    continue
                }
                let r = Double(color.redComponent)
                let g = Double(color.greenComponent)
                let b = Double(color.blueComponent)
                total += 0.2126 * r + 0.7152 * g + 0.0722 * b
                n += 1
            }
        }
        return n == 0 ? nil : total / Double(n)
    }

    // MARK: - 夹具

    /// 三条录音，刻意覆盖列表的三种状态：用户起过名的、没起名（回落成时间）、
    /// 有不可信段的。全是今天/昨天/前天，是为了让分组标题（今天/昨天/M月d日）
    /// 三条都出现一次——那三档都是列表要画的
    private static func seedFixture(into sessionsDirectory: URL) {
        let store = RecordingsStore(
            directory: sessionsDirectory,
            recordingsDirectory: sessionsDirectory.deletingLastPathComponent()
                .appendingPathComponent("recordings", isDirectory: true)
        )
        let calendar = Calendar.current
        let now = Date()
        func at(daysAgo: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }

        func segment(_ text: String, start: Int, end: Int,
                     grade: TranscriptGrade? = .good, question: Bool = false) -> TranscriptSegment {
            var segment = TranscriptSegment(
                text: text, isFinal: true,
                startTimeMillis: start, endTimeMillis: end,
                timestamp: now, languages: ["zh-CN"]
            )
            segment.qualityGrade = grade
            if question {
                segment.questionLevel = 2
                segment.coreQuestion = text
            }
            return segment
        }

        func session(title: String, course: String, startedAt: Date, minutes: Int,
                     segments: [TranscriptSegment]) -> RecordingSession {
            let part = RecordingPart(
                id: UUID(), fileName: nil, startedAt: startedAt,
                durationMillis: minutes * 60_000, offsetMillis: 0, segments: segments
            )
            return RecordingSession(id: UUID(), startedAt: startedAt, updatedAt: startedAt,
                                    parts: [part], title: title, course: course)
        }

        store.save(session(
            title: "第 3 讲 · 梯度下降", course: "机器学习", startedAt: at(daysAgo: 0, hour: 9),
            minutes: 96,
            segments: [
                segment("今天讲梯度下降，它其实是在参数空间里找下降最快的方向。", start: 0, end: 9_000),
                segment("学习率太大会震荡，太小会收敛得很慢，大家调的时候要看曲线。", start: 9_000, end: 18_000),
                segment("这里谁来回答一下，为什么负梯度方向是最快的？", start: 18_000, end: 25_000, question: true),
                segment("对，因为泰勒展开的一阶项里它取到最小值。", start: 25_000, end: 31_000),
            ]
        ))
        // 没起名：列表回落显示「M月d日 HH:mm」，同一行还会补上时刻。
        // 这一段**刻意让 fair 和 poor 并存**：质量状态那格曾经写着
        // 「有坏段就只说坏段」，并存时会静默吞掉存疑段数——夹具里必须有
        // 一条并存的数据，这条回归才看得见
        store.save(session(
            title: "", course: "机器学习", startedAt: at(daysAgo: 1, hour: 14),
            minutes: 88,
            segments: [
                segment("接着上节课讲反向传播，先把链式法则再推一遍。", start: 0, end: 8_000, grade: .fair),
                segment("每一层的误差项来自上一层权重的转置乘上本层梯度。", start: 8_000, end: 16_000, grade: .poor),
                segment("这部分考试会考，注意矩阵的维度要对上。", start: 16_000, end: 22_000),
            ]
        ))
        store.save(session(
            title: "第一章 极限", course: "高等数学", startedAt: at(daysAgo: 3, hour: 10),
            minutes: 102,
            segments: [
                segment("我们从数列的极限讲起，ε-N 语言是这一章的地基。", start: 0, end: 9_000),
                segment("这一段识别不可信", start: 9_000, end: 14_000, grade: .poor),
                segment("给定任意小的 ε，都存在 N，使得 n 大于 N 时差的绝对值小于 ε。", start: 14_000, end: 22_000),
            ]
        ))
    }
}
