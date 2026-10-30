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

        // 分屏渲染开关。做成环境变量而不是新 CLI 参数：
        // `--ui-snapshot` 的解析在 `App.swift`，本包不许改它
        //   · `recordings`：P14-1/P14-2/P14-3 的「只渲 4 张」；
        //   · `p14-4`：P14-4 的五屏 × 亮暗共 10 张，跳过录音列表；
        //   · `p14-5`：P14-5 只改设置页，只渲 settings 亮/暗 2 张；
        //   · `p15-1`：P15-1 只改录音卡片，只渲有数据的 recordings 亮/暗 2 张
        //     （空态屏不验波形，不浪费一次渲染）；
        //   · `p15-2`：P15-2 加概览条，同样只要 recordings 亮/暗 2 张；
        //   · `p15-3`：P15-3 改转录页为时间轴，只要 transcription 亮/暗 2 张
        let only = ProcessInfo.processInfo.environment["UI_SNAPSHOT_ONLY"]
        let onlyRecordings = only == "recordings"
        let onlyFive = only == "p14-4"
        let onlySettings = only == "p14-5"
        let onlyRecordingsTwo = only == "p15-1" || only == "p15-2"
        let onlyTimeline = only == "p15-3"
        let screens: [(name: String, view: AnyView, tallHeight: CGFloat?)] = {
            if onlyRecordings {
                return allScreens.filter { $0.name.hasPrefix("recordings") }
            }
            if onlyFive {
                return allScreens.filter { !$0.name.hasPrefix("recordings") }
            }
            if onlySettings {
                return allScreens.filter { $0.name == "settings" }
            }
            if onlyRecordingsTwo {
                return allScreens.filter { $0.name == "recordings" }
            }
            if onlyTimeline {
                return allScreens.filter { $0.name == "transcription" }
            }
            return allScreens
        }()
        if onlyRecordings {
            print("  模式：只渲录音屏（UI_SNAPSHOT_ONLY=recordings）")
            print("")
        }
        if onlyFive {
            print("  模式：只渲五屏 10 张（UI_SNAPSHOT_ONLY=p14-4）")
            print("")
        }
        if onlySettings {
            print("  模式：只渲设置屏 2 张（UI_SNAPSHOT_ONLY=p14-5）")
            print("")
        }
        if onlyRecordingsTwo {
            print("  模式：只渲录音屏 2 张（UI_SNAPSHOT_ONLY=\(only ?? "")）")
            print("")
        }
        if onlyTimeline {
            print("  模式：只渲转录屏 2 张（UI_SNAPSHOT_ONLY=p15-3）")
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

        // ── 自检 ⑥：五屏共用左右边距 24（P14-4）──
        //
        // 五屏都用 `RecordingLayout.pagePadding`（P14-4 把页边距并到
        // 录音列表那一套）。变异实验：把它改成 40（旧的 `pagePadding`），
        // 这条红——顺手也会把 10 张快照的左基线全部推歪
        failure.check(Theme.RecordingLayout.pagePadding == 24,
                      "五屏左右边距 = 24",
                      detail: "（实得 \(Theme.RecordingLayout.pagePadding)）")

        // ── 自检 ⑦：亮暗真的渲成了两套（色板没被忽略）──
        // 两种分屏模式各挑一张同时在两种外观下都存在的屏
        let schemePair = onlyTimeline
            ? "transcription"
            : ((onlyFive || onlySettings) ? "settings" : "recordings")
        if let light = written["\(schemePair)-light.png"],
           let dark = written["\(schemePair)-dark.png"],
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

            // P15-5 起转录页没有卡片（时间轴上的段落是透明的），
            // 卡片分离那两条在 p15-3 模式下没有对象可判——替代判据
            // 「段落透明」「发丝线在」在下面的自检 ⑭ 里
            if onlyTimeline {
                continue
            }
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

        // ── 自检 ⑨：圆角与字号档位（P14-1 定死五档，P15-2 批准新增 metric）──
        //
        // 这些是「规格里的数」而不是观感判据：派单把字号和圆角写死了，
        // 谁哪天顺手把标题调回 48、或又给某处新开一档数字，这里必须红。
        // P15-2 的概览读数明确要求 28/700，于是这一档从五档变六档——
        // 不是把判据放松成「随便几档」，新值仍然要写进这个集合
        failure.check(Theme.Radius.card == 16, "卡片圆角 = 16",
                      detail: "（实得 \(Theme.Radius.card)）")
        failure.check(Theme.Spacing.cardPaddingH == 20 && Theme.Spacing.cardPaddingV == 16,
                      "卡片内边距 = 水平 20 / 垂直 16",
                      detail: "（实得 \(Theme.Spacing.cardPaddingH) / \(Theme.Spacing.cardPaddingV)）")
        let styleSizes: Set<CGFloat> = [
            Theme.Text.largeTitle.size, Theme.Text.metric.size,
            Theme.Text.bodyEmphasized.size, Theme.Text.summary.size,
            Theme.Text.meta.size, Theme.Text.footnote.size,
        ]
        failure.check(styleSizes == Set<CGFloat>([32, 28, 17, 15, 13, 11]),
                      "字号正好六档 32/28/17/15/13/11",
                      detail: "（实得 \(styleSizes.sorted().map { "\($0)" }.joined(separator: "/"))）")
        failure.check(Theme.Text.metric.weight == .bold,
                      "概览读数 28/700")
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
            let lightIsGray6 = abs(lightBG.0 - 241.0 / 255) < 0.002
                && abs(lightBG.1 - 241.0 / 255) < 0.002
                && abs(lightBG.2 - 244.0 / 255) < 0.002
            failure.check(lightIsGray6, "亮色页面底 = #F1F1F4",
                          detail: String(format: "（%.4f, %.4f, %.4f）", lightBG.0, lightBG.1, lightBG.2))
            let darkIsBlack = darkBG.0 < 0.001 && darkBG.1 < 0.001 && darkBG.2 < 0.001
            failure.check(darkIsBlack, "深色页面底 = #000000",
                          detail: String(format: "（%.4f, %.4f, %.4f）", darkBG.0, darkBG.1, darkBG.2))
        } else {
            failure.check(false, "页面底色能解析成 sRGB")
        }
        let expectedLayers: [Theme.Shadow.Layer] = [
            .init(opacity: 0.06, radius: 2, y: 1),
            .init(opacity: 0.10, radius: 20, y: 6),
        ]
        failure.check(Theme.Shadow.layers(elevation: 1, scheme: .light) == expectedLayers,
                      "亮色一级阴影 = 两层 (0,1,2,0.06) + (0,6,20,0.10)",
                      detail: "（实得 \(Theme.Shadow.layers(elevation: 1, scheme: .light).map { "(y\($0.y), r\($0.radius), \($0.opacity))" }.joined(separator: " + "))）")
        failure.check(Theme.Shadow.layers(elevation: 1, scheme: .dark).isEmpty,
                      "深色一级零阴影")
        // 深色卡片底必须正好是 #1C1C1E（P14-2 评审：原来 elevation>0
        // 被换成了 #2C2C2E，卡片和纯黑底分不开）。这一条直接钉 token，
        // 不靠像素亮度带——#1C1C1E 和 #2C2C2E 都落在那个带里
        if let darkFill = srgbComponents(Theme.cardTokens(elevation: 1, scheme: .dark).fill,
                                         scheme: .dark) {
            let isCard = abs(darkFill.0 - 28.0 / 255) < 0.002
                && abs(darkFill.1 - 28.0 / 255) < 0.002
                && abs(darkFill.2 - 30.0 / 255) < 0.002
            failure.check(isCard, "深色卡片底 = #1C1C1E（不被 cardElevated 覆盖）",
                          detail: String(format: "（%.4f, %.4f, %.4f）", darkFill.0, darkFill.1, darkFill.2))
        } else {
            failure.check(false, "深色卡片底能解析成 sRGB")
        }

        // ── 自检 ⑫：角标拆分成形状正确的胶囊（P14-3）──
        //
        // 每个胶囊都必须是「数字 + 段 + 状态」；一种状态一个胶囊，
        // 顺序固定（已核实 → 存疑 → 不可信）；最多两个彩色胶囊，
        // 第三个状态并进灰底「N 段异常」。**红胶囊里只许有异常**——
        // P14-2 的「2 段已核实 · 1 段不可信」整句塞进红底，语义上把
        // 已核实也说成异常，这一组判据就是钉住它别再回来
        let badgePattern = try? NSRegularExpression(
            pattern: #"^\d+ 段(已核实|存疑|不可信|异常)$"#
        )
        func badgeTexts(_ verified: Int, _ fair: Int, _ poor: Int) -> [String] {
            RecordingBadge.items(verified: verified, fair: fair, poor: poor).map(\.text)
        }
        let badgeCases: [(String, [String], Int)] = [
            ("全部可信", badgeTexts(4, 0, 0), 1),
            ("只有存疑", badgeTexts(0, 1, 0), 1),
            ("只有不可信", badgeTexts(0, 0, 1), 1),
            ("已核实 + 不可信", badgeTexts(2, 0, 1), 2),
            ("三种状态并存", badgeTexts(1, 1, 1), 3),
        ]
        for (label, texts, expectedCount) in badgeCases {
            failure.check(texts.count == expectedCount,
                          "\(label)：拆成 \(expectedCount) 个胶囊",
                          detail: "（实得 \(texts.count) 个：\(texts.joined(separator: "、"))）")
        }
        let allBadgeTexts = badgeCases.flatMap(\.1)
        let badShape = allBadgeTexts.filter { text in
            let range = NSRange(text.startIndex..., in: text)
            return badgePattern?.firstMatch(in: text, range: range) == nil
        }
        failure.check(badShape.isEmpty, "每个胶囊都是「数字 + 段 + 状态」形状",
                      detail: badShape.isEmpty ? "" : "（越界 \(badShape.joined(separator: "、"))）")
        failure.check(badgeTexts(1, 1, 1) == ["1 段已核实", "1 段存疑", "1 段异常"],
                      "三种状态：顺序固定，第三个并入灰底",
                      detail: "（实得 \(badgeTexts(1, 1, 1).joined(separator: "、"))）")
        failure.check(badgeTexts(2, 0, 1) == ["2 段已核实", "1 段不可信"],
                      "已核实与不可信分属两个胶囊（顺序固定）",
                      detail: "（实得 \(badgeTexts(2, 0, 1).joined(separator: "、"))）")
        let mixed = RecordingBadge.items(verified: 1, fair: 1, poor: 1)
        let colored = mixed.filter { $0.kind != .overflow }
        failure.check(colored.count <= 2, "彩色胶囊最多 2 个",
                      detail: "（实得 \(colored.count) 个）")
        failure.check(mixed.last?.kind == .overflow && mixed.last?.text == "1 段异常",
                      "超出的状态并入灰底「N 段异常」",
                      detail: "（实得「\(mixed.last?.text ?? "无")」）")
        let redTexts = RecordingBadge.items(verified: 2, fair: 0, poor: 1)
            .filter { $0.kind == .poor }
            .map(\.text)
        failure.check(redTexts == ["1 段不可信"], "不可信胶囊里只放异常",
                      detail: "（实得 \(redTexts.joined(separator: "、"))）")

        // ── 自检 ⑬：分屏模式的张数 ──
        if onlyRecordings {
            failure.check(expected.count == 4,
                          "只渲录音屏 4 张（亮/暗 × 有数据/空）",
                          detail: "（实得 \(expected.count) 张：\(expected.joined(separator: "、"))）")
        }
        if onlyFive {
            failure.check(expected.count == 10,
                          "只渲五屏 10 张（五屏 × 亮/暗）",
                          detail: "（实得 \(expected.count) 张：\(expected.joined(separator: "、"))）")
        }
        if onlySettings {
            failure.check(expected.count == 2,
                          "只渲设置屏 2 张（亮/暗）",
                          detail: "（实得 \(expected.count) 张：\(expected.joined(separator: "、"))）")
        }
        if onlyRecordingsTwo {
            failure.check(expected.count == 2,
                          "只渲录音屏 2 张（亮/暗）",
                          detail: "（实得 \(expected.count) 张：\(expected.joined(separator: "、"))）")
        }

        // ── 自检 ⑭：时间轴（P15-3）──
        //
        // 三条判据按派单来：节点颜色映射、竖线覆盖（节点纵坐标递增、
        // 首末都盖住）、live 标记存在。
        //   · 颜色映射是纯函数，不依赖像素——快照没渲出来它也能验；
        //   · 覆盖与 live 标记只能看像素：竖线是 Canvas 画的，节点是
        //     overlay 里的 Circle，布局对不对唯独这一层能抓到
        if onlyTimeline {
            failure.check(expected.count == 2,
                          "只渲转录屏 2 张（亮/暗）",
                          detail: "（实得 \(expected.count) 张：\(expected.joined(separator: "、"))）")

            let nodeTest = TimelineNodeStatus.selfTest()
            failure.check(nodeTest.failed == 0,
                          "节点颜色映射自检 \(nodeTest.passed) 条全绿（5 种状态 + live 标记）",
                          detail: nodeTest.failed == 0 ? "" : "（红 \(nodeTest.failed) 条）")

            // 轨道中心在页面 x = 24（页边距）+ 4（轨道半宽）= 28pt
            let spineX = Int(28 * scale)
            let expectedNodes = populated.transcription.segments.count
            for schemeName in ["light", "dark"] {
                let imageName = "transcription-\(schemeName).png"
                guard let rep = bitmap(at: output.appendingPathComponent(imageName)),
                      let pixels = Pixels(rep) else {
                    failure.check(false, "\(imageName) 能读成像素")
                    continue
                }
                let bg = pixels.backgroundLuminance()
                let spineXs = (spineX - 2)...(spineX + 2)

                // 竖线：1pt 线在 @2x 上落在两三个像素列里，只认正中间
                // 那一列会随光栅化相位漂移，所以取邻域里最偏离背景的值
                // 浅色下卡片投影（10% / 20pt）会漏到轨道这一列，亮度差
                // 约 0.02，和深色竖线自身的 0.026 同量级——所以浅色用
                // 更高的阈值（竖线 35% 叠 #F1F1F4 后约 0.044），深色没有阴影
                let spineThreshold = schemeName == "light" ? 0.03 : 0.015
                var covered = [Bool](repeating: false, count: pixels.height)
                for y in 0..<pixels.height {
                    var worst = 0.0
                    for x in spineXs where x >= 0 && x < pixels.width {
                        worst = max(worst, abs(pixels.luma(x, y) - bg))
                    }
                    covered[y] = worst > spineThreshold
                }

                // 节点：8pt 圆只有轨道这一列有颜色，正文/时间戳都从 x=44pt
                // 之后才开始，所以按「这一列是否发色」就能把节点单独找出来。
                // 灰色节点（未核查）和竖线同色，这里数不出来——夹具的四段
                // 恰好四色都不灰，数量对得上；未核查节点由纯函数自检兜。
                //
                // 页头里也有 accent 色的文字链接（「上传云端」「本节课提问」），
                // 其中一部分正好落在轨道这一列上。节点是实心圆，圆心上
                // 横向有 8pt（16px）连续同色；文字笔画只有 8px 左右。
                // 所以「横向连续发色宽度 ≥ 12px」才是节点，只按纵向高度
                // 过滤会把 13px 高的字也数进来
                func chromatic(_ x: Int, _ y: Int) -> Bool {
                    let (r, g, b) = pixels.rgb(x, y)
                    return max(r, g, b) - min(r, g, b) > 0.22
                }
                func chromaticRunWidth(_ y: Int) -> Int {
                    var low = spineX, high = spineX
                    while low > 0, chromatic(low - 1, y) { low -= 1 }
                    while high < pixels.width - 1, chromatic(high + 1, y) { high += 1 }
                    return high - low + 1
                }
                var blobs: [(low: Int, high: Int)] = []
                var blobStart: Int?
                for y in 0..<pixels.height {
                    let hasColor = spineXs.contains { x in
                        x >= 0 && x < pixels.width && chromatic(x, y)
                    }
                    if hasColor {
                        if blobStart == nil { blobStart = y }
                    } else if let start = blobStart {
                        let center = (start + y - 1) / 2
                        if y - start >= 6, chromaticRunWidth(center) >= 12 {
                            blobs.append((start, y - 1))
                        }
                        blobStart = nil
                    }
                }
                if let start = blobStart, pixels.height - start >= 6 {
                    let center = (start + pixels.height - 1) / 2
                    if chromaticRunWidth(center) >= 12 {
                        blobs.append((start, pixels.height - 1))
                    }
                }
                let centers = blobs.map { ($0.low + $0.high) / 2 }

                failure.check(blobs.count == expectedNodes,
                              "\(imageName) 轨道上 \(expectedNodes) 个状态节点",
                              detail: "（实得 \(blobs.count) 个）")
                let ascending = zip(centers, centers.dropFirst()).allSatisfy { $0 < $1 }
                failure.check(ascending && centers.count >= 2,
                              "\(imageName) 节点纵坐标自上而下递增",
                              detail: "（节点中心 \(centers.map { "\($0)" }.joined(separator: " → "))）")

                // 竖线必须是一条不断的线把首末节点都串起来：允许 4px
                // 的缝（节点与线的抗锯齿交界），超过就算断
                var runs: [(Int, Int)] = []
                var runStart: Int?
                var lastY = -100
                for y in 0..<pixels.height where covered[y] {
                    if let start = runStart, y - lastY > 4 {
                        runs.append((start, lastY))
                        runStart = y
                    } else if runStart == nil {
                        runStart = y
                    }
                    lastY = y
                }
                if let start = runStart { runs.append((start, lastY)) }
                let spine = runs.first { run in
                    centers.allSatisfy { $0 >= run.0 && $0 <= run.1 }
                }
                let coversEnds = spine.map { run in
                    guard let first = blobs.first, let last = blobs.last else { return false }
                    return run.0 >= first.low
                        && run.1 >= last.high + Int(8 * scale)
                } ?? false
                failure.check(spine != nil && coversEnds,
                              "\(imageName) 竖线从首节点贯穿到末节点（中间不断、不越过首节点）",
                              detail: spine.map { "（线 \($0.0)–\($0.1)px）" } ?? "（没有贯穿的线）")

                // live 标记：末尾那个正在转写的节点必须是对比度最强的那支
                // accent 蓝（#0071E3）。三个通道的判法与别色无歧义：
                // 橙/红 b 很低，绿 b−r 只有 0.16，都不满足 b−r > 0.4
                let accentIndex = centers.firstIndex { y in
                    let (r, _, b) = pixels.rgb(spineX, y)
                    return b - r > 0.4 && b > 0.6
                }
                failure.check(accentIndex == centers.indices.last,
                              "\(imageName) live 标记是最后一个节点的 accent 蓝",
                              detail: accentIndex.map { "（第 \($0 + 1) 个节点）" } ?? "（没找到 accent 节点）")

                // 两种橙要能分开：夹具第 2 个节点是「存疑」warning、
                // 第 3 个是「无法核实」unknown。派单把两者都定成橙，
                // 那就只能靠明度差——两个 token 的亮度差不到 0.05 时，
                // 8pt 的圆点是两个一样的点（深色最初用 #FFB340 就是这个毛病）
                if centers.count >= 3 {
                    let warningLuma = lumaOf(pixels.rgb(spineX, centers[1]))
                    let unknownLuma = lumaOf(pixels.rgb(spineX, centers[2]))
                    failure.check(abs(warningLuma - unknownLuma) >= 0.05,
                                  "\(imageName) 存疑与无法核实两种橙分得开",
                                  detail: String(format: "（亮度 %.3f vs %.3f）", warningLuma, unknownLuma))
                }

                // P15-5：段落必须透明——没有卡片底、没有圆角、没有描边。
                // 取段内一块没有文字的区域（x=800pt；正文最长也只到约
                // 550pt），y 取节点中心往下 40px（时间戳行 + 内边距之后），
                // 要求它和页面底**逐像素相同**。上一版的 #1C1C1E 卡片底
                // 亮度 0.11、高亮卡 0.96，都逃不过这一条
                if centers.count == expectedNodes {
                    let samples = centers.map { pixels.luma(1600, $0 + 40) }
                    let worst = samples.map { abs($0 - bg) }.max() ?? 0
                    failure.check(worst <= 0.01,
                                  "\(imageName) 四段底板透明（= 页面底，无卡片）",
                                  detail: String(format: "（页面底 %.4f，段内 %@）",
                                                 bg, samples.map { String(format: "%.4f", $0) }.joined(separator: " / ")))
                }

                // 段与段之间的 0.5pt 发丝线：横向贯穿整个内容宽
                // （1052pt 内容区 - 16 左缩进 ≈ 2072px），只出现在
                // 首末节点之间。判定不走 `longestRunLuminances`：它记的是
                // 「最长同色段」的起始值，文字行里的抗锯齿像素会把整行
                // 背景也包进 0.012 的容差里，一屏文字能刷出二十来条假线。
                // 这里直接要求「整行几乎同色，且与页面底差得明显」
                func dividerRow(_ y: Int) -> Bool {
                    let color = pixels.luma(1600, y)
                    // 浅色 0.02、深色 0.01：低于这个就只是抗锯齿，不是线
                    let threshold = schemeName == "light" ? 0.02 : 0.01
                    guard abs(color - bg) > threshold else { return false }
                    var same = 0, total = 0
                    // 从 x=200 起：左边 128px 内有竖线/节点，不给它们算数
                    for x in stride(from: 200, to: min(2000, pixels.width), by: 7) {
                        total += 1
                        if abs(pixels.luma(x, y) - color) < 0.01 { same += 1 }
                    }
                    return total > 0 && Double(same) / Double(total) > 0.9
                }
                let listRange = (blobs.first?.low ?? 0)...(blobs.last?.high ?? pixels.height)
                let dividerRows = (listRange).filter(dividerRow)
                var groups = 0
                for y in dividerRows where !dividerRows.contains(y - 1) { groups += 1 }
                failure.check(groups == expectedNodes - 1,
                              "\(imageName) 段间发丝线 \(expectedNodes - 1) 条",
                              detail: "（实得 \(groups) 条：\(dividerRows.map { "\($0)" }.joined(separator: "、"))）")
            }
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
            let (r, g, b) = rgb(x, y)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        /// 0–1 的 sRGB 三通道。时间轴的节点颜色判据要分「蓝/绿/橙」，
        /// 亮度分不开（accent 蓝和未知橙在深色下亮度接近）
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return (Double(data[offset]) / 255,
                    Double(data[offset + 1]) / 255,
                    Double(data[offset + 2]) / 255)
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

    /// 0–1 的 sRGB 三通道 → 亮度。时间轴两种橙靠明度区分，判据要能算它
    private static func lumaOf(_ rgb: (Double, Double, Double)) -> Double {
        0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
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
        // P14-2：这一条原来 title 为空、靠日期回落当标题，评审看到的是
        // 「同一列表里一条是讲次、一条是日期」。标题永远是课程/讲次，
        // 日期时间只出现在元信息行第一项。
        // 这一段**刻意让 fair 和 poor 并存**：质量角标必须两种数都报
        store.save(session(
            title: "第 4 讲 · 反向传播", course: "机器学习", startedAt: at(daysAgo: 1, hour: 14),
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
