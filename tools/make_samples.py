"""Generates the sample documents used for development screenshots and store images.

Each document is drawn flat, then "photographed": placed on a desk in perspective with uneven light and a soft shadow,
the way a phone photo of a page looks. manifest.json records where the page corners are in every photo, so the debug build can
crop them exactly. Run: python tools/make_samples.py   (writes design/samples/*.jpg and design/samples/manifest.json)."""
import json
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "design" / "samples"
FONTS = Path("C:/Windows/Fonts")


def font(name, size):
    for candidate in (FONTS / name, FONTS / name.lower(), FONTS / name.upper()):
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    return ImageFont.load_default()


def paper(w, h, tint=(251, 249, 244)):
    rng = np.random.default_rng(7)
    base = np.ones((h, w, 3), dtype=np.float32) * np.array(tint, dtype=np.float32)
    base += rng.normal(0, 1.4, (h, w, 1)).astype(np.float32)
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB")


def text_width(draw, text, f):
    return draw.textlength(text, font=f)


def wrap(draw, text, f, width):
    lines, line = [], ""
    for word in text.split():
        trial = (line + " " + word).strip()
        if text_width(draw, trial, f) <= width:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


# ---------------------------------------------------------------- pages

def invoice():
    w, h = 1700, 2200
    img = paper(w, h)
    d = ImageDraw.Draw(img)
    ink, teal, grey = (28, 32, 38), (24, 92, 76), (110, 116, 124)
    d.rectangle([0, 0, w, 24], fill=teal)
    d.text((120, 110), "HARBOR & PINE", font=font("arialbd.ttf", 62), fill=teal)
    d.text((120, 188), "Studio Co.", font=font("arial.ttf", 38), fill=grey)
    for i, line in enumerate(["48 Wharf Street", "Portland, OR 97204", "hello@harborpine.studio"]):
        d.text((120, 270 + i * 44), line, font=font("arial.ttf", 30), fill=grey)
    d.text((w - 120 - text_width(d, "INVOICE", font("arialbd.ttf", 92)), 100), "INVOICE", font=font("arialbd.ttf", 92), fill=ink)
    meta = [("Invoice no.", "2026-114"), ("Date", "12 Nov 2026"), ("Due", "26 Nov 2026")]
    for i, (k, v) in enumerate(meta):
        y = 250 + i * 50
        d.text((w - 620, y), k, font=font("arial.ttf", 32), fill=grey)
        d.text((w - 120 - text_width(d, v, font("arialbd.ttf", 32)), y), v, font=font("arialbd.ttf", 32), fill=ink)
    d.text((120, 520), "BILL TO", font=font("arialbd.ttf", 28), fill=grey)
    for i, line in enumerate(["Northwind Outfitters", "Attn: Priya Raman", "212 Alder Avenue", "Seattle, WA 98101"]):
        d.text((120, 570 + i * 48), line, font=font("arialbd.ttf" if i == 0 else "arial.ttf", 36), fill=ink)

    top = 860
    d.rectangle([120, top, w - 120, top + 78], fill=(231, 238, 235))
    cols = [(150, "Description"), (1010, "Qty"), (1180, "Rate"), (w - 150, "Amount")]
    for x, label in cols:
        f = font("arialbd.ttf", 30)
        d.text((x - (text_width(d, label, f) if label == "Amount" else 0), top + 22), label, font=f, fill=teal)
    rows = [
        ("Brand identity workshop", 1, 1800.00),
        ("Logo and mark design", 1, 2400.00),
        ("Packaging mockups (6 SKUs)", 6, 350.00),
        ("Website style guide", 1, 1200.00),
        ("Revision rounds", 3, 150.00),
    ]
    y = top + 100
    subtotal = 0
    for desc, qty, rate in rows:
        amount = qty * rate
        subtotal += amount
        f = font("arial.ttf", 34)
        d.text((150, y), desc, font=f, fill=ink)
        d.text((1010, y), str(qty), font=f, fill=ink)
        d.text((1180, y), f"${rate:,.2f}", font=f, fill=ink)
        amt = f"${amount:,.2f}"
        d.text((w - 150 - text_width(d, amt, f), y), amt, font=f, fill=ink)
        d.line([120, y + 66, w - 120, y + 66], fill=(222, 224, 226), width=2)
        y += 88
    tax = subtotal * 0.08
    total = subtotal + tax
    y += 30
    for label, value, bold in [("Subtotal", subtotal, False), ("Sales tax 8%", tax, False), ("Total due", total, True)]:
        f = font("arialbd.ttf" if bold else "arial.ttf", 40 if bold else 34)
        v = f"${value:,.2f}"
        d.text((1030, y), label, font=f, fill=teal if bold else grey)
        d.text((w - 150 - text_width(d, v, f), y), v, font=f, fill=ink)
        y += 70 if bold else 56
    d.text((120, 1700), "Payment terms", font=font("arialbd.ttf", 30), fill=teal)
    for i, line in enumerate(wrap(d, "Please pay within 14 days by bank transfer to Harbor & Pine Studio Co., account ending 4417. Thank you for your business.", font("arial.ttf", 30), 900)):
        d.text((120, 1750 + i * 42), line, font=font("arial.ttf", 30), fill=grey)
    d.line([1060, 2010, w - 120, 2010], fill=ink, width=3)
    d.text((1060, 2025), "Authorised signature", font=font("arial.ttf", 26), fill=grey)
    return img


def receipt():
    w, h = 900, 2100
    img = paper(w, h, (252, 252, 250))
    d = ImageDraw.Draw(img)
    ink = (36, 36, 38)
    f = font("cour.ttf", 44)
    fb = font("courbd.ttf", 52)
    y = 90
    d.text(((w - text_width(d, "CORNER COFFEE", fb)) / 2, y), "CORNER COFFEE", font=fb, fill=ink)
    y += 90
    for line in ["214 Mercer St", "Seattle, WA 98109", "Tel (206) 555-0134"]:
        d.text(((w - text_width(d, line, f)) / 2, y), line, font=f, fill=ink)
        y += 56
    y += 30
    d.text((70, y), "Nov 14 2026  08:42", font=f, fill=ink)
    y += 56
    d.text((70, y), "Order #0392  Dine in", font=f, fill=ink)
    y += 70
    d.line([70, y, w - 70, y], fill=ink, width=3)
    y += 30
    items = [("Flat white", 4.75), ("Oat latte", 5.25), ("Almond croissant", 4.50), ("Cold brew", 4.95), ("Breakfast wrap", 8.95)]
    total = 0
    for name, price in items:
        total += price
        d.text((70, y), name, font=f, fill=ink)
        p = f"{price:.2f}"
        d.text((w - 70 - text_width(d, p, f), y), p, font=f, fill=ink)
        y += 62
    y += 10
    d.line([70, y, w - 70, y], fill=ink, width=3)
    y += 30
    tax = total * 0.1
    for label, value, big in [("Subtotal", total, False), ("Tax 10%", tax, False), ("TOTAL", total + tax, True)]:
        ff = fb if big else f
        d.text((70, y), label, font=ff, fill=ink)
        v = f"{value:.2f}"
        d.text((w - 70 - text_width(d, v, ff), y), v, font=ff, fill=ink)
        y += 76 if big else 60
    y += 30
    d.text((70, y), "VISA **** 4821", font=f, fill=ink)
    y += 60
    d.text((70, y), "Approved  Auth 084217", font=f, fill=ink)
    y += 110
    for line in ["THANK YOU!", "See you tomorrow"]:
        d.text(((w - text_width(d, line, fb if line.startswith("THANK") else f)) / 2, y), line, font=fb if line.startswith("THANK") else f, fill=ink)
        y += 70
    return img


CONTRACT = [
    ("RESIDENTIAL LEASE AGREEMENT", [
        ("1. Parties.", "This Lease Agreement is made on 1 December 2026 between Maria Alvarez (the Landlord) and Daniel Okafor (the Tenant) for the residential property located at 77 Cedar Court, Unit 4B, Portland, Oregon 97205."),
        ("2. Term.", "The tenancy begins on 1 January 2027 and continues for twelve (12) months, ending on 31 December 2027, unless renewed or ended earlier in line with this Agreement."),
        ("3. Rent.", "The Tenant agrees to pay monthly rent of $1,850.00, due on the first day of each month by bank transfer. Rent received after the fifth day of the month incurs a late fee of $50.00."),
        ("4. Security deposit.", "The Tenant has paid a security deposit of $1,850.00. The Landlord will return it within thirty (30) days after the tenancy ends, less any deductions permitted by law for damage beyond normal wear and tear."),
    ]),
    ("UTILITIES AND MAINTENANCE", [
        ("5. Utilities.", "The Tenant is responsible for electricity, gas, internet and renters insurance. The Landlord will pay for water, sewer and refuse collection."),
        ("6. Maintenance.", "The Tenant will keep the premises clean and report any needed repairs promptly. The Landlord will make repairs to major systems within a reasonable time after written notice."),
        ("7. Pets.", "No pets are allowed without the written consent of the Landlord. A pet deposit of $300.00 applies to each approved animal."),
        ("8. Entry.", "The Landlord may enter the premises with at least twenty-four (24) hours notice for inspections, repairs or showings, or at any time in an emergency."),
        ("9. Quiet enjoyment.", "The Tenant will not disturb neighbors and will follow all building rules, including quiet hours between 10:00 p.m. and 7:00 a.m."),
    ]),
    ("TERMINATION AND SIGNATURES", [
        ("10. Notice.", "Either party may end the tenancy at the end of the term by giving at least sixty (60) days written notice. Without notice the Agreement continues month to month."),
        ("11. Governing law.", "This Agreement is governed by the laws of the State of Oregon. Any change must be in writing and signed by both parties."),
        ("12. Entire agreement.", "This document is the entire agreement between the parties and replaces all earlier discussions about the property."),
    ]),
]


def contract(page_index):
    w, h = 1700, 2200
    img = paper(w, h)
    d = ImageDraw.Draw(img)
    ink = (26, 26, 30)
    title, clauses = CONTRACT[page_index]
    d.text(((w - text_width(d, title, font("BOOKOSB.TTF", 54))) / 2, 150), title, font=font("BOOKOSB.TTF", 54), fill=ink)
    d.line([300, 240, w - 300, 240], fill=ink, width=3)
    y = 330
    body = font("BOOKOS.TTF", 36)
    head = font("BOOKOSB.TTF", 36)
    for label, text in clauses:
        d.text((150, y), label, font=head, fill=ink)
        y += 56
        for line in wrap(d, text, body, w - 300):
            d.text((150, y), line, font=body, fill=ink)
            y += 52
        y += 34
    if page_index == 2:
        y = max(y + 120, 1400)
        for who, name in [("Landlord", "Maria Alvarez"), ("Tenant", "Daniel Okafor")]:
            d.line([150, y + 110, 760, y + 110], fill=ink, width=3)
            d.text((150, y + 124), f"{who}: {name}", font=font("BOOKOS.TTF", 32), fill=ink)
            d.line([900, y + 110, 1300, y + 110], fill=ink, width=3)
            d.text((900, y + 124), "Date", font=font("BOOKOS.TTF", 32), fill=ink)
            y += 330
    f = font("BOOKOS.TTF", 28)
    foot = f"Page {page_index + 1} of 3"
    d.text(((w - text_width(d, foot, f)) / 2, h - 130), foot, font=f, fill=(120, 120, 124))
    return img


def notes():
    w, h = 1700, 2200
    img = Image.new("RGB", (w, h), (250, 241, 168))
    d = ImageDraw.Draw(img)
    for y in range(260, h - 80, 64):
        d.line([0, y, w, y], fill=(176, 196, 214), width=2)
    d.line([190, 0, 190, h], fill=(214, 120, 120), width=3)
    d.line([200, 0, 200, h], fill=(214, 120, 120), width=3)
    ink = (36, 48, 92)
    d.text((250, 110), "Q4 planning meeting", font=font("calibrib.ttf", 78), fill=ink)
    d.text((250, 200), "Tue 17 Nov  |  Studio room", font=font("calibri.ttf", 40), fill=(92, 96, 110))
    y = 300
    items = [
        ("Goals", True), ("Ship the new onboarding by 4 Dec", False), ("Cut support replies to under 24 hours", False),
        ("Launch the referral page", False), ("Budget", True), ("Design tools: $2,400 (approved)", False),
        ("Ad spend: hold at $6k per month", False), ("Actions", True), ("Priya: draft launch email by Friday", False),
        ("Daniel: confirm printer quote", False), ("Maria: book the offsite venue", False), ("Next check-in: Tue 24 Nov, 10:00", False),
    ]
    for text, heading in items:
        if heading:
            y += 20
            d.text((250, y), text, font=font("calibrib.ttf", 52), fill=ink)
        else:
            d.text((250, y), "-  " + text, font=font("calibri.ttf", 46), fill=ink)
        y += 64
    return img


# ---------------------------------------------------------------- photography

def solve(src, dst):
    a = []
    for (x, y), (u, v) in zip(src, dst):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y])
    b = [c for pt in dst for c in pt]
    return np.linalg.solve(np.array(a, dtype=np.float64), np.array(b, dtype=np.float64))


def desk(w, h, kind, seed):
    rng = np.random.default_rng(seed)
    if kind == "wood":
        base = np.array([116, 80, 52], dtype=np.float32)
        grain = rng.normal(0, 1, (h, 1)).astype(np.float32)
        grain = np.repeat(grain, w, axis=1)
        grain = np.array(Image.fromarray(((grain * 24 + 128).clip(0, 255)).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.6)), dtype=np.float32) - 128
        img = base[None, None, :] + (grain[:, :, None] * 0.9) + rng.normal(0, 2.0, (h, w, 1))
        # planks
        for x in range(0, w, 460):
            img[:, x:x + 5, :] *= 0.62
    elif kind == "slate":
        base = np.array([64, 70, 78], dtype=np.float32)
        img = base[None, None, :] + rng.normal(0, 3.5, (h, w, 1))
    else:
        base = np.array([196, 190, 180], dtype=np.float32)
        img = base[None, None, :] + rng.normal(0, 3.0, (h, w, 1))
    yy, xx = np.mgrid[0:h, 0:w]
    light = 1.06 - 0.28 * (((xx - w * 0.35) / w) ** 2 + ((yy - h * 0.3) / h) ** 2) * 2.4
    img = img * light[:, :, None]
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")


def photograph(page, corners, kind, seed, shade=0.0):
    W, H = 1800, 2400
    base = desk(W, H, kind, seed)
    src = [(0, 0), (page.width, 0), (page.width, page.height), (0, page.height)]
    coeffs = solve(corners, src)
    warped = page.transform((W, H), Image.PERSPECTIVE, tuple(coeffs), Image.BICUBIC)
    mask = Image.new("L", page.size, 255).transform((W, H), Image.PERSPECTIVE, tuple(coeffs), Image.BICUBIC)
    mask = mask.filter(ImageFilter.GaussianBlur(0.8))
    shadow = mask.filter(ImageFilter.GaussianBlur(26)).transform((W, H), Image.AFFINE, (1, 0, -22, 0, 1, -34))
    sh = np.array(shadow, dtype=np.float32)[:, :, None] / 255.0
    canvas = np.array(base, dtype=np.float32) * (1 - 0.55 * sh)
    paper_arr = np.array(warped, dtype=np.float32)
    yy, xx = np.mgrid[0:H, 0:W]
    cx = sum(p[0] for p in corners) / 4
    cy = sum(p[1] for p in corners) / 4
    light = 1.0 - 0.20 * ((xx - cx) / W + (yy - cy) / H * 0.6) - 0.10 * np.hypot((xx - cx) / W, (yy - cy) / H)
    if shade:
        blob = np.exp(-(((xx - cx - 250) / 420.0) ** 2 + ((yy - cy + 500) / 360.0) ** 2))
        light = light - shade * blob
    paper_arr = paper_arr * light[:, :, None]
    m = np.array(mask, dtype=np.float32)[:, :, None] / 255.0
    out = canvas * (1 - m) + paper_arr * m
    rng = np.random.default_rng(seed + 1)
    out += rng.normal(0, 2.6, out.shape)
    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB").filter(ImageFilter.GaussianBlur(0.7))
    quad = [[round(x / W, 4), round(y / H, 4)] for x, y in corners]
    return img, quad


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = [
        ("invoice", invoice(), [(262, 300), (1578, 236), (1640, 2084), (186, 2150)], "wood", 11, 0.0),
        ("receipt", receipt(), [(520, 210), (1260, 250), (1318, 2150), (452, 2196)], "slate", 12, 0.0),
        ("contract1", contract(0), [(238, 262), (1612, 300), (1566, 2118), (196, 2064)], "wood", 13, 0.16),
        ("contract2", contract(1), [(226, 290), (1598, 250), (1634, 2090), (174, 2142)], "wood", 14, 0.0),
        ("contract3", contract(2), [(250, 244), (1588, 292), (1530, 2112), (212, 2060)], "wood", 15, 0.0),
        ("notes", notes(), [(204, 330), (1560, 244), (1650, 2056), (150, 2170)], "light", 16, 0.12),
    ]
    quads = {}
    for name, page, corners, kind, seed, shade in jobs:
        img, quad = photograph(page, corners, kind, seed, shade)
        img.save(OUT / f"{name}.jpg", quality=90)
        quads[name] = quad
        print("wrote", name)
    manifest = {
        "docs": [
            {"title": "Invoice 2026-114", "pages": [{"file": "invoice.jpg", "quad": quads["invoice"], "filter": "auto"}]},
            {"title": "Corner Coffee receipt", "pages": [{"file": "receipt.jpg", "quad": quads["receipt"], "filter": "bw"}]},
            {"title": "Rental agreement", "pages": [
                {"file": "contract1.jpg", "quad": quads["contract1"], "filter": "auto"},
                {"file": "contract2.jpg", "quad": quads["contract2"], "filter": "auto"},
                {"file": "contract3.jpg", "quad": quads["contract3"], "filter": "auto"},
            ]},
            {"title": "Q4 planning notes", "pages": [{"file": "notes.jpg", "quad": quads["notes"], "filter": "magic"}]},
        ]
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    print("manifest ok")


if __name__ == "__main__":
    main()
