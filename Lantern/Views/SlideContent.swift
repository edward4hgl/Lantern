import SwiftUI
import Photos
import AVFoundation
import UIKit

/// 一页的渲染：普通图 / 实况照片 / 视频，一套外观。
///
/// 两条硬要求：上来先查缓存，命中就同步上屏（翻页路径上不该有网络请求）；
/// 真正画上屏的那一刻才回调 `onReady`，所以加载时间不计入停留时间。
struct SlideContent: View {

    let item: SlideItem
    /// 这一页属于哪一代，回调带回去让上层丢弃上一页的迟到回调
    let generation: Int
    /// 偶数页推近、奇数页拉远
    let zoomIn: Bool
    let isPaused: Bool

    let onReady: (Int) -> Void
    let onVideoProgress: (Int, Double) -> Void
    /// 视频的 player 交给上层 —— 进度条拖动要直接对它 seek
    let onVideoPlayer: (Int, AVPlayer?) -> Void
    let onVideoFinished: () -> Void
    let onLivePhotoFinished: () -> Void

    @EnvironmentObject private var settings: SlideshowSettings

    @State private var stillImage: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    /// 「先糊后清」的高清层，由 `VideoQualityUpgrader` 交接过来
    @State private var hdPlayer: AVPlayer?
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let player {
                    PlayerLayerContainer(
                        player: player,
                        hdPlayer: hdPlayer,
                        isMuted: !settings.videoAudio,
                        isPaused: isPaused,
                        loops: false,
                        videoGravity: fit == .fill ? .resizeAspectFill : .resizeAspect,
                        onReady: { [generation] in onReady(generation) },
                        onProgress: { [generation] fraction in onVideoProgress(generation, fraction) },
                        onFinished: onVideoFinished,
                        // 交接后进度条拖动 / 暂停要打到新的 player 上
                        onHandover: { [generation] hd in onVideoPlayer(generation, hd) }
                    )
                    .ignoresSafeArea()
                } else if let livePhoto, settings.playLivePhotos {
                    LivePhotoContainer(
                        livePhoto: livePhoto,
                        contentMode: fit == .fill ? .scaleAspectFill : .scaleAspectFit,
                        isMuted: !settings.videoAudio,
                        autoplay: true,
                        onPlaybackEnded: onLivePhotoFinished
                    )
                    .ignoresSafeArea()
                    .onAppear { onReady(generation) }
                } else if let stillImage {
                    stillLayer(stillImage, size: geo.size)
                } else if loadFailed {
                    failureView
                } else {
                    loadingView
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .task(id: item.id) {
            await load()
        }
    }

    // MARK: - 填充方式

    private var fit: FitMode { settings.fitMode(for: item) }

    /// 铺满用 aspectFill、完整显示用 aspectFit；缓存 key 里带这个值，用错等于白预热
    private var imageContentMode: PHImageContentMode {
        fit == .fill ? .aspectFill : .aspectFit
    }

    private var swiftUIContentMode: ContentMode {
        fit == .fill ? .fill : .fit
    }

    // MARK: - 静帧

    @ViewBuilder
    private func stillLayer(_ image: UIImage, size: CGSize) -> some View {
        ZStack {
            if fit == .fit {
                // 完整显示时用同一张图铺满并重度模糊，替代黑边
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 40, opaque: true)
                    .overlay(Color.black.opacity(0.35))
                    .clipped()
            }

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: swiftUIContentMode)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .center)
                .clipped()
        }
        .onAppear {
            startKenBurns()
            onReady(generation)
        }
    }

    private func startKenBurns() {
        // 「随机」也可能抽到推近，所以先解析成具体效果再判断
        let style = settings.transition.resolved(seed: generation)
        guard style == .kenBurns, settings.kenBurnsZoom > 0.001 else {
            scale = 1.0
            return
        }
        let target = zoomIn ? 1.0 + settings.kenBurnsZoom : 1.0
        if zoomIn {
            scale = 1.0
            withAnimation(.easeInOut(duration: max(3.0, settings.photoInterval + 1.0))) {
                scale = target
            }
        } else {
            scale = 1.0 + settings.kenBurnsZoom
            withAnimation(.easeInOut(duration: max(3.0, settings.photoInterval + 1.0))) {
                scale = 1.0
            }
        }
    }

    // MARK: - 占位

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.8))
                .controlSize(.large)

            VStack(spacing: 5) {
                Text("正在获取下一张")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                Text(item.kindLabel)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }

    private var failureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text("这张取不到")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        }
        .onAppear { onReady(generation) }
    }

    // MARK: - 载入（缓存优先）

    private func load() async {
        loadFailed = false
        stillImage = nil
        livePhoto = nil
        player = nil
        hdPlayer = nil
        onVideoPlayer(generation, nil)

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
            loadFailed = true
            Log.media.error("asset vanished: \(item.shortID, privacy: .public)")
            return
        }

        let pixelSize = DisplayMetrics.pixelSize
        let contentMode = imageContentMode
        let pipeline = PreloadPipeline.shared

        // 视频：落盘缓存 → 预热池 → 现场请求
        if item.isVideo {
            // 升过清晰的视频已经存成本地文件，直接本地播，无网络、无低清阶段
            if let fileURL = HDVideoCache.shared.existingURL(for: asset) {
                let local = AVPlayerItem(url: fileURL)
                local.preferredForwardBufferDuration = 0.5
                let fresh = AVPlayer(playerItem: local)
                fresh.automaticallyWaitsToMinimizeStalling = false
                fresh.allowsExternalPlayback = false
                fresh.usesExternalPlaybackWhileExternalScreenIsActive = false
                player = fresh
                onVideoPlayer(generation, fresh)
                Log.media.debug("hd cache hit \(item.shortID, privacy: .public)")
                return
            }

            if let warm = VideoWarmPool.shared.player(for: item.id) {
                // 预热过的 player 可能停在上一轮播完的位置，回头再看要倒回开头。
                // seek 在 async 上下文里会被解析成返回 Bool 的异步重载，必须 await。
                let position = warm.currentTime().seconds
                if position.isFinite, position > 0.25 {
                    _ = await warm.seek(to: .zero)
                }
                player = warm
                onVideoPlayer(generation, warm)
                scheduleHDUpgrade(for: warm)
                return                    // onReady 由 KVO status == .readyToPlay 触发
            }

            if let ready = await MediaLoader.shared.playerItem(for: asset) {
                ready.preferredForwardBufferDuration = 0.5
                let fresh = AVPlayer(playerItem: ready)
                fresh.automaticallyWaitsToMinimizeStalling = false
                fresh.allowsExternalPlayback = false
                fresh.usesExternalPlaybackWhileExternalScreenIsActive = false
                player = fresh
                onVideoPlayer(generation, fresh)
                scheduleHDUpgrade(for: fresh)
            } else {
                loadFailed = true
            }
            return
        }

        // 实况照片：预热命中就同步上屏
        if item.isLivePhoto, settings.playLivePhotos {
            if let cached = pipeline.cachedLivePhoto(for: item.id) {
                livePhoto = cached
                return                    // onReady 由容器 onAppear 触发
            }
            if let live = await MediaLoader.shared.livePhoto(for: asset, targetSize: pixelSize) {
                livePhoto = live
                return
            }
            // 取不到实况就退化成静帧
            Log.media.info("live photo unavailable, falling back to still")
        }

        if let cached = ImageLoader.shared.cachedImage(for: item.id,
                                                       targetSize: pixelSize,
                                                       contentMode: contentMode) {
            stillImage = cached
            return                        // onReady 由 stillLayer.onAppear 触发
        }

        if let image = await ImageLoader.shared.image(
            for: asset,
            targetSize: pixelSize,
            contentMode: contentMode
        ) {
            stillImage = image
        } else {
            loadFailed = true
        }
    }

    /// 后台要一份 `.highQualityFormat`，缓冲盖住播放头后交给容器做交叉淡化。
    /// 低清那份一秒都不停，所以看不到换档卡顿。
    private func scheduleHDUpgrade(for player: AVPlayer) {
        guard settings.videoHDUpgrade else { return }
        VideoQualityUpgrader.shared.schedule(for: player, assetID: item.id) { hd in
            hdPlayer = hd
            // 淡入之后再落盘：不跟播放抢带宽，存下来的也一定是用户真看过的那一段
            storeHDToDisk()
        }
    }

    private func storeHDToDisk() {
        guard settings.videoHDUpgrade, settings.videoDiskCache else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
            return
        }
        HDVideoCache.shared.store(asset)
    }
}
