import Foundation
import Photos
import UIKit

// MARK: - 相册引用

struct AlbumRef: Identifiable, Hashable {
    enum Kind: String {
        case shared     // iCloud 共享相簿
        case user       // 自己建/同步的相簿
        case smart      // 智能相簿（最近、收藏、截图…）
        case other

        var badge: String {
            switch self {
            case .shared: return "共享"
            case .user: return "相簿"
            case .smart: return "智能"
            case .other: return "其他"
            }
        }

        var symbol: String {
            switch self {
            case .shared: return "person.2.crop.square.stack"
            case .user: return "rectangle.stack"
            case .smart: return "sparkles.rectangle.stack"
            case .other: return "questionmark.square.dashed"
            }
        }
    }

    let id: String
    let title: String
    let kind: Kind
    let count: Int
    let coverAssetID: String?

    var isEmpty: Bool { count == 0 }
}

// MARK: - 服务

/// 相册枚举 + 资源查询 + 变更观察。整个 App 唯一碰 Photos 的地方。
///
/// 变更观察是为了共享相簿实时跟进：别人加一张照片，挂墙上的 iPad 自己跟上。
/// 任何变更把 `revision` +1，上层拿它当 `.task(id:)` 依赖重取。
@MainActor
final class PhotoLibraryService: NSObject, ObservableObject {

    @Published private(set) var status: PHAuthorizationStatus
    @Published private(set) var albums: [AlbumRef] = []
    @Published private(set) var isLoadingAlbums = false
    /// 相册库版本号。任何 Photos 变更都 +1，让界面自动重取。
    @Published private(set) var revision: Int = 0

    private var isObserving = false

    override init() {
        self.status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
    }

    deinit {
        // PHPhotoLibrary 会强引用 observer，必须摘掉，否则 deinit 永远不来
        if isObserving {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    // MARK: 授权

    var isAuthorized: Bool {
        status == .authorized || status == .limited
    }

    var shouldShowSettingsShortcut: Bool {
        status == .denied || status == .restricted
    }

    func refreshStatus() {
        let new = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if new != status {
            status = new
            Log.photos.info("authorization -> \(String(describing: new.rawValue), privacy: .public)")
        }
    }

    /// 请求（或升级）相册权限，成功后顺手把相册列出来。
    @discardableResult
    func requestAccess() async -> Bool {
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        status = granted
        if granted == .authorized || granted == .limited {
            startObservingIfNeeded()
            await reloadAlbums()
            return true
        }
        return false
    }

    /// 回前台时刷一次权限：用户可能刚去系统设置里改过。
    func handleForeground() async {
        refreshStatus()
        if isAuthorized {
            startObservingIfNeeded()
            if albums.isEmpty { await reloadAlbums() }
        }
    }

    // MARK: 变更观察

    func startObservingIfNeeded() {
        guard !isObserving else { return }
        PHPhotoLibrary.shared().register(self)
        isObserving = true
        Log.photos.info("change observer registered")
    }

    // MARK: 相册列表

    func reloadAlbums() async {
        guard isAuthorized else {
            albums = []
            return
        }
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }

        var collected: [AlbumRef] = []

        // 1) iCloud 共享相簿 —— 这是「共享相册幻灯片」的主场，优先排最前面
        let shared = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumCloudShared, options: nil
        )
        shared.enumerateObjects { collection, _, _ in
            if let ref = Self.makeAlbumRef(collection, kind: .shared) {
                collected.append(ref)
            }
        }

        // 2) 普通相簿（含同步进来的）
        let regular = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        regular.enumerateObjects { collection, _, _ in
            let subtype = collection.assetCollectionSubtype
            guard subtype != .albumCloudShared else { return }   // 上面已经收过
            guard subtype != .albumMyPhotoStream else { return } // 我的照片流：老设备残留，多为空
            if let ref = Self.makeAlbumRef(collection, kind: .user) {
                collected.append(ref)
            }
        }

        // 3) 智能相簿里真正有用的几个
        let wantedSmart: [PHAssetCollectionSubtype] = [
            .smartAlbumUserLibrary,
            .smartAlbumFavorites,
            .smartAlbumLivePhotos,
            .smartAlbumRecentlyAdded,
            .smartAlbumVideos,
        ]
        for subtype in wantedSmart {
            let result = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil
            )
            result.enumerateObjects { collection, _, _ in
                if let ref = Self.makeAlbumRef(collection, kind: .smart) {
                    collected.append(ref)
                }
            }
        }

        // 排序：共享 > 普通 > 智能；同类里空相簿沉底，其余按张数降序
        let order: [AlbumRef.Kind: Int] = [.shared: 0, .user: 1, .smart: 2, .other: 3]
        collected.sort { lhs, rhs in
            let lo = order[lhs.kind] ?? 9
            let ro = order[rhs.kind] ?? 9
            if lo != ro { return lo < ro }
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        albums = collected
        Log.photos.info("albums loaded: \(collected.count, privacy: .public)")
    }

    private static func makeAlbumRef(_ collection: PHAssetCollection, kind: AlbumRef.Kind) -> AlbumRef? {
        let count = PHAsset.fetchAssets(in: collection, options: nil).count
        let title = collection.localizedTitle ?? "未命名相簿"
        var coverID: String?
        if count > 0 {
            let coverOptions = PHFetchOptions()
            coverOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            coverOptions.fetchLimit = 1
            coverID = PHAsset.fetchAssets(in: collection, options: coverOptions).firstObject?.localIdentifier
        }
        return AlbumRef(
            id: collection.localIdentifier,
            title: title,
            kind: kind,
            count: count,
            coverAssetID: coverID
        )
    }

    // MARK: 资源查询

    /// 取某个相簿里的幻灯片素材（图片 + 实况照片 + 视频），已按偏好排好序。
    func fetchItems(albumID: String, order: SlideOrder, skipVideos: Bool) -> [SlideItem] {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil
        ).firstObject else {
            Log.photos.error("collection not found for id \(albumID, privacy: .public)")
            return []
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: order == .oldestFirst)]

        var mediaTypes: [NSNumber] = [NSNumber(value: PHAssetMediaType.image.rawValue)]
        if !skipVideos {
            mediaTypes.append(NSNumber(value: PHAssetMediaType.video.rawValue))
        }
        // 用 mediaType 过滤比在内存里 filter 快得多，而且省内存
        options.predicate = NSPredicate(format: "mediaType IN %@", mediaTypes)
        options.includeHiddenAssets = false

        let result = PHAsset.fetchAssets(in: collection, options: options)
        var items: [SlideItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(SlideItem(asset: asset))
        }

        switch order {
        case .oldestFirst, .newestFirst:
            // 并列项用 localIdentifier 兜底定序：共享相簿里大量照片的 creationDate 完全相同
            //（同一批上传，时间戳只到秒），PhotoKit 对并列项的先后两次 fetch 不保证一致，
            // 会让「第几张 / 共几张」在播放中途跳数字。必须在内存里补 —— localIdentifier
            // 不在 PHFetchOptions 允许的排序键里，塞进 sortDescriptors 会抛异常。
            let ascending = (order == .oldestFirst)
            items.sort { lhs, rhs in
                let a = lhs.creationDate ?? .distantPast
                let b = rhs.creationDate ?? .distantPast
                if a != b { return ascending ? a < b : a > b }
                return lhs.id < rhs.id
            }
        case .shuffle:
            items.shuffle()
        case .recentFirstShuffled:
            // 最近 50 张保持时间序打头阵，剩下的打乱接在后面：
            // 既有「刚拍的会先看到」的确定感，又不会每次都播一路旧照片
            let head = Array(items.prefix(50))
            var tail = Array(items.dropFirst(50))
            tail.shuffle()
            items = head + tail
        }

        Log.photos.info("items for album: \(items.count, privacy: .public)")
        return items
    }
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // 回调在任意后台队列；只做一件事：通知主线程有变化
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.revision &+= 1
            Log.photos.debug("library changed, revision = \(self.revision, privacy: .public)")
        }
    }
}
