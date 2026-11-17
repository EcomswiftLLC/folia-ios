"""Resizes the app icon into the website asset sizes. Run: python tools/make_site_assets.py"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
OUT = ROOT / "website/folia/assets"
OUT.mkdir(parents=True, exist_ok=True)
im = Image.open(SRC).convert("RGB")
for name, size in (("icon-512.png", 512), ("apple-touch-icon.png", 180), ("favicon-32.png", 32)):
    im.resize((size, size), Image.LANCZOS).save(OUT / name)
print("assets written to", OUT)
