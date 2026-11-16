"""生成 README 用的效果图：合成的日落海湾（不含任何真实照片），
按 App 实际排版画上水印——右上角 84pt 时钟、左下角 📍地点 · 拍摄日期 · 日期计算。

    python tools/make_preview.py

风景全部由 numpy 计算：天空渐变、太阳光晕、三层山脊、水面倒影与碎光。
"""
from __future__ import annotations

import math
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "preview.png"

W, H = 2732, 2048            # iPad Pro 12.9 横屏
HORIZON = 1146
SUN = (1810.0, 1074.0)
SUN_R = 86.0
SCALE = 2.0                  # App 里 1pt = 这里 2px

FONTS = pathlib.Path("C:/Windows/Fonts")
F_LIGHT = FONTS / "segoeuil.ttf"
F_CJK = FONTS / "msyh.ttc"
F_CJK_SB = FONTS / "msyhbd.ttc"


def smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def ridge(width: int, base: float, amp: float, seed: int, rough: float) -> np.ndarray:
    rng = np.random.default_rng(seed)
    x = np.arange(width, dtype=np.float32) / width
    y = np.full(width, base, dtype=np.float32)
    for k in range(1, 7):
        y -= amp * (0.55 ** k) * np.sin(2 * math.pi * k * rough * x + rng.uniform(0, 2 * math.pi))
    return y


def horizontal_blur(arr: np.ndarray, sigma: float) -> np.ndarray:
    """只沿水平方向模糊（arr 是 h×w×3 的 0..1 浮点）。"""
    radius = int(sigma * 3)
    ker = np.array([math.exp(-(i * i) / (2 * sigma * sigma)) for i in range(-radius, radius + 1)], np.float32)
    ker /= ker.sum()
    h, w, c = arr.shape
    out = np.empty_like(arr)
    for ch in range(c):
        flat = arr[:, :, ch]
        pad = np.pad(flat, ((0, 0), (radius, radius)), mode="edge")
        for row in range(h):
            out[row, :, ch] = np.convolve(pad[row], ker, mode="valid")
    return out


def build_scene() -> np.ndarray:
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    img = np.zeros((H, W, 3), dtype=np.float32)

    # 天空
    t = np.clip(yy / HORIZON, 0.0, 1.0)
    top = np.array([0.085, 0.070, 0.185], dtype=np.float32)
    mid = np.array([0.420, 0.210, 0.280], dtype=np.float32)
    low = np.array([1.000, 0.570, 0.235], dtype=np.float32)
    sky = top + (mid - top) * smoothstep(t / 0.55)[..., None]
    sky = sky + (low - sky) * (smoothstep((t - 0.45) / 0.55) ** 2.0)[..., None]
    img[:HORIZON] = sky[:HORIZON]

    # 太阳与三层光晕
    d = np.sqrt((xx - SUN[0]) ** 2 + (yy - SUN[1]) ** 2)
    for radius, peak, colour in ((1400.0, 0.34, (1.00, 0.60, 0.24)),
                                 (620.0, 0.42, (1.00, 0.76, 0.36)),
                                 (240.0, 0.52, (1.00, 0.92, 0.72))):
        img += (np.clip(1.0 - d / radius, 0.0, 1.0) ** 2.4)[..., None] * peak * np.array(colour, np.float32)
    img += np.clip((SUN_R + 4 - d) / 10.0, 0.0, 1.0)[..., None] * np.array([1.00, 0.96, 0.82], np.float32)

    # 云带
    rng = np.random.default_rng(11)
    band = np.zeros((HORIZON, W), dtype=np.float32)
    for _ in range(12):
        cy = rng.uniform(0.08, 0.78) * HORIZON
        thick = rng.uniform(30, 95)
        x0 = rng.uniform(-0.25, 0.75) * W
        length = rng.uniform(0.45, 1.15) * W
        horiz = np.exp(-((xx[:HORIZON] - (x0 + length / 2)) / (length / 2)) ** 2)
        vert = np.exp(-((yy[:HORIZON] - cy - 26 * np.sin(xx[:HORIZON] / 260.0)) / thick) ** 2)
        band += horiz * vert * rng.uniform(0.22, 0.5)
    band = np.clip(band, 0, 1)
    band = np.array(Image.fromarray((band * 255).astype(np.uint8)).filter(
        ImageFilter.GaussianBlur(11)), dtype=np.float32) / 255.0
    img[:HORIZON] += band[..., None] * np.array([0.98, 0.66, 0.46], np.float32) * 0.45

    # 三层山脊
    for base, amp, seed, rough, colour, weight in (
        (HORIZON - 172, 88, 13, 1.0, np.array([0.34, 0.21, 0.24], np.float32), 0.62),
        (HORIZON - 92, 66, 29, 1.7, np.array([0.16, 0.10, 0.15], np.float32), 0.86),
        (HORIZON - 26, 40, 41, 2.6, np.array([0.055, 0.040, 0.065], np.float32), 1.0),
    ):
        line = ridge(W, base, amp, seed, rough)[None, :]
        mask = (yy >= line) & (yy < HORIZON)
        img[mask] = img[mask] * (1 - weight) + colour * weight

    # 水面：倒影采样 + 横向拉伸
    rows = np.arange(HORIZON, H, dtype=np.float32)
    src_y = np.clip(HORIZON - 1 - (rows - HORIZON) * 0.55, 0, HORIZON - 1).astype(np.int32)
    refl = np.clip(img[src_y, :, :] * 0.55, 0, 1)
    water = horizontal_blur(refl, 9.0) * 0.6 + horizontal_blur(refl, 26.0) * 0.4
    water = np.clip(water, 0, 1) * np.linspace(1.0, 0.62, water.shape[0], dtype=np.float32)[:, None, None]
    img[HORIZON:] = water

    # 落日在水面的一道碎光
    col = np.exp(-((xx - SUN[0]) / 118.0) ** 2)
    ripple = 0.45 + 0.55 * np.clip(np.sin(yy / 5.5 + np.sin(xx / 70.0) * 1.2), 0, 1)
    spark = (col * ripple) ** 2.6
    spark[:HORIZON] = 0.0
    img += spark[..., None] * np.array([1.00, 0.70, 0.36], np.float32) * 0.8

    # 压边角
    vig = np.clip(1.0 - ((xx - W / 2) ** 2 / (W * 0.78) ** 2
                         + (yy - H / 2) ** 2 / (H * 0.78) ** 2) * 0.5, 0.62, 1.0)
    img *= vig[..., None]
    return np.clip(img, 0.0, 1.0)


def to_srgb(linear: np.ndarray) -> np.ndarray:
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * np.power(linear, 1 / 2.4) - 0.055)


def pin_icon(d: ImageDraw.ImageDraw, x: float, y: float, size: float, colour) -> None:
    """定位针（字体里没有可用的 emoji，直接画）。"""
    r = size * 0.30
    cx, cy = x + r, y + r
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=colour, width=max(2, int(size * 0.08)))
    inner = r * 0.44
    d.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=colour)
    d.polygon([(cx - r * 0.62, cy + r * 0.55), (cx + r * 0.62, cy + r * 0.55),
               (cx, y + size * 0.98)], fill=colour)


def render() -> Image.Image:
    base = to_srgb(build_scene()) * 255.0
    canvas = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    f_clock = ImageFont.truetype(str(F_LIGHT), int(84 * SCALE))
    f_date = ImageFont.truetype(str(F_CJK), int(18 * SCALE))
    f_cap = ImageFont.truetype(str(F_CJK), int(20 * SCALE))
    f_cap_sb = ImageFont.truetype(str(F_CJK_SB), int(20 * SCALE))

    right = W - int(30 * SCALE)

    # 右上角时钟：时间 84pt，日期 18pt，右对齐，无背景无阴影
    b = d.textbbox((0, 0), "20:41", font=f_clock)
    d.text((right - (b[2] - b[0]) - b[0], int(22 * SCALE) - b[1]), "20:41",
           font=f_clock, fill=(255, 255, 255, 240))
    b2 = d.textbbox((0, 0), "11月16日 周日", font=f_date)
    d.text((right - (b2[2] - b2[0]) - b2[0], int(22 * SCALE) + int(92 * SCALE) - b2[1]),
           "11月16日 周日", font=f_date, fill=(255, 255, 255, 168))

    def capsule(items, top: int, fill_alpha: int) -> int:
        pad_x, pad_y, gap = int(13 * SCALE), int(8 * SCALE), int(7 * SCALE)
        widths, heights = [], []
        for kind, text, f in items:
            if kind == "pin":
                widths.append(int(18 * SCALE))
                heights.append(int(18 * SCALE))
                continue
            bb = d.textbbox((0, 0), text, font=f)
            widths.append(bb[2] - bb[0])
            heights.append(bb[3] - bb[1])
        content_h = max(heights)
        total_w = sum(widths) + gap * (len(items) - 1) + pad_x * 2
        h = content_h + pad_y * 2
        left = int(30 * SCALE)
        d.rounded_rectangle([left, top, left + total_w, top + h], radius=h // 2,
                            fill=(255, 255, 255, fill_alpha),
                            outline=(255, 255, 255, 54), width=1)
        cx = left + pad_x
        for (kind, text, f), wd, hh in zip(items, widths, heights):
            if kind == "pin":
                pin_icon(d, cx, top + pad_y + (content_h - hh) / 2, hh, (255, 255, 255, 232))
            else:
                bb = d.textbbox((0, 0), text, font=f)
                alpha = 150 if kind == "dot" else 240
                d.text((cx - bb[0], top + pad_y + (content_h - hh) / 2 - bb[1]), text,
                       font=f, fill=(255, 255, 255, alpha))
            cx += wd + gap
        return top + h

    # 左下角：第一行「拍摄日期 · 📍地点」，第二行「称呼 年龄」——和 App 里两枚胶囊一致
    pad = int(42 * SCALE)
    row_h = int(20 * SCALE) + int(8 * SCALE) * 2
    gap = int(8 * SCALE)
    y2 = H - pad - row_h
    y1 = y2 - gap - row_h
    capsule([("text", "2025年7月12日", f_cap),
             ("dot", "·", f_cap),
             ("pin", None, None),
             ("text", "旧金山", f_cap)], y1, 30)
    capsule([("text", "宝宝", f_cap_sb), ("text", "2岁3个月", f_cap)], y2, 26)

    return Image.alpha_composite(canvas, layer).convert("RGB")


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    render().save(OUT, optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size:,} B)")


if __name__ == "__main__":
    main()
