import SwiftUI
import UIKit

/// 根视图：选相簿 → 进轮播。
/// 用值路由而不是 `NavigationLink(destination:)`，这样 iPad 多窗口时每个窗口各持一份路径。
struct RootView: View {

    @StateObject private var library = PhotoLibraryService()
    @EnvironmentObject private var settings: SlideshowSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            AlbumListView(library: library)
                .navigationDestination(for: AlbumRef.self) { album in
                    SlideshowView(album: album, library: library)
                }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            // 用户可能刚去系统设置里开了权限
            Task { await library.handleForeground() }
        }
        .tint(settings.accentColor)
    }
}

extension SlideshowSettings {
    var accentColor: Color { .blue }
}
