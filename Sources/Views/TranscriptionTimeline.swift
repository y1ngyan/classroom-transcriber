import SwiftUI

/// 时间轴节点状态（P15-3）。
///
/// 顺序就是「问题严重度」：已核实 → 存疑 → 不可信 → 无法核实 → 未核查 → live。
/// 节点颜色是这一屏唯一的「段状态」编码——卡片里不再有质量角标之外的
/// 强色块，所以这六种颜色必须彼此分得开，且与 `Theme` 里已有的状态色
/// 逐一对得上（见 `selfTest`，改颜色值而忘了改这里会红）。
enum TimelineNodeStatus: String, CaseIterable, Equatable {
    case verified
    case doubtful
    case untrustworthy
    case unverifiable
    case unchecked
    case live

    var color: Color {
        switch self {
        case .verified: return Theme.success
        case .doubtful: return Theme.warning
        case .untrustworthy: return Theme.error
        case .unverifiable: return Theme.unknown
        case .unchecked: return Theme.textTertiary
        case .live: return Theme.accent
        }
    }

    /// 自检要认的「呼吸动画」标记。只有 live 节点带这个标记；
    /// 动画本身在 `TimelineRail` 里按它开启
    var isLive: Bool { self == .live }

    /// 状态判定。**纯函数**，不读 store、不看界面。
    ///
    /// 优先级：正在转写 > 转录质量 > 核查结论。
    /// 为什么质量压过核查：一段文字如果识别本身崩了，哪怕这段话恰好在
    /// 常识上「说得对」，用户也不该看到一个绿色节点说这段可信——他读到的
    /// 文字是错的。质量是这段**文字**的状态，核查是这段**说法**的状态，
    /// 节点回答的是前者。
    ///
    /// `good` 不映射成 `verified`：绝大多数段都是 good，给每段都点一个
    /// 绿点等于没有状态编码。已核实只来自真的跑过核查且结论为 verified
    static func resolve(segment: TranscriptSegment,
                        checkState: SegmentCheckState,
                        isActive: Bool) -> TimelineNodeStatus {
        if isActive { return .live }
        switch segment.qualityGrade {
        case .poor: return .untrustworthy
        case .fair: return .doubtful
        default: break
        }
        switch checkState {
        case .done(.verified): return .verified
        case .done(.disputed): return .doubtful
        case .done(.unverifiable): return .unverifiable
        case .none, .checking, .failed: return .unchecked
        }
    }

    // MARK: - 自检

    struct SelfTestResult {
        var lines: [String]
        var passed: Int
        var failed: Int
    }

    /// `--timeline-selftest`：节点颜色映射（6 种状态）+ live 标记。
    /// 竖线是否真的贯穿由快照的像素判据验（`--ui-snapshot`），这里不重复
    static func selfTest() -> SelfTestResult {
        var lines: [String] = ["时间轴节点自检（纯函数 · 不依赖界面）"]
        var passed = 0
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        func segment(grade: TranscriptGrade?) -> TranscriptSegment {
            var s = TranscriptSegment(
                text: "夹具", isFinal: true,
                startTimeMillis: 0, endTimeMillis: 1_000,
                timestamp: Date(timeIntervalSince1970: 0), languages: ["zh-CN"]
            )
            s.qualityGrade = grade
            return s
        }

        // 五条：状态 → 颜色。逐条对着 `Theme` 的颜色断言，
        // 而不是对着 `TimelineNodeStatus` 自己再写一遍同样的 switch
        let cases: [(name: String, status: TimelineNodeStatus,
                     check: SegmentCheckState, grade: TranscriptGrade?,
                     color: Color)] = [
            ("已核实 → success", .verified, .done(.verified), .good, Theme.success),
            ("存疑 → warning", .doubtful, .none, .fair, Theme.warning),
            ("不可信 → error", .untrustworthy, .none, .poor, Theme.error),
            ("无法核实 → unknown", .unverifiable, .done(.unverifiable), .good, Theme.unknown),
            ("未核查 → textTertiary", .unchecked, .none, .good, Theme.textTertiary),
        ]
        for c in cases {
            let resolved = resolve(segment: segment(grade: c.grade),
                                   checkState: c.check, isActive: false)
            check(resolved == c.status && resolved.color == c.color,
                  c.name,
                  resolved == c.status ? "" : "（实得 \(resolved.rawValue)）")
        }

        // live：正在转写的那一段，状态判定必须压过其它所有状态，
        // 并且带 `isLive` 标记——动画开关读的就是它
        let live = resolve(segment: segment(grade: .poor),
                           checkState: .done(.disputed), isActive: true)
        check(live == .live && live.isLive,
              "live 覆盖质量/核查状态并带 animating 标记",
              "（实得 \(live.rawValue) / isLive=\(live.isLive)）")
        check(TimelineNodeStatus.allCases.filter(\.isLive) == [.live],
              "只有 live 状态带 animating 标记",
              "（实得 \(TimelineNodeStatus.allCases.filter(\.isLive).map(\.rawValue))）")

        // P15-4：卡片是「挂在轴上」，不是浮起来的列表项——elevation 必须
        // 是 0（浅色下一级就会出两层阴影），且离轴 16
        check(TimelineMetrics.cardElevation == 0,
              "卡片 elevation = 0（时间轴上不出阴影）",
              "（实得 \(TimelineMetrics.cardElevation)）")
        check(TimelineMetrics.contentInset == 16,
              "轨道到卡片 16",
              "（实得 \(TimelineMetrics.contentInset)）")

        lines.append("")
        lines.append(failed == 0
                     ? "✅ 时间轴节点自检通过（\(passed) 条）"
                     : "❌ 时间轴节点自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }
}

/// 时间轴一行的尺寸。数值是派单定死的；**间距 12 / 行内 6 直接复用
/// `Theme` 的档位**，不在这里另开一套。
enum TimelineMetrics {
    /// 节点直径 8、竖线 1pt、竖线不透明度 35%
    static let nodeDiameter: CGFloat = 8
    static let lineWidth: CGFloat = 1
    static let lineOpacity: Double = 0.35
    /// 节点中心离行顶 8：时间戳是 11pt/16 行高，节点正中对着它的中线
    static let nodeCenterY: CGFloat = 8
    /// 轨道左沿到卡片左沿 16。节点中心在 x=4（线也在那），所以卡片离
    /// 竖线中心 12——P15-4 评审嫌 20 太大、卡片像散落的独立块，收到 16
    static let contentInset: CGFloat = 16
    /// 时间轴上的卡片**不带阴影**（elevation 0）。卡片是挂在轴上的一个
    /// 段落，不是浮起来的列表项；浅色下哪怕只给一级阴影，一排卡片也会
    /// 各自投出影子，把一条连续的流读成互不相干的条目
    static let cardElevation = 0
    /// 相邻段之间 12
    static let rowSpacing: CGFloat = Theme.Spacing.s12
    /// 节点行与正文 6
    static let nodeToBody: CGFloat = Theme.Spacing.s6
    /// 最后一段竖线往下渐隐的长度
    static let fadeLength: CGFloat = 28
}

/// 转录时间轴的一行：左侧竖线 + 节点，右侧时间戳 + 卡片。
///
/// **竖线按行画，不按整段画**：整段一条线需要量到所有行的真实高度，
/// 而列表是 `LazyVStack`，屏幕外的行还没被创建，量不到就等于线在
/// 每一屏的底部断掉。按行画则每行只负责自己那一段：行与行之间
/// 用「行底 padding + spacing 0」无缝接上，滚到哪里都是连续的。
struct TranscriptTimelineRow: View {
    let segment: TranscriptSegment
    let status: TimelineNodeStatus
    let isFirst: Bool
    let isLast: Bool
    let attachments: [ImageAttachment]
    let checkState: SegmentCheckState
    var onRemoveAttachment: ((ImageAttachment) -> Void)?
    var onCheck: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: TimelineMetrics.nodeToBody) {
            // 时间戳从卡片里搬到这里（P15-3）：它定位的是**这一行**，
            // 不是卡片内部的一行元数据
            Text(segment.formattedTimestamp)
                .font(Theme.Text.footnote.font
                    .weight(.semibold)
                    .monospacedDigit())
                .foregroundStyle(Theme.textSupporting)

            TranscriptLine(
                segment: segment,
                attachments: attachments,
                onRemoveAttachment: onRemoveAttachment,
                checkState: checkState,
                onCheck: onCheck,
                cardElevation: TimelineMetrics.cardElevation,
                // P15-4：live 只由节点（accent 呼吸点）表达。原来把
                // `isActive` 透传给卡片，会叠一层 4% 的 highlight 底，
                // 最后一段看起来像被单独选中的浅灰卡——它不是选中项
                isActive: false,
                showsTimestamp: false
            )
        }
        .padding(.leading, TimelineMetrics.contentInset)
        .padding(.bottom, isLast ? 0 : TimelineMetrics.rowSpacing)
        .overlay(alignment: .topLeading) {
            TimelineRail(status: status, isFirst: isFirst, isLast: isLast)
                .frame(width: TimelineMetrics.nodeDiameter)
        }
    }
}

/// 左侧轨道：一条贯穿的竖线 + 一个状态节点。
private struct TimelineRail: View {
    let status: TimelineNodeStatus
    let isFirst: Bool
    let isLast: Bool

    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let top = isFirst ? TimelineMetrics.nodeCenterY : 0
            // 时长 0.6 秒的单程 × autoreverse = 1.2 秒一个完整循环
            ZStack(alignment: .top) {
                Canvas { context, size in
                    guard size.height > top else { return }
                    var path = Path()
                    path.move(to: CGPoint(x: centerX, y: top))
                    path.addLine(to: CGPoint(x: centerX, y: size.height))
                    let color = Theme.textTertiary
                        .opacity(TimelineMetrics.lineOpacity)
                    if isLast {
                        // 最后一段的下沿渐隐到 0：时间轴在这里结束，
                        // 一刀切的断头线会被读成「下面还有内容没画」
                        let fadeStart = max(top, size.height - TimelineMetrics.fadeLength)
                        context.stroke(
                            path,
                            with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: color, location: 0),
                                    .init(color: color,
                                          location: fadeStart / max(size.height, 1)),
                                    .init(color: .clear, location: 1),
                                ]),
                                startPoint: CGPoint(x: centerX, y: 0),
                                endPoint: CGPoint(x: centerX, y: size.height)
                            ),
                            lineWidth: TimelineMetrics.lineWidth
                        )
                    } else {
                        context.stroke(path, with: .color(color),
                                       lineWidth: TimelineMetrics.lineWidth)
                    }
                }

                Circle()
                    .fill(status.color)
                    .frame(width: TimelineMetrics.nodeDiameter,
                           height: TimelineMetrics.nodeDiameter)
                    .scaleEffect(pulse ? 1.35 : 1.0)
                    .position(x: centerX, y: TimelineMetrics.nodeCenterY)
            }
        }
        .onAppear {
            // 呼吸只给 live 节点。repeatForever 挂在 withAnimation 上，
            // 而不是给 Circle 一个常驻 animation modifier——后者会在
            // 每次重绘时重新起一轮，动画相位随滚动抖
            guard status.isLive else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}
