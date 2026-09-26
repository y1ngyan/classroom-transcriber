import Foundation

/// 笔记导出失败的两种情形。分开是刻意的：**「没内容可导」和「导不进去」是两件事**，
/// 用户要做的动作也不同（前者去点「生成笔记」，后者去换路径/看权限）
enum NotesExportError: LocalizedError {
    case emptyNotes
    case emptyPath
    case cannotPrepareDirectory(path: String, reason: String)
    case writeFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyNotes:
            return "还没有笔记内容，先点「生成笔记」"
        case .emptyPath:
            return "导出失败：没给路径"
        case .cannotPrepareDirectory(let path, let reason):
            return "导出失败：建不出目录 \(path)（\(reason)）"
        case .writeFailed(let path, let reason):
            return "导出失败：写不进 \(path)（\(reason)）"
        }
    }
}

/// 笔记导出：把「一段 Markdown 文本 + 一个目标路径 → 磁盘上一个文件」这一步单独抽出来。
///
/// 为什么要抽（这是这一包真正的根因，不是顺手重构）：这段逻辑原来长在
/// `NotesStore.export()` 里，而那条路上横着一个 `NSSavePanel.runModal()`——
/// 无头自检碰不了 GUI 面板，于是**「导出」是全项目唯一一条从来没有被任何自检
/// 覆盖过的路径**。用户 2026-09-24 报「点了导出生成不了文件」，回头一看连一条
/// 能跑的判据都没有，只能靠读代码猜。抽出来之后 `--export-notes-selftest`
/// 才能离线把写文件这段跑穿。
///
/// 这里**不 import AppKit**：不弹面板、不碰 UI、不联网，无头入口才能直接调它。
enum NotesExporter {

    /// 无头入口和自检共用的夹具。**只在一处定义**：两边各写一份，改了一处漏一处，
    /// 就会出现「`--export-notes` 导得出、自检却挂」这种自相矛盾。
    ///
    /// 刻意带上中文、标题、列表、表格、行内反引号——这几样任何一样被
    /// 「顺手规整」掉，导出的文件和用户在页面上看到的就不是一份东西了
    static let sampleMarkdown = """
    ## 核心知识点大纲
    - 梯度下降：沿着 loss function 的负梯度方向迭代 [00:00:08]
    - 学习率的影响见下表 [00:00:22]

    ## 关键术语解释
    | 术语 | 解释 |
    | --- | --- |
    | learning rate | 每次迭代的步长 |

    ## 行动项
    - 在 MNIST 上实现一遍 `gradient_descent` [00:00:58]
    """

    /// 把 markdown **原样**写到 url。
    ///
    /// 「原样」是这条函数的全部契约：笔记正文是模型产出的 Markdown，导出就该是
    /// 它本来的样子。任何「顺手规整一下」的转换（补标题、统一换行、去掉空行）
    /// 都会让磁盘上的文件和用户在页面上看到的不是一份东西——
    /// 那正是「内容与产出一致」这条判据要钉住的事。
    static func write(_ markdown: String, to url: URL) throws {
        // 空白串按「没有内容」处理：只写了几个空格的文件存下来毫无用处，
        // 而且会让调用方以为导出成功了
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotesExportError.emptyNotes
        }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw NotesExportError.writeFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    /// 默认文件名。`NotesStore` 的保存面板和 `--export-notes` 共用这一处，
    /// 免得两边各拼一个日期格式、改名时漏掉一处
    static func defaultFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "课堂笔记-\(formatter.string(from: date)).md"
    }

    /// 把命令行给的「一个路径」解释成最终要写的文件 URL。
    ///
    /// 接受两种写法，因为用户说「导出到这个目录」和「导出成这个文件」时
    /// 打出来的东西都长这样，没必要让他先想清楚是哪种：
    ///   · 以 `.md` 结尾 → 就当文件路径，父目录不存在就建出来
    ///   · 其他 → 当目录，建出来，用 `defaultFileName` 拼一个文件名
    ///
    /// 空串**必须显式挡掉**：`URL(fileURLWithPath: "")` 会解析成**当前工作目录**
    /// （`URL(fileURLWithPath: "").path` 就是 cwd 本身，不是错误），于是
    /// `--export-notes ""` 会安安静静往 cwd 里写一个文件。人不该靠运气躲开这个。
    /// 这道 guard 有断言钉着，见 `selfTest` 里的「空路径：必须报错」
    static func resolveTarget(path: String, now: Date = Date()) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesExportError.emptyPath }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        // 建目录失败也要包成 NotesExportError：裸的 Cocoa 文案（「The file "x"
        // couldn't be saved…」）和 write 那条路径的措辞对不上，用户看到两套说法
        func makeDirectory(_ target: URL) throws {
            do {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true
                )
            } catch {
                throw NotesExportError.cannotPrepareDirectory(
                    path: target.path, reason: error.localizedDescription
                )
            }
        }

        if url.pathExtension.lowercased() == "md" {
            try makeDirectory(url.deletingLastPathComponent())
            return url
        }
        try makeDirectory(url)
        return url.appendingPathComponent(defaultFileName(for: now))
    }
}

// MARK: - 无头自检

extension NotesExporter {

    /// 自检结果。**分开报「过了几条 / 红了几条」**，退出码要按它定——
    /// 只打印不返回，调用方就只能靠人眼看，那是 `--whisper-selftest` 踩过的坑
    struct SelfTestResult {
        var lines: [String] = []
        var passed = 0
        var failed = 0
    }

    /// 离线自检：**不弹面板、不联网、不加载模型、不发声**，就在临时目录里写文件。
    ///
    /// 为什么值得有：导出这条路径一直没有判据（原因见类型头部的注释）。
    /// 这几条断言钉的都是「静默失败」那个形状——写没写成、失败说没说，
    /// 恰恰是用户报的那个 bug 里没人能回答的两个问题
    static func selfTest() -> SelfTestResult {
        var r = SelfTestResult()
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            if ok { r.passed += 1; r.lines.append("  ✅ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
            else { r.failed += 1; r.lines.append("  ❌ \(title)" + (detail.isEmpty ? "" : " · \(detail)")) }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ct-export-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            check(false, "准备临时目录", "\(error.localizedDescription)")
            return r
        }

        let sample = sampleMarkdown

        // ① 写得出、非空、**内容与输入一字不差**
        let fileTarget = root.appendingPathComponent("explicit.md")
        do {
            try write(sample, to: fileTarget)
            let readBack = (try? String(contentsOf: fileTarget, encoding: .utf8)) ?? ""
            // 先取出属性字典再取 .size：写成一句 `try? …[.size] as? Int ?? 0`
            // 会多套一层 Optional，编译器报「?? 右边永远用不到」
            let attributes = try? fm.attributesOfItem(atPath: fileTarget.path)
            let size = (attributes?[.size] as? Int) ?? 0
            check(fm.fileExists(atPath: fileTarget.path) && size > 0,
                  "写出：文件存在且非空", "\(size) 字节")
            check(readBack == sample,
                  "写出：内容与产出一致（原样，含中文与 Markdown 结构）",
                  readBack == sample ? "逐字节相同" : "读回来和写出去的不一样")
        } catch {
            check(false, "写出：文件存在且非空", "\(error.localizedDescription)")
            check(false, "写出：内容与产出一致", "上一条已经失败")
        }

        // ② 无笔记时必须是**明确失败**，不是静默返回
        for (name, value) in [("空串", ""), ("纯空白", "   \n\t  ")] {
            do {
                try write(value, to: root.appendingPathComponent("empty.md"))
                check(false, "无笔记（\(name)）：必须报错而不是静默", "居然写成功了")
            } catch let error as NotesExportError {
                let msg = error.errorDescription ?? ""
                check(msg.contains("生成笔记"),
                      "无笔记（\(name)）：报错且说清下一步做什么", msg)
            } catch {
                check(false, "无笔记（\(name)）：报错类型应是 NotesExportError",
                      "\(type(of: error))")
            }
        }

        // ③ 目标不可写时必须**报出来**，不许静默吞掉
        let locked = root.appendingPathComponent("locked")
        do {
            try fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            do {
                try write(sample, to: locked.appendingPathComponent("nope.md"))
                check(false, "目标不可写：必须报错而不是静默", "居然写成功了（是不是在 root 下跑？）")
            } catch let error as NotesExportError {
                let msg = error.errorDescription ?? ""
                check(msg.contains("导出失败") && msg.contains("nope.md"),
                      "目标不可写：报错可见且带路径", msg)
            }
        } catch {
            check(false, "目标不可写：造夹具失败", "\(error.localizedDescription)")
        }

        // ④ 路径解释：给目录 → 目录 + 默认文件名；给 .md → 就当文件
        //
        // 断言里**写字面串，不写 `defaultFileName(for:)`**：拿被测代码自己调的那个
        // 函数去断言它自己的输出是循环的——把 `dateFormat` 改成 `yyyy/MM/dd`，
        // 断言两边一起变，照样绿。这里钉的是「2028-11-22」这个字面串，
        // 改格式必然红
        let stamp = Date(timeIntervalSince1970: 1_858_464_000)
        let expectedName = "课堂笔记-2028-11-22.md"
        check(defaultFileName(for: stamp) == expectedName,
              "默认文件名：日期格式钉死", defaultFileName(for: stamp))

        let dirURL = try? resolveTarget(path: root.appendingPathComponent("byDir").path, now: stamp)
        check(dirURL?.lastPathComponent == expectedName && dirURL?.pathExtension == "md",
              "路径解释：给目录 → 拼默认文件名",
              dirURL?.lastPathComponent ?? "解析失败")

        // ⑤ 空路径必须挡住，不能落到「当前工作目录」上（见 resolveTarget 的注释）
        do {
            _ = try resolveTarget(path: "   \n ", now: stamp)
            check(false, "空路径：必须报错", "居然解析成功了")
        } catch let error as NotesExportError {
            check((error.errorDescription ?? "").contains("没给路径"),
                  "空路径：报错说清原因", error.errorDescription ?? "")
        } catch {
            check(false, "空路径：报错类型应是 NotesExportError", "\(type(of: error))")
        }

        let explicit = root.appendingPathComponent("byFile/custom.md")
        let fileURL = try? resolveTarget(path: explicit.path, now: stamp)
        check(fileURL?.lastPathComponent == "custom.md"
              && fm.fileExists(atPath: explicit.deletingLastPathComponent().path),
              "路径解释：给 .md → 就当文件，并把父目录建出来",
              fileURL?.path ?? "解析失败")

        return r
    }
}
