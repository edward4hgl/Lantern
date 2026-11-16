import UIKit

/// 全屏取图用的像素尺寸。
enum DisplayMetrics {

    /// 正方形，边长 = 屏幕长边 × scale。
    ///
    /// 不用 `bounds.size * scale`：一转屏宽高互换，缓存 key 就变成另一个值，
    /// 预取好的全作废。正方形在两种方向下 key 相同，比例由 PhotoKit 自己装。
    @MainActor
    static var pixelSize: CGSize {
        let bounds = UIScreen.main.bounds.size
        let side = max(bounds.width, bounds.height) * UIScreen.main.scale
        return CGSize(width: side, height: side)
    }
}
