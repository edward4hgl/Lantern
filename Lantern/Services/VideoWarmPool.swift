import Foundation
import Photos
import AVFoundation

/// 视频预热池 —— 让视频翻页也接近零等待。
///
/// `requestPlayerItem` 拿到的只是清单（能算时长），解码器还没醒、首帧没解出来。
/// 要做到一翻页就出画面，得四步：挂到 `AVPlayer` 上 → 等 `status == .readyToPlay`
/// → `preroll(atRate: 0)` 预解码首帧 → `automaticallyWaitsToMinimizeStalling = false`。
/// 翻到这一页时把预热好的 player 直接交给 `PlayerLayerContainer`，`play()` 就是第一帧。
///
/// 容量 3、一次预热后续两个视频：每多一个 `AVPlayer` 就多一组硬解码器，
/// 而相簿里常有两段视频挨着，只预热一段的话第一段播完还得现拉第二段。
@MainActor
final class VideoWarmPool {

    static let shared = VideoWarmPool()

    private final class Slot {
        let assetID: String
        let player: AVPlayer
        init(assetID: String, player: AVPlayer) {
            self.assetID = assetID
            self.player = player
        }
    }

    /// LRU：越靠后越新。正在播的一定在末尾，永远不会被淘汰。
    private var slots: [Slot] = []
    private var building: Set<String> = []
    private let capacity = 3
    private let warmDepth = 2
    /// 纪元：`cancelAll()` 递增，在飞的预热靠它认出「用户已经离开了」
    private var poolEpoch = 0

    private init() {}

    // MARK: - 取用

    /// 同步取一个预热好的 player。命中时移到 LRU 末尾（标记为正在用）。
    func player(for assetID: String) -> AVPlayer? {
        guard let index = slots.firstIndex(where: { $0.assetID == assetID }) else { return nil }
        let slot = slots.remove(at: index)
        slots.append(slot)
        return slot.player
    }

    func isWarm(_ assetID: String) -> Bool {
        slots.contains { $0.assetID == assetID }
    }

    // MARK: - 预热

    /// 从「接下来几张」里挑出前两个视频预热。`warm` 自带 `building` 去重。
    func warmUpcoming(_ items: [SlideItem]) {
        let videos = items.filter(\.isVideo).prefix(warmDepth)
        guard !videos.isEmpty else { return }
        for video in videos {
            warm(assetID: video.id)
        }
    }

    func warm(assetID: String) {
        if isWarm(assetID) || building.contains(assetID) { return }
        building.insert(assetID)

        // .userInitiated：比图片预热更急，视频准备链路更长
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer { self.building.remove(assetID) }

            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
                return
            }

            // 已落盘的不必预热：本地文件建 item 是一帧的事，而且 `SlideContent`
            // 命中缓存时会自建 player、不取池子里的，预热它只白占槽位。
            guard HDVideoCache.shared.existingURL(for: asset) == nil else { return }

            guard let item = await MediaLoader.shared.playerItem(for: asset) else {
                Log.media.error("warm failed, no player item: \(String(assetID.prefix(8)), privacy: .public)")
                return
            }
            guard !self.isWarm(assetID) else { return }

            // 记下纪元：退出轮播后这条 Task 不该再把 player 塞回池子占解码器
            let epoch = self.poolEpoch

            // 只要半秒前置缓冲：翻页先出画面，剩下边播边下
            item.preferredForwardBufferDuration = 0.5

            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            player.allowsExternalPlayback = false
            player.usesExternalPlaybackWhileExternalScreenIsActive = false
            player.automaticallyWaitsToMinimizeStalling = false

            // 状态仍是 .unknown 时 AVPlayer 拒绝 preroll
            let readyToPreroll = await self.waitUntilReady(player)

            // 等不到 ready 也不扔：item 已过缓冲状态机，挂上 layer 后 KVO 会回调 onReady。
            // 只有 .failed 才丢。
            guard player.status != .failed else {
                player.replaceCurrentItem(with: nil)
                return
            }

            if readyToPreroll {
                // 结果不参与判断：preroll 失败只是首帧没预解码，画面晚一两帧
                player.preroll(atRate: 0) { finished in
                    if !finished {
                        Log.media.debug("preroll declined \(String(assetID.prefix(8)), privacy: .public)")
                    }
                }
            }

            guard !self.isWarm(assetID) else {
                player.replaceCurrentItem(with: nil)
                return
            }
            guard epoch == self.poolEpoch else {
                player.replaceCurrentItem(with: nil)
                return
            }

            if self.slots.count >= self.capacity {
                let dropped = self.slots.removeFirst()
                dropped.player.pause()
                dropped.player.replaceCurrentItem(with: nil)
            }

            self.slots.append(Slot(assetID: assetID, player: player))
            Log.media.debug("warmed video \(String(assetID.prefix(8)), privacy: .public) ready=\(readyToPreroll)")
        }
    }

    /// 轮询等 `player.status` 走到 readyToPlay。不用 KVO + continuation：
    /// 超时后回调再来会 resume 两次；这里 40ms 一探总共也就几十次。
    private func waitUntilReady(_ player: AVPlayer, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch player.status {
            case .readyToPlay:
                return true
            case .failed:
                return false
            default:
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        return player.status == .readyToPlay
    }

    func cancelAll() {
        poolEpoch &+= 1        // 让在飞的预热自我作废
        for slot in slots {
            slot.player.pause()
            slot.player.replaceCurrentItem(with: nil)
        }
        slots.removeAll()
        building.removeAll()
    }
}
