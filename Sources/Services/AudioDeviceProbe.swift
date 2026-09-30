import AVFoundation
import Foundation

/// `--audio-devices`：**只读**列出输入设备。
///
/// 派单书 ① 要的四样（名称 / UID / 输入声道数 / 当前采样率 / 是不是系统默认输入），
/// 外加一件容易混掉的事：**`AVAudioEngine` 的输入节点实际用的那一个，与
/// 「系统默认输入」不是同一个概念**。所以这两个分别报，不合并成一格。
///
/// **它不录音、不开设备、不改任何系统音频设置、不触发授权弹窗**（派单书 ① 的
/// 三条禁令 + ⑨）。具体做法：整条路走 CoreAudio 的 HAL 属性读取
/// （`InputDeviceCatalog`），一次都不碰 `AVAudioEngine`。
enum AudioDeviceProbe {

    static func run() -> [String] {
        var lines: [String] = []
        lines.append("输入设备清单（只读 · 不录音 · 不发声 · 不改系统音频设置）")
        lines.append("")

        let status = InputDeviceCatalog.microphoneAuthorization
        lines.append("麦克风授权：\(status.displayName)")
        if status != .authorized {
            // ⑨：未授权也要**说清楚为什么**，不能只给一个空列表让人猜。
            // 这一条尤其反直觉——HAL 枚举**不需要**授权，所以设备名照样列得出来，
            // 而人会以为「都列出来了，那授权肯定是好的」。所以这句话必须点破：
            // 列得出来 ≠ 录得了
            lines.append("  ⚠️ 未授权**不影响下面这份清单**（CoreAudio 枚举设备不需要授权），")
            lines.append("     但它会让 \("--mic-level") 拒绝运行。")
            for line in InputDeviceCatalog.unauthorizedAdvice.split(separator: "\n") {
                lines.append("     \(line)")
            }
        }
        lines.append("")

        let defaultID = InputDeviceCatalog.defaultInputDeviceID()
        let devices = InputDeviceCatalog.allInputDevices()

        if devices.isEmpty {
            lines.append("❌ 一只输入设备都列不出来。可能的原因：")
            lines.append("   · 机器上确实一个输入设备都没有（连内建麦都没有是异常）")
            lines.append("   · 更常见的是刚才那条授权状态不是「已授权」，系统把它挡住了")
            lines.append("     ——这种情况下先去授权，再重跑本入口")
            return lines
        }

        lines.append("系统默认输入设备：")
        if let info = InputDeviceCatalog.info(of: defaultID) {
            lines.append("  \(info.name)   ← 系统的默认输入（CoreAudio kAudioHardwarePropertyDefaultInputDevice）")
            lines.append("     UID \(info.uid) · \(info.channels)ch · \(Int(info.sampleRate))Hz")
        } else {
            lines.append("  （读不出来。defaultInputDeviceID = \(defaultID)）")
        }
        lines.append("")

        lines.append("全部输入设备（\(devices.count) 只）：")
        for (id, info) in devices {
            let mark = id == defaultID ? "●" : "○"
            let note = id == defaultID ? "  ← 系统默认输入" : ""
            lines.append("  \(mark) \(info.name)\(note)")
            lines.append("     ID \(id) · UID \(info.uid) · \(info.channels)ch · \(Int(info.sampleRate))Hz")
        }
        lines.append("")

        // 「引擎会用的那一个」单列一格，理由就是它会和上面那个不一样。
        //
        // **⚠️ 这一格有副作用，得说清楚**：2026-09-30 实测，光构造一个
        // `AVAudioEngine`（不 prepare、不 start）就会让 CoreAudio 在**本进程里**
        // 造出一只私有聚合设备 `CADefaultDeviceAggregate-<pid>-0`，并把它加进
        // `kAudioHardwarePropertyDevices`。它不占麦克风、不改任何设置、进程退出
        // 即消失，但上面那份「全部输入设备」是在它出现**之前**列的——先后顺序
        // 决定了这份清单里有没有它。所以下面这一格明确标出来
        lines.append("AVAudioEngine 输入节点当前报告的 deviceID：\(engineDeviceIDText())")
        lines.append("  说明：这一格是**构造 AVAudioEngine 读出来的**，而光是构造它就会让")
        lines.append("  系统多出一只进程私有的聚合设备（名字里带 pid、退出即消失）。")
        lines.append("  引擎报的若是这种容器，`InputDeviceResolution` **不会**把它写进存档，")
        lines.append("  而是回落到系统默认输入并记 source=default——容器不是麦克风，")
        lines.append("  而且那个名字事后对不上任何东西。")
        return lines
    }

    /// 不启动引擎地读一次 `inputNode.auAudioUnit.deviceID`。
    ///
    /// 这是唯一一处碰 `AVAudioEngine` 的地方，而且**只是构造一下、读一个属性**：
    /// 不 `prepare()`、不 `start()`、不装 tap——设备一次都不会被占住
    /// （实测：构造 + 读属性不触发麦克风占用，也不弹授权框）
    private static func engineDeviceIDText() -> String {
        let engine = AVAudioEngine()
        let id = engine.inputNode.auAudioUnit.deviceID
        guard let info = InputDeviceCatalog.info(of: id) else {
            return "\(id)（**指不上任何设备**——存档里不会记它）"
        }
        if info.isCoreAudioDefaultAggregate {
            return "\(id)（\(info.name) · **CoreAudio 自己造的默认聚合容器**，"
                + "不是麦克风；存档里会回落到系统默认输入）"
        }
        return "\(id)（\(info.name)）"
    }
}
