import SwiftUI

/// 录音列表顶部「本周概览」（P15-2）。
///
/// 它不是卡片，是一层**数据画面**：标题、三个读数、一排 7 天柱。
/// 用留白和下方一条分隔线与列表分开——卡片在录音页的含义是「一条录音」，
/// 给概览也套一张卡会让它看起来像一条可以点进去的记录。
///
/// 所有数字来自 `RecordingStats`（纯函数聚合），视图不自己算数，
/// 也不在 body 里读盘：概览只是 index.json 摘要的一次投影。
struct RecordingsOverview: View {
    let stats: RecordingStats

    /// 柱高 36、柱宽 6、间距 4、圆角 2：派单定死的一组尺寸。
    /// 7 × 6 + 6 × 4 = 66pt 宽，比三个读数窄许多，所以左对齐后
    /// 右半边是留白——概览是读数，不是占满整行的仪表盘
    private enum Bar {
        static let width: CGFloat = 6
        static let spacing: CGFloat = Theme.Spacing.xs
        static let height: CGFloat = 36
        static let cornerRadius: CGFloat = 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本周")
                .textStyle(Theme.Text.footnote)
                .fontWeight(.semibold)
                .tracking(0.5)
                .foregroundStyle(Theme.textSupporting)
                .padding(.bottom, Theme.Spacing.s10)

            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s32) {
                metric(stats.formattedWeeklyDuration, color: Theme.textPrimary)
                metric("\(stats.weeklySessionCount) 段课", color: Theme.textPrimary)
                // 存疑用 warning 色：它是这条概览里唯一需要用户留意的数字，
                // 另外两个只是规模。三个都主色的话，扫一眼分不出重点
                metric("\(stats.doubtfulSegmentCount) 段存疑", color: Theme.warning)
            }
            .padding(.bottom, Theme.Spacing.md)

            HStack(alignment: .bottom, spacing: Bar.spacing) {
                ForEach(Array(stats.dailyValues.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: Bar.cornerRadius)
                        // 当天用 accent；其余三级色 50%，不与当天争视觉重量。
                        // 空天高度为 0（归一化判据要求），不画最小高度去假装有数据
                        .fill(index == stats.dailyValues.count - 1
                              ? Theme.accent
                              : Theme.textTertiary.opacity(0.5))
                        .frame(width: Bar.width, height: Bar.height * max(0, min(1, value)))
                }
            }
            // 柱高只在容器底部对齐；给容器固定的 36 高，空天就不会把整排压扁
            .frame(height: Bar.height, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 只展示，不响应点击：概览没有下钻目标，做成可点只会给一个死入口
        .accessibilityElement(children: .combine)
    }

    private func metric(_ text: String, color: Color) -> some View {
        Text(text)
            .textStyle(Theme.Text.metric)
            .monospacedDigit()
            .foregroundStyle(color)
    }
}
