import Foundation
import Photos
import AVFoundation
import UIKit

/// 预热管线：把「接下来几张」真正解码进内存。
///
/// 与 `PHCachingImageManager.startCachingImages` 的区别：后者只是「告诉系统我可能要」，
/// 缓存归系统所有、查不到也不保证命中；这里把**真正那一次请求**在后台跑完放进自己的
/// `NSCache`，翻页时同步取出，零等待。
///
/// 只预热当前页之后 6 张，且**串行**：六条并发 iCloud 下载会互抢带宽，
/// 反而拖慢最近那一张 —— 而那一张才是马上要看的。
@MainActor
final class PreloadPipeline {

    static let shared = PreloadPipeline()

    private let images = ImageLoader.shared

    private let livePhotos: NSCache<NSString, PHLivePhoto> = {
        let c = NSCache<NSString, PHLivePhoto>()
        c.countLimit = 6
        return c
    }()

    /// 视频不在这里预热 —— 归 `VideoWarmPool` 管。两边都去 `requestPlayerItem`
    /// 会让同一个视频被下载两遍、互抢带宽。

    /// 当前窗口的串行预热任务。换窗口 / 离开轮播直接 cancel。
    private var pump: Task<Void, Never>?
    private var windowIDs: [String] = []

    private init() {}

    // MARK: - 命中查询（同步，翻页路径上调用）

    func cachedImage(for id: String, mode: PHImageContentMode) -> UIImage? {
        images.cachedImage(for: id, targetSize: DisplayMetrics.pixelSize, contentMode: mode)
    }

    func cachedLivePhoto(for id: String) -> PHLivePhoto? {
        livePhotos.object(forKey: id as NSString)
    }

    /// 这一页是不是已经可以零等待上屏
    func isReady(_ item: SlideItem, mode: PHImageContentMode, playLivePhotos: Bool) -> Bool {
        if item.isVideo {
            return VideoWarmPool.shared.isWarm(item.id)
        }
        if item.isLivePhoto, playLivePhotos, cachedLivePhoto(for: item.id) != nil {
            return true
        }
        return cachedImage(for: item.id, mode: mode) != nil
    }

    // MARK: - 开窗

    /// 按顺序预热 `items`（调用方传「当前页之后」的滑动窗口，含首尾环绕）。
    /// 每次都重建 pump：旧窗口的下载立刻停，不跟新窗口抢。
    ///
    /// `mode` 逐张求一次 —— 四类素材可各用铺满 / 完整显示，而 `ImageLoader`
    /// 的缓存 key 里带 contentMode，用错模式等于白预热。
    func preload(_ items: [SlideItem],
                 mode: (SlideItem) -> PHImageContentMode,
                 playLivePhotos: Bool) {
        let wanted = items.map(\.id)
        // 窗口没变就不重启动，避免共享相簿刷新反复打断正在下的那几张
        if wanted == windowIDs, pump != nil, !(pump?.isCancelled ?? true) {
            return
        }
        windowIDs = wanted
        pump?.cancel()

        // 先把 contentMode 算成值数组：Task 的 body 是 escaping 的，
        // 直接捕获非 escaping 的 `mode` 会报 "Escaping closure captures non-escaping parameter"。
        let modes = items.map(mode)

        pump = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            for (index, item) in items.enumerated() {
                if Task.isCancelled { return }
                let contentMode = modes[index]
                if self.isReady(item, mode: contentMode, playLivePhotos: playLivePhotos) { continue }
                await self.load(item: item,
                                contentMode: contentMode,
                                playLivePhotos: playLivePhotos)
            }
            self.pump = nil
        }
    }

    func cancelAll() {
        pump?.cancel()
        pump = nil
        windowIDs.removeAll()
    }

    // MARK: - 单个素材的预热

    private func load(item: SlideItem,
                      contentMode: PHImageContentMode,
                      playLivePhotos: Bool) async {
        if item.isVideo { return }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
            return
        }

        if item.isLivePhoto, playLivePhotos {
            guard !Task.isCancelled else { return }
            if let live = await MediaLoader.shared.livePhoto(for: asset, targetSize: DisplayMetrics.pixelSize) {
                livePhotos.setObject(live, forKey: item.id as NSString)
                Log.media.debug("preloaded live photo \(item.shortID, privacy: .public)")
                return
            }
            // 实况取不到就退化成静帧预热
        }

        guard !Task.isCancelled else { return }
        _ = await images.image(for: asset,
                               targetSize: DisplayMetrics.pixelSize,
                               contentMode: contentMode)
        Log.media.debug("preloaded still \(item.shortID, privacy: .public)")
    }
}
