import SwiftUI

/// 灯箱 —— 把你的共享相簿变成一面会自己换照片的墙。
@main
struct LanternApp: App {

    @StateObject private var settings = SlideshowSettings()

    var body: some Scene {
        // 单个 WindowGroup 在 iPadOS 上天然支持多窗口（Stage Manager / 外接屏），
        // 每个窗口有自己的 NavigationStack 与自己的 SlideDeck —— 一台 iPad 可以同时
        // 挂两个相簿，接上投影就是一左一右两块画面。
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)   // 照片墙没有浅色模式，浅色只会在换片瞬间闪白
        }
    }
}
