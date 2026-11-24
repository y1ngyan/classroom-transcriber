import SwiftUI
import AppKit

/// 悬浮字幕窗（「灵动岛」式）：贴在屏幕顶部的一条胶囊，说话时展开两行，
/// 停顿几秒后缩成小胶囊。**点一下就能开始/停止录音**，按住可以拖到任意位置。
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
    /// 界面层。**弱引用**：浮层不该把整个 AppState 拽住，
    /// 否则 App 关掉后浮层控制器还留着一个活的 AppState
    private weak var appState: AppState?
    private var model = SubtitleOverlayModel()

    private var idleTask: Task<Void, Never>?
    /// 用户是否亲手拖过（拖过就不再自动居中）
    private var hasUserPosition = false
    /// 最近一次「窗口被移动」的时刻。拖动中每秒会来几十条 didMove，
    /// 每条都写配置、并照旧按旧位置 setFrame 的话，窗口会被自己的刷新拽回去
    private var lastMoveAt: Date = .distantPast
    private var persistTask: Task<Void, Never>?
    /// 拖动后的左上角位置（y 存的是顶边：窗口高度会随展开变化）
    private var savedOrigin: CGPoint?

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    /// 由 App 在启动时接上（主线程）
    func attach(appState: AppState) {
        self.appState = appState
    }

    /// 点一下岛：没在录就开始，在录就停。
    ///
    /// 和转录页那个按钮走**同一条**路径（`startTranscription` / `stop`），
    /// 不在浮层里另写一份启动逻辑——两份启动迟早分家，而且是那种最难查的分家
    func toggleRecording() {
        guard let appState else { return }
        if appState.transcription.isRunning {
            appState.transcription.stop()
        } else {
            Task { await appState.startTranscription() }
        }
        refresh()
    }

    func show() {
        if panel == nil {
            let saved = AppConfig.subtitleOverlayOrigin
            hasUserPosition = saved != nil
            savedOrigin = saved.map { CGPoint(x: $0.x, y: $0.top) }
            panel = makePanel()
        }
        panel?.orderFrontRegardless()
        scheduleIdleCheck()
    }

    func hide() {
        idleTask?.cancel()
        idleTask = nil
        persistTask?.cancel()
        persistTask = nil
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
        // 拖动中/刚拖完：不要按旧位置重排，否则窗口会被自己的刷新拽回去
        guard Date().timeIntervalSince(lastMoveAt) > 0.35 else { return }

        let isRecording = appState?.transcription.isRunning ?? false
        hosting.rootView = SubtitleIslandView(
            model: model,
            isRecording: isRecording,
            onTap: { [weak self] in self?.toggleRecording() }
        )

        let snapshot = SubtitleOverlayLogic.snapshot(recent: model.lines,
                                                     secondsSinceUpdate: model.secondsSinceUpdate)
        let units = SubtitleOverlayLogic.widthUnits(for: snapshot.lines)
        let width = CGFloat(units) * 13 + 48          // 13pt ≈ 一个中文字宽
        let height: CGFloat = snapshot.collapsed ? 34 : 34 + CGFloat(max(0, snapshot.lines.count - 1)) * 22

        if hasUserPosition, let origin = savedOrigin {
            // 拖动过：保持左上角不动，只让高度向下长（否则展开时会盖住上方的字）
            let top = origin.y + panel.frame.height
            var rect = NSRect(x: origin.x, y: top - height, width: width, height: height)
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                rect.origin.x = min(max(rect.minX, visible.minX + 4), visible.maxX - width - 4)
                rect.origin.y = min(max(rect.minY, visible.minY + 4), visible.maxY - height - 4)
            }
            panel.setFrame(rect, display: true)
        } else if let screen = NSScreen.main {
            let x = screen.frame.midX - width / 2
            let top = screen.visibleFrame.maxY - 12
            panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        }
    }

    /// 每秒看一眼「是不是该收起了」，顺带把录音状态刷上去。
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
                // 每秒重建一次：绿点/「点我开始录制」要跟着引擎状态走，
                // 不能等下一句话来了才更新（用户点了开始却半天没反应会以为没生效）
                self.refresh()
            }
        }
    }

    /// 窗口被移动。
    ///
    /// 拖动过程中每秒会收到几十条通知：这里**只记时间**，等停下来
    /// （350ms 没有新移动）再记位置、写配置。原来每条都写一次配置，
    /// 既卡又在拖动中途改窗口尺寸，手感就是「拖不准」
    private func handleWindowMoved() {
        lastMoveAt = Date()
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.commitUserPosition()
        }
    }

    /// 停稳之后才记：顶边固定（窗口随行数长高时向下长）
    private func commitUserPosition() {
        guard let panel else { return }
        let frame = panel.frame
        hasUserPosition = true
        savedOrigin = CGPoint(x: frame.minX, y: frame.maxY)
        AppConfig.setSubtitleOverlayOrigin(x: Double(frame.minX), top: Double(frame.maxY))
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
        // 允许点击（一键录音）、允许拖动（拖到不挡字幕的地方）。
        // `ignoresMouseEvents` 必须为 false，否则鼠标事件根本到不了窗上
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: SubtitleIslandView(
            model: model,
            isRecording: appState?.transcription.isRunning ?? false,
            onTap: { [weak self] in self?.toggleRecording() }
        ))
        // 用户一拖，就记下位置并停止自动居中——否则下一句一来就被拽回屏幕顶部，
        // 用户会觉得「拖了没用」
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWindowMoved() }
        }
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

/// 岛的样子：说话时两行字，静止只剩一个小胶囊 + 状态点
struct SubtitleIslandView: View {
    var model: SubtitleOverlayModel
    /// 正在录音吗。点一下岛就能开关，所以这个状态必须一眼看得出，
    /// 否则用户不知道自己是「点了没反应」还是「没点中」
    var isRecording: Bool = false
    var onTap: () -> Void = {}

    private var snapshot: SubtitleOverlayLogic.Snapshot {
        SubtitleOverlayLogic.snapshot(recent: model.lines,
                                      secondsSinceUpdate: model.secondsSinceUpdate)
    }

    var body: some View {
        let snap = snapshot
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // 绿点 = 正在录；灰点 = 没在录。点一下岛就能开关，所以这个点必须
                // 一眼看得出状态，否则用户不知道自己是「点了没反应」还是「没点中」
                Circle()
                    .fill(isRecording ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                if snap.collapsed {
                    Text(SubtitleOverlayLogic.statusLabel(isRecording: isRecording,
                                                          hasLines: !snap.lines.isEmpty))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isRecording ? .secondary : .primary)
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
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { onTap() }
        .help(isRecording ? "点一下停止录音" : "点一下开始录音")
    }
}
