import Foundation
import Photos
import SwiftUI

/// 轮播引擎：素材列表、当前位置、暂停状态、节奏推进。
@MainActor
final class SlideDeck: ObservableObject {

    @Published private(set) var items: [SlideItem] = []
    @Published private(set) var index: Int = 0
    /// 每翻一页 +1。用它而不是 `index` 驱动计时与重建视图 ——
    /// 单张相簿的 index 永远不变，那样计时器不会重启。
    @Published private(set) var generation: Int = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published var isPaused = false

    private let library: PhotoLibraryService
    private var albumID: String?
    private var loadToken = UUID()

    init(library: PhotoLibraryService) {
        self.library = library
    }

    // MARK: - 派生

    var current: SlideItem? {
        guard items.indices.contains(index) else { return items.first }
        return items[index]
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// 预取窗口：接下来 6 张（环形）
    var nextItems: [SlideItem] {
        guard !items.isEmpty else { return [] }
        var out: [SlideItem] = []
        out.reserveCapacity(min(6, items.count))
        for offset in 1...min(6, items.count) {
            out.append(items[(index + offset) % items.count])
        }
        return out
    }

    var positionLabel: String {
        guard !items.isEmpty else { return "" }
        return "\(index + 1) / \(items.count)"
    }

    // MARK: - 载入

    func load(album: AlbumRef, order: SlideOrder, skipVideos: Bool, resumeIndex: Int?) async {
        let token = UUID()
        loadToken = token

        isLoading = true
        errorText = nil
        albumID = album.id

        let fetched = library.fetchItems(albumID: album.id, order: order, skipVideos: skipVideos)
        guard loadToken == token else { return }   // 期间又发起了新载入

        items = fetched
        isLoading = false

        if fetched.isEmpty {
            index = 0
            errorText = "这个相簿里还没有可播放的照片"
            return
        }

        if let resumeIndex, fetched.indices.contains(resumeIndex) {
            index = resumeIndex
        } else {
            index = 0
        }
        generation &+= 1
        Log.playback.info("deck loaded: \(fetched.count, privacy: .public) items")
    }

    /// 相簿内容变了：按 id 保住当前这张重新拉列表。
    ///
    /// 只有「当前这张真的换了」才 +1 generation；张数变化只影响分母。
    /// 否则共享相簿一进新照片，正在播的视频会被整段重建、从头缓冲。
    func refreshPreservingCurrent(order: SlideOrder, skipVideos: Bool) async {
        guard let albumID else { return }
        let previousID = current?.id

        let fetched = library.fetchItems(albumID: albumID, order: order, skipVideos: skipVideos)
        guard !fetched.isEmpty else {
            items = []
            index = 0
            generation &+= 1
            return
        }
        items = fetched
        if let previousID, let newIndex = fetched.firstIndex(where: { $0.id == previousID }) {
            index = newIndex
        } else if index >= fetched.count {
            index = 0
        }
        if current?.id != previousID {
            generation &+= 1
        }
        Log.playback.info("deck refreshed, \(fetched.count, privacy: .public) items")
    }

    // MARK: - 导航

    func advance() {
        guard !items.isEmpty else { return }
        index = (index + 1) % items.count
        generation &+= 1
    }

    func back() {
        guard !items.isEmpty else { return }
        index = (index - 1 + items.count) % items.count
        generation &+= 1
    }

    func jump(to newIndex: Int) {
        guard items.indices.contains(newIndex) else { return }
        index = newIndex
        generation &+= 1
    }

    func togglePause() { isPaused.toggle() }
}
