import AVFoundation
import Foundation
import Observation

/// 转录详情页的音频播放器（P17）。
///
/// **为什么是「一个全局实例」而不是详情页自己的 `@State`**：这个仓库在
/// P17 之前没有任何播放器（录音列表那个 ▶ 只是装饰图标，整张卡点了是
/// 打开详情）。派单要求「沿用现有播放器，不要新建第二套」——现状是零套，
/// 所以这里只建一套，挂在 `AppState.transcriptPlayer` 上。切标签页、
/// 进出详情页都不该有两个 `AVAudioPlayer` 抢同一个输出设备。
///
/// **多片段会话**：一条会话可以由多次录制拼起来（「接着录」），音频是
/// 每个片段一个 wav，时间轴却是跨片段连续的。播放器因此维护一组
/// `Clip`（片段 id + 绝对偏移），按会话时间轴上的毫秒定位到具体文件；
/// 播完一个片段自动接下一个。
///
/// **它不做的事**：不调 `AVAudioSession`（macOS 桌面 App 不适用）、
/// 不改系统音量、不循环。没有音频的会话（`fileName == nil`）里
/// `hasAudio` 为 false，点句子只移动高亮位置、不会假装在播放。
@MainActor
@Observable
final class TranscriptPlayer {

    /// 一个片段对应的音频文件，`offsetMillis` 是它在会话时间轴上的起点
    struct Clip: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let offsetMillis: Int
        let durationMillis: Int

        var endMillis: Int { offsetMillis + durationMillis }
        var range: Range<Int> { offsetMillis..<max(offsetMillis, endMillis) }
    }

    private(set) var clips: [Clip] = []
    /// 会话时间轴上的绝对毫秒。播放中用 0.1 秒的轮询刷新
    private(set) var currentTimeMillis = 0
    private(set) var isPlaying = false
    private(set) var loadedSessionID: UUID?

    private var player: AVAudioPlayer?
    private var activeClipID: UUID?
    private var tickTask: Task<Void, Never>?

    var hasAudio: Bool { !clips.isEmpty }

    // MARK: - 装载

    /// 会话换了才重建 clip 列表。同一会话反复进出详情页不重置播放位置——
    /// 用户翻回列表再点进来，刚才听到哪儿还在
    func load(session: RecordingSession, audioDirectory: URL) {
        guard loadedSessionID != session.id else { return }
        stop()
        loadedSessionID = session.id
        clips = session.parts.compactMap { part in
            guard let name = part.fileName, !name.isEmpty else { return nil }
            return Clip(
                id: part.id,
                url: audioDirectory.appendingPathComponent(name),
                offsetMillis: part.offsetMillis,
                durationMillis: part.durationMillis
            )
        }
    }

    // MARK: - 播放控制

    /// 跳到会话时间轴上的某毫秒。`play == false` 只定位不发声。
    func seek(toMillis millis: Int, play: Bool) {
        let target = max(0, millis)
        guard !clips.isEmpty else {
            currentTimeMillis = target
            return
        }

        let clip = clip(containing: target) ?? (target < clips[0].offsetMillis ? clips[0] : clips[clips.count - 1])
        let local = max(0, target - clip.offsetMillis)

        if activeClipID != clip.id || player == nil {
            reload(clip)
        }
        guard let player else {
            currentTimeMillis = target
            return
        }

        player.currentTime = min(Double(local) / 1000,
                                 max(0, Double(clip.durationMillis) / 1000))
        currentTimeMillis = target

        if play {
            player.play()
            isPlaying = player.isPlaying
            if isPlaying { startTicker() }
        } else {
            player.pause()
            isPlaying = false
            stopTicker()
        }
    }

    /// 空格键：播放 / 暂停。暂停后再按从当前位置继续
    func togglePlayPause() {
        if isPlaying {
            pause()
            return
        }
        guard hasAudio else { return }
        if player == nil {
            seek(toMillis: currentTimeMillis, play: true)
        } else {
            player?.play()
            isPlaying = player?.isPlaying ?? false
            if isPlaying { startTicker() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    /// 离开详情页 / 换会话：停声、清定时轮询。**不删任何文件**
    func stop() {
        player?.stop()
        player = nil
        activeClipID = nil
        isPlaying = false
        stopTicker()
        currentTimeMillis = 0
    }

    // MARK: - 内部

    private func reload(_ clip: Clip) {
        player?.stop()
        guard let created = try? AVAudioPlayer(contentsOf: clip.url) else {
            player = nil
            activeClipID = nil
            return
        }
        created.prepareToPlay()
        player = created
        activeClipID = clip.id
    }

    private func clip(containing millis: Int) -> Clip? {
        // 片段边界那一毫秒归后一个片段：前一段的 end 和后一段的 offset
        // 在正常数据里相等，归前归后都行，定死一边免得两边都命中断言
        clips.first { $0.offsetMillis <= millis && millis < $0.endMillis }
            ?? clips.last { $0.offsetMillis <= millis }
    }

    private func startTicker() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.poll()
            }
        }
    }

    private func stopTicker() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func poll() {
        guard isPlaying,
              let player,
              let clip = clips.first(where: { $0.id == activeClipID })
        else { return }

        currentTimeMillis = clip.offsetMillis + Int(player.currentTime * 1000)

        // `currentTime > 0.05` 用来排除「刚 play() 还没真正开始」的那一拍：
        // AVAudioPlayer 起播有一小段延迟，这时 isPlaying 可能还是 false，
        // 不设这个门槛会把开头当成「已经播完」
        guard !player.isPlaying, player.currentTime > 0.05 else { return }

        if let next = clips.first(where: { $0.offsetMillis >= clip.endMillis }) {
            seek(toMillis: next.offsetMillis, play: true)
        } else {
            currentTimeMillis = clip.endMillis
            isPlaying = false
            stopTicker()
        }
    }
}
