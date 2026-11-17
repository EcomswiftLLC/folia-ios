"""Draws the Folia app icon: a white sheet with a folded corner and a mint scan beam across it, on deep green.
Run: python tools/make_icon.py   (writes the three 1024 px PNGs into the asset catalog)."""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "Sources/Resources/Assets.xcassets/AppIcon.appiconset"
S = 4096
FINAL = 1024


def background(top, bottom):
    t = np.linspace(0, 1, S, dtype=np.float32)[:, None]
    x = np.linspace(0, 1, S, dtype=np.float32)[None, :]
    mix = np.clip(t * 0.85 + x * 0.15, 0, 1)
    arr = np.zeros((S, S, 3), dtype=np.float32)
    for k in range(3):
        arr[:, :, k] = top[k] + (bottom[k] - top[k]) * mix
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def compose(top, bottom, sheet, shade, ink, beam, glow=True):
    img = background(top, bottom)
    d = ImageDraw.Draw(img)
    w, h = S * 0.46, S * 0.58
    x0, y0 = (S - w) / 2, (S - h) / 2 - S * 0.01
    x1, y1 = x0 + w, y0 + h
    fold = w * 0.30
    # soft shadow under the sheet
    shadow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shadow).polygon(
        [(x0, y0 + S * 0.02), (x1 - fold, y0 + S * 0.02), (x1, y0 + fold + S * 0.02), (x1, y1 + S * 0.03), (x0, y1 + S * 0.03)], fill=150
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.02))
    img = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), img, shadow)
    d = ImageDraw.Draw(img)
    d.polygon([(x0, y0), (x1 - fold, y0), (x1, y0 + fold), (x1, y1), (x0, y1)], fill=sheet)
    d.polygon([(x1 - fold, y0), (x1, y0 + fold), (x1 - fold, y0 + fold)], fill=shade)
    # text lines
    lw = S * 0.016
    for i, frac in enumerate((0.80, 0.80, 0.58)):
        y = y0 + h * (0.48 + i * 0.13)
        d.rounded_rectangle([x0 + w * 0.14, y, x0 + w * (0.14 + frac * 0.72), y + lw], radius=lw / 2, fill=ink)
    d.rounded_rectangle([x0 + w * 0.14, y0 + h * 0.24, x0 + w * 0.46, y0 + h * 0.24 + lw * 1.6], radius=lw / 2, fill=ink)
    # scan beam
    by = y0 + h * 0.38
    bh = S * 0.012
    if glow:
        halo = Image.new("L", (S, S), 0)
        ImageDraw.Draw(halo).rounded_rectangle([x0 - w * 0.16, by - bh * 1.5, x1 + w * 0.16, by + bh * 2.5], radius=bh, fill=255)
        halo = halo.filter(ImageFilter.GaussianBlur(S * 0.022)).point(lambda v: int(v * 0.75))
        img = Image.composite(Image.new("RGB", (S, S), beam), img, halo)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([x0 - w * 0.14, by, x1 + w * 0.14, by + bh], radius=bh / 2, fill=beam)
    return img.resize((FINAL, FINAL), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    compose((0x13, 0x8A, 0x6E), (0x06, 0x3B, 0x2F), (0xFA, 0xFB, 0xFA), (0xC9, 0xD8, 0xD2), (0x0B, 0x6B, 0x55), (0x7B, 0xF0, 0xCB)).save(OUT / "AppIcon-1024.png")
    compose((0x0B, 0x4A, 0x3A), (0x03, 0x16, 0x12), (0xE9, 0xEF, 0xEC), (0xA9, 0xBC, 0xB4), (0x0B, 0x6B, 0x55), (0x6B, 0xE8, 0xC2)).save(OUT / "AppIcon-1024-dark.png")
    compose((0x20, 0x20, 0x20), (0x00, 0x00, 0x00), (0xF2, 0xF2, 0xF2), (0xB0, 0xB0, 0xB0), (0x55, 0x55, 0x55), (0xFF, 0xFF, 0xFF), glow=False).convert("L").convert("RGB").save(
        OUT / "AppIcon-1024-tinted.png"
    )
    print("icons written to", OUT)


if __name__ == "__main__":
    main()
