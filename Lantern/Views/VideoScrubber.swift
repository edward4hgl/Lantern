import SwiftUI

/// 视频进度条：底部控制条正上方，可拖。
///
///     0:12 ─────●───────────── 1:45
///
/// 两端是「已播 / 总长」，中间轨道 + 圆点拇指。整行 24pt 高，`contentShape` 把触摸区撑满，
/// 墙上伸手也点得中。拖动时实时 `onScrub`（画面跟着跳），松手 `onCommit`。
struct VideoScrubber: View {

    /// 当前进度 0...1（由外部 periodic observer 提供）
    let fraction: Double
    /// 视频总时长（秒）
    let duration: Double
    /// 拖动中
    let onScrub: (Double) -> Void
    /// 松手
    let onCommit: (Double) -> Void

    @State private var dragging = false
    @State private var localFraction: Double = 0

    private var shown: Double {
        let value = dragging ? localFraction : fraction
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(timeText(shown * duration))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 52, alignment: .leading)

            bar

            Text(timeText(duration))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 52, alignment: .trailing)
        }
        .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let thumb: CGFloat = 15
            let filled = width * shown

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(0, filled), height: 4)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .offset(x: min(max(filled - thumb / 2, 0), width - thumb))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .scaleEffect(dragging ? 1.18 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: dragging)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let raw = value.location.x / width
                        localFraction = min(max(raw, 0), 1)
                        onScrub(localFraction)
                    }
                    .onEnded { _ in
                        onCommit(localFraction)
                        dragging = false
                    }
            )
        }
        .frame(height: 24)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
