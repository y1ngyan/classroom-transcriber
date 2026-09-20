import AVFoundation
import Speech
import Foundation

/// 无头文件转录：把音频文件喂给 SpeechAnalyzer，把结果打到 stdout。
///
/// 两个用途：
/// 1. 终端验证整条转录链路（不需要麦克风权限）
/// 2. 「录音文件转录」功能的底座
enum FileTranscription {

    /// 可选的识别预设。progressive 系列为实时低延迟设计，精度较低；
    /// 文件转录应该用非 progressive 系列。
    enum PresetChoice: String, CaseIterable {
        case progressive
        case timeIndexed
        case timeIndexedAlternatives
        case plain

        var preset: SpeechTranscriber.Preset {
            switch self {
            case .progressive: return .progressiveTranscription
            case .timeIndexed: return .timeIndexedProgressiveTranscription
            case .timeIndexedAlternatives: return .timeIndexedTranscriptionWithAlternatives
            case .plain: return .transcription
            }
        }
    }

    static func run(
        path: String,
        locales: [String] = ["zh-CN"],
        presetChoice: PresetChoice = .timeIndexedAlternatives
    ) async {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ 文件不存在: \(path)")
            return
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            print("❌ 无法读取音频: \(error.localizedDescription)")
            return
        }

        let duration = Double(file.length) / file.fileFormat.sampleRate
        print("📁 \(url.lastPathComponent) · \(String(format: "%.1f", duration))s · \(Int(file.fileFormat.sampleRate))Hz")

        // 1. 匹配受支持的 locale（标识符形式可能是 zh-CN / zh_CN / zh-Hans，做宽松匹配）
        let supported = await SpeechTranscriber.supportedLocales
        let usable = resolve(locales, against: supported)

        guard !usable.isEmpty else {
            print("❌ 没有可用语言模型")
            print("   请求: \(locales.joined(separator: ", "))")
            print("   SpeechTranscriber 支持 \(supported.count) 个:")
            for l in supported { print("     · \(l.identifier)") }
            return
        }
        print("🌐 挂载语言模型: \(usable.map(\.identifier).joined(separator: " + "))")

        // 2. 构建 transcriber。attributeOptions 加逐字符置信度：
        //    质量自评的唯一可信信号，也是这条命令的端到端验证手段
        //    （--quality-selftest 只测分档纯函数，置信度本身准不准要在这里看）
        let transcribers = usable.map { locale in
            var presetWithConfidence = presetChoice.preset
            presetWithConfidence.attributeOptions.insert(.transcriptionConfidence)
            return SpeechTranscriber(locale: locale, preset: presetWithConfidence)
        }

        // 3. 下载设备端模型
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: transcribers) {
                print("⬇️  正在下载语言模型（首次运行需要几分钟）…")

                let poller = Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        let p = request.progress
                        if p.totalUnitCount > 0 {
                            print(String(format: "      … %.0f%%", p.fractionCompleted * 100))
                        } else {
                            print("      …")
                        }
                    }
                }
                try await request.downloadAndInstall()
                poller.cancel()
                print("✅ 模型就绪")
            } else {
                print("✅ 模型已安装，无需下载")
            }
        } catch {
            print("❌ 模型下载失败: \(error.localizedDescription)")
            return
        }

        // 4. 创建 analyzer
        let modules: [any SpeechModule] = transcribers
        let analyzer = SpeechAnalyzer(modules: modules)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            print("❌ 无法确定音频格式")
            return
        }

        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            print("❌ 分析器初始化失败: \(error.localizedDescription)")
            return
        }

        // 5. 并发消费每个语言模型的结果
        print("")
        print("──────────── 转录结果 ────────────")

        await withTaskGroup(of: Void.self) { group in
            for (transcriber, locale) in zip(transcribers, usable) {
                let label = locale.identifier
                group.addTask {
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }

                            guard result.isFinal else { continue }

                            let start = result.range.start.seconds
                            let end = (result.range.start + result.range.duration).seconds
                            // 每段报平均置信度和分档：质量自评的端到端验证
                            // 就靠这行——好音频该看到 0.9+，崩坏音频 0.6 上下
                            let confidences = TranscriptQualityAssessor.confidences(from: result.text)
                            let grade = TranscriptQualityAssessor.grade(confidences: confidences)
                            let confidenceNote = confidences.isEmpty ? "无置信度" : String(
                                format: "置信度 %.3f · %@",
                                confidences.reduce(0, +) / Double(confidences.count),
                                grade?.label ?? "未评"
                            )
                            print(String(
                                format: "[%@] %6.2f → %6.2f  %@（%@）",
                                label, start, end, text, confidenceNote
                            ))
                        }
                    } catch {
                        print("[\(label)] ⚠️ 中断: \(error.localizedDescription)")
                    }
                }
            }

            // 6. 喂文件
            do {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            } catch {
                print("❌ 转录失败: \(error.localizedDescription)")
            }

            await group.waitForAll()
        }

        print("──────────────────────────────────")
        print("完成")
    }

    /// 该语言在没指定地区时优先选用的地区。
    /// 不做这层映射的话，「en」会按字母序匹配到 en-ZA（南非英语）。
    private static let preferredRegions: [String: String] = [
        "en": "US", "zh": "CN", "ja": "JP", "ko": "KR",
        "fr": "FR", "de": "DE", "es": "ES", "pt": "BR",
    ]

    /// 把请求的语言标识符映射到系统实际支持的 Locale 上。
    /// 文件转录和实时转录共用，避免两边对标识符形式的假设不一致。
    static func resolve(_ requested: [String], against supported: [Locale]) -> [Locale] {
        var result: [Locale] = []

        for raw in requested {
            let normalized = raw.replacingOccurrences(of: "_", with: "-").lowercased()

            // 1. 完整标识符精确匹配
            if let exact = supported.first(where: { $0.identifier.lowercased() == normalized }) {
                result.append(exact)
                continue
            }

            // 2. 语言码匹配，优先取指定地区，其次取该语言的默认地区
            let parts = normalized.split(separator: "-").map(String.init)
            let languageCode = parts.first ?? normalized
            let wantedRegion = parts.count > 1
                ? parts[1].uppercased()
                : preferredRegions[languageCode]?.uppercased()

            let candidates = supported.filter {
                $0.language.languageCode?.identifier.lowercased() == languageCode
            }

            if let wantedRegion,
               let hit = candidates.first(where: {
                   $0.region?.identifier.uppercased() == wantedRegion
               }) {
                result.append(hit)
                continue
            }

            if let first = candidates.first {
                result.append(first)
            }
        }

        return result
    }
}
