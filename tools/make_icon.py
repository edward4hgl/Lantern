#!/usr/bin/env python3
"""生成 Lantern 的 App 图标（1024×1024，单尺寸 iOS 图标）。

设计：纯黑底 + 一团暖光。没有灯罩、没有把手、没有拟物 —— 只留下「亮着的一盏灯」
这个最容易被记住的形状。缩到 40pt 时仍然认得出，不会糊成一块。
"""
from __future__ import annotations

import math
import os

import numpy as np
from PIL import Image

SIZE = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, "..", "Lantern", "Assets.xcassets",
                                  "AppIcon.appiconset", "icon-1024.png"))


def srgb_to_linear(x: np.ndarray) -> np.ndarray:
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * (x ** (1 / 2.4)) - 0.055)


def radial(n: int, cx: float, cy: float, r: float) -> np.ndarray:
    """返回 0..1 的归一化距离场（中心 0，半径 r 处 1）。"""
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / r
    return d


def build() -> Image.Image:
    n = SIZE
    cx = cy = n / 2.0

    # ---- 底色：近乎黑，但带一点冷紫，避免纯黑在 OLED 上和边框糊在一起
    base = np.array([0.043, 0.043, 0.055], dtype=np.float32)
    img = np.zeros((n, n, 3), dtype=np.float32) + base

    # ---- 外层光晕：三层不同半径的加性暖光，叠出有机的衰减，而不是死板的高斯
    glow_layers = [
        # (半径, 峰值强度, 颜色)
        (0.58, 0.30, (1.00, 0.58, 0.20)),   # 大范围暖雾（收紧，别把四角洗灰）
        (0.40, 0.34, (1.00, 0.72, 0.36)),   # 中景
        (0.27, 0.52, (1.00, 0.90, 0.68)),   # 紧贴灯芯的亮部
    ]
    for radius_frac, peak, color in glow_layers:
        r = n * radius_frac / 2.0
        d = np.clip(radial(n, cx, cy, r), 0.0, 1.0)
        # smoothstep 衰减：中心平顶，边缘柔和落地
        falloff = 1.0 - (d * d * (3.0 - 2.0 * d))
        falloff = np.clip(falloff, 0.0, 1.0) ** 1.6
        c = np.array(color, dtype=np.float32)
        img += falloff[..., None] * peak * c * 0.55

    # ---- 灯芯：一个实心圆，内部是暖白 → 橙的径向渐变
    core_r = n * 0.155
    d_core = radial(n, cx, cy, core_r)
    inside = d_core <= 1.0

    core_inner = np.array([1.00, 0.97, 0.90], dtype=np.float32)
    core_outer = np.array([1.00, 0.55, 0.18], dtype=np.float32)
    t = np.clip(d_core, 0.0, 1.0)[..., None] ** 1.5
    core = core_inner * (1.0 - t) + core_outer * t
    img = np.where(inside[..., None], core, img)

    # ---- 一道细光环，把灯芯从光雾里「拎」出来
    ring_r = n * 0.205
    ring_w = n * 0.0035
    ring = np.exp(-((radial(n, cx, cy, 1.0) * 1.0 - ring_r) ** 2) / (2 * ring_w ** 2))
    img += ring[..., None] * 0.16 * np.array([1.0, 0.93, 0.80], dtype=np.float32)

    # ---- 收边：中心保持通透，四角压到近黑，图标在桌面上才有「一块玻璃」的边
    vignette = np.clip(1.0 - (radial(n, cx, cy, n * 0.72) ** 2) * 1.25, 0.06, 1.0)
    img *= vignette[..., None]

    # ---- 曝光保护：上面是线性加法，这里压回 0..1 再做 gamma
    img = linear_to_srgb(img)
    arr = (np.clip(img, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)

    return Image.fromarray(arr, mode="RGB")


def main() -> None:
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    im = build()
    assert im.size == (SIZE, SIZE)
    im.save(OUT, format="PNG", optimize=True)
    small = im.resize((40, 40), Image.LANCZOS)
    # 40pt 自查：中心亮度必须明显高于四角，否则小尺寸下会糊成一块暗方块
    px = np.asarray(small, dtype=np.float32)
    center = px[16:24, 16:24].mean()
    corners = np.concatenate([px[:8, :8].ravel(), px[:8, -8:].ravel(),
                              px[-8:, :8].ravel(), px[-8:, -8:].ravel()]).mean()
    print(f"wrote {OUT} ({os.path.getsize(OUT):,} B)")
    print(f"40pt check: center={center:.1f} corners={corners:.1f} "
          f"contrast={center - corners:.1f}")
    assert center - corners > 30, "小尺寸下对比不足，图标会糊"


if __name__ == "__main__":
    main()
