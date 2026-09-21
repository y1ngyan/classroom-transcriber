import Foundation
import Observation

/// 用户自己存下来的课程词表（「我的词库」）。
///
/// 为什么要有它：内置的 `CoursePresets` 是写死的 6 包，覆盖不到任意课程；
/// 而联网生成出来的那包词是对**这门课**定制的——用一次就丢，等于白花
/// 一次检索和两次模型调用。存成预设之后，同一门课下次上课前点一下就位。
///
/// **和 `glossary.json`（当前词表）分开存，这是有意的。**
/// 当前词表是「这节课要用的」，预设是「备着以后用的」——词表必须在开录前
/// 定下来，如果两者共用一份存储，为了下一门课载入预设就会把此刻已经就位
/// 的那套词表冲掉，而那节课的识别已经没法补了。
@Observable
final class CoursePresetStore {

    /// 用户自建的词库，按保存顺序
    private(set) var custom: [CoursePreset] = []
    private(set) var statusMessage = ""

    /// 内置 + 自建。选词表的菜单用这个，不是 `CoursePresets.all`
    var all: [CoursePreset] { CoursePresets.all + custom }

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("presets.json")
    }()

    static var storeFilePath: String { storeURL.path }

    init() {
        load()
    }

    /// 把当前词表存成一包预设。
    ///
    /// **同名覆盖而不是新增。** 用户改完几个词再存一次，期望的是"更新这一包"，
    /// 不是"又出来一包几乎一样的"——菜单里两条同名项没法选。
    @discardableResult
    func save(name rawName: String, entries: [GlossaryEntry]) -> CoursePreset? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空词表存下来没有意义：载入它什么也不改，用户会以为功能坏了
        let usable = entries.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !name.isEmpty else {
            statusMessage = "❌ 给这包词起个名字（一般就用课程名）"
            return nil
        }
        guard !usable.isEmpty else {
            statusMessage = "❌ 当前词表是空的，没东西可存"
            return nil
        }

        let preset = CoursePreset(
            id: custom.first { $0.name == name }?.id ?? UUID().uuidString,
            name: name,
            summary: "自建词库 · \(usable.count) 词",
            entries: usable
        )

        if let index = custom.firstIndex(where: { $0.name == name }) {
            custom[index] = preset
            statusMessage = "已更新「\(name)」（\(usable.count) 词）"
        } else {
            custom.append(preset)
            statusMessage = "已存为「\(name)」（\(usable.count) 词）· 下次上课前在「载入课程预设」里一键载入"
        }
        persist()
        return preset
    }

    func remove(id: String) {
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }
        let name = custom[index].name
        custom.remove(at: index)
        statusMessage = "已删除「\(name)」"
        persist()
    }

    // MARK: - 落盘

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: Self.storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(custom).write(to: Self.storeURL, options: .atomic)
        } catch {
            statusMessage = "❌ 词库保存失败: \(error.localizedDescription)"
        }
    }

    /// 读不出来时**留空继续跑**，不抛错。
    ///
    /// 自建词库是附加功能，文件坏了最坏的结果是"我的词库不见了"；
    /// 但如果这里崩掉或抛出去，整个术语表页面都打不开——而里面还有
    /// 此刻正在用的那份 `glossary.json`。降级的代价要小于失效的代价。
    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        do {
            custom = try JSONDecoder().decode([CoursePreset].self, from: data)
        } catch {
            custom = []
            statusMessage = "⚠️ 自建词库读取失败（已忽略）: \(error.localizedDescription)"
        }
    }
}
