import Foundation
import SwiftUI

// MARK: - 枚举

enum SlideOrder: String, CaseIterable, Identifiable, Codable {
    case oldestFirst
    case newestFirst
    case recentFirstShuffled
    case shuffle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oldestFirst: return "最早在前"
        case .newestFirst: return "最新在前"
        case .recentFirstShuffled: return "最新的先随机"
        case .shuffle: return "全部随机"
        }
    }

    var hint: String {
        switch self {
        case .oldestFirst: return "像翻相册，从头看起"
        case .newestFirst: return "先看刚拍的"
        case .recentFirstShuffled: return "先放最近 50 张，再随机"
        case .shuffle: return "每次都不一样"
        }
    }
}

enum FitMode: String, CaseIterable, Identifiable, Codable {
    case fill
    case fit

    var id: String { rawValue }
    var label: String { self == .fill ? "铺满屏幕" : "完整显示" }
}

/// 四类素材各自记「铺满 / 完整显示」：竖照片铺满会裁掉脸，横视频铺满几乎没损失。
enum FitTarget: String, CaseIterable, Identifiable, Codable {
    case photoPortrait
    case photoLandscape
    case videoPortrait
    case videoLandscape

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photoPortrait: return "竖屏照片"
        case .photoLandscape: return "横屏照片"
        case .videoPortrait: return "竖屏视频"
        case .videoLandscape: return "横屏视频"
        }
    }
}

enum TransitionStyle: String, CaseIterable, Identifiable, Codable {
    case kenBurns
    case crossFade
    case slide
    case push
    case flip
    case zoomFade
    case cut
    case random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kenBurns: return "缓慢推近"
        case .crossFade: return "淡入淡出"
        case .slide: return "横向滑动"
        case .push: return "翻页推挤"
        case .flip: return "立体翻页"
        case .zoomFade: return "缩放淡入"
        case .cut: return "直接切换"
        case .random: return "随机（每张不一样）"
        }
    }

    var duration: Double {
        switch self {
        case .kenBurns: return 0.9
        case .crossFade: return 0.75
        case .slide: return 0.55
        case .push: return 0.6
        case .flip: return 0.65
        case .zoomFade: return 0.7
        case .cut: return 0.0
        case .random: return 0.65
        }
    }

    /// 「随机」实际从这几种里挑 —— 排除它自己和 `.cut`（0 时长，混在随机里显得卡顿）。
    static let randomPool: [TransitionStyle] = [
        .kenBurns, .crossFade, .slide, .push, .flip, .zoomFade
    ]

    /// 把 `.random` 落成具体某一种。用 generation 当种子：
    /// 同一页永远解析成同一种效果，不会因为重绘而中途变卦。
    func resolved(seed: Int) -> TransitionStyle {
        guard self == .random else { return self }
        let pool = Self.randomPool
        guard !pool.isEmpty else { return .crossFade }
        let index = abs(seed &* 2654435761) % pool.count
        return pool[index]
    }
}

// MARK: - 设置

/// 偏好全部落 UserDefaults。用 @Published + didSet 手动回写，
/// 因为 @AppStorage 只在 View 里发通知，放进 ObservableObject 改了界面不刷新。
@MainActor
final class SlideshowSettings: ObservableObject {

    private enum Key {
        /// 旧版的「每张停留」，现在只用于一次性迁移
        static let interval = "lantern.interval"
        static let photoInterval = "lantern.photoInterval"
        static let videoInterval = "lantern.videoInterval"
        static let order = "lantern.order"
        static let fit = "lantern.fit"
        static let fitPhotoPortrait = "lantern.fit.photoPortrait"
        static let fitPhotoLandscape = "lantern.fit.photoLandscape"
        static let fitVideoPortrait = "lantern.fit.videoPortrait"
        static let fitVideoLandscape = "lantern.fit.videoLandscape"
        static let transition = "lantern.transition"
        static let showClock = "lantern.showClock"
        static let showProgress = "lantern.showProgress"
        static let showCaptureDate = "lantern.showCaptureDate"
        static let showPlace = "lantern.showPlace"
        static let showAgeLabel = "lantern.showAgeLabel"
        static let subjectName = "lantern.subjectName"
        static let subjectBirthday = "lantern.subjectBirthday"
        static let ageTemplate = "lantern.ageTemplate"
        static let playLivePhotos = "lantern.playLivePhotos"
        static let videoAudio = "lantern.videoAudio"
        static let dimLevel = "lantern.dimLevel"
        static let kenBurnsZoom = "lantern.kenBurnsZoom"
        static let skipVideos = "lantern.skipVideos"
        static let videoHDUpgrade = "lantern.videoHDUpgrade"
        /// 必须与 `HDVideoCache.defaultsKey` 保持同一个字符串。
        /// 这里不直接引用那个常量 —— `HDVideoCache` 是 `@MainActor`，
        /// 从这个 static 初始化里读会被判成跨隔离访问。
        static let videoDiskCache = "lantern.videoDiskCache"
        static let resumeLastPosition = "lantern.resumeLastPosition"
        static let lastAlbumID = "lantern.lastAlbumID"
        static let lastIndexPrefix = "lantern.lastIndex."
    }

    private let defaults: UserDefaults

    /// 照片（含实况照片的静帧）停留秒数。
    @Published var photoInterval: Double {
        didSet { defaults.set(photoInterval, forKey: Key.photoInterval) }
    }
    /// 视频停留秒数。**0 = 播完为止**，设了值也会被视频自身时长封顶。
    @Published var videoInterval: Double {
        didSet { defaults.set(videoInterval, forKey: Key.videoInterval) }
    }

    /// 这一页实际停留秒数。返回 `nil` 表示交给播放结束回调推进，
    /// 调用方只需挂个远大于时长的兜底计时器，否则会和 `onFinished` 抢着翻页。
    func holdSeconds(for item: SlideItem) -> Double? {
        if item.isVideo {
            let duration = max(item.duration, 0.5)
            guard videoInterval > 0.5 else { return nil }
            guard videoInterval < duration - 0.4 else { return nil }
            return videoInterval
        }
        return max(photoInterval, 1)
    }
    @Published var order: SlideOrder {
        didSet { defaults.set(order.rawValue, forKey: Key.order) }
    }

    /// 四类素材各自的填充方式。
    @Published var fitForPhotoPortrait: FitMode {
        didSet { defaults.set(fitForPhotoPortrait.rawValue, forKey: Key.fitPhotoPortrait) }
    }
    @Published var fitForPhotoLandscape: FitMode {
        didSet { defaults.set(fitForPhotoLandscape.rawValue, forKey: Key.fitPhotoLandscape) }
    }
    @Published var fitForVideoPortrait: FitMode {
        didSet { defaults.set(fitForVideoPortrait.rawValue, forKey: Key.fitVideoPortrait) }
    }
    @Published var fitForVideoLandscape: FitMode {
        didSet { defaults.set(fitForVideoLandscape.rawValue, forKey: Key.fitVideoLandscape) }
    }
    @Published var transition: TransitionStyle {
        didSet { defaults.set(transition.rawValue, forKey: Key.transition) }
    }
    @Published var showClock: Bool {
        didSet { defaults.set(showClock, forKey: Key.showClock) }
    }
    @Published var showProgress: Bool {
        didSet { defaults.set(showProgress, forKey: Key.showProgress) }
    }
    /// 左下角的拍摄日期水印。常显，不随控制条一起收。
    @Published var showCaptureDate: Bool {
        didSet { defaults.set(showCaptureDate, forKey: Key.showCaptureDate) }
    }
    /// 日期后面跟不跟「📍广州」。没定位信息的照片自然不会显示。
    @Published var showPlace: Bool {
        didSet { defaults.set(showPlace, forKey: Key.showPlace) }
    }
    /// 日期下方那句「宝宝 2岁3个月」。
    @Published var showAgeLabel: Bool {
        didSet { defaults.set(showAgeLabel, forKey: Key.showAgeLabel) }
    }
    /// 称呼，套进模板的 `{name}`。
    @Published var subjectName: String {
        didSet { defaults.set(subjectName, forKey: Key.subjectName) }
    }
    /// 生日。nil = 没设，日期计算不生效 —— 用 nil 而不是「1970 年的某个哨兵值」，
    /// 因为下次读出来时能一眼看出「用户根本没填」。
    @Published var subjectBirthday: Date? {
        didSet {
            if let subjectBirthday {
                defaults.set(subjectBirthday.timeIntervalSince1970, forKey: Key.subjectBirthday)
            } else {
                defaults.removeObject(forKey: Key.subjectBirthday)
            }
        }
    }
    /// 模板，支持 `{name}` 与 `{age}` 两个占位符。
    @Published var ageTemplate: String {
        didSet { defaults.set(ageTemplate, forKey: Key.ageTemplate) }
    }
    @Published var playLivePhotos: Bool {
        didSet { defaults.set(playLivePhotos, forKey: Key.playLivePhotos) }
    }
    @Published var videoAudio: Bool {
        didSet { defaults.set(videoAudio, forKey: Key.videoAudio) }
    }
    /// 0 = 不压暗，1 = 全黑。夜间挂在客厅用 0.35 左右最舒服。
    @Published var dimLevel: Double {
        didSet { defaults.set(dimLevel, forKey: Key.dimLevel) }
    }
    @Published var kenBurnsZoom: Double {
        didSet { defaults.set(kenBurnsZoom, forKey: Key.kenBurnsZoom) }
    }
    @Published var skipVideos: Bool {
        didSet { defaults.set(skipVideos, forKey: Key.skipVideos) }
    }
    /// 视频「先糊后清」：起播用 `.fastFormat` 抢时间，后台再换高清。
    /// 默认开 —— 关掉就退化成「一直播低清但不折腾」。
    @Published var videoHDUpgrade: Bool {
        didSet { defaults.set(videoHDUpgrade, forKey: Key.videoHDUpgrade) }
    }
    /// 把升过清晰的视频原片留在本地，保留最近 3 个（LRU）。
    /// 下次同一个视频直接本地起播 —— 不用等 iCloud、也不用再低清一遍。
    @Published var videoDiskCache: Bool {
        didSet {
            defaults.set(videoDiskCache, forKey: Key.videoDiskCache)
            // 关掉就顺手清干净，别让用户在「设置里已经关了」之后
            // 还占着几百 MB 却找不到地方删。
            if !videoDiskCache { HDVideoCache.shared.clear() }
        }
    }
    @Published var resumeLastPosition: Bool {
        didSet { defaults.set(resumeLastPosition, forKey: Key.resumeLastPosition) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 照片停留：新键优先，其次读旧版 `lantern.interval`（一次性迁移），最后默认 6 秒
        let legacyInterval = defaults.object(forKey: Key.interval) as? Double
        let storedPhoto = defaults.object(forKey: Key.photoInterval) as? Double
        photoInterval = min(max(storedPhoto ?? legacyInterval ?? 6, 2), 120)
        // 视频停留：0 = 播完为止，是更省心的默认值（不会把长视频截断）
        videoInterval = min(max(defaults.object(forKey: Key.videoInterval) as? Double ?? 0, 0), 180)

        order = SlideOrder(rawValue: defaults.string(forKey: Key.order) ?? "") ?? .oldestFirst

        // 四类填充：没单独设过就继承旧版那个总开关。
        // 必须先落局部常量：init 里读 self.fitMode 会被判 used before being initialized。
        let inheritedFit = FitMode(rawValue: defaults.string(forKey: Key.fit) ?? "") ?? .fill
        fitForPhotoPortrait = FitMode(rawValue: defaults.string(forKey: Key.fitPhotoPortrait) ?? "") ?? inheritedFit
        fitForPhotoLandscape = FitMode(rawValue: defaults.string(forKey: Key.fitPhotoLandscape) ?? "") ?? inheritedFit
        fitForVideoPortrait = FitMode(rawValue: defaults.string(forKey: Key.fitVideoPortrait) ?? "") ?? inheritedFit
        fitForVideoLandscape = FitMode(rawValue: defaults.string(forKey: Key.fitVideoLandscape) ?? "") ?? inheritedFit
        transition = TransitionStyle(rawValue: defaults.string(forKey: Key.transition) ?? "") ?? .kenBurns

        showClock = defaults.object(forKey: Key.showClock) as? Bool ?? true
        showProgress = defaults.object(forKey: Key.showProgress) as? Bool ?? true
        showCaptureDate = defaults.object(forKey: Key.showCaptureDate) as? Bool ?? true
        showPlace = defaults.object(forKey: Key.showPlace) as? Bool ?? true
        showAgeLabel = defaults.object(forKey: Key.showAgeLabel) as? Bool ?? false
        subjectName = defaults.string(forKey: Key.subjectName) ?? ""
        if let stamp = defaults.object(forKey: Key.subjectBirthday) as? Double {
            subjectBirthday = Date(timeIntervalSince1970: stamp)
        } else {
            subjectBirthday = nil
        }
        ageTemplate = defaults.string(forKey: Key.ageTemplate) ?? AgeLabel.defaultTemplate
        playLivePhotos = defaults.object(forKey: Key.playLivePhotos) as? Bool ?? true
        videoAudio = defaults.object(forKey: Key.videoAudio) as? Bool ?? false
        dimLevel = defaults.object(forKey: Key.dimLevel) as? Double ?? 0
        kenBurnsZoom = defaults.object(forKey: Key.kenBurnsZoom) as? Double ?? 0.09
        skipVideos = defaults.object(forKey: Key.skipVideos) as? Bool ?? false
        videoHDUpgrade = defaults.object(forKey: Key.videoHDUpgrade) as? Bool ?? true
        videoDiskCache = defaults.object(forKey: Key.videoDiskCache) as? Bool ?? true
        resumeLastPosition = defaults.object(forKey: Key.resumeLastPosition) as? Bool ?? true
    }

    // MARK: 每个窗口独立记住播到第几张

    var lastAlbumID: String? {
        get { defaults.string(forKey: Key.lastAlbumID) }
        set { defaults.set(newValue, forKey: Key.lastAlbumID) }
    }

    func savedIndex(forAlbum id: String) -> Int {
        defaults.integer(forKey: Key.lastIndexPrefix + id)
    }

    func saveIndex(_ index: Int, forAlbum id: String) {
        guard resumeLastPosition else { return }
        defaults.set(index, forKey: Key.lastIndexPrefix + id)
    }

    // MARK: 按素材挑填充方式

    /// 这一张该用铺满还是完整显示。
    /// 「竖 / 横」看像素尺寸，「照片 / 视频」看 mediaType —— 实况照片归照片那一档。
    func fitMode(for item: SlideItem) -> FitMode {
        let portrait = item.pixelHeight > item.pixelWidth
        switch (item.isVideo, portrait) {
        case (false, true): return fitForPhotoPortrait
        case (false, false): return fitForPhotoLandscape
        case (true, true): return fitForVideoPortrait
        case (true, false): return fitForVideoLandscape
        }
    }

    func fitMode(for target: FitTarget) -> FitMode {
        switch target {
        case .photoPortrait: return fitForPhotoPortrait
        case .photoLandscape: return fitForPhotoLandscape
        case .videoPortrait: return fitForVideoPortrait
        case .videoLandscape: return fitForVideoLandscape
        }
    }

    func setFitMode(_ mode: FitMode, for target: FitTarget) {
        switch target {
        case .photoPortrait: fitForPhotoPortrait = mode
        case .photoLandscape: fitForPhotoLandscape = mode
        case .videoPortrait: fitForVideoPortrait = mode
        case .videoLandscape: fitForVideoLandscape = mode
        }
    }

    func resetAll() {
        for key in [Key.interval, Key.photoInterval, Key.videoInterval,
                    Key.order, Key.fit, Key.transition, Key.showClock,
                    Key.showProgress, Key.showCaptureDate, Key.showPlace, Key.showAgeLabel,
                    Key.subjectName, Key.subjectBirthday, Key.ageTemplate,
                    Key.playLivePhotos, Key.videoAudio,
                    Key.dimLevel, Key.kenBurnsZoom, Key.skipVideos, Key.videoHDUpgrade,
                    Key.videoDiskCache,
                    Key.resumeLastPosition,
                    Key.fitPhotoPortrait, Key.fitPhotoLandscape,
                    Key.fitVideoPortrait, Key.fitVideoLandscape] {
            defaults.removeObject(forKey: key)
        }
        photoInterval = 6
        videoInterval = 0
        order = .oldestFirst
        fitForPhotoPortrait = .fill
        fitForPhotoLandscape = .fill
        fitForVideoPortrait = .fill
        fitForVideoLandscape = .fill
        transition = .kenBurns
        showClock = true
        showProgress = true
        showCaptureDate = true
        showPlace = true
        showAgeLabel = false
        subjectName = ""
        subjectBirthday = nil
        ageTemplate = AgeLabel.defaultTemplate
        playLivePhotos = true
        videoAudio = false
        dimLevel = 0
        kenBurnsZoom = 0.09
        skipVideos = false
        videoHDUpgrade = true
        videoDiskCache = true
        resumeLastPosition = true
    }
}
