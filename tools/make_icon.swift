#!/usr/bin/env swift
//
// 生成 App 图标。
//
// 为什么是代码画而不是塞一张 PNG：图标要 16/32/64/128/256/512/1024 八个尺寸，
// 每个尺寸都从矢量重画一遍，小尺寸才不至于是一坨模糊的重采样。而且这个项目
// 没有 Xcode、没有 Asset Catalog，一张张手动导出既不可复现也没法微调。
//
// 用法：
//   swift tools/make_icon.swift            生成正式图标（选用 variants 里标 default 的那个）
//   swift tools/make_icon.swift --variants 只出一张方案对照图，供人眼挑
//
// 产物：build/icon/AppIcon.icns
//

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - 设计稿常量
//
// 全部按 1024×1024 的画布写，渲染时整体缩放。改这里就能改图标。

let canvas: CGFloat = 1024
let center = CGPoint(x: canvas / 2, y: canvas / 2)

/// **背景必须铺满整张画布，圆角由系统来切。**
///
/// 这条是实测出来的：先前自己画了一个 824×824 的圆角方块，四周留白，
/// 结果 macOS 26 把整张图当成「旧式图标」，缩小之后垫在一个灰色圆角
/// 托盘上——双层圆角，看着就是坏的。换成满幅不透明之后，系统自己套上
/// 标准的圆角遮罩和玻璃质感，就是原生图标的样子。
/// 拿系统里 Telegram / Steam 的图标比对过，它们同样是满幅的。
///
/// 代价是形状完全交给系统，在 macOS 26 以前满幅就是一块方砖，
/// 所以 build.sh 里 LSMinimumSystemVersion 写的是 26.0。

/// 标记内容的宽度上限
let markWidth: CGFloat = 562
/// 声波条的高度上限。留足边距——顶到画布边上会显得局促
let barMaxHeight: CGFloat = 438

/// 背景渐变。锚在品牌色 #0071E3 上，上浅下深——
/// 纯平涂在白色 Dock 上会显得像贴纸，一点点渐变就够了。
let gradientTop = (r: 0x33, g: 0x96, b: 0xFF)
let gradientBottom = (r: 0x00, g: 0x57, b: 0xC2)

// MARK: - 方案

/// 三套构图。声波是「录音」，对勾是「核实」——这个 App 干的就是这两件事，
/// 图标得说清楚是哪一个，或者说清楚两个的关系。
enum Variant: String, CaseIterable {
    /// 只要声波。最简，但换个 App 名照样能用——播客、录音笔、语音备忘
    case wave
    /// 声波 + 对勾并置。左右读作「录下来 → 核实过」
    case waveCheck
    /// 声波条的顶边连起来是一个对勾。第一版被淘汰过，原因是比例没取对：
    /// 左肩做到了 0.80 高，而对勾的左臂本来就该是低的，结果读出来是
    /// 「一个 V 形的柱状图」。这一版保留原比例，用来对照。
    case checkBars
    /// 同上，但比例按对勾的真实顶边重新取样，条数也加到 7 条，
    /// 让顶边成为一条连续的折线而不是五个孤立的点。
    case checkBarsFine
    /// C 的意图换一种画法：条不再从底边长出来，而是骑在对勾线上，
    /// 条高就相当于笔画粗细。
    case checkRibbon

    var title: String {
        switch self {
        case .wave: return "A 纯声波"
        case .waveCheck: return "B 声波 + 对勾"
        case .checkBars: return "C 顶轮廓成对勾（原比例）"
        case .checkBarsFine: return "C′ 顶轮廓成对勾（重取比例）"
        case .checkRibbon: return "C″ 条骑在对勾线上"
        }
    }
}

/// 对勾的顶边取样。从左肩 0.49 降到谷底 0.18，再升到右肩 0.91 ——
/// 关键在左肩必须低：左高右高就成了 V，不成对勾。
/// 谷底落在 1/3 处而不是正中，对上对勾那个偏左的转折点。
let checkOutlineFine: [CGFloat] = [0.485, 0.295, 0.175, 0.358, 0.542, 0.725, 0.909]
/// 原比例
let checkOutlinePlain: [CGFloat] = [0.80, 0.52, 0.26, 0.60, 1.00]

/// 对勾的中心折线（x 从 0 到 1，y 从底 0 到顶 1）。
///
/// 两个斜率必须拉开：左臂 1.97（短而陡），右臂 1.04（长而缓）。
/// 先前取的是 1.35 对 1.12，两条臂差不多斜，读出来是个对称的 V。
/// 对勾之所以是「勾」，全靠这个不对称。
let checkCenterline: [(x: CGFloat, y: CGFloat)] = [(0, 0.74), (0.30, 0.15), (1, 0.88)]
/// 条高占 barMaxHeight 的比例。C″ 里条高就是笔画粗细，所以统一，
/// 不做波形起伏——起伏一上来，对勾又散架了
let ribbonBarHeight: CGFloat = 0.26

/// 在折线上按 x 取 y
func centerlineY(at x: CGFloat) -> CGFloat {
    for index in 0..<(checkCenterline.count - 1) {
        let a = checkCenterline[index]
        let b = checkCenterline[index + 1]
        guard x >= a.x, x <= b.x else { continue }
        let t = (x - a.x) / max(0.0001, b.x - a.x)
        return a.y + t * (b.y - a.y)
    }
    return checkCenterline.last!.y
}

/// 正式采用哪个
let chosen: Variant = .checkRibbon

// MARK: - 颜色

func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// MARK: - 形状

/// 一排中心落在给定折线上的胶囊条。
func drawBarsAlongPath(
    in ctx: CGContext,
    ratios: [CGFloat],
    totalWidth: CGFloat,
    left: CGFloat,
    gapRatio: CGFloat
) {
    let count = CGFloat(ratios.count)
    let barWidth = totalWidth / (count + (count - 1) * gapRatio)
    let gap = barWidth * gapRatio
    let height = barMaxHeight * ribbonBarHeight
    let baseline = center.y - barMaxHeight / 2

    var x = left
    for index in ratios.indices {
        // 取条的中心所在的 x，而不是左边缘——用左边缘的话整排会往左下偏
        let centerXRatio = (x - left + barWidth / 2) / totalWidth
        let y = baseline + centerlineY(at: centerXRatio) * barMaxHeight
        let rect = CGRect(x: x, y: y - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        ))
        ctx.fillPath()
        x += barWidth + gap
    }
}

/// 一排竖向胶囊条。
/// - Parameters:
///   - ratios: 每条的相对高度
///   - alignBottom: true 时所有条底边对齐，顶边的轮廓就是 ratios 本身
func drawBars(
    in ctx: CGContext,
    ratios: [CGFloat],
    left: CGFloat,
    totalWidth: CGFloat,
    gapRatio: CGFloat,
    alignBottom: Bool = false
) {
    let count = CGFloat(ratios.count)
    let barWidth = totalWidth / (count + (count - 1) * gapRatio)
    let gap = barWidth * gapRatio
    let baseline = center.y - barMaxHeight / 2

    var x = left
    for ratio in ratios {
        let height = barMaxHeight * ratio
        let rect = alignBottom
            ? CGRect(x: x, y: baseline, width: barWidth, height: height)
            : CGRect(x: x, y: center.y - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        ))
        ctx.fillPath()
        x += barWidth + gap
    }
}

/// 对勾。坐标是「和声波并排」时的最终位置——不靠 translate 挪，
/// 那种偏移量算错一次就会像刚才那样直接压在声波上。
///
/// 端点要按线宽的一半往外让：圆头笔帽会从端点再探出 lineWidth/2，
/// 只按路径坐标算边界，实际画出来会宽出一圈。
func drawCheck(in ctx: CGContext, lineWidth: CGFloat) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 517, y: 505))
    path.addLine(to: CGPoint(x: 610, y: 403))
    path.addLine(to: CGPoint(x: 761, y: 629))
    ctx.setStrokeColor(srgb(255, 255, 255))
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
}

// MARK: - 绘制

/// 把整个图标画进 `ctx`，`size` 是目标边长（px）。
func drawLogo(in ctx: CGContext, size: CGFloat, variant: Variant) {
    ctx.saveGState()
    defer { ctx.restoreGState() }

    ctx.scaleBy(x: size / canvas, y: size / canvas)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // 背景：铺满整张画布 + 渐变
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [srgb(gradientTop.r, gradientTop.g, gradientTop.b),
                 srgb(gradientBottom.r, gradientBottom.g, gradientBottom.b)] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: center.x, y: canvas),
            end: CGPoint(x: center.x, y: 0),
            options: []
        )
    }

    // 前景
    ctx.setFillColor(srgb(255, 255, 255))
    let small = size <= 32
    let gapRatio: CGFloat = small ? 0.55 : 0.72
    let left = center.x - markWidth / 2

    switch variant {
    case .wave:
        // 小尺寸下把五条减到三条：16px 下每条只有 0.9px、间隙 0.66px，
        // 抗锯齿之后会糊成一块白。真做图标就是要在小尺寸上换一个更简
        // 的构图，而不是把大图缩下去。
        let ratios: [CGFloat] = small
            ? [0.42, 1.00, 0.58]
            : [0.36, 1.00, 0.52, 0.78, 0.30]
        drawBars(in: ctx, ratios: ratios, left: left, totalWidth: markWidth, gapRatio: gapRatio)

    case .waveCheck:
        if small {
            // 16/32px 下对勾和声波并排必然糊，退回到纯声波
            drawBars(
                in: ctx, ratios: [0.42, 1.00, 0.58],
                left: left, totalWidth: markWidth, gapRatio: gapRatio
            )
        } else {
            // 左边一组声波，右边一个对勾。
            //
            // 组间距必须明显大于条间距，否则四个元素会读成「一排四样」，
            // 而不是「两组」。所以声波只占 34%，中间空出 52。
            drawBars(
                in: ctx, ratios: [0.52, 1.00, 0.66],
                left: left, totalWidth: markWidth * 0.34, gapRatio: 0.62
            )
            drawCheck(in: ctx, lineWidth: 75)
        }

    case .checkBars:
        if small {
            // 小尺寸下对勾的顶轮廓读不出来，退回纯声波——16px 能看懂的
            // 只有最简单的那几个形状
            drawBars(
                in: ctx, ratios: [0.42, 1.00, 0.58],
                left: left, totalWidth: markWidth, gapRatio: gapRatio
            )
        } else {
            drawBars(
                in: ctx, ratios: checkOutlinePlain,
                left: left, totalWidth: markWidth, gapRatio: gapRatio,
                alignBottom: true
            )
        }

    case .checkBarsFine:
        if small {
            drawBars(
                in: ctx, ratios: [0.42, 1.00, 0.58],
                left: left, totalWidth: markWidth, gapRatio: gapRatio
            )
        } else {
            // 条间距压到 0.35（别处是 0.72）：太大就只剩一排疏落的柱子，
            // 顶边连不起来；太小则糊成一块，声波的质感没了
            drawBars(
                in: ctx, ratios: checkOutlineFine,
                left: left, totalWidth: markWidth, gapRatio: 0.35,
                alignBottom: true
            )
        }

    case .checkRibbon:
        // 小尺寸只是把同一个对勾做简化（8 条减到 4 条），不换成别的图形。
        // 图标各尺寸之间是同一个标志，缩小版换个概念就成了另一个 logo
        let bars = small ? 4 : 8
        drawBarsAlongPath(
            in: ctx,
            ratios: Array(repeating: 1, count: bars),
            totalWidth: markWidth * 0.92,
            left: left + markWidth * 0.04,
            gapRatio: small ? 0.34 : 0.42
        )
    }
}

// MARK: - 输出

func makeContext(width: Int, height: Int) -> CGContext? {
    CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"])
    }
    try data.write(to: url)
}

func renderIcon(size: Int, variant: Variant) -> CGImage? {
    guard let ctx = makeContext(width: size, height: size) else { return nil }
    drawLogo(in: ctx, size: CGFloat(size), variant: variant)
    return ctx.makeImage()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// 产物目录要跟着 `build.sh` 的 `${BUILD_DIR}` 走（P0-1 补充要求 ⑧）。
///
/// 写死 `build/icon` 的后果不是「图标生成到别处」这么无害：一次重定向的构建
/// 仍然会**往用户那份 `build/` 里写文件**，而 `build.sh` 里那句
/// 「我这次一个字节都没碰用户的目录」正是人拿来决定要不要重新授权麦克风的
/// 依据——半吊子的重定向比没有重定向更糟，它让那句话变成假的。
///
/// 默认（没设这个变量）仍然是 `build/icon`，行为不变
let buildDirName = ProcessInfo.processInfo.environment["CLASSROOM_BUILD_DIR"] ?? "build"
let buildDir = buildDirName.hasPrefix("/")
    ? URL(fileURLWithPath: buildDirName, isDirectory: true)
    : root.appendingPathComponent(buildDirName, isDirectory: true)
let outputDir = buildDir.appendingPathComponent("icon")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - 对照图

func drawComparisonSheet() throws {
    let columns = Variant.allCases
    let sizes = [512, 128, 64, 32, 16]
    let cell: CGFloat = 200
    let labelHeight: CGFloat = 34
    let headerHeight: CGFloat = 54
    let margin: CGFloat = 28

    let width = margin * 2 + cell * CGFloat(sizes.count)
    let height = headerHeight + margin + CGFloat(columns.count) * (cell + labelHeight) + margin

    guard let sheet = makeContext(width: Int(width), height: Int(height)) else { exit(1) }

    // 中灰底：白底和黑底的图标都要能看清，灰底是唯一的折中
    sheet.setFillColor(srgb(126, 126, 126))
    sheet.fill(CGRect(x: 0, y: 0, width: width, height: height))

    func label(_ text: String, at point: CGPoint, size: CGFloat = 14, bold: Bool = false) {
        let name = bold ? "SFMono-Bold" : "SFMono-Regular"
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: srgb(255, 255, 255)]
        ))
        sheet.textPosition = point
        CTLineDraw(line, sheet)
    }

    // 表头：各尺寸
    for (index, size) in sizes.enumerated() {
        label("\(size)px", at: CGPoint(x: margin + cell * CGFloat(index) + 8, y: height - 40))
    }

    for (row, variant) in columns.enumerated() {
        let rowTop = height - headerHeight - margin - CGFloat(row) * (cell + labelHeight)
        label(
            variant.title,
            at: CGPoint(x: margin + 4, y: rowTop - 22),
            size: 17,
            bold: variant == chosen
        )

        for (index, size) in sizes.enumerated() {
            guard let image = renderIcon(size: size, variant: variant) else { continue }
            // 尺寸小的放大到能看清：16px 原样贴出来等于没贴
            let side0 = CGFloat(size)
            let zoom = side0 <= 32
                ? min(6, 128 / side0)          // 小的放大到看得清
                : min(1, 160 / side0)          // 大的缩到格子里
            let side = CGFloat(size) * zoom
            sheet.interpolationQuality = zoom > 1 ? .none : .high
            sheet.draw(image, in: CGRect(
                x: margin + cell * CGFloat(index) + (cell - side) / 2,
                y: rowTop - cell + (cell - side) / 2,
                width: side,
                height: side
            ))
        }
    }

    guard let image = sheet.makeImage() else { exit(1) }
    let url = outputDir.appendingPathComponent("variants.png")
    try writePNG(image, to: url)
    print("  对照图: \(url.path)")
}

if CommandLine.arguments.contains("--variants") {
    try drawComparisonSheet()
    exit(0)
}

// MARK: - 正式产出

let iconsetDir = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

/// .iconset 要求的固定文件名 —— 名字写错 `iconutil` 会直接报错，
/// 所以这里是照着它能接受的那套名字枚举的，不是猜的
let slots: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

print("方案：\(chosen.title)")
for slot in slots {
    guard let image = renderIcon(size: slot.pixels, variant: chosen) else { exit(1) }
    try writePNG(image, to: iconsetDir.appendingPathComponent(slot.name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconsetDir.path,
    "-o", outputDir.appendingPathComponent("AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("❌ iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
print("✅ \(outputDir.appendingPathComponent("AppIcon.icns").path)")
