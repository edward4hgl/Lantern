import SwiftUI

/// 画面信息层：只放右上角时钟。视频进度条不在这里（它要接手势，而这层 `allowsHitTesting(false)`）。
///
/// 不加背景、不加阴影 —— 任何渐变或 shadow 在浅色照片上都会糊出一条灰带 / 一圈灰边。
struct ChromeOverlay: View {

    let showClock: Bool

    var body: some View {
        ZStack(alignment: .top) {
            if showClock {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ClockView()
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 每秒刷一次的时间。用 `TimelineView` 而不是 Timer：后台 / 息屏时自动降频。
/// 84pt 是为了挂客厅三米外也认得出几点；日期 18pt 陪衬。
struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .trailing, spacing: 4) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 84, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.94))

                Text(context.date, format: .dateTime.month(.defaultDigits).day().weekday(.abbreviated))
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }
}
