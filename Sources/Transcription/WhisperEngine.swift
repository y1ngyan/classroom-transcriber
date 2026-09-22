import AVFoundation
import Foundation
import whisper

/// 进程退出前的 ggml 清理 —— **所有 `exit()` 都必须走 `exitReleasingGgml`**。
///
/// **为什么必须是全局的**：whisper context 从来不只有一份。GUI 启动时 `AppState`
/// 会按配置预热一份（`AppState` 里那个 `warmUp()`），无头入口又各自构造一份，
/// `--mic-selftest` 那条路上两者**同时**存在。而 ggml 的 Metal 后端在静态析构时
/// 断言 `[rsets->data count] == 0`：**只要还有任意一份 context 活着**，进程就以
/// abort 结束（实测 exit=134，栈在 `__cxa_finalize_ranges` → `ggml_metal_device_free`）。
///
/// 所以「放掉自己那一个」是不够的。`--whisper-prewarm` 明明已经调过
/// `runtime.unload()` 却仍然 134，正是因为它放掉的是自检自己造的那一份，而
/// AppKit 那条路上 `AppState` 造的那一份还活着。清理必须能找到**所有** context。
///
/// **顺序是硬约束**：先 `whisper_free`（把 buffer 还给后端，residency set 才空得
/// 下来），再 `ggml_backend_unload`。反过来会在后端已拆的情况下 free context。
enum GgmlTeardown {

    private static let lock = NSLock()
    /// 还活着的 context。`OpaquePointer` 可哈希，正好当身份用。
    ///
    /// `nonisolated(unsafe)` 的依据：**每一次**读写都在 `lock` 里（`adopt` / `release`
    /// / `releaseAll` 三个入口无一例外），所以这里的可变全局状态是安全的。
    /// Swift 6 看不出「调用方都记得加锁」，只能靠这个显式承诺。
    nonisolated(unsafe) private static var live: Set<OpaquePointer> = []

    /// 登记新造的 context（`WhisperEngine.init` 造完就登记）
    static func adopt(_ context: OpaquePointer) {
        lock.lock()
        defer { lock.unlock() }
        live.insert(context)
    }

    /// 放掉一个 context。**幂等**——已经放过的返回 false，不会再 free 一次。
    /// 所以 `WhisperEngine.deinit` 和退出清理谁先跑，都不会重复释放。
    @discardableResult
    static func release(_ context: OpaquePointer) -> Bool {
        lock.lock()
        let owned = live.remove(context) != nil
        lock.unlock()
        guard owned else { return false }
        whisper_free(context)
        return true
    }

    /// 放掉**所有**还活着的 context，再卸掉动态加载的 ggml 后端。幂等，可重复调。
    ///
    /// 返回值给自检打印用：「这次退出到底放掉了几个 context、卸了哪些后端」——
    /// 没有这个数字，出问题时只能看见一个 exit=134，看不见是谁没放。
    @discardableResult
    static func releaseAll() -> (contexts: Int, backends: [String]) {
        lock.lock()
        let pending = live
        live.removeAll()
        lock.unlock()

        // 先 context 后后端，顺序不能反（见类型注释）
        for context in pending {
            whisper_free(context)
        }

        // `ggml_backend_unload` 只对**动态库加载**的后端有效，而
        // `ggml_backend_load_all()` 正是从 .so 加载的（Metal / BLAS / CPU），
        // 所以这里逐个卸得掉——实测它会打 `ggml_metal_free: deallocating`。
        //
        // **先把名字全取下来，再倒着卸。** 两件事都是必须的：
        // ① 名字只能在卸之前取——`ggml_backend_unload` 会把该后端从注册表里
        //    `unregister`（头文件原话），卸完再问名字就是问一个不在册的
        // ② 必须**倒着**卸：摘除会让后面的下标前移。正向 `0..<count` 遍历时
        //    count 一边走一边缩，第二次取下标就越界——2026-09-22 实测直接
        //    `ggml-backend-reg.cpp:321 GGML_ASSERT(index < reg_count())`，
        //    把「退出时 abort」原样复现了一遍，只是这次 abort 在自己的代码里
        //
        // 倒着卸也正好是「后加载的先拆」，与 `ggml_backend_load_all` 的加载
        // 顺序相反，依赖关系上是安全的那一头
        let names: [String] = (0..<ggml_backend_reg_count()).map { index in
            guard let reg = ggml_backend_reg_get(index),
                  let name = ggml_backend_reg_name(reg) else { return "?" }
            return String(cString: name)
        }
        for index in stride(from: ggml_backend_reg_count(), through: 1, by: -1) {
            guard let reg = ggml_backend_reg_get(index - 1) else { continue }
            ggml_backend_unload(reg)
        }
        return (pending.count, names)
    }
}

/// 无头入口唯一的退出出口。**不许再出现裸 `exit()`。**
///
/// 裸 `exit()` 会跳过 AppKit 终止流程，ggml 的静态析构随即 abort（exit=134）。
/// 把清理钉死在这一个函数里，「这次忘了放」在结构上就不可能再发生——
/// 之前是每个出口各写一遍、还要判断「这次是不是用了 whisper」，于是漏了。
///
/// 刻意不是 `@MainActor`：出口散落在 `Task.detached` 和 `Task { @MainActor }` 里，
/// 必须从任何隔离域都调得到。
func exitReleasingGgml(_ code: Int32 = 0) -> Never {
    GgmlTeardown.releaseAll()
    exit(code)
}

/// 本地 Whisper 转录引擎（whisper.cpp 的 Swift 封装）。
///
/// 存在的理由：Apple 的 SpeechTranscriber 在低质量音频上表现明显更差——
/// 同一条录音（整体 -49.5 dBFS、2-4kHz 衰减 21dB）两者对比：
///
/// ```
///   Whisper：  但途中遭到了叛乱分子的圍攻 / 統籌高質量發展和高水平安全
///   Apple：    更遭到了判断自己的围武 / 高产品安全（应为高水平安全）
/// ```
///
/// 而且 Whisper 原生自带标点和语义断句（Apple 的 TranscriptionOption
/// 里根本没有 punctuation），省掉了我们自己造的两轮启发式。
///
/// **代价**：Whisper 是批处理模型，不是流式。所以这个引擎按「累积窗口」
/// 工作——把最近一段音频切出来整块转，不是逐帧吐字。调用方（引擎）负责
/// 攒音频和触发时机。
///
/// 模型：medium-q5_0（514MB，8GB 内存实测跑得动）。中文默认输出繁体，
/// 这里统一转成简体（见 `ChineseText`）。
/// `@unchecked Sendable` 的依据：whisper context 的**每一次**使用都在
/// `lock` 里（`transcribe` 全程持锁），所以实例本身可以跨线程转移
/// （预热在后台队列造、录音时给滑窗队列用）。`deinit` 里的 `whisper_free`
/// 不在锁里——它只在最后一个引用消失时执行，而那时不可能还有持锁的调用者
/// （调用者自己就握着引用）。
final class WhisperEngine: @unchecked Sendable {

    /// 模型的下载地址。用 hf-mirror 是因为国内直连 huggingface 不稳
    static let modelFileName = "ggml-medium-q5_0.bin"
    static let modelURL = "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"
    /// 514MB，带余量做校验
    static let expectedModelBytes: Int64 = 500_000_000

    /// 模型放哪。用 Application Support 而不是 App 包里——
    /// 514MB 打进 bundle 会让 App 大一倍，而且升级 App 就白下一遍
    static var modelDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    static var modelPath: URL {
        modelDirectory.appendingPathComponent(modelFileName)
    }

    /// 实际要加载的模型文件。
    ///
    /// 允许用 `CLASSROOM_WHISPER_MODEL` 指到别处：514MB 的模型未必每个人都
    /// 想放在 Application Support 里（外置盘、已有的另一份量化版本都说得通）。
    /// 缺省位置是可发现的——`Application Support/ClassroomTranscriber/models/`，
    /// 而且设置页会把完整路径显示出来（`WhisperRuntime.modelURL`），
    /// 因为「模型放哪儿」这个问题不该只能靠翻文档回答。
    static var resolvedModelURL: URL {
        if let raw = ProcessInfo.processInfo.environment["CLASSROOM_WHISPER_MODEL"],
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return modelPath
    }

    static var isModelReady: Bool {
        FileManager.default.fileExists(atPath: resolvedModelURL.path)
    }

    enum WhisperError: LocalizedError {
        case modelMissing
        case initFailed
        case inferenceFailed(Int32)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing: return "Whisper 模型未下载"
            case .initFailed: return "Whisper 模型加载失败"
            case .inferenceFailed(let code): return "Whisper 推理失败（错误码 \(code)）"
            case .downloadFailed(let reason): return "模型下载失败：\(reason)"
            }
        }
    }

    private var context: OpaquePointer?
    /// 只从使用它的队列访问。whisper_full 是重计算，调用方会放到后台
    private let lock = NSLock()

    /// 用解析出来的路径构造（默认 Application Support/models，
    /// 可用 `CLASSROOM_WHISPER_MODEL` 覆盖）
    convenience init() throws {
        try self.init(modelURL: Self.resolvedModelURL)
    }

    /// 指定模型路径。抽出来是为了自检能喂一个**不存在的路径**，
    /// 验证「模型缺失 → 抛错」这条分支，而不是只能靠挪走真模型去测
    init(modelURL: URL) throws {
        // 先查文件，再动 ggml 后端。顺序反过来的话，模型缺失这条路径
        // 也要先付一次后端初始化的钱（实测冷启动下 Metal 内核编译要 30 秒），
        // 而且自检里那条「缺模型 → 抛错」的分支会顺带把 GPU 拉起来
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperError.modelMissing
        }

        // ggml 的后端必须先显式加载：少了这一步，whisper_init 会在
        // make_buft_list 里 GGML_ASSERT(device) failed 直接崩，
        // 而且崩在 C++ 里看不出原因（2026-09-21 实测的 abort 栈：
        // whisper_init_from_file_with_params → make_buft_list → ggml_abort）
        ggml_backend_load_all()

        var params = whisper_context_default_params()
        params.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw WhisperError.initFailed
        }
        context = ctx
        // 登记进全局表。退出清理要能找到**所有** context，不只是本对象这一份
        // （理由见 `GgmlTeardown`）
        GgmlTeardown.adopt(ctx)
    }

    deinit {
        // 走 `release` 而不是直接 `whisper_free`：退出清理可能已经先一步把它
        // 放掉了，那这里就该什么都不做——直接 free 会二次释放
        if let context { GgmlTeardown.release(context) }
    }

    /// 转一段 16kHz 单声道 Float32 PCM。
    ///
    /// - Parameter language: 课堂是中文为主，默认 zh
    /// - Returns: 转出来的段（含时间范围和逐字符置信度），文本已经是简体
    func transcribe(_ samples: [Float], language: String = "zh") throws -> [WhisperSegment] {
        lock.lock()
        defer { lock.unlock() }

        guard let context else { throw WhisperError.initFailed }
        guard !samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // language 是 C 字符串指针，要保证它在 whisper_full 期间存活
        let langCString = strdup(language)
        defer { free(langCString) }
        params.language = UnsafePointer(langCString)
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        // 关掉这些输出：App 里跑，stdout 会被当成日志刷屏
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        // 要时间戳，UI 要显示段落时间
        params.no_timestamps = false
        // 单段最长字符数：默认 0（不限），课堂长句会被切成很长的段，
        // 限制一下让输出更接近自然句
        params.max_len = 60

        var mutable = samples
        let code = mutable.withUnsafeMutableBufferPointer { buf in
            whisper_full(context, params, buf.baseAddress, Int32(buf.count))
        }
        guard code == 0 else { throw WhisperError.inferenceFailed(code) }

        let count = whisper_full_n_segments(context)
        var result: [WhisperSegment] = []
        for i in 0..<count {
            guard let raw = whisper_full_get_segment_text(context, i) else { continue }
            let text = ChineseText.toSimplified(String(cString: raw))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // t0/t1 的单位是 10ms（whisper.cpp 的约定）
            let t0 = whisper_full_get_segment_t0(context, i)
            let t1 = whisper_full_get_segment_t1(context, i)
            result.append(WhisperSegment(
                text: text,
                startMillis: Int(t0) * 10,
                endMillis: Int(t1) * 10,
                confidences: Self.spreadTokenProbabilities(
                    Self.tokenProbabilities(context: context, segment: i)
                )
            ))
        }
        return result
    }

    // MARK: - 置信度：Whisper 的逐 token 概率 → 逐字符置信度

    /// 从上下文里读第 `segment` 段的逐 token 概率，**连原始字节一起返回**。
    ///
    /// 为什么带字节而不是 `String`：whisper 的中文 BPE 会把一个汉字**拆成
    /// 两个 token**（各占该字 UTF-8 的一半字节）。单独把任何一个 token 解成
    /// `String` 都拿不到那个字——`String(cString:)` 会把半个字的字节序列
    /// 变成一个 U+FFFD（`�`）。实测就是这么错的：6 个 token 被当成
    /// 6 个字符，而段落正文只有 3 个字，置信度比正文多出一截、和文字位置
    /// 对不上（65 段里有 19 段对不齐）。
    /// 所以这里保留原始字节，交给 `spreadTokenProbabilities` 跨 token 拼接
    /// 之后再切字符。
    ///
    /// 过滤不能少：`id < eot` 排掉特殊 token（`<|endoftext|>` / `[_TT_*]`
    /// 时间戳 / `<|startoftranscript|>` 等，id 从 eot 起算）——实测每个段落
    /// 的 token 列表里都夹着它们，`[_BEG_]` 和 `[_TT_*]` 各一个
    private static func tokenProbabilities(
        context: OpaquePointer,
        segment: Int32
    ) -> [(bytes: [UInt8], probability: Double)] {
        let tokenCount = whisper_full_n_tokens(context, segment)
        guard tokenCount > 0 else { return [] }

        let eot = whisper_token_eot(context)
        var tokens: [(bytes: [UInt8], probability: Double)] = []
        tokens.reserveCapacity(Int(tokenCount))

        for j in 0..<tokenCount {
            let data = whisper_full_get_token_data(context, segment, j)
            guard data.id < eot else { continue }
            guard let raw = whisper_full_get_token_text(context, segment, j) else { continue }
            // 按 strlen 取原始字节，**不做 UTF-8 校验**——半个汉字的字节序列
            // 本来就不是合法 UTF-8，但它是拼出那个字的一部分
            let bytes = Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(raw), count: strlen(raw)))
            tokens.append((bytes: bytes, probability: Double(whisper_full_get_token_p(context, segment, j))))
        }
        return tokens
    }

    /// 把「逐 token 概率」摊成「逐字符置信度」。**纯函数**——抽出来是为了
    /// 自检能直接喂构造字节序列验证，不用真跑一次推理（模型 514MB，自检
    /// 不该依赖它）。
    ///
    /// 为什么要摊开：质量分档（`TranscriptQualityAssessor`）是按**字符**统计的，
    /// 因为 Apple 那条链路原生给的就是逐字符置信度。Whisper 只给逐 token 概率，
    /// 若按 token 统计，同一个评估器在两条链路上的口径就不一致（中文一个 token
    /// 常常是 1-2 个字，英文一个 token 可以是一整个词）——同一段文本换个引擎
    /// 档位就变。摊开后两条链路共用同一个评估器和同一组阈值。
    ///
    /// 三条规则（都有实测依据）：
    /// 1. **跨 token 拼字节**再切字符——一个汉字可能横跨两个 token；
    /// 2. 一个字符的置信度取**参与拼接的那些 token 里最小的概率**——
    ///    字符的可信度由最没把握的那半个字决定；
    /// 3. 纯空白字符不产生条目——它不占正文的可见位置，不参与统计
    ///    （否则 `confidences.count == 正文可见字符数` 这个不变量就不成立，
    ///    接界面做逐字高亮时会整体错位）。
    ///
    /// 末尾未凑齐的字节序列直接丢弃（推理被截断时的残字节）。
    ///
    /// **阈值是已知缺口**：token 概率的分布和 Apple 的逐字符置信度不是一个
    /// 量纲（Apple 实测准确段 0.96 / 崩坏段 0.58；Whisper 实测中位 0.895、
    /// 均值 0.727、<0.5 占 26%）。不能直接照搬——不要在没有新数据的情况下
    /// 改 `TranscriptQualityAssessor` 的常数。
    static func spreadTokenProbabilities(
        _ tokens: [(bytes: [UInt8], probability: Double)]
    ) -> [Double] {
        var result: [Double] = []
        /// 当前正在拼的字符已经吃到的字节
        var pending: [UInt8] = []
        /// 这个字符还需要几个字节才算完整
        var remaining = 0
        /// 参与当前字符的所有 token 里最小的概率
        var lowestProbability = 1.0

        for token in tokens {
            let probability = min(max(token.probability, 0), 1)
            for byte in token.bytes {
                pending.append(byte)
                if remaining == 0 {
                    let length = utf8Length(leadingByte: byte)
                    guard length > 0 else {
                        // 非法首字节（悬空的续字节），丢掉，别让它污染下一个字
                        pending.removeAll(keepingCapacity: true)
                        lowestProbability = 1.0
                        continue
                    }
                    remaining = length
                }
                remaining -= 1
                lowestProbability = min(lowestProbability, probability)
                guard remaining == 0 else { continue }

                let isBlank = pending.count == 1 && [0x20, 0x09, 0x0A, 0x0D].contains(pending[0])
                if !isBlank { result.append(lowestProbability) }
                pending.removeAll(keepingCapacity: true)
                lowestProbability = 1.0
            }
        }
        return result
    }

    /// UTF-8 首字节 → 这个字符的总字节数。0 表示它不是合法首字节
    private static func utf8Length(leadingByte byte: UInt8) -> Int {
        if byte < 0x80 { return 1 }          // 0xxxxxxx ASCII
        if byte & 0xE0 == 0xC0 { return 2 }  // 110xxxxx
        if byte & 0xF0 == 0xE0 { return 3 }  // 1110xxxx
        if byte & 0xF8 == 0xF0 { return 4 }  // 11110xxx
        return 0
    }

    /// 便捷重载：按 token 文本（整字符）构造字节序列。给自检用例用
    static func spreadTokenProbabilities(
        _ tokens: [(text: String, probability: Double)]
    ) -> [Double] {
        spreadTokenProbabilities(tokens.map { (bytes: Array($0.text.utf8), probability: $0.probability) })
    }

    /// 把任意采样率的音频转成 Whisper 要的 16kHz 单声道 Float32。
    ///
    /// Whisper 的输入格式是固定的（16kHz mono float），不做这一步
    /// 会得到完全错误的结果而且不报错
    /// 从**已经是 16kHz 单声道 Float32** 的缓冲里取出样本。
    ///
    /// 和 `resampleTo16k` 分开是因为实时链路那一边已经用 AVAudioConverter
    /// 转过了（转换必须在 MicTap 里自己做，理由见 `firstChannelAsMono`），
    /// 再走一次转换器只是白跑一遍重采样——每秒十几次的音频线程上，白跑的
    /// 每一次都是一次可能丢帧的分配。
    static func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func resampleTo16k(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)
        guard let target,
              let converter = AVAudioConverter(from: buffer.format, to: target) else { return nil }

        let ratio = 16_000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil,
              let channel = output.floatChannelData?[0] else { return nil }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    // MARK: - 自检

    /// 纯本地自检：繁简转换 + 概率聚合纯函数 + 「缺模型报错不崩」这条分支。
    ///
    /// 不跑推理：模型 514MB、加载就要半秒，自检应该是随手能跑的东西。
    /// 真推理的端到端验证走独立探针（把本文件编译进探针跑真实录音）。
    static func selfTest() -> [String] {
        var lines: [String] = ["Whisper 引擎自检（繁简转换 + 概率聚合 + 缺模型分支 · 纯本地，不跑推理、不发网络请求）"]
        var allPassed = true

        func check(_ name: String, _ condition: Bool, _ detail: String) {
            allPassed = allPassed && condition
            lines.append("  \(condition ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        // --- 一、繁简转换 ---
        check("系统 ICU 变换可用", ChineseText.isAvailable, "開 → 开")

        let traditional = "(開門) 謝謝收看! 請訂閱支持! 統籌高質量發展和高水平安全 途中遭到了叛亂分子的圍攻 著急 乾部"
        let expected = "(开门) 谢谢收看! 请订阅支持! 统筹高质量发展和高水平安全 途中遭到了叛乱分子的围攻 着急 干部"
        let converted = ChineseText.toSimplified(traditional)
        check("繁简·真实句全覆盖", converted == expected, converted == expected ? "" : "得到「\(converted)」")

        // 原手写表漏掉的字（門 請 謝）和它原理上做不到的上下文歧义（著急 乾部）——
        // 这三类是当初那张表的具体缺陷，钉成回归用例
        check("繁简·原表漏字 門/請/謝",
              ChineseText.toSimplified("開門請進謝謝") == "开门请进谢谢",
              ChineseText.toSimplified("開門請進謝謝"))
        check("繁简·上下文歧义 著急/乾部",
              ChineseText.toSimplified("著急乾部") == "着急干部",
              ChineseText.toSimplified("著急乾部"))

        // 不该动的必须原样不动：转错会让英文术语 / 数字失真
        check("空字符串不动", ChineseText.toSimplified("") == "", "")
        let ascii = "PyTorch 3.14 gradient descent, loss=0.023"
        check("英文数字原样不动", ChineseText.toSimplified(ascii) == ascii, ascii)
        check("判繁·简体文本", !ChineseText.looksTraditional("这是一个简体句子"), "")
        check("判繁·繁体文本", ChineseText.looksTraditional("這是一個繁體句子"), "")

        // --- 二、概率聚合（纯函数，构造数据） ---
        let spread = spreadTokenProbabilities([
            (" 你", 0.9),      // 带前导空格：只有 1 个可见字符 → 1 个置信度
            ("好", 0.8),
            ("hello", 0.7),    // 英文一 token 五个字符 → 5 个
            ("   ", 0.5),      // 纯空白 → 不产生条目
            ("", 0.4),         // 空 token → 不产生条目
            ("超额", 1.5),      // 越界值 → 夹到 1.0
            ("负值", -0.2),     // 越界值 → 夹到 0
        ])
        let expectedSpread: [Double] = [0.9, 0.8] + Array(repeating: 0.7, count: 5) + [1.0, 1.0, 0.0, 0.0]
        check("概率摊开·长度与可见字符一致",
              spread.count == expectedSpread.count,
              "\(spread.count) 个字符 ← 期望 \(expectedSpread.count)")
        check("概率摊开·数值与顺序", spread == expectedSpread, "\(spread)")
        check("概率摊开·全部落在 0...1", spread.allSatisfy { $0 >= 0 && $0 <= 1 }, "")
        check("概率摊开·空输入",
              spreadTokenProbabilities([(text: String, probability: Double)]()).isEmpty, "")

        // 回归用例：中文 BPE 会把一个汉字**拆成两个 token**（各占一半字节）。
        // 这是 65 段里 19 段「置信度和正文对不齐」的根因——单个 token 单独解码
        // 只能得到 U+FFFD（�），6 个 token 被当成 6 个字符，而正文只有 3 个字。
        // 「負」的 UTF-8 是 E8 B2 A0，这里拆成 [E8 B2] + [A0]
        let splitAcrossTokens = spreadTokenProbabilities([
            (bytes: Array("你".utf8), probability: 0.9),
            (bytes: [0xE8, 0xB2], probability: 0.8),  // 「負」的前两个字节
            (bytes: [0xA0], probability: 0.6),        // 「負」的最后一个字节
            (bytes: Array("责".utf8), probability: 0.95),
        ])
        check("概率摊开·汉字跨 token 拼回一个字",
              splitAcrossTokens == [0.9, 0.6, 0.95],
              "\(splitAcrossTokens) ← 期望 [0.9, 0.6, 0.95]（跨 token 的字符取最小概率）")

        // 一个字符被拆到三个 token 上（4 字节字符的极端情况）
        let splitAcrossThree = spreadTokenProbabilities([
            (bytes: [0xF0], probability: 0.9),
            (bytes: [0x9F, 0x98], probability: 0.5),
            (bytes: [0x80], probability: 0.8),
        ])
        check("概率摊开·跨三个 token 拼回一个字",
              splitAcrossThree == [0.5], "\(splitAcrossThree) ← 期望 [0.5]（取最小）")

        // 悬空续字节 / 截断残字节不能凭空造出字符（造出来就会让长度又多出来）
        check("概率摊开·悬空续字节不产字符",
              spreadTokenProbabilities([(bytes: [0xA0], probability: 0.5)]).isEmpty, "")
        check("概率摊开·截断残字节不产字符",
              spreadTokenProbabilities([(bytes: [0xE8, 0xB2], probability: 0.5)]).isEmpty, "")

        // 不变量：摊开后的个数 == 正文的可见字符数（接界面逐字高亮的前提）
        let mixed = "你好 hello 世界"
        let mixedSpread = spreadTokenProbabilities(
            mixed.split(separator: " ").map { (text: String($0), probability: 0.9) }
        )
        check("概率摊开·与正文可见字符数一致",
              mixedSpread.count == mixed.filter { !$0.isWhitespace }.count,
              "\(mixedSpread.count) ← 期望 \(mixed.filter { !$0.isWhitespace }.count)")

        // 摊开后的数组能直接喂质量评估器——这是「两条链路共用同一个评估器」的接口前提
        check("概率摊开后可进分档器",
              TranscriptQualityAssessor.grade(confidences: spread) != nil,
              "档位 \(TranscriptQualityAssessor.grade(confidences: spread)?.label ?? "nil")")

        // --- 三、缺模型：报错，不是崩溃 ---
        let missing = URL(fileURLWithPath: "/tmp/__不存在的_whisper_模型__.bin")
        do {
            _ = try WhisperEngine(modelURL: missing)
            check("模型缺失 → 抛错", false, "居然构造成功了")
        } catch let error as WhisperError {
            let isModelMissing: Bool
            if case .modelMissing = error { isModelMissing = true } else { isModelMissing = false }
            check("模型缺失 → 抛 modelMissing", isModelMissing, error.errorDescription ?? "")
        } catch {
            check("模型缺失 → 抛 modelMissing", false, "抛了别的错：\(error)")
        }

        // --- 四、当前模型就位情况（如实报告，不是缺陷）---
        if isModelReady {
            let size = (try? FileManager.default.attributesOfItem(atPath: modelPath.path)[.size] as? Int64) ?? 0
            lines.append("  ℹ️ 模型已就位 · \(modelPath.path) · \(String(format: "%.1f", Double(size) / 1_000_000)) MB")
        } else {
            lines.append("  ℹ️ 模型未下载 · 期望位置 \(modelPath.path)")
            lines.append("     下载（国内走 hf-mirror）：\(modelURL)")
        }

        lines.append(allPassed ? "✅ Whisper 引擎自检通过" : "❌ Whisper 引擎自检未通过")
        return lines
    }
}

/// Whisper 转出来的一段
struct WhisperSegment: Equatable {
    var text: String
    var startMillis: Int
    var endMillis: Int

    /// 逐字符置信度，由 token 概率摊开而来。与 `text` 的可见字符一一对应。
    /// Apple 那条链路的逐字符置信度是框架原生给的，这里是它的等价物——
    /// 档位判定走同一个 `TranscriptQualityAssessor`
    var confidences: [Double] = []

    /// 这段的档位。没拿到置信度时返回 nil（不乱判）
    var grade: TranscriptGrade? {
        TranscriptQualityAssessor.grade(confidences: confidences)
    }

    /// 平均置信度（排障用，也是分档用的那个数）
    var averageConfidence: Double? {
        guard !confidences.isEmpty else { return nil }
        return confidences.reduce(0, +) / Double(confidences.count)
    }
}
