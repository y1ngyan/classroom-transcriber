import Foundation

/// 学习笔记的落盘。**独立目录、独立文件**，与转录彻底分离（拍板 3b）。
///
/// 目录布局（Application Support/ClassroomTranscriber/study-notes/）：
///   `<uuid>.notes.json` —— 一条 `StudyNotes`
///
/// **为什么另开一个目录，而不是放进 `sessions/`**：`RecordingsStore.rebuildIndex`
/// 会扫 `sessions/` 下所有 `.json` 去重建索引（它按扩展名认文件），把笔记文件
/// 放进去会被它当成一条坏掉的会话读一遍——虽然解不出来会被 `continue` 跳过，
/// 但那是「碰巧没出事」。更实在的理由是拍板 3b 要的就是物理分离：转录目录里
/// 混着模型写过手的东西，谁扫谁都得先判断一遍这是哪种文件。
///
/// 没有 `index.json`：笔记是**按会话 id 直接取**的（详情页手里就有 id），
/// 列表页不需要它。多一份索引就多一处会跟正文不一致的地方
enum StudyNotesStorage {

    /// `.notes.json` 而不是 `.json`：目录里同时躺着转录文件时（用户手工
    /// 拷到一起、或者将来两个目录合并），后缀就是唯一的区分手段
    static let fileSuffix = ".notes.json"

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ClassroomTranscriber", isDirectory: true)
            .appendingPathComponent("study-notes", isDirectory: true)
    }

    static func fileURL(sessionID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString)\(fileSuffix)")
    }

    /// 写一份笔记。编码参数照 `RecordingsStore`：`prettyPrinted + sortedKeys`
    /// 是为了能直接打开看/进 diff，`.atomic` 是为了不留下写了一半的文件
    static func save(_ notes: StudyNotes, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(notes).write(
            to: fileURL(sessionID: notes.sessionID, in: directory),
            options: .atomic
        )
    }

    /// 读一份笔记。**没有这份笔记返回 nil，文件坏了也返回 nil**——
    /// 两者在调用方看来是同一件事（「现在没有可显示的笔记」），而笔记是
    /// 可重生成的派生数据，为一份坏文件把详情页弄崩不值得。
    /// 要区分「没有」和「坏了」的话得看文件在不在，那是 `hasNotes` 的事
    static func load(sessionID: UUID, in directory: URL) -> StudyNotes? {
        let url = fileURL(sessionID: sessionID, in: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StudyNotes.self, from: data)
    }

    static func delete(sessionID: UUID, in directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(sessionID: sessionID, in: directory))
    }
}
