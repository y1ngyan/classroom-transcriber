import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    enum Tab: String, CaseIterable {
        case transcription = "转录"
        case recordings = "录音"
        case factCheck = "事实核查"
        case notes = "笔记"
        case glossary = "术语表"
        // 位置按 B4a 的功能顺序：词库 → 查答案 → 说话人。
        // tab 从 6 变 7，宽度只有实机能量（拍板第 10 条：先按 7 个做，
        // 挤的话再退回「提问并入录音详情」那条路）
        case questions = "提问"
        case settings = "设置"
    }

    /// 选中项住在 `AppState`（见那边的注释）：录音空状态的引导按钮要能切页
    private var tab: Tab { appState.selectedTab }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Group {
                switch tab {
                case .transcription:
                    TranscriptionView()
                case .recordings:
                    RecordingsView()
                case .factCheck:
                    FactCheckView()
                case .notes:
                    NotesView()
                case .glossary:
                    GlossaryView()
                case .questions:
                    QuestionsView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }

    private var tabBar: some View {
        HStack(spacing: Theme.Spacing.lg) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { appState.selectedTab = item }
                } label: {
                    VStack(spacing: Theme.Spacing.xs) {
                        Text(item.rawValue)
                            // 选中态只靠字重和颜色区分，不加底、不加框
                            .font(.system(
                                size: Theme.Text.caption.size,
                                weight: tab == item ? .medium : .regular
                            ))
                            .foregroundStyle(tab == item ? Theme.textPrimary : Theme.textSecondary)

                        // 选中下标。未选中时留同尺寸的透明块占位，
                        // 否则切换时整排标签会左右挪一下
                        Rectangle()
                            .fill(tab == item ? Theme.accent : Color.clear)
                            .frame(width: 22, height: 2)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if tab == .transcription, appState.transcription.isRunning {
                StatusMark(kind: .live, text: "录制中")
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.md)
        .overlay(alignment: .bottom) {
            Separator()
        }
    }
}
