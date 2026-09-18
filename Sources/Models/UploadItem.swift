import Foundation

/// 上传队列里的一项。
///
/// 整个结构 `Codable` 且**包含续传所需的全部状态**（uploadId + 已传分片
/// 的 ETag），因为它会跟着队列一起落盘。App 重启后靠这份状态接着传，
/// 而不是从头再来。
struct UploadItem: Identifiable, Codable, Equatable {

    enum Status: String, Codable {
        case queued
        case uploading
        case paused
        case completed
        case failed

        var label: String {
            switch self {
            case .queued: return "排队中"
            case .uploading: return "上传中"
            case .paused: return "已暂停"
            case .completed: return "已完成"
            case .failed: return "失败"
            }
        }

        /// 是否还能被用户操作（重传 / 继续）
        var isTerminal: Bool { self == .completed }
    }

    var id: UUID = UUID()
    /// 本地音频文件的绝对路径
    var filePath: String
    /// 显示用的文件名
    var fileName: String
    /// COS 对象键。**排队时就定下来并持久化**——续传必须用同一个键，
    /// 每次重新生成的话已传的分片就全成了孤儿
    var key: String
    var totalBytes: Int64 = 0
    var uploadedBytes: Int64 = 0
    var status: Status = .queued
    var uploadID: String?
    var completedParts: [Int: String] = [:]
    var message: String = ""
    var createdAt: Date = Date()

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(uploadedBytes) / Double(totalBytes))
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// 断点续传状态。和 COSService 之间来回传的就是这个
    var uploadState: COSService.UploadState {
        get {
            COSService.UploadState(
                uploadID: uploadID,
                completedParts: completedParts,
                uploadedBytes: uploadedBytes,
                totalBytes: totalBytes
            )
        }
        set {
            uploadID = newValue.uploadID
            completedParts = newValue.completedParts
            uploadedBytes = newValue.uploadedBytes
            totalBytes = newValue.totalBytes
        }
    }
}

enum UploadKey {
    /// 生成 COS 对象键。
    ///
    /// **刻意只用 ASCII**：对象键里放中文会让 URL 路径的编码方式在
    /// 「签名」和「实际请求」两边产生分歧，而 COS 签名是对整个请求串
    /// 做哈希的，差一个百分号就全错。用时间戳 + 短 UUID 足够唯一，
    /// 中文原始文件名留在本地 `fileName` 里显示。
    static func make(for fileURL: URL, prefix: String = AppConfig.cosKeyPrefix) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let suffix = UUID().uuidString.prefix(8).lowercased()
        // 扩展名是唯一一处从文件名漏进键里的东西，而它同样可能是中文
        // （`课堂.录音`）。不是纯 ASCII 就整个丢掉——键的唯一性由时间戳
        // 和 UUID 保证，扩展名只是给人看的。
        let rawExt = fileURL.pathExtension.lowercased()
        let ext = rawExt.allSatisfy(\.isASCII) ? rawExt : ""
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = "\(stamp)-\(suffix)\(ext.isEmpty ? "" : ".\(ext)")"

        return trimmedPrefix.isEmpty ? name : "\(trimmedPrefix)/\(name)"
    }
}
