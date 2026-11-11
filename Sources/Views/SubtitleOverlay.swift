import SwiftUI
import AppKit

/// 悬浮字幕窗（「灵动岛」式）：贴在屏幕顶部中间的一条胶囊，
/// 说话时展开成两行字，停顿几秒后缩成一个小胶囊。
///
/// 为什么是 `NSPanel` 而不是 SwiftUI `WindowGroup`：
/// - 它不能抢焦点（用户正在看网课，字幕窗一抢焦点网课就暂停了）；
/// - 要浮在全屏 App 之上（网课多半是全屏播放），`collectionBehavior` 里要有
///   `.fullScreenAuxiliary`；
/// - 要能出现在所有 Space 上（`.canJoinAllSpaces`）。
/// `WindowGroup` 这三条都做不到，或者要绕很多圈。
@MainActor
final class SubtitleOverlayController {

    static let shared = SubtitleOverlayController()

    private var panel: NSPanel?
    private var model = SubtitleOverlayModel()
    private var idleTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        scheduleIdleCheck()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        idleTask?.cancel()
        idleTask = nil
        panel?.orderOut(nil)
        panel = nil                     // 下次 show 重建，避免残留旧尺寸
    }

    /// 收一句新文本。空串会被忽略（静音窗不产生段，不该把字幕刷空）
    func push(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.append(text)
        refresh()
        scheduleIdleCheck()
    }

    /// 清空（停止转录时调用）
    func clear() {
        model.reset()
        refresh()
    }

    private func refresh() {
        guard let panel, let hosting = panel.contentView as? NSHostingView<SubtitleIslandView> else {
            return
        }
        hosting.rootView = SubtitleIslandView(model: model)
        let snapshot = SubtitleOverlayLogic.snapshot(recent: model.lines,
                                                     secondsSinceUpdate: model.secondsSinceUpdate)
        let units = SubtitleOverlayLogic.widthUnits(for: snapshot.lines)
        let width = CGFloat(units) * 13 + 48          // 13pt ≈ 一个中文字宽
        let height: CGFloat = snapshot.collapsed ? 34 : 34 + CGFloat(max(0, snapshot.lines.count - 1)) * 22
        if let screen = NSScreen.main {
            let x = screen.frame.midX - width / 2
            let top = screen.visibleFrame.maxY - 12
            panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        }
    }

    /// 每秒看一眼「是不是该收起了」。
    ///
    /// 用 Task 循环而不是 `Timer`：Timer 的回调是 `@Sendable`，要跨 actor 调
    /// `invalidate()`/`refresh()`，Swift 6 会判数据竞争；Task 由 `@MainActor`
    /// 继承隔离，天然不用加锁
    private func scheduleIdleCheck() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.model.tick()
                let snapshot = SubtitleOverlayLogic.snapshot(recent: self.model.lines,
                                                             secondsSinceUpdate: self.model.secondsSinceUpdate)
                if snapshot.collapsed { self.refresh() }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true         // 字幕不该拦住鼠标点击
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: SubtitleIslandView(model: model))
        return panel
    }
}

/// 悬浮窗的状态：最近几句 + 最后一次更新时刻
@Observable
@MainActor
final class SubtitleOverlayModel {
    private(set) var lines: [String] = []
    private(set) var lastUpdate = Date()
    /// 每句完成后记一次时间，供「停顿就收起」判断
    private(set) var lastCompletion = Date()

    var secondsSinceUpdate: Double {
        Date().timeIntervalSince(lastCompletion)
    }

    func append(_ text: String) {
        lines.append(text)
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
        lastUpdate = Date()
        lastCompletion = Date()
    }

    func tick() { /* 只用来推动重绘；时间由 `secondsSinceUpdate` 现算 */ }

    func reset() {
        lines = []
        lastUpdate = Date()
        lastCompletion = Date.distantPast
    }
}

/// 岛的样子：说话时两行字，静止只剩一个小胶囊 + 呼吸点
struct SubtitleIslandView: View {
    var model: SubtitleOverlayModel

    private var snapshot: SubtitleOverlayLogic.Snapshot {
        SubtitleOverlayLogic.snapshot(recent: model.lines,
                                      secondsSinceUpdate: model.secondsSinceUpdate)
    }

    var body: some View {
        let snap = snapshot
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(snap.collapsed ? Color.gray : Color.green)
                    .frame(width: 7, height: 7)
                if snap.collapsed {
                    Text(snap.lines.isEmpty ? "转录待机" : "已暂停说话")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if let latest = snap.lines.last {
                    Text(latest)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !snap.collapsed, snap.lines.count > 1, let previous = snap.lines.first {
                Text(previous)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // 深色半透明底 + 材质：压在全屏视频上也不会糊成一片
            RoundedRectangle(cornerRadius: snap.collapsed ? 17 : 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: snap.collapsed ? 17 : 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .padding(1)
    }
}
