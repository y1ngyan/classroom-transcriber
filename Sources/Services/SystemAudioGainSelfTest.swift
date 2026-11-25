import Foundation

/// `SystemAudioGain` 的自检（纯函数）。盯的是「正常音量的播放被多此一举地改电平」——
/// 那正是准确率被拖低的一种来源
enum SystemAudioGainSelfTest {
    struct SelfTestResult { var lines: [String]; var passed: Int; var failed: Int }

    static func run() -> SelfTestResult {
        var lines: [String] = ["─── 系统声音电平补偿自检 ───"]
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("  \(ok ? "✅" : "❌") \(title)" + (detail.isEmpty ? "" : " · \(detail)"))
        }

        // 课堂实录实测 RMS 0.10–0.15：一个字节都不该动
        check(SystemAudioGain.gain(forRMS: 0.12) == 1, "正常音量（0.12）不动它")
        check(SystemAudioGain.gain(forRMS: 0.02) == 1, "刚到阈值也不动（小于才补）")
        check(SystemAudioGain.gain(forRMS: 0.01) > 1, "偏小（0.01）才补",
              String(format: "×%.1f", SystemAudioGain.gain(forRMS: 0.01)))
        check(SystemAudioGain.gain(forRMS: 0.0005) == SystemAudioGain.maxGain,
              "很低的电平封顶 ×\(Int(SystemAudioGain.maxGain))",
              String(format: "×%.0f", SystemAudioGain.gain(forRMS: 0.0005)))
        check(SystemAudioGain.gain(forRMS: 0.00001) == 1,
              "接近全零（<0.0001）不放大——那已经是没声音，放大只是放大噪声")
        check(SystemAudioGain.gain(forRMS: 0) == 1, "全零不放大（0 乘任何数还是 0）")
        check(abs(SystemAudioGain.rms(of: [0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.001,
              "RMS 计算正确", String(format: "%.3f", SystemAudioGain.rms(of: [0.5, -0.5, 0.5, -0.5])))

        lines.append(failed == 0 ? "✅ 电平补偿自检通过（\(passed) 条）"
                                 : "❌ 电平补偿自检未通过（过 \(passed) / 红 \(failed)）")
        return SelfTestResult(lines: lines, passed: passed, failed: failed)
    }
}
