import Foundation
import Photos
import CoreLocation

/// PHAsset 的轻量快照。
///
/// PHAsset 不遵守 Equatable/Hashable，直接放进 SwiftUI state 会被误判成每次都在变。
/// 这里只带出要用的字段，用 localIdentifier 当稳定 id。
struct SlideItem: Identifiable, Hashable {
    let id: String
    let mediaType: PHAssetMediaType
    let isLivePhoto: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    /// 视频时长（秒）；图片为 0
    let duration: Double
    let creationDate: Date?
    let isFavorite: Bool
    /// 拍摄地坐标。存两个 Double 而不是 CLLocation —— 后者不遵守 Hashable。
    let latitude: Double?
    let longitude: Double?

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.mediaType = asset.mediaType
        self.isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.duration = asset.mediaType == .video ? asset.duration : 0
        self.creationDate = asset.creationDate
        self.isFavorite = asset.isFavorite
        self.latitude = asset.location?.coordinate.latitude
        self.longitude = asset.location?.coordinate.longitude
    }

    var isVideo: Bool { mediaType == .video }

    static func == (lhs: SlideItem, rhs: SlideItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension SlideItem {
    /// 日志用的短标识
    var shortID: String {
        let raw = id.split(separator: "/").last.map(String.init) ?? id
        return String(raw.suffix(8))
    }

    var kindLabel: String {
        if isVideo { return "视频" }
        if isLivePhoto { return "实况照片" }
        return "照片"
    }
}
