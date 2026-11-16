import SwiftUI
import AVFoundation
import UIKit

/// 视频画面容器：双层 `AVPlayerLayer`，用交叉淡化做「先糊后清」。
///
/// 升级画质不换 item、只淡上一层图层 —— 换 item 会重建解码管线，旧 layer 冻在上一帧，
/// 肉眼是「卡一下」。低清始终在下面播着，高清 0.28 秒淡上来，看不出来。
/// 淡完才停低清，并把进度 / 播完的通知源切到高清。
final class PlayerSurfaceView: UIView {

    let baseLayer = AVPlayerLayer()
    let hdLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // 自己加两个子 layer，所以不再用 `layerClass = AVPlayerLayer.self`
        layer.addSublayer(baseLayer)
        layer.addSublayer(hdLayer)
        hdLayer.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 关掉隐式动画，否则旋转 / 改尺寸时两个 layer 会自己「飘」一下
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.frame = bounds
        hdLayer.frame = bounds
        CATransaction.commit()
    }

    /// 把高清层淡上来。**不动任何 player**，变的只有不透明度。
    func revealHD(duration: Double) {
        guard hdLayer.player != nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = hdLayer.opacity
        animation.toValue = 1.0
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        hdLayer.opacity = 1.0
        hdLayer.add(animation, forKey: "revealHD")
    }

    func hideHD() {
        hdLayer.removeAnimation(forKey: "revealHD")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hdLayer.opacity = 0
        hdLayer.player = nil
        CATransaction.commit()
    }
}

struct PlayerLayerContainer: UIViewRepresentable {

    /// 低清那份（起播用的 `.fastFormat`）。整个停留期间一直在播。
    let player: AVPlayer
    /// 高清那份（`VideoQualityUpgrader` 交过来的影子 player）。`nil` = 只显示低清。
    let hdPlayer: AVPlayer?
    let isMuted: Bool
    let isPaused: Bool
    let loops: Bool
    /// 铺满 / 完整显示由 layer 的 gravity 决定，和图片的 contentMode 对齐
    let videoGravity: AVLayerVideoGravity

    var onReady: (() -> Void)? = nil
    var onProgress: ((Double) -> Void)? = nil
    var onFinished: (() -> Void)? = nil
    /// 淡化结束、画面归高清之后回调 —— 上层要把 seek / 暂停路由到这个新 player 了
    var onHandover: ((AVPlayer) -> Void)? = nil

    /// 交叉淡化时长。太短能看见接缝，太长会有「两层同时在」的重影感。
    private let crossFade: Double = 0.28

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.baseLayer.videoGravity = videoGravity
        view.hdLayer.videoGravity = videoGravity
        view.baseLayer.player = player
        context.coordinator.prepare(base: player, view: view, crossFade: crossFade)
        return view
    }

    func updateUIView(_ view: PlayerSurfaceView, context: Context) {
        view.baseLayer.videoGravity = videoGravity
        view.hdLayer.videoGravity = videoGravity
        context.coordinator.update(base: player,
                                   hd: hdPlayer,
                                   view: view,
                                   isMuted: isMuted,
                                   isPaused: isPaused)
    }

    /// 必须是 static：写实例方法不报错，但 SwiftUI 永远不调它
    static func dismantleUIView(_ view: PlayerSurfaceView, coordinator: Coordinator) {
        coordinator.teardown()
        view.baseLayer.player = nil
        view.hideHD()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(loops: loops,
                    onReady: onReady,
                    onProgress: onProgress,
                    onFinished: onFinished,
                    onHandover: onHandover)
    }

    final class Coordinator {

        /// 只观察，不拥有。player 生命周期归 `VideoWarmPool` / `VideoQualityUpgrader`。
        private weak var base: AVPlayer?
        private weak var hd: AVPlayer?
        /// 事件源：交接前是 base，交接后是 hd。若一直盯着已停播的 base，
        /// 就收不到 `.AVPlayerItemDidPlayToEndTime`，轮播会卡死在这一页。
        private weak var active: AVPlayer?

        private weak var view: PlayerSurfaceView?
        private var handedOver = false
        private var crossFade: Double = 0.28
        /// 最近一次上层给的暂停态。淡化分两步走，中间用户可能点了暂停，
        /// 交接时要按这个值决定高清那层该不该继续播。
        private var isPaused = false

        private let loops: Bool
        private let onReady: (() -> Void)?
        private let onProgress: ((Double) -> Void)?
        private let onFinished: (() -> Void)?
        private let onHandover: ((AVPlayer) -> Void)?

        private var itemObservation: NSKeyValueObservation?
        private var statusObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        private var timeObserver: Any?
        private var timeObserverOwner: AVPlayer?
        private var didReportReady = false

        init(loops: Bool,
             onReady: (() -> Void)?,
             onProgress: ((Double) -> Void)?,
             onFinished: (() -> Void)?,
             onHandover: ((AVPlayer) -> Void)?) {
            self.loops = loops
            self.onReady = onReady
            self.onProgress = onProgress
            self.onFinished = onFinished
            self.onHandover = onHandover
        }

        // MARK: - 生命周期

        func prepare(base: AVPlayer, view: PlayerSurfaceView, crossFade: Double) {
            self.view = view
            self.crossFade = crossFade
            self.base = base
            self.active = base
            configure(base)
            watchCurrentItem(of: base)
            installTimeObserver(on: base)
        }

        func update(base: AVPlayer, hd: AVPlayer?, view: PlayerSurfaceView,
                    isMuted: Bool, isPaused: Bool) {
            self.view = view

            // 换了一页 / 换了一个 player：全部重来
            if self.base !== base {
                resetObservers()
                self.base = base
                self.active = base
                self.hd = nil
                handedOver = false
                didReportReady = false
                view.hideHD()
                view.baseLayer.player = base
                configure(base)
                watchCurrentItem(of: base)
                installTimeObserver(on: base)
            }

            // 记下来：淡化是异步分两步做的（写完这帧之后才真正开始淡），
            // 中途用户可能已经点了暂停，那时候不能把高清那层播起来。
            self.isPaused = isPaused

            if let hd, self.hd !== hd {
                beginCrossFade(hd, isMuted: isMuted)
            } else if hd == nil, self.hd != nil, !handedOver {
                self.hd = nil
                view.hideHD()
            }

            // 播放 / 暂停 / 静音作用在「真正在屏幕上的那一层」。
            // 但淡化期间两层都得播，否则淡出来的是一张静止画面。
            let target = handedOver ? (self.hd ?? base) : base
            target.isMuted = isMuted
            target.allowsExternalPlayback = false
            target.usesExternalPlaybackWhileExternalScreenIsActive = false

            if isPaused {
                target.pause()
                if !handedOver { hd?.pause() }
            } else {
                target.play()
                if !handedOver { hd?.play() }
            }
        }

        func teardown() {
            // `VideoQualityUpgrader` 是 @MainActor、这个 Coordinator 不是，直接调会跨隔离；
            // dismantleUIView 本就在主线程，投一次主队列即可。
            if let base {
                DispatchQueue.main.async {
                    VideoQualityUpgrader.shared.cancel(for: base)
                }
            }
            resetObservers()
            base?.pause()
            hd?.pause()
            view?.hideHD()
        }

        // MARK: - 交叉淡化

        private func beginCrossFade(_ hd: AVPlayer, isMuted: Bool) {
            self.hd = hd
            configure(hd)
            // 淡化期间音频归低清，避免两份同样的声音叠成回声
            hd.isMuted = true
            // 暂停态要同步，否则淡完看到「暂停中画面却在动」
            if isPaused { hd.pause() } else { hd.play() }

            guard let view else { return }
            view.hdLayer.videoGravity = view.baseLayer.videoGravity
            view.hdLayer.player = hd
            view.revealHD(duration: crossFade)
            Log.media.debug("hd layer fading in")

            DispatchQueue.main.asyncAfter(deadline: .now() + crossFade + 0.02) { [weak self] in
                guard let self, !self.handedOver, self.hd === hd else { return }
                self.handedOver = true
                // 低清下场：停播即放掉解码器（layer 还在下面，但已是静态最后一帧）
                self.base?.pause()
                hd.isMuted = isMuted
                if self.isPaused { hd.pause() } else { hd.play() }
                // 事件源改到高清：进度与播完通知都从这里来
                self.active = hd
                self.watchCurrentItem(of: hd)
                self.installTimeObserver(on: hd)
                self.onHandover?(hd)
                Log.media.debug("hd layer handed over")
            }
        }

        // MARK: - 观察

        private func configure(_ player: AVPlayer) {
            player.actionAtItemEnd = loops ? .none : .pause
            player.allowsExternalPlayback = false
            player.usesExternalPlaybackWhileExternalScreenIsActive = false
        }

        /// 观察的是 **`player.currentItem`**，不是某个固定的 item。
        private func watchCurrentItem(of player: AVPlayer) {
            itemObservation?.invalidate()
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] observed, _ in
                guard let self else { return }
                self.bind(item: observed.currentItem)
            }
        }

        /// 只重绑 item 相关的 status KVO 与播完通知。
        /// 故意不重置 `didReportReady`：换档不是「新的一页」，
        /// 重置会让上层把进度归零、再跑一次 `onReady`。
        private func bind(item: AVPlayerItem?) {
            statusObservation?.invalidate()
            statusObservation = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil

            guard let item else { return }

            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                guard let self else { return }
                switch observed.status {
                case .readyToPlay:
                    guard !self.didReportReady else { return }
                    self.didReportReady = true
                    // 必须推迟到下一个 runloop：预热过的 player 在 makeUIView 里就已
                    // .readyToPlay，KVO 的 .initial 会同步触发 —— 那一刻还在 SwiftUI
                    // 视图更新中，直接改上层 @State 会报「Modifying state during view update」。
                    DispatchQueue.main.async {
                        self.onProgress?(0)
                        self.onReady?()
                    }
                case .failed:
                    Log.media.error("video item failed: \(observed.error?.localizedDescription ?? "unknown", privacy: .public)")
                default:
                    break
                }
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                guard let player = self.active else { return }
                if self.loops {
                    player.seek(to: .zero)
                    player.play()
                } else {
                    Log.media.debug("video finished")
                    self.onProgress?(1)
                    self.onFinished?()
                }
            }
        }

        /// 每 0.2 秒报一次真实播放位置。只有视频会用到这个值。
        private func installTimeObserver(on player: AVPlayer) {
            removeTimeObserver()
            let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                guard let item = self.active?.currentItem else { return }
                let total = item.duration.seconds
                guard total.isFinite, total > 0 else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.onProgress?(min(max(seconds / total, 0), 1))
            }
            timeObserverOwner = player
        }

        private func removeTimeObserver() {
            if let timeObserver, let timeObserverOwner {
                timeObserverOwner.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
            timeObserverOwner = nil
        }

        private func resetObservers() {
            itemObservation?.invalidate()
            itemObservation = nil
            statusObservation?.invalidate()
            statusObservation = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            removeTimeObserver()
        }

        deinit {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            statusObservation?.invalidate()
            itemObservation?.invalidate()
            if let timeObserver, let timeObserverOwner {
                timeObserverOwner.removeTimeObserver(timeObserver)
            }
        }
    }
}
