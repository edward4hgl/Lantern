import Foundation
import Photos
import UIKit

/// 图片解码缓存。
///
/// 幻灯片卡顿的大头是「切到下一张才开始 requestImage」，所以取到的图都存在这里，
/// 翻页时先同步查一次，命中就直接上屏。
@MainActor
final class ImageLoader {

    static let shared = ImageLoader()

    private let manager = PHCachingImageManager()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 64
        c.totalCostLimit = 320 * 1024 * 1024
        return c
    }()

    private init() {}

    func image(for asset: PHAsset,
               targetSize: CGSize,
               contentMode: PHImageContentMode) async -> UIImage? {
        let key = cacheKey(asset.localIdentifier, targetSize, contentMode)
        if let hit = cache.object(forKey: key) {
            return hit
        }

        return await withCheckedContinuation { continuation in
            var settled = false
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            manager.requestImage(for: asset,
                                 targetSize: targetSize,
                                 contentMode: contentMode,
                                 options: options) { image, info in
                // 先来一张降级图，不能当结果用
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                    return
                }
                if settled { return }
                settled = true

                if let error = info?[PHImageErrorKey] as? Error {
                    Log.media.error("image request failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(returning: nil)
                    return
                }

                if let image {
                    let cost = Int(image.size.width * image.size.height * image.scale * 4)
                    self.cache.setObject(image, forKey: key, cost: cost)
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 同步命中查询。`targetSize` 与 `contentMode` 必须和取图时一致，否则 key 对不上。
    func cachedImage(for id: String, targetSize: CGSize, contentMode: PHImageContentMode) -> UIImage? {
        cache.object(forKey: cacheKey(id, targetSize, contentMode))
    }

    private func cacheKey(_ id: String, _ size: CGSize, _ mode: PHImageContentMode) -> NSString {
        let suffix = mode == .aspectFill ? "f" : "t"
        return "\(id)|\(Int(size.width))x\(Int(size.height))|\(suffix)" as NSString
    }
}
