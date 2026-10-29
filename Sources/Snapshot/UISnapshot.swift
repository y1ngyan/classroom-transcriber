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
///     这三件只有人对着 App 看才算验过；
///   · 笔记正文是 `WKWebView`，离屏渲染**拍不到它加载后的内容**。
///     `notes` 快照拍的是「还没有笔记」那一档（有图标、有引导、有卡片），
///     生成后的正文长什么样只验到「外面那张卡片」，里面没有验。
///   · `transcription` / `glossary` 两张只截得到**内容最后一段**（转录列表 /
///     术语列表）：页头占掉一屏，而离屏宿主滚不动（见 `renderBottom`）。
///     它们是「列表区域」的快照，不是整页。
///
/// **夹具不碰用户数据**：会话库整个建在临时目录里；术语表/核查/转录三项
/// 用 store 的预置 init（不读也不写用户的 glossary.json / 真实录音库），
/// 渲完即删。
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

        seedRecordings(into: dataSessions)

        let transcript = transcriptFixture()
        let checks = factCheckFixture(segments: transcript)
        let terms = glossaryFixture()

        let populated = AppState(
            sessionsDirectory: dataSessions,
            audioDirectory: dataAudio,
            transcription: TranscriptionEngine(segments: transcript),
            factCheck: FactCheckStore(results: checks),
            glossary: GlossaryStore(entries: terms)
        )
        // 空状态那个 AppState 用空目录 + 空 store：一条都不造，index 读出来就是空的。
        // 术语表也显式给空数组——走默认 init 会读用户真实的 glossary.json
        let empty = AppState(
            sessionsDirectory: emptySessions,
            audioDirectory: emptyAudio,
            transcription: TranscriptionEngine(),
            factCheck: FactCheckStore(results: []),
            glossary: GlossaryStore(entries: [])
        )

        failure.check(populated.recordings.summaries.count == 3,
                      "录音夹具读回来 3 条",
                      detail: "（实得 \(populated.recordings.summaries.count)）")
        let mixedQuality = populated.recordings.summaries.filter {
            $0.poorCount > 0 && $0.fairCount > 0
        }
        failure.check(mixedQuality.count == 1,
                      "录音夹具里有一条「不可信 + 存疑」并存",
                      detail: "（实得 \(mixedQuality.count) 条）")
        failure.check(populated.transcription.segments.count == 4,
                      "转录夹具 4 段",
                      detail: "（实得 \(populated.transcription.segments.count)）")
        failure.check(populated.factCheck.results.count == 3,
                      "核查夹具 3 条",
                      detail: "（实得 \(populated.factCheck.results.count)）")
        failure.check(populated.glossary.entries.count == 5,
                      "术语表夹具 5 条",
                      detail: "（实得 \(populated.glossary.entries.count)）")
        failure.check(empty.recordings.summaries.isEmpty && empty.recordings.recoveryItems.isEmpty,
                      "空状态夹具确实为空")

        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // ── 渲染 ──
        // `tallHeight` 只给「关键内容在折叠线以下」的屏：
        //   · 术语表 —— 页头是三段说明，760pt 一屏只拍得到说明，拍不到术语列表；
        //   · 转录 —— 760pt 一屏时第四段（正在转写、`isHighlighted`）落在底部
        //     栏后面，所以加高宿主。高度只要让**整张列表装得进滚动区**即可：
        //     装得下时列表按自身高度停在顶部，快照展示的就是真实使用中
        //     「滚到末尾」的那一个静止状态，且最后一张卡片与底栏之间留出安全区。
        // 离屏宿主不能滚（见 `renderBottom` 的注释），只能把宿主加高再截最后一段
        let allScreens: [(name: String, view: AnyView, tallHeight: CGFloat?)] = [
            ("transcription", AnyView(TranscriptionView().environment(populated)), 980),
            ("fact-check", AnyView(FactCheckView().environment(populated)), nil),
            ("notes", AnyView(NotesView().environment(populated)), nil),
            ("glossary", AnyView(GlossaryView().environment(populated)), 2000),
            ("settings", AnyView(SettingsView().environment(populated)), nil),
            ("recordings", AnyView(RecordingsView().environment(populated)), nil),
            ("recordings-empty", AnyView(RecordingsView().environment(empty)), nil),
        ]

        // P14-1：只看录音这一屏时（派单要求「只渲 4 张」），用
        // `UI_SNAPSHOT_ONLY=recordings` 把其余五屏整体跳过。做成环境变量而不是
        // 新 CLI 参数：`--ui-snapshot` 的解析在 `App.swift`，本包不许改它
        let onlyRecordings = ProcessInfo.processInfo.environment["UI_SNAPSHOT_ONLY"]
            == "recordings"
        let screens = onlyRecordings
            ? allScreens.filter { $0.name.hasPrefix("recordings") }
            : allScreens
        if onlyRecordings {
            print("  模式：只渲录音屏（UI_SNAPSHOT_ONLY=recordings）")
            print("")
        }

        var written: [String: URL] = [:]
        for screen in screens {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                let name = "\(screen.name)-\(suffix).png"
                let url = output.appendingPathComponent(name)
                do {
                    if let tall = screen.tallHeight {
                        try renderBottom(of: screen.view, scheme: scheme,
                                         tallHeight: tall, to: url)
                    } else {
                        try render(screen.view, scheme: scheme, to: url)
                    }
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
        failure.check(missing.isEmpty, "\(expected.count) 张 PNG 全部落盘",
                      detail: missing.isEmpty ? "" : "（缺 \(missing.joined(separator: "、"))）")
        failure.check(undersized.isEmpty, "每张 > 1KB",
                      detail: undersized.isEmpty ? "" : "（\(undersized.joined(separator: "、"))）")
        failure.check(wrongSize.isEmpty, "尺寸 = \(Int(canvas.width * scale))×\(Int(canvas.height * scale))",
                      detail: wrongSize.isEmpty ? "" : "（\(wrongSize.joined(separator: "、"))）")

        // ── 自检 ②：token 值域 ──
        let allLayers = Theme.Shadow.card + Theme.Shadow.cardRaised
        let badOpacity = allLayers.filter { !(0.01...0.15).contains($0.opacity) }
        // 半径下限 P14-1 由 4 收到 2：定死的两层阴影里，贴桌面那层就是 2
        let badRadius = allLayers.filter { !(2...40).contains($0.radius) }
        let badY = allLayers.filter { !(0...20).contains($0.y) }
        failure.check(badOpacity.isEmpty, "阴影 opacity 都在 0.01–0.15",
                      detail: badOpacity.isEmpty ? "" : "（越界 \(badOpacity.map { "\($0.opacity)" }.joined(separator: "、"))）")
        failure.check(badRadius.isEmpty, "阴影半径都在 2–40pt",
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

        // ── 自检 ⑤：正文补充灰字对比度 ──
        //
        // 判据是 WCAG 的 AA 正文标准：sRGB 相对亮度算出的对比度 ≥ 4.5:1。
        // 三个底都测——同一档灰字会同时出现在页面底和两级卡片底上，
        // 只测白底会漏掉卡片里最暗的那一档。
        // 变异实验：把 `textSupporting` 换回 `textSecondary`（#86868B），
        // 亮色三档会掉到 3.4–3.6:1，这一组必须红
        for scheme in [ColorScheme.light, .dark] {
            let schemeName = scheme == .light ? "亮色" : "深色"
            guard let text = srgbComponents(Theme.textSupporting, scheme: scheme) else {
                failure.check(false, "\(schemeName) textSupporting 能解析成 sRGB")
                continue
            }
            let backgrounds: [(String, Color)] = [
                ("页面底", Theme.background),
                ("卡片底", Theme.Surface.card),
                ("抬高卡片底", Theme.Surface.cardElevated),
            ]
            for (backgroundName, background) in backgrounds {
                guard let backgroundRGB = srgbComponents(background, scheme: scheme) else {
                    failure.check(false, "\(schemeName) \(backgroundName) 能解析成 sRGB")
                    continue
                }
                let ratio = contrastRatio(text, backgroundRGB)
                failure.check(ratio >= 4.5,
                              "\(schemeName) textSupporting / \(backgroundName) 对比度 ≥ 4.5:1",
                              detail: String(format: "（%.2f:1）", ratio))
            }
        }

        // ── 自检 ⑥：转录页底部安全区 ──
        //
        // 转录页的底部栏用 `safeAreaInset` 挂在列表上，预留量取
        // `Theme.Control.floatingBarHeight`。这条判据盯的是那个常量：
        // 它必须至少「胶囊高度 + 一级间距」，否则最后一张卡片会被压住。
        // 变异实验：把 floatingBarHeight 改成 pillHeight，这条红
        let requiredInset = Theme.Control.pillHeight + Theme.Spacing.md
        failure.check(Theme.Control.floatingBarHeight >= requiredInset,
                      "转录页底部预留 ≥ 胶囊高度 + Spacing.md",
                      detail: String(format: "（%.0f ≥ %.0f + %.0f）",
                                     Theme.Control.floatingBarHeight,
                                     Theme.Control.pillHeight,
                                     Theme.Spacing.md))

        // ── 自检 ⑦：亮暗真的渲成了两套（色板没被忽略）──
        if let light = written["recordings-light.png"], let dark = written["recordings-dark.png"],
           let lightLum = cornerLuminance(light), let darkLum = cornerLuminance(dark) {
            failure.check(lightLum > 0.9 && darkLum < 0.1,
                          "亮/暗两张分别是浅底和黑底",
                          detail: String(format: "（角落亮度 %.2f / %.2f）", lightLum, darkLum))
        } else {
            failure.check(false, "亮/暗两张能读出来做像素比对")
        }

        // ── 自检 ⑧：每张非空 + 卡片真的从背景里分出来 ──
        //
        // **这是 P13-1 那个「页头有数、下面空白」的直接判据**：只看文件
        // 大小会被一张白图骗过，所以按像素数「和页面底色不一样的点」。
        // 卡片分离分两种外观判，因为两种外观靠的东西不同：
        //   · 浅色：卡片底也是白的，靠 6% 描边（+阴影）分界 → 找竖边；
        //   · 深色：靠更亮一档的底 → 找长横条；描边单独再判一条
        //     （变异实验里「底还在、描边没了」必须能红）。
        for name in expected {
            guard let rep = bitmap(at: output.appendingPathComponent(name)),
                  let pixels = Pixels(rep) else {
                failure.check(false, "\(name) 能读成像素")
                continue
            }
            let background = pixels.backgroundLuminance()
            let fraction = pixels.nonBackgroundFraction(background: background, stride: 2)
            failure.check(fraction >= 0.0025,
                          "\(name) 像素非空",
                          detail: String(format: "（非背景 %.2f%%）", fraction * 100))

            if name.hasSuffix("-dark.png") {
                let runs = pixels.longestRunLuminances(minLength: 200, tolerance: 0.012)
                // 卡片底是一大片同色；描边是**两三条**同色长横线。
                // 用「有多少行出现了这么长的同色横条」把两者分开：
                // 变异实验里把卡片底改成 .clear，行数会掉到个位数
                let fillBand = 0.08...0.22
                let fillRows = runs.filter { fillBand.contains($0.luma) }
                failure.check(fillRows.count >= 20,
                              "\(name) 深色卡片底色从背景分出来",
                              detail: "（同色长条 \(fillRows.count) 行）")
                let fillLuma = mostCommon(fillRows.map(\.luma))
                // 描边比它所在的底再亮一档；把描边透明度改成 0 之后，
                // 整张卡只剩底这一种亮度，这条就红。
                //
                // 两个收紧（都是变异 ② 抓出来的漏网）：
                //   · 长条按 **900px** 起步：200px 太松，「开始录制」「补标点」
                //     这类蓝色胶囊本身就有一两百像素宽；
                //   · 还要求这条亮线和**卡片底色的行相邻**：转录页正在转写的
                //     那一段整卡都被提亮（`isHighlighted`），它也是一条又亮
                //     又宽的长条；而它是「一整块」，不是「一条贴着底的线」。
                //     描边线与卡片底只隔 0–3 行，提亮块与别的卡的底隔着 8pt
                let edges = pixels.longestRunLuminances(minLength: 900, tolerance: 0.012)
                let threshold = (fillLuma ?? 0.05) + 0.025
                let fillYs = fillLuma.map { fill in
                    runs.filter { abs($0.luma - fill) <= 0.012 }.map(\.y)
                } ?? []
                let border = edges.contains { edge in
                    guard (threshold...0.32).contains(edge.luma) else { return false }
                    return fillYs.contains { abs($0 - edge.y) <= 3 }
                }
                failure.check(border, "\(name) 深色卡片有 0.5pt 描边",
                              detail: fillLuma == nil ? "" : String(format: "（底 %.3f，要求 ≥ %.3f 的长条）", fillLuma!, threshold))
            } else {
                // 浅色卡片底是白的、页面是 #F5F5F7：分离靠 6% 黑描边
                // （合成后约 0.94，比页面底暗一档）。**不能再用固定亮度带**：
                // P14-1 之前页面是纯白（1.0），落在带外；现在页面底自己也
                // 落在 0.85–0.98 里，固定带会被整行背景骗过。所以按
                // 「比该图左上角页面底暗 0.004 以上」判，描边合成后约暗 0.02
                let pageLuma = pixels.backgroundLuminance()
                let edges = pixels.longestRunLuminances(minLength: 900, tolerance: 0.012)
                let border = edges.contains {
                    (pageLuma - 0.08)...(pageLuma - 0.004) ~= $0.luma
                }
                failure.check(border, "\(name) 亮色卡片有描边（从页面底分出边界）",
                              detail: String(format: "（页面底 %.3f）", pageLuma))
            }
        }

        // ── 自检 ⑨：圆角与字号五档（P14-1 定死）──
        //
        // 这些是「规格里的数」而不是观感判据：派单把 32/17/15/13/11 和圆角 16
        // 写死了，谁哪天顺手把标题调回 48、或给卡片新开一档 14pt，这里必须红
        failure.check(Theme.Radius.card == 16, "卡片圆角 = 16",
                      detail: "（实得 \(Theme.Radius.card)）")
        failure.check(Theme.Spacing.cardPaddingH == 20 && Theme.Spacing.cardPaddingV == 16,
                      "卡片内边距 = 水平 20 / 垂直 16",
                      detail: "（实得 \(Theme.Spacing.cardPaddingH) / \(Theme.Spacing.cardPaddingV)）")
        let styleSizes: Set<CGFloat> = [
            Theme.Text.largeTitle.size, Theme.Text.bodyEmphasized.size,
            Theme.Text.summary.size, Theme.Text.meta.size, Theme.Text.footnote.size,
        ]
        failure.check(styleSizes == Set<CGFloat>([32, 17, 15, 13, 11]),
                      "字号正好五档 32/17/15/13/11",
                      detail: "（实得 \(styleSizes.sorted().map { "\($0)" }.joined(separator: "/"))）")
        failure.check(Theme.Text.largeTitle.weight == .bold,
                      "页面标题 32/700")
        failure.check(Theme.Text.bodyEmphasized.weight == .semibold,
                      "分组/卡片标题 17/600")
        failure.check(Theme.Text.summary.weight == .regular && Theme.Text.meta.weight == .regular,
                      "摘要/元数据 400")

        // ── 自检 ⑩：间距只允许节奏表里的值 ──
        let offRhythm = Theme.RecordingLayout.spacingValues.filter {
            !Theme.Spacing.rhythm.contains($0)
        }
        failure.check(offRhythm.isEmpty,
                      "录音页间距全部落在 2/4/6/10/12/16/20/24/28/32",
                      detail: offRhythm.isEmpty ? "" : "（越界 \(offRhythm.map { "\($0)" }.joined(separator: "、"))）")

        // ── 自检 ⑪：页面底色与两级阴影（P14-1 定死）──
        //
        // 阴影按**数值逐层比对**，不比范围：范围判据分不出「两层」和
        // 「四层都落在范围内」，而定死的就是两层这两个数
        if let lightBG = srgbComponents(Theme.background, scheme: .light),
           let darkBG = srgbComponents(Theme.background, scheme: .dark) {
            let lightIsGray6 = abs(lightBG.0 - 245.0 / 255) < 0.002
                && abs(lightBG.1 - 245.0 / 255) < 0.002
                && abs(lightBG.2 - 247.0 / 255) < 0.002
            failure.check(lightIsGray6, "亮色页面底 = #F5F5F7",
                          detail: String(format: "（%.4f, %.4f, %.4f）", lightBG.0, lightBG.1, lightBG.2))
            let darkIsBlack = darkBG.0 < 0.001 && darkBG.1 < 0.001 && darkBG.2 < 0.001
            failure.check(darkIsBlack, "深色页面底 = #000000",
                          detail: String(format: "（%.4f, %.4f, %.4f）", darkBG.0, darkBG.1, darkBG.2))
        } else {
            failure.check(false, "页面底色能解析成 sRGB")
        }
        let expectedLayers: [Theme.Shadow.Layer] = [
            .init(opacity: 0.06, radius: 10, y: 2),
            .init(opacity: 0.04, radius: 2, y: 1),
        ]
        failure.check(Theme.Shadow.layers(elevation: 1, scheme: .light) == expectedLayers,
                      "亮色一级阴影 = 两层 (0,2,10,0.06) + (0,1,2,0.04)",
                      detail: "（实得 \(Theme.Shadow.layers(elevation: 1, scheme: .light).map { "(y\($0.y), r\($0.radius), \($0.opacity))" }.joined(separator: " + "))）")
        failure.check(Theme.Shadow.layers(elevation: 1, scheme: .dark).isEmpty,
                      "深色一级零阴影")

        // ── 自检 ⑫：这一包只渲 4 张 ──
        if onlyRecordings {
            failure.check(expected.count == 4,
                          "只渲录音屏 4 张（亮/暗 × 有数据/空）",
                          detail: "（实得 \(expected.count) 张：\(expected.joined(separator: "、"))）")
        }

        for line in failure.lines { print(line) }
        print("")
        print(failure.count == 0
              ? "✅ 界面快照通过（\(failure.lines.count) 条判据）"
              : "❌ 界面快照未通过（\(failure.count) 条红 / 共 \(failure.lines.count) 条）")
        exitReleasingGgml(failure.count == 0 ? 0 : 1)
    }

    // MARK: - 像素探针

    /// 直接读位图缓冲的扫描器。
    ///
    /// 用 `bitmapData` 而不是 `colorAt`：后者每次调用都要走一遍
    /// NSColor 解析，14 张 2200×1520 的图要跑几百万次，快照会从
    /// 「一条命令」变成「等一分钟」。PNG 解码出来是 8-bit 非平面位图，
    /// 通道顺序（RGBA/BGRA）不影响这里的判据——阈值按亮度差定的，
    /// 灰度文字和描边在两种顺序下都落同一条带
    private struct Pixels {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytesPerPixel: Int
        let data: UnsafeMutablePointer<UInt8>

        init?(_ rep: NSBitmapImageRep) {
            guard !rep.isPlanar,
                  rep.bitsPerSample == 8,
                  rep.samplesPerPixel >= 3,
                  let data = rep.bitmapData else { return nil }
            width = rep.pixelsWide
            height = rep.pixelsHigh
            bytesPerRow = rep.bytesPerRow
            bytesPerPixel = max(3, rep.bitsPerPixel / 8)
            self.data = data
        }

        func luma(_ x: Int, _ y: Int) -> Double {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let r = Double(data[offset])
            let g = Double(data[offset + 1])
            let b = Double(data[offset + 2])
            return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }

        /// 左上角 8×8 的平均亮度。三张屏在这个位置都是页面底
        func backgroundLuminance() -> Double {
            var total = 0.0
            var n = 0
            for y in 0..<8 {
                for x in 0..<8 {
                    total += luma(x, y)
                    n += 1
                }
            }
            return n == 0 ? 0 : total / Double(n)
        }

        /// 和背景亮度差超过阈值的像素占比。纯背景（或者没画出来的空白）≈ 0
        func nonBackgroundFraction(background: Double, stride: Int) -> Double {
            var different = 0
            var total = 0
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    if abs(luma(x, y) - background) > 0.02 { different += 1 }
                    total += 1
                    x += stride
                }
                y += stride
            }
            return total == 0 ? 0 : Double(different) / Double(total)
        }

        /// 从下往上第一个「和背景不一样」的像素行。整张都是背景 → nil。
        /// 给「加高宿主、裁最后一段」的屏找内容末尾用
        func lastNonBackgroundRow(background: Double) -> Int? {
            guard height > 0, width > 0 else { return nil }
            for y in stride(from: height - 1, through: 0, by: -1) {
                var x = 0
                while x < width {
                    if abs(luma(x, y) - background) > 0.02 { return y }
                    x += 2
                }
            }
            return nil
        }

        /// 每一行里最长的那条**同色横条**的亮度与行号（长度不够 `minLength` 的行不给值）。
        ///
        /// 为什么按「横条」判：卡片底是一大片同色（几百行），描边是两三条
        /// 同色长线，文字永远凑不出 200 px 连续同色。这样「底」和「描边」
        /// 可以分开数，变异实验才有一个能红的方向：
        ///   · 底改成 `.clear` → 落在底色带里的行数掉光；
        ///   · 描边透明度改成 0 → 只剩底色一种亮度，没有「更亮的长条」
        ///
        /// 行号一并返回：描边判据还要求这条亮线和卡片底**相邻**，
        /// 否则转录页那张被整体提亮的卡会被当成一条粗描边
        func longestRunLuminances(minLength: Int, tolerance: Double) -> [(y: Int, luma: Double)] {
            var result: [(y: Int, luma: Double)] = []
            result.reserveCapacity(height)
            for y in 0..<height {
                var runStart = luma(0, y)
                var runLength = 1
                var bestLength = 0
                var best: Double?
                // 最长的那条，不是最后一条：一张居中窄卡的两侧都是页面底色，
                // 收尾时那条背景跑得也不短，按「最后一条」记会把卡片底写成 0
                for x in 1..<width {
                    let value = luma(x, y)
                    if abs(value - runStart) <= tolerance {
                        runLength += 1
                    } else {
                        runStart = value
                        runLength = 1
                    }
                    if runLength > bestLength {
                        bestLength = runLength
                        best = runLength >= minLength ? value : best
                    }
                }
                if bestLength >= minLength, let best { result.append((y, best)) }
            }
            return result
        }
    }

    /// 一组亮度里出现最多的那个（按 0.005 分箱）。卡片底色的几百行会压倒
    /// 只有两三行的描边。空数组返回 nil
    private static func mostCommon(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for value in values {
            counts[Int((value / 0.005).rounded()), default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        return Double(best.key) * 0.005
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
        let rep = try renderBitmap(of: view, scheme: scheme, height: canvas.height)
        try write(rep, to: url)
    }

    /// 给「卡片在折叠线以下」的屏用：宿主加高到内容装得下，整页画完，
    /// 再裁出**最下面**一段可视区（内容末尾往上 `canvas` 那么高）。
    ///
    /// **为什么不滚 ScrollView**：`NSHostingView` 里的 scroll 是
    /// `HostingScrollView`，它的 `documentView.bounds` 恒为 0，改
    /// `clipView` 的 `bounds.origin` 会被夹回 0（2026-10-29 实测）——正文
    /// 不是靠 AppKit 的 document view 滚的，滚不了。
    ///
    /// 代价：这一屏顶部那几段说明文字不在快照里。它本来也只是说明文案，
    /// 而这一版要验的是列表行卡片化成没成——报告里必须写明这一点。
    static func renderBottom(of view: AnyView, scheme: ColorScheme,
                             tallHeight: CGFloat, to url: URL) throws {
        let rep = try renderBitmap(of: view, scheme: scheme, height: tallHeight)
        let pixels = Pixels(rep)
        let background = pixels?.backgroundLuminance() ?? 0
        let target = Int(canvas.height * scale)
        // 内容最下面一行再往下留 8pt 边，免得裁掉卡片底边那 0.5pt 描边
        let lastContent = (pixels?.lastNonBackgroundRow(background: background) ?? rep.pixelsHigh - 1) + 8
        let end = min(rep.pixelsHigh, max(target, lastContent))
        let start = end - target
        guard let cg = rep.cgImage,
              let cropped = cg.cropping(to: CGRect(x: 0, y: start,
                                                   width: Int(canvas.width * scale),
                                                   height: target))
        else { throw RenderError.noBitmap }
        guard let png = NSBitmapImageRep(cgImage: cropped)
            .representation(using: .png, properties: [:]) else { throw RenderError.noPNG }
        try png.write(to: url, options: .atomic)
    }

    private static func renderBitmap(of view: AnyView, scheme: ColorScheme,
                                     height: CGFloat) throws -> NSBitmapImageRep {
        let size = NSSize(width: canvas.width, height: height)
        let host = NSHostingView(
            rootView: view
                .frame(width: canvas.width, height: height)
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
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw RenderError.noBitmap }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
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

    /// 左上角一块 8×8 的平均亮度。取角落是因为所有屏在这个位置都是页面底
    static func cornerLuminance(_ url: URL) -> Double? {
        guard let rep = bitmap(at: url), let pixels = Pixels(rep) else { return nil }
        return pixels.backgroundLuminance()
    }

    // MARK: - 对比度

    /// 把 `Theme` 的动态色调到指定外观下解析成 sRGB 分量。
    ///
    /// `Theme.adaptive` 用的是 `NSColor(name:provider:)`，它的 provider 读的是
    /// **当前绘制外观**——所以必须先 `performAsCurrentDrawingAppearance`
    /// 再取颜色，否则两种外观会解析成同一个值，对比度自检就变成了空转
    static func srgbComponents(_ color: Color, scheme: ColorScheme) -> (Double, Double, Double)? {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        guard let appearance else { return nil }
        var components: (Double, Double, Double)?
        appearance.performAsCurrentDrawingAppearance {
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            components = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }
        return components
    }

    /// WCAG 2.x 的相对亮度（sRGB 先做 gamma 展开再加权）
    static func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    static func contrastRatio(_ a: (Double, Double, Double),
                              _ b: (Double, Double, Double)) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - 夹具

    /// 转录夹具：四段，覆盖「有提问 / 有存疑段 / 最后一段还没定稿」三种状态。
    /// 最后一段刻意 `isFinal = false`——转录页要给它一个 `isHighlighted` 态，
    /// 快照里得看得见那一行
    private static func transcriptFixture() -> [TranscriptSegment] {
        let now = Date()
        func segment(_ text: String, start: Int, end: Int,
                     finalized: Bool = true, grade: TranscriptGrade? = .good,
                     question: Bool = false) -> TranscriptSegment {
            var segment = TranscriptSegment(
                text: text, isFinal: finalized,
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
        return [
            segment("今天讲梯度下降，它其实是在参数空间里找下降最快的方向。",
                    start: 0, end: 9_000),
            segment("学习率太大会震荡，太小会收敛得很慢，大家调的时候要看曲线。",
                    start: 9_000, end: 18_000, grade: .fair),
            segment("这里谁来回答一下，为什么负梯度方向是最快的？",
                    start: 18_000, end: 25_000, question: true),
            segment("对，因为泰勒展开的一阶项里它取到最小值。",
                    start: 25_000, end: 31_000, finalized: false),
        ]
    }

    /// 核查夹具：三种结论各一条，且挂在转录夹具的前三段上
    /// （悬停浮窗会按 segmentID 去取上下文）
    private static func factCheckFixture(segments: [TranscriptSegment]) -> [FactCheckResult] {
        let verified = FactCheckResult(
            segmentID: segments[0].id,
            claim: "梯度下降是在参数空间里找下降最快的方向。",
            status: .verified,
            explanation: "梯度方向是函数增长最快的方向，负梯度因此是最快下降方向，这是多元微积分的基本结论。",
            confidence: 0.94,
            sources: [
                FactCheckSource(title: "梯度下降 - 维基百科", url: "https://zh.wikipedia.org/wiki/梯度下降"),
                FactCheckSource(title: "Gradient descent", url: "https://en.wikipedia.org/wiki/Gradient_descent"),
            ]
        )
        let disputed = FactCheckResult(
            segmentID: segments[1].id,
            claim: "学习率太大会震荡，太小会收敛得很慢。",
            status: .disputed,
            explanation: "方向上正确，但「太小只会收敛慢」不完整：学习率过小在非凸问题上可能停在很差的局部区域。",
            confidence: 0.63,
            sources: [FactCheckSource(title: "Learning rate", url: "https://en.wikipedia.org/wiki/Learning_rate")]
        )
        let unverifiable = FactCheckResult(
            segmentID: segments[2].id,
            claim: "负梯度方向是最快的方向。",
            status: .unverifiable,
            explanation: "没有检索到能判定这句话的可靠来源：它依赖「最快」是在什么度量下说的。",
            confidence: 0,
            sources: []
        )
        return [verified, disputed, unverifiable]
    }

    /// 术语表夹具：五条，全部带真实别名。
    ///
    /// **刻意不留空的「误转写」**：空的 TextField 会把占位提示语
    /// （「误转写，用「、」分隔（可留空）」）画在数据行里，看快照的人
    /// 会把它读成一条假数据。P13-3 之前第 4 条就是这样。
    /// 空别名的真实使用场景由编辑器本身的占位提示覆盖，快照不负责演它
    private static func glossaryFixture() -> [GlossaryEntry] {
        [
            GlossaryEntry(term: "梯度下降", aliases: ["梯度递减"], note: "一种一阶最优化算法"),
            GlossaryEntry(term: "学习率", aliases: ["learning rate"], note: "每次更新的步长"),
            GlossaryEntry(term: "反向传播", aliases: ["backprop"], note: "按链式法则逐层求梯度"),
            GlossaryEntry(term: "卷积", aliases: ["convolution"], note: "局部加权求和"),
            GlossaryEntry(term: "过拟合", aliases: ["overfitting"], note: "训练集表现好、泛化差"),
        ]
    }

    /// 三条录音，刻意覆盖列表的三种状态：用户起过名的、没起名（回落成时间）、
    /// 有不可信段的。全是今天/昨天/前天，是为了让分组标题（今天/昨天/M月d日）
    /// 三条都出现一次——那三档都是列表要画的。
    /// 第二条刻意让 fair 和 poor 并存：质量状态那格必须两种数都报
    private static func seedRecordings(into sessionsDirectory: URL) {
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
        // 「有坏段就只说坏段」，并存时会静默吞掉存疑段数
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
