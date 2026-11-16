import Foundation
import Photos
import AVFoundation

/// 高清视频落盘缓存：升过清晰的视频原片存沙盒，下次同一个视频当本地文件播。
///
/// 「先糊后清」只对当次播放有效 —— 高清活在内存里的影子 `AVPlayer` 上，翻页就没了，
/// 回来时 `MediaLoader.playerItem` 仍先给 `.fastFormat` 低清副本，于是每次都经历
/// 「糊两三秒 → 淡入高清」。这里在升清晰成功后用 `PHAssetResourceManager.writeData`
/// 把原片写到 `Caches/HDVideoCache/`，下次 `AVPlayerItem(url:)` 直接高清起播。
///
/// 三个取舍：
/// 1. 只留最近 3 个，按 mtime 做 LRU（每次命中都会 touch），原片动辄几百 MB。
/// 2. 文件名带 `modificationDate`：素材被编辑过就查不到旧文件，顺手删掉，
///    不会放上一次编辑前的内容。
/// 3. 放 Caches：系统存储吃紧时可直接回收，最差退化成重新下载。
@MainActor
final class HDVideoCache {

    static let shared = HDVideoCache()

    /// 与 `SlideshowSettings.Key.videoDiskCache` 必须是同一串
    static let defaultsKey = "lantern.videoDiskCache"

    private let capacity = 3
    /// 兜底总容量：三个 4K 长片可能上 GB
    private let byteCap = 2_000_000_000

    private let fileManager = FileManager.default

    /// 正在写盘的素材，避免同一个视频并发写两遍
    private var inFlight: Set<String> = []

    private let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("HDVideoCache", isDirectory: true)
        directory = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - 开关

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    // MARK: - 查

    /// 有没有已落盘的高清文件。命中就 touch 一下（LRU 看 mtime）。
    /// 素材被编辑过（`modificationDate` 变了）时删掉旧文件返回 nil —— 宁可重下。
    func existingURL(for asset: PHAsset) -> URL? {
        guard enabled else { return nil }
        let prefix = sanitizedName(asset)
        let wanted = fileName(for: asset)

        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var hit: URL?
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix + "~") else { continue }
            if name == wanted {
                hit = url
            } else {
                try? fileManager.removeItem(at: url)
                Log.media.debug("dropped stale hd cache \(String(asset.localIdentifier.suffix(6)), privacy: .public)")
            }
        }

        if let hit {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: hit.path)
        }
        return hit
    }

    // MARK: - 写

    /// 升清晰成功后调用。已在缓存 / 正在写 / 开关关着都直接返回。
    func store(_ asset: PHAsset) {
        guard enabled else { return }
        let id = asset.localIdentifier
        guard !inFlight.contains(id) else { return }
        guard existingURL(for: asset) == nil else { return }

        inFlight.insert(id)
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.write(asset)
            self.inFlight.remove(id)
        }
    }

    /// 清空（设置里关掉开关时调用）
    func clear() {
        guard let items = try? fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { return }
        for url in items {
            try? fileManager.removeItem(at: url)
        }
        inFlight.removeAll()
        Log.media.info("hd video cache cleared")
    }

    // MARK: - 内部

    private func write(_ asset: PHAsset) async {
        // 剪辑过的视频用 .fullSizeVideo，未剪辑的用 .video
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video }) else {
            Log.media.debug("hd cache skipped: no video resource")
            return
        }

        let destination = directory.appendingPathComponent(fileName(for: asset))
        // 先写临时文件再原子挪过去：中途被杀不会留下半截可播文件
        let temporary = directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
        defer { try? fileManager.removeItem(at: temporary) }

        do {
            try await writeData(resource, to: temporary)
        } catch {
            Log.media.debug("hd cache write failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            Log.media.debug("hd cache move failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        evict()
        let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
        let bytes = (attributes?[.size] as? Int) ?? 0
        Log.media.info("hd cached \(String(asset.localIdentifier.suffix(6)), privacy: .public) \(bytes / 1_048_576, privacy: .public)MB")
    }

    private func writeData(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        // iCloud 上的原片也要能下下来
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// LRU：按 mtime 新→旧，超出 `capacity` 个或累计超 `byteCap` 的删掉
    private func evict() {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = items.compactMap { url in
            guard url.pathExtension == "mov" else { return nil }
            // 跳过正在写的临时文件
            guard !url.lastPathComponent.hasPrefix("tmp-") else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }
        entries.sort { $0.date > $1.date }

        var total = 0
        for (index, entry) in entries.enumerated() {
            total += entry.size
            guard index >= capacity || total > byteCap else { continue }
            try? fileManager.removeItem(at: entry.url)
            Log.media.debug("evicted hd cache \(entry.url.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: - 命名

    /// `localIdentifier` 形如 `E1B2.../L0/001`，带斜杠不能直接当文件名
    private func sanitizedName(_ asset: PHAsset) -> String {
        asset.localIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "~", with: "-")
    }

    /// 名字带素材版本时间戳：素材被编辑后 `modificationDate` 变，旧缓存自然作废
    private func fileName(for asset: PHAsset) -> String {
        let stamp = Int(asset.modificationDate?.timeIntervalSince1970 ?? 0)
        return "\(sanitizedName(asset))~\(stamp).mov"
    }
}
