"""Regenerate docs/icons/*.png from the app's palette.

    python3 -m pip install --user pillow
    python3 tools/make_icons.py

Full-bleed square artwork (safe for "maskable"): a night-blue ground, an amber
sun just breaking a horizon, and one indigo star — the small hours, ending.
"""
from pathlib import Path
from PIL import Image, ImageDraw

BG = (10, 13, 20)          # --bg
SURFACE = (21, 27, 39)     # --surface
DAWN = (232, 161, 92)      # --dawn
DAWN_SOFT = (58, 42, 27)   # --dawn-soft
DEEP = (110, 125, 224)     # --deep

OUT = Path(__file__).resolve().parent.parent / "docs" / "icons"


def draw(size: int) -> Image.Image:
    s = size * 4  # supersample, then downscale for clean edges
    im = Image.new("RGB", (s, s), BG)
    d = ImageDraw.Draw(im)
    horizon = int(s * 0.64)
    # sky glow just above the horizon
    for i in range(40):
        t = i / 40
        r = int(s * (0.40 - 0.22 * t))
        col = tuple(int(BG[k] + (DAWN_SOFT[k] - BG[k]) * (0.15 + 0.85 * t)) for k in range(3))
        d.ellipse([s / 2 - r * 1.5, horizon - r, s / 2 + r * 1.5, horizon + r], fill=col)
    # the sun, cut by the horizon
    r = int(s * 0.17)
    d.ellipse([s / 2 - r, horizon - r, s / 2 + r, horizon + r], fill=DAWN)
    d.rectangle([0, horizon, s, s], fill=BG)
    d.rectangle([int(s * 0.18), horizon, int(s * 0.82), horizon + max(2, s // 90)], fill=DAWN)
    # ground band
    d.rectangle([0, horizon + s // 30, s, s], fill=SURFACE)
    d.rectangle([0, horizon + s // 30 + s // 60, s, s], fill=BG)
    # one star
    st = max(3, int(s * 0.035))
    cx, cy = int(s * 0.70), int(s * 0.27)
    d.ellipse([cx - st, cy - st, cx + st, cy + st], fill=DEEP)
    return im.resize((size, size), Image.LANCZOS)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, size in [("icon-192.png", 192), ("icon-512.png", 512), ("apple-touch-icon.png", 180)]:
        draw(size).save(OUT / name, optimize=True)
        print("wrote", OUT / name)


if __name__ == "__main__":
    main()
