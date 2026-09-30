import AVFoundation
import CoreAudio
import Foundation

/// 一只输入设备的身份快照。**存档里记的就是它**（见 `RecordingCapture`）。
///
/// 为什么四个字段都要存，而不是只存一个名字：同名设备是真实存在的
/// （插两只同样的 USB 麦、同一型号的耳机换着用），而**名字也不是稳定标识**
/// ——用户能在「音频 MIDI 设置」里改设备名，改了之后历史存档就对不上了。
/// `uid` 才是 CoreAudio 认的那个稳定标识（换名字、换插口都不变）。
/// 声道数和采样率是「这条录音当时是什么形态」的现场证据：它们变了
/// 说明采集链路换过一档，而这正是事后要回答的问题
struct InputDeviceInfo: Codable, Equatable {
    var name: String
    var uid: String
    /// 输入声道数（`kAudioDevicePropertyStreamConfiguration` 的输入侧求和）
    var channels: Int
    /// 名义采样率 Hz
    var sampleRate: Double

    /// CoreAudio 为了「跟着系统默认设备走」**自己造出来**的那只私有聚合设备。
    ///
    /// 2026-09-30 实测（`/tmp/devprobe2.swift`，本机）：**光构造一个
    /// `AVAudioEngine`**（不 prepare、不 start）就会让 CoreAudio 在进程里凭空
    /// 多出一只 `CADefaultDeviceAggregate-<pid>-0`（transport =
    /// `kAudioDeviceTransportTypeAggregate` = 1735554416，1 个输入声道），
    /// 它随即出现在 `kAudioHardwarePropertyDevices` 里，而引擎的
    /// `inputNode.auAudioUnit.deviceID` 报的就是它。
    ///
    /// **它不该被写进存档**，虽然它「读得出来」：名字里带的是**当前进程的 pid**
    /// （实测 68686 / 68744 两次就不同），进程一退就没了，事后拿这个名字
    /// 对不上任何东西。它是个容器，不是麦克风——它后面的那一只（对默认聚合来说）
    /// 就是系统默认输入，所以这种情况回落到系统默认，并把来源记成 default。
    ///
    /// 用户自己建的聚合设备（uid 是用户起的）不在这一条里：那是一次**明确的**
    /// 选择，照记
    var isCoreAudioDefaultAggregate: Bool {
        uid.hasPrefix("CADefaultDeviceAggregate")
    }
}

/// 中途换设备的一条记录。
///
/// **为什么必须有这一条**（派单书 ②）：外置麦被拔掉、AirPods 断连都是真实场景，
/// 而「这节课前半段用外置麦、后半段回落到内建麦」这件事只在**有第二条记录**
/// 时才看得出来。只有一条「开始时是哪个麦」的话，那节录到一半换了麦的课
/// 仍然无法归属
struct InputDeviceChange: Codable, Equatable {
    /// 相对本次录制起点的毫秒数。
    ///
    /// **粒度就是轮询间隔（1 秒）**，不是换设备的真实时刻——探针只能在
    /// 下一次轮询时发现它。这个数不要当「设备切换发生在第 N 秒」的精确值用，
    /// 它说的是「第 N 秒之后、第 N+1 秒之前」
    var atMillis: Int
    /// 换之前的设备。nil = 之前就读不到设备（引擎还没起/设备全没了）
    var from: InputDeviceInfo?
    /// 换之后的设备。nil = 换完之后读不到（设备被拔掉且没有回落到别的）
    var to: InputDeviceInfo?

    var summary: String {
        let a = from?.name ?? "（无）"
        let b = to?.name ?? "（无）"
        return "设备已变：\(a) → \(b)，发生在第 \(atMillis / 1000) 秒"
    }
}

/// 「这一次录的是哪个麦」——写进存档的那一份。
///
/// 派单书 ② 点名要的六样：设备名 / UID / 输入声道数 / 采样率 / 增益档 / 后端。
/// 前四样在 `device` 里，后两样是**这次录制自己的设置**（不是设置页现在的值）
struct RecordingCapture: Codable, Equatable {
    var device: InputDeviceInfo
    /// 这个设备是怎么定下来的。见 `InputDeviceResolution.Source`
    var source: String
    /// 增益档（`MicGainMode.rawValue`）
    var gain: String
    /// 后端（`TranscriptionBackend.rawValue`）
    var backend: String
    /// 录制途中的换设备记录，按发生顺序。空 = 全程同一只麦
    var changes: [InputDeviceChange] = []
}

/// 输入设备的枚举与身份读取。**只读**：不录音、不开设备、不改任何系统设置。
///
/// 走的是 CoreAudio 的 HAL 属性读取（`AudioObjectGetPropertyData`），不是
/// `AVAudioEngine`——后者只要碰 `inputNode` 就会把设备占住。**这一条是硬约束**：
/// 这个类型会被 `--audio-devices` 这种「只列一下」的入口和 App 启动时的
/// 日志行调用，它们都不许抢用户的麦克风（派单书 ⑩）。
///
/// **它不需要麦克风授权**（实测：HAL 属性读取不触发 TCC）。所以未授权时
/// 设备清单照样列得出来——这一点必须在输出里说清楚，否则「未授权却能列出设备」
/// 会被当成「授权没生效」。授权卡住的是**录音**，见 `MicLevelProbe` 的闸
enum InputDeviceCatalog {

    // MARK: - 原始 HAL 读取

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 系统默认输入设备。读不到返回 0
    static func defaultInputDeviceID() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
        return status == noErr ? id : 0
    }

    /// 全部音频设备（输入输出都在里面）。调用方按输入声道数过滤
    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let text = value else { return nil }
        return text as String
    }

    /// 输入侧的声道数。
    ///
    /// 形状看着绕（先问大小、再分配、再读）是 HAL 的规定动作：
    /// `AudioBufferList` 是个变长结构，字节数只有先问才知道
    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    // MARK: - 对外

    /// 一只设备的身份快照。**输入声道数为 0 的返回 nil**——那是输出设备
    /// （扬声器），列进「输入设备清单」只会让人以为麦克风多了几只。
    /// 读不到名字/UID 也返回 nil：存档里记一只「?」等于没记
    static func info(of id: AudioDeviceID) -> InputDeviceInfo? {
        guard id != 0 else { return nil }
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        guard let name = stringProperty(id, kAudioObjectPropertyName),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
        else { return nil }
        return InputDeviceInfo(
            name: name, uid: uid,
            channels: channels,
            sampleRate: nominalSampleRate(id)
        )
    }

    /// 全部**输入**设备，按 HAL 给的顺序
    static func allInputDevices() -> [(id: AudioDeviceID, info: InputDeviceInfo)] {
        allDeviceIDs().compactMap { id in
            info(of: id).map { (id, $0) }
        }
    }

    /// 麦克风的授权状态（同步查询，**不触发弹窗**）。
    ///
    /// 和 `TranscriptionEngine.requestPermissions()` 的区别就在这：
    /// 那个是 `requestAccess`（会弹窗、会阻塞），这个只读状态。
    /// 探针和启动日志都只该用这一个——它们没有资格替用户做授权决定
    static var microphoneAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 未授权时那句人话。**每条入口都要打同一句**（`--audio-devices` 与
    /// `--mic-level` 共用），免得两处各写一句、哪天改了一处
    static let unauthorizedAdvice = """
    麦克风未授权：去 系统设置 → 隐私与安全性 → 麦克风 里勾上「Classroom Transcriber」，
    或在 App 里点一次录制让它弹窗（这一步必须由人来点，探针不会替你弹）。
    """
}

/// 「该记哪一只设备」。**纯函数**——所以它能被自检直接喂构造好的输入。
///
/// 存在的理由（派单书 ②原话：「不是在别处查一次系统默认就算数」）：
/// `AVAudioEngine` 的输入节点和「系统默认输入设备」**可以不是同一只**
/// （实测：引擎未启动时 `inputNode.auAudioUnit.deviceID` 报 121，
/// 而系统默认输入是 90——两个都不是同一只设备）。所以这里把「谁优先」
/// 写成一个有判据的函数，而不是散在调用点上各写各的
enum InputDeviceResolution {

    /// 这个设备身份是从哪来的。**它必须进存档**：两个来源的可信度不一样，
    /// 事后查「这节课到底用的哪只麦」时，「引擎自己报的」和「引擎没报出可用的、
    /// 我们回落到了系统默认」是两个不同的结论
    enum Source: String {
        /// 引擎输入节点自己报的 deviceID，而且它在设备表里找得到
        case engine
        /// 引擎没报出可用设备（未启动 / 报的是内部占位值 / 设备已消失），
        /// 回落到系统默认输入设备
        case systemDefault = "default"
    }

    struct Resolved: Equatable {
        var info: InputDeviceInfo
        var source: Source
        /// 引擎自己报的那个 ID。**留着是为了事后能对账**：它和 `info`
        /// 对不上时，「引擎报的 ID 不在设备表里」这件事本身就是要记的现场
        var engineDeviceID: AudioDeviceID
    }

    /// 谁优先：**引擎自己报的**，前提是它真的指得上一只麦克风。
    ///
    /// 两道前提都是实测逼出来的，不是防御性编程：
    ///
    /// · **在设备表里找得到**。引擎报的 ID 有可能什么都指不上（0、或者已经
    ///   被拔掉的那只），采信它就会往存档里写一只不存在的麦——比不记更糟，
    ///   因为它看起来是真的；
    /// · **不是 CoreAudio 那只默认聚合设备**。2026-09-30 实测：光构造一个
    ///   `AVAudioEngine` 就会造出一只 `CADefaultDeviceAggregate-<pid>-0`，
    ///   引擎报的就是它。它是**真的**、`info(of:)` 读得出名字，所以「在设备表里
    ///   找得到」这一条拦不住它——而它的名字里带着进程 pid，事后对不上任何东西。
    ///   这半句不加的话，每一节课的存档都会记下这么一只容器
    ///
    /// 落回 `defaultInfo` 时来源记成 `.systemDefault`：**回落这件事本身要留痕**，
    /// 否则事后分不清「引擎自己报的就是它」和「引擎没报出可用的、我们猜的」
    static func resolve(
        engineDeviceID: AudioDeviceID,
        engineInfo: InputDeviceInfo?,
        defaultInfo: InputDeviceInfo?
    ) -> Resolved? {
        if let engineInfo, !engineInfo.isCoreAudioDefaultAggregate {
            return Resolved(info: engineInfo, source: .engine, engineDeviceID: engineDeviceID)
        }
        guard let defaultInfo else { return nil }
        return Resolved(info: defaultInfo, source: .systemDefault, engineDeviceID: engineDeviceID)
    }

    /// `resolve` 加上两次真实查表——**引擎和 App 都调这一个**。
    ///
    /// 两个查表参数带默认值，是为了让自检能塞一张**假设备表**进来：真表在这台
    /// 机器上只有「内建麦 + 外置麦」两只，而「引擎报的这只和系统默认那只不是同一只」
    /// 这个场景，靠真表构造不出来（要构造得先插两只麦）。所以判据只能靠注入。
    ///
    /// 注入的是**两次查表**，不是 `resolve` 本身——「谁优先」那条规则仍然只有
    /// `resolve` 一处写法，自检驱动的是**生产的这个函数**
    static func resolveFromCatalog(
        engineDeviceID: AudioDeviceID,
        engineInfo: (AudioDeviceID) -> InputDeviceInfo? = { InputDeviceCatalog.info(of: $0) },
        defaultInfo: (AudioDeviceID) -> InputDeviceInfo? = { InputDeviceCatalog.info(of: $0) },
        systemDefaultID: () -> AudioDeviceID = { InputDeviceCatalog.defaultInputDeviceID() }
    ) -> Resolved? {
        resolve(
            engineDeviceID: engineDeviceID,
            engineInfo: engineInfo(engineDeviceID),
            defaultInfo: defaultInfo(systemDefaultID())
        )
    }
}

/// 中途换设备的**状态机**。纯值类型、无 IO——自检可以拿一串脚本化的设备序列
/// 直接驱动它，不必真去拔麦。
///
/// 为什么单独一个类型而不是在引擎里写几个 if：换设备这件事有三条容易写错的边
/// （第一次读到的算不算「变化」、读不到设备算不算变化、换回来算不算第二次），
/// 而它们都只在**真实的拔插**里才暴露——没有这个纯函数，就只能靠用户上课时
/// 拔一次麦来验，那种反馈周期不是一个能用的验证方式
struct InputDeviceTracker: Equatable {

    /// 当前认为在用的设备。nil = 还没读到过
    private(set) var current: InputDeviceInfo?
    /// 变化记录，按发生顺序
    private(set) var changes: [InputDeviceChange] = []

    /// 开录时定下第一只设备。**它不算一次「变化」**——「开始录制」不是
    /// 「设备变了」，记进去的话每一节课的存档里都会凭空多一条 A → A
    mutating func start(with device: InputDeviceInfo?) {
        current = device
        changes.removeAll()
    }

    /// 观测一次。返回非 nil = 这一跳发生了换设备（调用方据此记日志）。
    ///
    /// **`nil`（读不到设备）也算一次变化**：外置麦被拔掉、且系统没有回落到
    /// 内建麦时，读到的就是「无」。把它当成「没变」会静默丢掉最要命的那一种现场
    /// ——录音还在继续、但已经没有输入了，而存档上看起来全程一切正常
    ///
    /// **比对的是 `uid`，不是名字**：名字可以被用户改（音频 MIDI 设置里），
    /// 改名不该被记成「换了设备」；而 uid 相同就是同一只麦
    @discardableResult
    mutating func observe(_ device: InputDeviceInfo?, atMillis: Int) -> InputDeviceChange? {
        if let a = current, let b = device, a == b { return nil }
        if current == nil, device == nil { return nil }

        let change = InputDeviceChange(atMillis: atMillis, from: current, to: device)
        current = device
        changes.append(change)
        return change
    }
}
