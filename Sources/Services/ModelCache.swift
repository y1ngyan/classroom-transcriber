import Foundation

/// 模型目录里的**一项**（一个文件）。
///
/// 为什么要分这么细，而不是「列出目录里所有文件」：清理这件事只对
/// **我们自己造出来的东西**成立。`ggml-*.bin` 是用户的资产——哪怕它没通过
/// 校验、哪怕它明显是个下坏的残骸，也不在我们能删的范围内。这一步区分
/// 做在类型里，而不是靠调用方「记得别删那个」。
struct ModelCacheItem: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        /// 占着正式名字、且通过校验
        case model
        /// 占着正式名字、但过不了校验（截断的、被代理塞了 HTML 的……）。
        /// **可报告、不可删**
        case damagedModel
        /// 未完成的下载（`.part`）
        case partial
        /// 未完成下载旁边的版本记录（`.part.meta.json`）。跟着 `.part` 一起清
        case sidecar
    }

    var id: String { url.path }
    var url: URL
    var kind: Kind
    var bytes: Int64
    var modified: Date?
    var meta: PartMeta?
    /// 读出来的大小/版本信息，给人看的一句话（「已下 12.3 MB · 记录 revision …」）
    var detail: String
}

/// 「准备删掉这些」。**先出计划、再动手**——确认框里显示的和实际删的
/// 是同一个东西，不是两处各算一遍
struct ModelCachePlan: Equatable, Sendable {
    var items: [ModelCacheItem]
    var totalBytes: Int64

    var isEmpty: Bool { items.isEmpty }

    /// 逐条明细（确认框里的那个列表）
    var itemLines: [String] {
        items.map { "  · \($0.url.lastPathComponent)（\(ModelCache.byteText($0.bytes))）" }
    }

    /// 「将删除 N 项、共多少」。措辞对标 `hf cache rm/prune --dry-run` 的
    /// `About to delete … (2.4G total)`——**它是一句总账**，所以
    /// `itemLines` 和它分开：总账已经在报告里出现过了，逐条明细再带一遍
    /// 就成了同一句话印两遍
    var totalLine: String {
        "About to delete \(items.count) item(s) (\(ModelCache.byteText(totalBytes)) total)"
    }

    /// 确认框里逐条念的内容
    var lines: [String] { itemLines + [totalLine] }
}

/// 模型目录的占用报告。
///
/// 对应派单第 4 条：**未完成的下载要单独列出来、能清、清之前说清楚释放多少**。
/// 现状是 `.part` 默默躺在那里，用户既不知道它占了多少、也不知道它是什么，
/// 更不知道怎么处理——而 500MB 级的残骸正好是最占地方的那种。
struct ModelCacheReport: Equatable, Sendable {
    var directory: String
    var items: [ModelCacheItem]

    var models: [ModelCacheItem] { items.filter { $0.kind == .model } }
    var damaged: [ModelCacheItem] { items.filter { $0.kind == .damagedModel } }
    var partials: [ModelCacheItem] { items.filter { $0.kind == .partial } }
    var sidecars: [ModelCacheItem] { items.filter { $0.kind == .sidecar } }

    /// 能清的：只有我们自己造的那些。
    ///
    /// 顺序有意义：`.part` 在前、它的版本记录紧跟在后——清理时先删数据
    /// 再删记录，中途被打断也不会留下一个「有记录没数据」的孤儿
    var freeable: [ModelCacheItem] { partials + sidecars }
    var freeableBytes: Int64 { freeable.reduce(0) { $0 + $1.bytes } }

    var plan: ModelCachePlan {
        ModelCachePlan(items: freeable, totalBytes: freeableBytes)
    }

    /// 逐行报告。两处**刻意保留 HF 的英文措辞**（见下面注释），其余中文——
    /// 探针按那两句 grep，而且它们本来就是从 `hf cache ls` / `hf cache prune
    /// --dry-run` 的输出里抄来的形状，翻译了反而对不上
    var summaryLines: [String] {
        var out: [String] = ["占用：\(directory)"]
        for item in models {
            out.append("  模型 \(item.url.lastPathComponent) · \(ModelCache.byteText(item.bytes)) · 通过校验")
        }
        for item in damaged {
            out.append("  残骸 \(item.url.lastPathComponent) · \(ModelCache.byteText(item.bytes)) · \(item.detail)")
        }
        // 这一句的措辞对标 `hf cache ls` 的 `Found X incomplete download(s)`：
        // 它是一个**独立的、可被 grep 的**信号，不该混进上面那堆明细里
        out.append("Found \(partials.count) incomplete download(s)")
        for item in partials {
            out.append("  未完成 \(item.url.lastPathComponent) · \(ModelCache.byteText(item.bytes)) · \(item.detail)")
        }
        for item in sidecars {
            out.append("  版本记录 \(item.url.lastPathComponent) · \(ModelCache.byteText(item.bytes))")
        }
        if !freeable.isEmpty {
            // 措辞对标 `hf cache rm/prune --dry-run` 的
            // `About to delete … (2.4G total)`
            out.append("About to delete \(freeable.count) item(s) (\(ModelCache.byteText(freeableBytes)) total)")
        }
        return out
    }

    /// 扫一遍目录。目录不存在 → 空报告（不是错误：第一次跑就该是空的）
    ///
    /// - Parameter manifest: 有清单时，每个文件**按自己的文件名**去清单里找
    ///   那一版。**不能拿「默认那一版」去套所有文件**：模型目录里同时躺着
    ///   `ggml-medium` 和 `ggml-large-v3`，用 medium 的大小去判 large-v3，
    ///   会把一个完好的模型报成「残骸，大小不对」
    static func scan(directory: URL, manifest: ModelManifest? = nil) -> ModelCacheReport {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        var items: [ModelCacheItem] = []

        for name in names.sorted() {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            let bytes = ModelDownloader.fileSize(url)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date

            let pin = manifest?.pin(forFile: name)
            if name.hasSuffix(".part.meta.json") {
                items.append(ModelCacheItem(url: url, kind: .sidecar, bytes: bytes,
                                            modified: modified, meta: nil,
                                            detail: "未完成下载的版本记录"))
            } else if name.hasSuffix(".part") {
                let meta = PartMeta.read(forPart: url)
                // `.part` 的名字是 `ggml-xxx.bin.part`，去掉后缀就是它对应
                // 的那个模型——版本比对照的是那一个，不是默认那一个
                let owner = manifest?.pin(forFile: String(name.dropLast(".part".count)))
                items.append(ModelCacheItem(url: url, kind: .partial, bytes: bytes,
                                            modified: modified, meta: meta,
                                            detail: partialDetail(meta: meta, pin: owner)))
            } else if name.hasPrefix("ggml-") && name.hasSuffix(".bin") {
                let failure = ModelFile.validationFailure(at: url, minimumBytes: 0, pin: pin)
                items.append(ModelCacheItem(
                    url: url, kind: failure == nil ? .model : .damagedModel,
                    bytes: bytes, modified: modified, meta: nil,
                    detail: failure ?? "通过校验"))
            }
            // 别的文件一律不列：这个目录是用户自己的，不是我们的缓存区，
            // 列出来只会让人以为我们打算动它们
        }
        return ModelCacheReport(directory: directory.path, items: items)
    }

    private static func partialDetail(meta: PartMeta?, pin: ModelPin?) -> String {
        guard let meta else { return "没有版本记录" }
        var parts: [String] = []
        if let revision = meta.revision { parts.append("记录 revision \(String(revision.prefix(12)))…") }
        if let size = meta.size, size > 0 {
            parts.append("源上共 \(ModelCache.byteText(size))")
        }
        if let pin {
            if let revision = meta.revision, revision == pin.revision {
                parts.append("与清单一致")
            } else {
                parts.append("与清单（\(pin.shortRevision)…）**不一致**，续传时会重下")
            }
        }
        return parts.isEmpty ? "没有版本记录" : parts.joined(separator: " · ")
    }

    /// 真的删。**只删 `plan` 里的东西**，而且删之前每一条都再确认一次它是
    /// 我们能删的种类——计划是算出来的，删除是不可逆的，两者之间不该只靠
    /// 「调用方不会搞错」
    ///
    /// 返回实际释放的字节数
    @discardableResult
    func clean(using fm: FileManager = .default) throws -> Int64 {
        var freed: Int64 = 0
        for item in plan.items {
            guard item.kind == .partial || item.kind == .sidecar else { continue }
            let before = ModelDownloader.fileSize(item.url)
            try fm.removeItem(at: item.url)
            freed += before
        }
        return freed
    }

}

/// 「这个目录占了多少、能清多少」这套东西的命名空间。
///
/// 单独拎出来只为一件事：`byteText`。它在报告、计划、确认框三处都要用，
/// 而这三处必须显示**同一个数**——三处各写一遍格式化，迟早会出现
/// 「清单说 512 MB、确认框说 0.51 GB」这种对不上的地方
enum ModelCache {

    /// 字节数说人话。和 `ModelAvailability.mbText` 同样的小于 100 保一位小数，
    /// 但多一档 GB——1.5GB 的模型库显示成「1544.2 MB」不便于读
    static func byteText(_ bytes: Int64) -> String {
        let gb = 1_000_000_000.0, mb = 1_000_000.0
        // KB 那一档和 `ModelAvailability.mbText` 同样的理由：模型目录里
        // 真会出现几十字节的碎屑（版本记录、下到一半就断的 `.part`），
        // 印成「0.0 MB」等于没说——而「将释放多少」这句话是要照着做决定的。
        //
        // 再往下一层还有一档：`%.0f` 把 9 字节印成「0 KB」，那和「0.0 MB」
        // 是同一种错——**文件非空却说成零**。所以 1KB 以下直接报字节数
        // （实测就是这条：`.part.meta.json` 是 91 字节，清理清单里印「0 KB」）
        if bytes < 1_000 { return "\(bytes) 字节" }
        if bytes < 1_000_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        if Double(bytes) >= gb { return String(format: "%.2f GB", Double(bytes) / gb) }
        if Double(bytes) >= 100 * mb { return String(format: "%.0f MB", Double(bytes) / mb) }
        return String(format: "%.1f MB", Double(bytes) / mb)
    }
}
