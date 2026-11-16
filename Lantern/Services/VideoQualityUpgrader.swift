import Foundation
import AVFoundation
import Photos

/// 「先糊后清」：起播用 `.fastFormat` 抢时间，后台再要一份 `.highQualityFormat`，
/// 能播了就交给第二层 `AVPlayerLayer` 交叉淡化上去。正在播的那份一秒都不停。
///
/// 四个容易踩空的点：① 没挂在 `AVPlayer` 上的 item 不缓冲，`status` 永远 `.unknown`
/// ② 挂上还要真播起来，`rate` 为 0 时管线不激活 ③ 不能一 ready 就交接，得等
/// `loadedTimeRanges` 盖住播放头并留余量 ④ 影子与主 player 会漂开，交接前要重新对齐。
@MainActor
final class VideoQualityUpgrader {

    static let shared = VideoQualityUpgrader()

    /// 影子 player：只为让高清 item 走完缓冲状态机，交接后立刻释放
    private var shadowPlayers: [ObjectIdentifier: AVPlayer] = [:]

    /// 每个正在播的 player 最多一条升级任务
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// 已经换成高清的 (player, asset)。`cancelAll()` 清空 ——
    /// 那时预热池已放掉全部 player，地址可能被复用，留着重会误判成「已升过」。
    private var upgraded: [ObjectIdentifier: String] = [:]

    /// 纪元：`cancelAll()` 递增，在飞的升级任务靠它认出「用户已经离开轮播」
    private var epoch = 0

    private let readyTimeout: TimeInterval = 25
    private let coverTimeout: TimeInterval = 15
    /// 换过去之后要留出的缓冲余量（秒）
    private let coverLead: Double = 2.0

    private init() {}

    // MARK: - 对外

    /// 给某个正在播的 player 排一次升级。同一个 player 重复调用幂等。
    ///
    /// - Parameter onPromote: 高清能播且缓冲够了时回调，参数是已在正确位置静音播放
    ///   的影子 player。调用方把它交给 `PlayerLayerContainer` 做交叉淡化 ——
    ///   这里**不碰**正在播的那个 player。
    func schedule(for player: AVPlayer, assetID: String, onPromote: @escaping (AVPlayer) -> Void) {
        let key = ObjectIdentifier(player)
        if upgraded[key] == assetID { return }
        if tasks[key] != nil { return }
        guard player.currentItem != nil else { return }

        let token = epoch
        tasks[key] = Task(priority: .utility) { [weak self, weak player] in
            guard let self, let player else { return }
            await self.upgrade(player: player,
                               assetID: assetID,
                               key: key,
                               token: token,
                               onPromote: onPromote)
        }
    }

    /// 这一页不要这个 player 了：停掉它名下的升级与影子 player
    func cancel(for player: AVPlayer) {
        let key = ObjectIdentifier(player)
        tasks[key]?.cancel()
        tasks[key] = nil
        releaseShadow(key)
    }

    /// 离开轮播：全部收摊
    func cancelAll() {
        epoch &+= 1
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        // 先拷一份 key：releaseShadow 会改 shadowPlayers，边遍历边删会崩
        for key in Array(shadowPlayers.keys) { releaseShadow(key) }
        upgraded.removeAll()
    }

    // MARK: - 主流程

    /// 全程显式 `self.`：函数里多处 `await`，之后访问成员省略 self 会报
    /// "Reference to property ... in closure requires explicit use of 'self'"。
    private func upgrade(player: AVPlayer,
                         assetID: String,
                         key: ObjectIdentifier,
                         token: Int,
                         onPromote: @escaping (AVPlayer) -> Void) async {
        defer { self.tasks[key] = nil }

        let original = player.currentItem
        guard original != nil else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return
        }

        guard let hd = await MediaLoader.shared.highQualityPlayerItem(for: asset) else { return }
        // 等高清的这段时间里，用户可能已经翻页 / 换了播放器
        guard token == self.epoch, player.currentItem === original else { return }

        // 影子 player 必须静音播起来，否则 item.status 停在 .unknown
        let shadow = AVPlayer(playerItem: hd)
        shadow.isMuted = true
        shadow.allowsExternalPlayback = false
        // 这里要的是老实攒缓冲，所以保持默认 true。主 player 那边才是 false。
        shadow.automaticallyWaitsToMinimizeStalling = true
        self.shadowPlayers[key] = shadow

        // 先对齐到当前位置：要缓冲的正是「接下来要播的那一段」，别从 0 秒白下
        await Self.seek(shadow, to: player.currentTime())
        shadow.play()

        let ready = await Self.waitUntilReady(hd, timeout: self.readyTimeout)
        guard ready else {
            Log.media.debug("hd upgrade skipped: high quality item never became ready")
            self.releaseShadow(key)
            return
        }

        // 等缓冲推到播放头前面
        let covered = await Self.waitUntilCovering(hd,
                                                   on: shadow,
                                                   lead: self.coverLead,
                                                   timeout: self.coverTimeout)
        guard token == self.epoch, player.currentItem === original else {
            self.releaseShadow(key)
            return
        }
        if !covered {
            Log.media.debug("hd upgrade deferred: buffered range does not cover the playhead yet")
            self.releaseShadow(key)
            return
        }

        // 交接前再对齐一次：影子是「发起升级那一刻」起播的，几十秒下来会漂开
        let basePosition = player.currentTime()
        await Self.seek(shadow, to: basePosition)
        // seek 之后给几帧把新位置的画面解出来，否则淡入第一眼是旧的
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard token == self.epoch, player.currentItem === original else {
            self.releaseShadow(key)
            return
        }

        // 所有权交给视图层：从这里起不再归这个池子管，
        // 否则 `cancelAll()` 会把正在显示的播放器停掉。
        self.shadowPlayers.removeValue(forKey: key)
        self.upgraded[key] = assetID
        onPromote(shadow)
        Log.media.info("hd layer handed over at \(String(format: "%.1f", basePosition.seconds), privacy: .public)s")
    }

    // MARK: - 小工具

    private func releaseShadow(_ key: ObjectIdentifier) {
        guard let shadow = shadowPlayers.removeValue(forKey: key) else { return }
        shadow.pause()
        shadow.replaceCurrentItem(with: nil)
    }

    /// 轮询等 `status == .readyToPlay`。不用 KVO + continuation：
    /// 超时之后那个 KVO 回调仍可能来一次，会把同一个 continuation resume 两次。
    private static func waitUntilReady(_ item: AVPlayerItem, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: break
            }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return item.status == .readyToPlay
    }

    private static func seek(_ player: AVPlayer, to time: CMTime) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 显式选带 completion handler 的重载：async 上下文里
            // `seek(to:toleranceBefore:toleranceAfter:)` 会被解析成返回 Bool 的异步版本
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    /// 等缓冲推到影子 player 播放头前面 `lead` 秒。
    /// 量影子自己的头才准（两边都在走）。本地文件常返回空 ranges，视为已够。
    private static func waitUntilCovering(_ item: AVPlayerItem,
                                          on shadow: AVPlayer,
                                          lead: Double,
                                          timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if coversPlayhead(item, head: shadow.currentTime(), lead: lead) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return coversPlayhead(item, head: shadow.currentTime(), lead: lead)
    }

    private static func coversPlayhead(_ item: AVPlayerItem, head: CMTime, lead: Double) -> Bool {
        let ranges = item.loadedTimeRanges
        if ranges.isEmpty { return true }            // 本地 / 已完整缓存
        let seconds = head.seconds
        guard seconds.isFinite else { return false }
        let need = seconds + lead
        for value in ranges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = start + range.duration.seconds
            if start.isFinite, end.isFinite, need <= end { return true }
        }
        return false
    }
}
