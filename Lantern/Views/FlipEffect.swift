import SwiftUI

/// 「立体翻页」过渡用的修饰：绕竖轴转一个角度、带透视，中途被压成窄条。
/// 缩放假装不出这个效果 —— 那看起来像同一张纸在变大变小。
struct FlipEffect: ViewModifier {
    let angle: Double
    let anchor: UnitPoint
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: anchor,
                perspective: 0.5
            )
            .opacity(opacity)
    }
}
