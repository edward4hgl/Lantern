import SwiftUI

/// 左下角水印：拍摄日期（可带📍地点）。
///
/// 不跟 chrome 一起隐藏（控制条 4 秒就收，水印要一直在）；放左下角，因为控制条居中、
/// 视频进度条横跨整幅，这里是唯一压不到的位置；用极淡胶囊而不是黑底条，
/// 白底照片看得清、暗部又不抢画面。
struct DateBadge: View {

    let date: Date?
    /// 反查出来的短地名；nil = 没定位信息，或还在查
    let place: String?

    var body: some View {
        Group {
            if let date {
                HStack(spacing: 7) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .medium))
                    Text(date, format: .dateTime.year().month().day())
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()

                    if let place, !place.isEmpty {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.35))
                        Text("📍\(place)")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                    }
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 日期计算那一行：「宝宝 2岁3个月」。内容由 `AgeLabel` 算好传进来，这里只管画。
/// 字号与透明度都比日期低一档 —— 它是注解。
struct AgeBadge: View {

    let text: String?

    var body: some View {
        Group {
            if let text, !text.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "figure.child")
                        .font(.system(size: 12, weight: .medium))
                    Text(text)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 7, y: 2)
            }
        }
        .allowsHitTesting(false)
    }
}
