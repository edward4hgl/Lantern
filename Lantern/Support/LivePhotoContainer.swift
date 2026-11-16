import SwiftUI
import PhotosUI
import Photos

/// PHLivePhotoView 的 SwiftUI 包装（UIKit 里唯一能把「按住动」做对的视图）。
/// 播完一遍就回调，挂墙场景不需要循环。
struct LivePhotoContainer: UIViewRepresentable {

    let livePhoto: PHLivePhoto
    let contentMode: UIView.ContentMode
    /// false = 出声
    var isMuted: Bool = true
    var autoplay: Bool = true
    var onPlaybackEnded: (() -> Void)? = nil

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.isMuted = isMuted
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.contentMode = contentMode
        // 每次都同步：用户在设置里一拨「视频声音」，这一张立刻跟着变
        view.isMuted = isMuted

        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
            context.coordinator.hasStarted = false
        }

        if autoplay, !context.coordinator.hasStarted, view.livePhoto != nil {
            context.coordinator.hasStarted = true
            view.startPlayback(with: .full)
        }
    }

    // UIKitRepresentable 的 dismantle 是 static —— 写成实例方法会静默失效
    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        view.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlaybackEnded: onPlaybackEnded)
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var hasStarted = false
        private let onPlaybackEnded: (() -> Void)?

        init(onPlaybackEnded: (() -> Void)?) {
            self.onPlaybackEnded = onPlaybackEnded
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView,
                           didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            Log.media.debug("live photo playback ended")
            onPlaybackEnded?()
        }
    }
}
