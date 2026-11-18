"""Builds the App Store screenshots (iPad 13 inch, 2064 x 2752) from the iPad CI screenshots.
Usage: python tools/make_store_shots_ipad.py <folder-with-CI-pngs> <output-folder>
Each store image is a real in-app screenshot placed under a short headline on the app's deep green brand background."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 2064, 2752
TOP, BOTTOM = (11, 92, 74), (4, 38, 31)
PAPER, MIST, MINT = (246, 248, 247), (176, 208, 197), (123, 240, 203)
SERIF = r"C:\Windows\Fonts\georgia.ttf"
SERIF_B = r"C:\Windows\Fonts\georgiab.ttf"

# (screenshot name, headline lines, sub line)
SLIDES = [
    ("library-light", ["Every document,", "in one place."], "Search titles and the words inside them"),
    ("page-light", ["Paper in,", "clean PDF out."], "Edges found, page straightened, light evened out"),
    ("crop-light", ["Fine-tune the", "corners."], "Drag, rotate and choose a look for each page"),
    ("sign-light", ["Sign without", "printing."], "Place your signature, the date or text on any PDF"),
    ("text-light", ["Copy the words", "from any scan."], "Text is read on your device, nothing is uploaded"),
    ("tools-light", ["Twelve PDF tools,", "all free."], "Merge, split, compress, protect and more"),
    ("doc-light", ["Organise every", "page."], "Crop, rotate, reorder and rename in a tap"),
    ("export-light", ["Share a PDF", "or pictures."], "Searchable PDFs, page sizes and quality you choose"),
]


def background():
    img = Image.new("RGB", (W, H))
    px = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        px.line([(0, y), (W, y)], fill=tuple(round(TOP[k] + (BOTTOM[k] - TOP[k]) * t) for k in range(3)))
    glow = Image.new("RGB", (W, H), MINT)
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse([W * 0.1, -H * 0.14, W * 0.9, H * 0.22], fill=60)
    return Image.composite(glow, img, mask.filter(ImageFilter.GaussianBlur(220)))


def rounded(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width, im.height], radius, fill=255)
    out = im.convert("RGBA")
    out.putalpha(mask)
    return out


def main(src, dst):
    src, dst = Path(src), Path(dst)
    dst.mkdir(parents=True, exist_ok=True)
    head = ImageFont.truetype(SERIF_B, 150)
    sub = ImageFont.truetype(SERIF, 64)
    for i, (name, lines, caption) in enumerate(SLIDES, 1):
        shot_path = src / f"{name}.png"
        if not shot_path.exists():
            print("missing", shot_path)
            continue
        canvas = background()
        d = ImageDraw.Draw(canvas)
        y = 170
        for line in lines:
            d.text((W / 2, y), line, font=head, fill=PAPER, anchor="ma")
            y += 180
        d.text((W / 2, y + 30), caption, font=sub, fill=MIST, anchor="ma")
        shot = Image.open(shot_path).convert("RGB")
        SW = 1500
        scale = SW / shot.width
        shot = shot.resize((SW, round(shot.height * scale)), Image.LANCZOS)
        framed = rounded(shot, 64)
        top = 680
        shadow = Image.new("RGBA", (framed.width + 160, framed.height + 160), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle([80, 80, 80 + framed.width, 80 + framed.height], 64, fill=(0, 0, 0, 170))
        shadow = shadow.filter(ImageFilter.GaussianBlur(40))
        canvas.paste(shadow, ((W - framed.width) // 2 - 80, top - 80), shadow)
        edge = Image.new("RGBA", (framed.width + 6, framed.height + 6), (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle([0, 0, edge.width - 1, edge.height - 1], 67, outline=MINT + (110,), width=4)
        canvas.paste(edge, ((W - framed.width) // 2 - 3, top - 3), edge)
        canvas.paste(framed, ((W - framed.width) // 2, top), framed)
        out = dst / f"{i:02d}-{name.replace('-light', '')}.png"
        canvas.convert("RGB").save(out, optimize=True)
        print("wrote", out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
