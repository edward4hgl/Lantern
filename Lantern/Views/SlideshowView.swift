import SwiftUI
import Photos
import AVFoundation
import UIKit

/// 全屏轮播。
///
/// 计时与加载分离：后面 6 张由 `PreloadPipeline` 真正解码进内存、视频由 `VideoWarmPool`
/// 预热好，翻页时同步取出；且只有 `readyGeneration == deck.generation`（这一页真的画上屏了）
/// 计时任务才会启动 —— 所以停留时间不含加载时间。永远不就绪的页有 watchdog 兜底跳过。
struct SlideshowView: View {

    let album: AlbumRef
    @ObservedObject var library: PhotoLibraryService

    @EnvironmentObject private var settings: SlideshowSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var deck: SlideDeck
    @State private var showChrome = true
    @State private var showSettings = false
    @State private var chromeHideTask: Task<Void, Never>?

    /// 已经真正上屏的那一页属于哪个 generation
    @State private var readyGeneration: Int = -1
    @State private var videoFraction: Double = 0
    /// 当前视频的 player，进度条拖动要直接对它 seek
    @State private var videoPlayer: AVPlayer?
    /// 用户正按着进度条 —— 这期间别让 periodic observer 把拇指拽回去
    @State private var isScrubbing = false
    /// 本页开始时算好的「第几张 / 共几张」。相簿后台进新照片会改 count，
    /// 实时读就会在播放中途跳数字。
    @State private var positionSnapshot: String = ""
    /// 本页拍摄地，缓存命中同步给，没命中异步补一次
    @State private var placeText: String?

    private let preloadWindow = 6

    init(album: AlbumRef, library: PhotoLibraryService) {
        self.album = album
        self.library = library
        _deck = StateObject(wrappedValue: SlideDeck(library: library))
    }

    private var pageReady: Bool { readyGeneration == deck.generation }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if deck.isEmpty {
                emptyState
            } else if let current = deck.current {
                SlideContent(
                    item: current,
                    generation: deck.generation,
                    zoomIn: deck.index % 2 == 0,
                    isPaused: deck.isPaused,
                    onReady: { stamp in
                        // 只认当前这一代，上一页的迟到回调丢掉
                        guard stamp == deck.generation else { return }
                        readyGeneration = stamp
                    },
                    onVideoProgress: { stamp, fraction in
                        guard stamp == deck.generation, !isScrubbing else { return }
                        videoFraction = fraction
                    },
                    onVideoPlayer: { stamp, player in
                        guard stamp == deck.generation else { return }
                        videoPlayer = player
                    },
                    onVideoFinished: { goNext() },
                    onLivePhotoFinished: { handleLivePhotoEnded() }
                )
                .id(deck.generation)
                .transition(transitionSpec)
            }

            if settings.dimLevel > 0.001 {
                Color.black
                    .opacity(settings.dimLevel)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // 拍摄日期 + 地点 + 日期计算：常显，不跟控制条一起收。
            // 放左下角 —— 进度条横跨整幅，这里是唯一压不到的位置。
            if !deck.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Spacer()
                    if settings.showCaptureDate {
                        DateBadge(date: deck.current?.creationDate,
                                  place: settings.showPlace ? placeText : nil)
                    }
                    if settings.showAgeLabel {
                        AgeBadge(text: ageLabelText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 30)
                .padding(.bottom, 42)
                .transition(.opacity)
            }

            if showChrome, !deck.isEmpty {
                ChromeOverlay(showClock: settings.showClock)
                    .transition(.opacity)

                topBar
                    .transition(.opacity)

                bottomControls
                    .transition(.opacity)
            }

            if deck.isPaused, !deck.isEmpty {
                pausedBadge
            }
        }
        .animation(transitionAnimation, value: deck.generation)
        .animation(.easeInOut(duration: 0.25), value: showChrome)
        .statusBarHidden(!showChrome)
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .contentShape(Rectangle())
        .gesture(swipeGesture)
        .onTapGesture(count: 2) { deck.togglePause() }
        .onTapGesture { toggleChrome() }
        .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 30) {
            deck.isPaused = true
        } onPressingChanged: { pressing in
            if !pressing { deck.isPaused = false }
        }
        .task { await initialLoad() }
        .task(id: clockKey) { await runClock() }
        .task(id: deck.generation) { await runWatchdog() }
        .task(id: library.revision) { await handleLibraryChange() }
        .onChange(of: deck.generation) { _ in
            videoFraction = 0
            videoPlayer = nil
            isScrubbing = false
            snapshotPageContext()
            preloadAhead()
            settings.saveIndex(deck.index, forAlbum: album.id)
        }
        .onChange(of: scenePhase) { phase in
            // 回前台时 iCloud 可能换了内容，重取一次
            if phase == .active {
                Task { await handleLibraryChange() }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // 实况照片要出声必须先把音频会话抬到 .playback，默认的 .ambient 守静音键
            AudioSession.prepareForPlayback()
            settings.lastAlbumID = album.id
            scheduleChromeHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            chromeHideTask?.cancel()
            PreloadPipeline.shared.cancelAll()
            VideoWarmPool.shared.cancelAll()
            VideoQualityUpgrader.shared.cancelAll()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(settings)
        }
    }

    // MARK: - 顶部条（返回 + 相簿信息）

    /// 左上角固定是返回按钮，不是投屏 —— 视频走裸 `AVPlayerLayer` 且关了外部播放，
    /// 系统连 AirPlay 入口都没有。这里只显示位置与类型，视频时间在进度条两端。
    private var topBar: some View {
        VStack {
            HStack(alignment: .center, spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回相簿列表")

                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(positionSnapshot.isEmpty ? deck.positionLabel : positionSnapshot)
                            .monospacedDigit()
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                        if let kind = deck.current?.kindLabel, !kind.isEmpty {
                            Text("·")
                            Text(kind)
                        }
                        if deck.isPaused {
                            Text("·")
                            Text("已暂停")
                                .foregroundStyle(.yellow.opacity(0.9))
                        }
                    }
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                }
                // 时钟 84pt，给它留位置免得压住相簿名
                .padding(.trailing, settings.showClock ? 240 : 0)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)

            Spacer()
        }
    }

    // MARK: - 底部：进度条 + 控制条

    private var bottomControls: some View {
        VStack(spacing: 10) {
            Spacer()

            if let value = videoProgressValue {
                VideoScrubber(
                    fraction: value,
                    duration: deck.current?.duration ?? 0,
                    onScrub: { fraction in
                        isScrubbing = true
                        videoFraction = fraction
                        seekVideo(to: fraction)
                    },
                    onCommit: { fraction in
                        seekVideo(to: fraction)
                        isScrubbing = false
                    }
                )
                .padding(.horizontal, 30)
                .transition(.opacity)
            }

            controlBar
        }
        .padding(.bottom, 40)
    }

    private var controlBar: some View {
        HStack(spacing: 4) {
            controlButton("backward.end.fill", label: "上一张") { back() }

            controlButton(deck.isPaused ? "play.fill" : "pause.fill",
                          label: deck.isPaused ? "继续" : "暂停") {
                deck.togglePause()
                scheduleChromeHide()
            }

            controlButton("forward.end.fill", label: "下一张") { goNext() }

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 28)
                .padding(.horizontal, 10)

            controlButton("slider.horizontal.3", label: "播放设置") { showSettings = true }

            controlButton("xmark", label: "退出轮播") { dismiss() }
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
    }

    /// 图标 23pt、触摸区 52×52（远超 44pt 下限），站着也点得准
    private func controlButton(_ symbol: String,
                               label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .medium))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var pausedBadge: some View {
        VStack {
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "pause.fill")
                Text("已暂停")
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.black.opacity(0.78))
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.88), in: Capsule())
            .padding(.bottom, 158)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 18) {
            if deck.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.8))
                    .controlSize(.large)
                Text("正在读相簿…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.35))
                Text(deck.errorText ?? "这个相簿是空的")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                Text("相簿：\(album.title)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                Button("返回选相簿") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.15))
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - 过渡

    /// 「随机」按 generation 解析成确定值，同一张停留期间不会自己变脸
    private var resolvedTransition: TransitionStyle {
        settings.transition.resolved(seed: deck.generation)
    }

    private var transitionAnimation: Animation? {
        let style = resolvedTransition
        guard style != .cut else { return nil }
        switch style {
        case .push:
            // 先快后缓，像翻杂志
            return .timingCurve(0.28, 0.72, 0.12, 1.0, duration: style.duration)
        default:
            return .easeInOut(duration: style.duration)
        }
    }

    private var transitionSpec: AnyTransition {
        switch resolvedTransition {
        case .slide:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .push:
            // 不带透明度：整幅像纸被推进推出，边缘不闪
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case .flip:
            return .asymmetric(
                insertion: .modifier(
                    active: FlipEffect(angle: 88, anchor: .leading, opacity: 0),
                    identity: FlipEffect(angle: 0, anchor: .leading, opacity: 1)
                ),
                removal: .modifier(
                    active: FlipEffect(angle: -88, anchor: .leading, opacity: 0),
                    identity: FlipEffect(angle: 0, anchor: .leading, opacity: 1)
                )
            )
        case .zoomFade:
            return .asymmetric(
                insertion: .scale(scale: 1.12).combined(with: .opacity),
                removal: .opacity
            )
        case .cut:
            return .identity
        default:
            return .opacity
        }
    }

    // MARK: - 手势

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -50 {
                    goNext()
                } else if value.translation.width > 50 {
                    back()
                }
            }
    }

    // MARK: - 本页上下文（位置读数 / 地点 / 日期计算）

    /// 本页开始时算一次，显示期间不动：冻结位置读数、地点先取缓存再异步反查。
    /// 反查回来要校验 generation，别把上一页的地名贴到这一页。
    private func snapshotPageContext() {
        positionSnapshot = deck.positionLabel

        guard let current = deck.current,
              let lat = current.latitude,
              let lon = current.longitude else {
            placeText = nil
            return
        }

        placeText = LocationNamer.shared.cachedPlace(latitude: lat, longitude: lon)

        let stamp = deck.generation
        Task { @MainActor in
            let resolved = await LocationNamer.shared.place(latitude: lat, longitude: lon)
            guard stamp == deck.generation else { return }
            placeText = resolved
        }
    }

    /// 「宝宝 2岁3个月」这类字句。没填日期就没有这一行。
    private var ageLabelText: String? {
        AgeLabel.text(birthday: settings.subjectBirthday,
                      at: deck.current?.creationDate,
                      name: settings.subjectName,
                      template: settings.ageTemplate)
    }

    // MARK: - 视频进度

    private var videoProgressValue: Double? {
        guard settings.showProgress,
              pageReady,
              deck.current?.isVideo == true else { return nil }
        return videoFraction
    }

    /// 拖动进度条直接对 player 跳转。容差 0.1 秒：够准，又不用等关键帧精确定位。
    private func seekVideo(to fraction: Double) {
        guard let player = videoPlayer,
              let current = deck.current,
              current.duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        let target = CMTime(seconds: clamped * current.duration, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    // MARK: - 节奏

    /// key 里带 `pageReady`：没就绪计时任务根本不启动，一秒都不扣；
    /// 也带照片 / 视频两个停留值，改任一个都让当前页重新起算。
    private var clockKey: String {
        "\(deck.generation)#\(Int(settings.photoInterval))#\(Int(settings.videoInterval))"
            + "#\(deck.isPaused)#\(deck.count)#\(pageReady ? 1 : 0)"
    }

    private func runClock() async {
        guard pageReady, !deck.isPaused, let current = deck.current else { return }

        let seconds: Double
        if let hold = settings.holdSeconds(for: current) {
            seconds = hold
        } else {
            // 视频「播完为止」：正常由 onFinished 推进，这里只是兜底，留足余量，
            // 否则会和 onFinished 抢着翻页、一次跳两页
            seconds = max(current.duration + 8, 12)
        }

        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return   // 被取消（翻页 / 改设置 / 暂停 / 离开）
        }
        guard !Task.isCancelled, !deck.isPaused else { return }
        goNext()
    }

    /// 兜底：这一页永远不就绪（iCloud 卡死 / 素材损坏）时到点往前走，墙上不会永远转圈
    private func runWatchdog() async {
        let limit = Double(max(settings.photoInterval, settings.videoInterval, 3)) + 15
        do {
            try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
        } catch {
            return
        }
        guard !Task.isCancelled, !pageReady, !deck.isPaused else { return }
        Log.playback.error("page \(self.deck.index, privacy: .public) never became ready, skipping")
        goNext()
    }

    private func goNext() {
        deck.advance()
        scheduleChromeHide()
    }

    private func back() {
        deck.back()
        scheduleChromeHide()
    }

    private func handleLivePhotoEnded() {
        // 实况播完给一点余韵再走
        guard !deck.isPaused else { return }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, !deck.isPaused else { return }
            goNext()
        }
    }

    // MARK: - 载入

    private func initialLoad() async {
        if !library.isAuthorized {
            _ = await library.requestAccess()
        }
        let resume: Int? = settings.resumeLastPosition ? settings.savedIndex(forAlbum: album.id) : nil
        await deck.load(
            album: album,
            order: settings.order,
            skipVideos: settings.skipVideos,
            resumeIndex: resume
        )
        snapshotPageContext()
        preloadAhead()
    }

    private func handleLibraryChange() async {
        guard !deck.isEmpty else { return }
        await deck.refreshPreservingCurrent(order: settings.order, skipVideos: settings.skipVideos)
        preloadAhead()
    }

    /// 预热「当前页之后」的窗口。视频多走一遍 `VideoWarmPool`：它要 preroll，不能只拿 playerItem。
    private func preloadAhead() {
        let upcoming = Array(deck.nextItems.prefix(preloadWindow))
        guard !upcoming.isEmpty else { return }
        PreloadPipeline.shared.preload(
            upcoming,
            // 逐张求填充模式：四类素材各一套设置，而缓存 key 里带 contentMode
            mode: { settings.fitMode(for: $0) == .fill ? .aspectFill : .aspectFit },
            playLivePhotos: settings.playLivePhotos
        )
        VideoWarmPool.shared.warmUpcoming(upcoming)
    }

    // MARK: - Chrome 自动隐藏

    private func toggleChrome() {
        showChrome.toggle()
        if showChrome { scheduleChromeHide() }
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        guard showChrome else { return }
        chromeHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { showChrome = false }
            }
        }
    }
}
