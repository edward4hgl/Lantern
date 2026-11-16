import Foundation
import Photos
import AVFoundation
import UIKit

/// 实况照片 / 视频的加载器。两者都可能从 iCloud 拉，所以都开了网络。
@MainActor
final class MediaLoader {

    static let shared = MediaLoader()

    private let manager = PHImageManager.default()

    private init() {}

    // MARK: - 实况照片

    func livePhoto(for asset: PHAsset, targetSize: CGSize) async -> PHLivePhoto? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PHLivePhoto?, Never>) in
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            var settled = false

            manager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { livePhoto, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                if settled { return }
                settled = true

                if let error = info?[PHImageErrorKey] as? Error {
                    Log.media.error("live photo request failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: livePhoto)
            }
        }
    }

    // MARK: - 视频

    /// 拿一段视频的 `AVPlayerItem`，用于起播。
    ///
    /// `deliveryMode` 用 `.fastFormat`：iCloud 原片未下载时 `.automatic` / `.highQualityFormat`
    /// 会先等原片下够才回调，几十秒起步；`.fastFormat` 允许先流一段低码率副本，
    /// 通常一两秒起播（本地素材仍返回原片）。之后再由 `VideoQualityUpgrader` 悄悄升清晰。
    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = true
            options.version = .current

            var settled = false

            manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                if settled { return }
                // requestPlayerItem 一般不回调降级，但保险起见还是判一下
                if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded { return }
                settled = true

                if let error = info?[PHImageErrorKey] as? Error {
                    Log.media.error("video request failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - 视频的高清副本（「先糊后清」用）

    /// 只要高清原片，**绝不用它起播**。与 `playerItem(for:)` 唯一差别是 `.highQualityFormat`：
    /// iCloud 未下载时会老实等原片下够，正适合放后台慢慢来（见 `VideoQualityUpgrader`）。
    /// 只回调一次终态，无需判降级；失败一律 nil，调用方放弃升级。
    func highQualityPlayerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current

            var settled = false

            manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                if settled { return }
                if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded { return }
                settled = true

                if let error = info?[PHImageErrorKey] as? Error {
                    Log.media.debug("hd video unavailable: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - 缩略图（列表用）

    func thumbnail(for assetID: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return nil
        }
        return await ImageLoader.shared.image(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill
        )
    }
}
