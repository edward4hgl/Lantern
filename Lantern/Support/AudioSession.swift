import AVFoundation

/// 音频会话：把它调成「能出声音」的状态。
///
/// 实况照片没声音的根因不在 `isMuted`，而是默认类别 `.ambient` 遵守静音键、常常干脆不出声
///（系统「照片」App 能出声是因为它设了 `.playback`）。
/// `.playback` 忽略静音键；`.mixWithOthers` 不打断用户正在放的音乐。
enum AudioSession {

    static func prepareForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            Log.media.error("audio session setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
