"""Builds the static Folia site into website/folia/.

  python website/build_site.py

The public support address is read from the "Contact:" line of docs/legal/privacy-policy.md (or from
FOLIA_SUPPORT_EMAIL if that is set), so it lives in one place. It is shown as selectable text, no mailto link.
Writes index.html, support/, privacy/, terms/, sitemap.xml, robots.txt. The privacy and terms pages are generated
from docs/legal/*.md (the draft notice block is stripped). Pure standard library."""
import html
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(os.environ.get("FOLIA_SITE_OUT") or ROOT / "website" / "folia")
LEGAL = ROOT / "docs" / "legal"
BASE = "https://ecomswiftllc.github.io/folia/"
UPDATED = "2026-11-18"
SITE_NAME = "PDF Scanner & Editor: Folia"


def find_support_email():
    env = os.environ.get("FOLIA_SUPPORT_EMAIL", "").strip()
    if env:
        return env
    text = (LEGAL / "privacy-policy.md").read_text(encoding="utf-8")
    m = re.search(r"\*\*Contact:\*\*\s*([^\s]+@[^\s]+)", text)
    if not m:
        sys.exit("No support address found in docs/legal/privacy-policy.md")
    return m.group(1).strip()


SUPPORT_EMAIL = find_support_email()

CSS = """
:root{--bg:#f1f3f5;--card:#fff;--ink:#0f1419;--mute:#56606b;--line:rgba(0,0,0,.1);--accent:#0b7a62;--soft:#e3f1ec}
@media (prefers-color-scheme:dark){:root{--bg:#0d1013;--card:#161a1f;--ink:#eceff2;--mute:#9fa7b0;--line:rgba(255,255,255,.12);--accent:#4fd1ac;--soft:#13261f}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
a{color:var(--accent)}a:focus-visible,summary:focus-visible{outline:3px solid var(--accent);outline-offset:3px;border-radius:6px}
.wrap{max-width:1040px;margin:0 auto;padding:0 20px}
.skip{position:absolute;left:-999px}.skip:focus{left:12px;top:12px;background:var(--card);padding:8px 12px;z-index:9}
.site-header{border-bottom:1px solid var(--line)}.site-header .wrap{display:flex;align-items:center;justify-content:space-between;min-height:64px;gap:16px}
.brand{display:flex;align-items:center;gap:10px;font:600 20px/1 Georgia,"Times New Roman",serif;color:var(--ink);text-decoration:none}
.brand img{width:32px;height:32px;border-radius:8px}
nav.top a{margin-left:20px;color:var(--mute);text-decoration:none;font-size:15px}nav.top a:hover{color:var(--ink)}
.hero{padding:64px 0 40px;display:grid;grid-template-columns:1.1fr .9fr;gap:40px;align-items:center}
.hero h1{font:400 clamp(40px,6vw,64px)/1.05 Georgia,"Times New Roman",serif;letter-spacing:-.02em;margin:0 0 16px}
.hero p.lede{font-size:20px;color:var(--mute);margin:0 0 24px;max-width:34ch}
.badge{display:inline-block;background:var(--soft);color:var(--accent);padding:8px 14px;border-radius:999px;font-weight:600;font-size:15px}
.hero .art{display:flex;justify-content:center}.hero .art img{width:min(320px,70%);height:auto;border-radius:22%;box-shadow:0 24px 60px rgba(7,92,74,.35)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px;padding:24px 0 8px;list-style:none;margin:0}
.grid li{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:20px}.grid h3{margin:0 0 6px;font-size:18px}.grid p{margin:0;color:var(--mute);font-size:15px}
section.block{padding:40px 0}section.block h2{font:400 34px/1.15 Georgia,serif;margin:0 0 8px}section.block>.wrap>p{color:var(--mute);max-width:60ch}
.faq details{background:var(--card);border:1px solid var(--line);border-radius:14px;margin:10px 0;padding:0 18px}.faq summary{cursor:pointer;padding:16px 0;font-weight:600;list-style:none}.faq summary::-webkit-details-marker{display:none}
.faq .answer{padding:0 0 16px;color:var(--mute)}.faq .answer p{margin:0 0 8px}
.page{padding:40px 0 64px}.doc{max-width:760px}.doc h1{font:400 44px/1.1 Georgia,serif;margin:0 0 12px}.doc h2{font:600 22px/1.3 Georgia,serif;margin:36px 0 8px}
.doc .meta{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px 18px;margin:16px 0;color:var(--mute)}.doc .meta p{margin:4px 0}
.email{font-weight:600;user-select:all}.small{color:var(--mute);font-size:14px}
.site-footer{border-top:1px solid var(--line);padding:32px 0;color:var(--mute);font-size:14px}.site-footer .wrap{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:24px}
.site-footer h2{font-size:15px;color:var(--ink);margin:0 0 8px}.site-footer ul{list-style:none;margin:0;padding:0}.site-footer a{color:var(--mute)}.legalline{grid-column:1/-1;margin:0}
@media(max-width:760px){.hero{grid-template-columns:1fr;padding-top:36px}.hero .art{order:-1}nav.top a{margin-left:12px}}
"""

URL_RE = re.compile(r"(https?://[^\s<)]+)")
MAIL_RE = re.compile(r"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})")


def head(title, description, path, root=""):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(description)}">
<link rel="canonical" href="{BASE}{path}">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(description)}">
<meta property="og:image" content="{BASE}assets/icon-512.png">
<meta name="theme-color" content="#0b7a62">
<link rel="icon" href="{root}assets/favicon-32.png" sizes="32x32">
<link rel="apple-touch-icon" href="{root}assets/apple-touch-icon.png">
<style>{CSS}</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
"""


def header(root):
    return f"""<header class="site-header"><div class="wrap">
<a class="brand" href="{root or './'}"><img src="{root}assets/favicon-32.png" alt="" width="32" height="32">Folia</a>
<nav class="top" aria-label="Main"><a href="{root}support/">Support</a><a href="{root}privacy/">Privacy</a><a href="{root}terms/">Terms</a></nav>
</div></header>
"""


def footer(root):
    return f"""<footer class="site-footer"><div class="wrap">
<div><h2>PDF Scanner &amp; Editor: Folia</h2><p>A free document scanner and PDF toolkit for iPhone and iPad. Your documents stay on your device.</p></div>
<nav aria-label="Footer"><h2>Pages</h2><ul><li><a href="{root or './'}">Home</a></li><li><a href="{root}support/">Support</a></li><li><a href="{root}privacy/">Privacy policy</a></li><li><a href="{root}terms/">Terms of use</a></li></ul></nav>
<div><h2>Ecom Swift LLC</h2><p>30 N Gould St #37906<br>Sheridan, WY 82801<br>United States</p><p class="email">{html.escape(SUPPORT_EMAIL)}</p></div>
<p class="legalline">&copy; 2026 Ecom Swift LLC. Apple, iPhone, iPad and the App Store are trademarks of Apple Inc. Folia is not affiliated with Apple or Google.</p>
</div></footer>
</body>
</html>
"""


FAQ = [
    ("Is Folia really free?", "<p>Yes. There is no subscription, no in-app purchase and no paid version. Ads from Google AdMob pay for the app: a banner on the Documents screen, and one rewarded video that you choose to watch before you save, share or print a finished document.</p>"),
    ("Are my documents uploaded anywhere?", "<p>No. Scanning, text recognition, PDF tools and signing all run on your device. We never receive your documents.</p>"),
    ("Do I need an account?", "<p>No. There is no sign-in and no sign-up.</p>"),
    ("Why am I asked to watch an ad?", "<p>Before you export, the app offers one short video that you choose to watch. One watched ad covers your exports for 2 minutes. If you choose Not now, nothing is exported and you can try again any time. If no ad is available, for example when you are offline, the export goes ahead anyway.</p>"),
    ("Can it read the text on a scan?", "<p>Yes. Folia reads text on the device and can make the PDF searchable, so you can search and copy words inside it. You can also copy the text of a scan as plain text.</p>"),
    ("Which devices does it run on?", "<p>iPhone and iPad with iOS 17 or iPadOS 17 or later. Scanning with the camera needs a device with a camera.</p>"),
    ("When can I download it?", "<p>Folia is not released yet. This page will link to the App Store listing once the app is live.</p>"),
    ("Who makes Folia?", "<p>Ecom Swift LLC, a company registered in Wyoming, United States. You can reach us on the <a href=\"support/\">support page</a>.</p>"),
]

FEATURES = [
    ("Scan in seconds", "Point the camera at a page. Edges are found, the page is straightened and the light is evened out."),
    ("Five clean looks", "Original, Auto, Magic colour, Grayscale and Black and white, switchable any time."),
    ("Searchable PDFs", "Text is read on your device, so PDFs can be searched and copied from."),
    ("Sign and fill", "Draw your signature once, then place it, the date or typed text on any PDF."),
    ("Merge, split, compress", "Join files, pull out pages, or shrink a PDF to fit an email."),
    ("Protect and unlock", "Lock a PDF with a password, or remove the password from one you can open."),
    ("Page numbers and watermarks", "Number every page or stamp DRAFT across a document."),
    ("ID card copy", "Front and back of a card on one sheet at its real size, ready to print."),
]


def build_index():
    title = "PDF Scanner & Editor: Folia | Free document scanner for iPhone and iPad"
    desc = "Free document scanner and PDF toolkit for iPhone and iPad. Scan, read text, sign, merge, split, compress and protect PDFs. Everything stays on your device. Coming soon."
    faq_html = "\n".join(f'<details><summary>{html.escape(q)}</summary><div class="answer">{a}</div></details>' for q, a in FAQ)
    feats = "\n".join(f"<li><h3>{n}</h3><p>{d}</p></li>" for n, d in FEATURES)
    body = head(title, desc, "") + header("") + f"""
<main id="main">
<div class="wrap hero">
<div><h1>Paper in, PDF out.</h1><p class="lede">Scan, sign and tidy documents with nothing to pay and nothing uploaded.</p><span class="badge">Coming soon to the App Store</span></div>
<div class="art"><img src="assets/icon-512.png" alt="Folia app icon: a sheet of paper with a scan line across it" width="320" height="320"></div>
</div>
<section class="block"><div class="wrap"><h2>Everything you do with a PDF</h2><p>Twelve tools in one app, all running on your iPhone or iPad.</p><ul class="grid">
{feats}
</ul></div></section>
<section class="block"><div class="wrap"><h2>Questions</h2><div class="faq">
{faq_html}
</div></div></section>
</main>
""" + footer("")
    (OUT / "index.html").write_text(body, encoding="utf-8")


def build_support():
    title = "Support | PDF Scanner & Editor: Folia"
    desc = "Get help with Folia: contact details and answers about scanning, text recognition, signing, passwords, ads and ID card copies."
    items = [
        ("How do I scan a document?", "<ol><li>Open Folia and tap Scan.</li><li>Hold the camera over the page. Folia finds the edges and takes the picture for you. Scan more pages if you need to.</li><li>Tap Save. Your pages appear in Documents, where you can crop, rotate, change the look and export.</li></ol>"),
        ("How do I make a PDF from photos I already have?", "<p>In Documents, tap the plus button and choose Choose from Photos. Folia looks for the page in each photo and straightens it. You can also choose Import from Files to add PDFs or picture files.</p>"),
        ("How do I sign a PDF?", "<ol><li>Open Tools and choose Sign and fill, or open a document and use the menu, then Sign and fill.</li><li>Choose a PDF or one of your scans.</li><li>Tap Signature and draw yours with your finger. It is saved on your device for next time.</li><li>Drag the signature into place, resize it with the slider, then tap Save signed PDF.</li></ol>"),
        ("How do I copy the text from a scan?", "<p>Open the document, tap the more button and choose Extract text. Folia reads the pages on your device. Copy the text or share it as a text file. When you export a PDF, leave Searchable text on to be able to search inside it.</p>"),
        ("Why am I asked to watch an ad?", "<p>Folia is free, and ads pay for it. Before you save, share or print, the app offers one short video that you choose to watch. One watched ad covers your exports for 2 minutes. If you choose Not now, nothing is exported and you can try again any time. If no ad is available, for example when you are offline or your ad privacy choice does not allow ads, the export goes ahead without one. Scanning and editing never need an ad.</p>"),
        ("I forgot the password of a PDF I locked", "<p>Folia cannot recover it. The password is not stored anywhere, which is what keeps the file safe. If you still have an unlocked copy, protect it again with a new password.</p>"),
        ("My scan looks too dark or too light", "<p>Open the page and try another look: Auto suits most pages, Black and white suits text, Magic colour suits colour documents. Rotate and crop with the buttons under the page.</p>"),
        ("I deleted the app and my documents are gone", "<p>Folia keeps documents only on your device, so they are removed with the app and we cannot recover them. Export important documents to Files or share them before you delete the app.</p>"),
        ("I saw an ad that seems wrong", "<p>Write to us at the address above. Tell us roughly when and where in the app you saw it and what it showed. A screenshot helps. We block ad categories and advertisers through Google AdMob where we can.</p>"),
        ("I want to change my ad or tracking choice", "<p>Open Settings in the app and look for the Ad privacy choices row, which appears where the law requires it. You can also change tracking in iOS Settings under Privacy and Security, then Tracking.</p>"),
    ]
    faq_html = "\n".join(f'<details><summary>{html.escape(q)}</summary><div class="answer">{a}</div></details>' for q, a in items)
    body = head(title, desc, "support/", root="../") + header("../") + f"""
<main id="main"><div class="page"><div class="wrap"><div class="doc">
<h1>Support</h1>
<p>Write to us and a person will read it.</p>
<p><span class="email">{html.escape(SUPPORT_EMAIL)}</span></p>
<p class="small">Select the address to copy it into your mail app.</p>
<p>A message gets answered faster when it includes your device (iPhone or iPad) and its iOS version, what you were doing and what happened, and a screenshot if it helps. Please do not send documents with personal details unless we ask.</p>
<p>Folia is not released yet, so support right now covers questions about the app before launch.</p>
<h2>Common questions</h2>
<div class="faq">
{faq_html}
</div>
<h2>Company</h2>
<p>Ecom Swift LLC<br>30 N Gould St #37906<br>Sheridan, WY 82801<br>United States</p>
<p>Read the <a href="../privacy/">privacy policy</a> and the <a href="../terms/">terms of use</a>.</p>
</div></div></div></main>
""" + footer("../")
    (OUT / "support").mkdir(exist_ok=True)
    (OUT / "support" / "index.html").write_text(body, encoding="utf-8")


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)

    def url(m):
        u = m.group(1)
        trail = ""
        while u and u[-1] in ".,;":
            trail = u[-1] + trail
            u = u[:-1]
        return f'<a href="{u}" rel="noopener">{u}</a>{trail}'

    t = URL_RE.sub(url, t)
    # email addresses stay as selectable text (no mailto link)
    parts = re.split(r"(<a .*?</a>)", t)
    parts = [p if p.startswith("<a ") else MAIL_RE.sub(r'<span class="email">\1</span>', p) for p in parts]
    return "".join(parts)


def md_to_html(md):
    md = re.sub(r"<!-- DRAFT-NOTICE-START -->.*?<!-- DRAFT-NOTICE-END -->", "", md, flags=re.S)
    out, para, items = [], [], []
    title = ""
    meta_open = False
    seen_h2 = False

    def flush_para():
        nonlocal para
        if para:
            out.append("<p>" + "<br>".join(inline(p) for p in para) + "</p>")
            para = []

    def flush_list():
        nonlocal items
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items = []

    for raw in md.splitlines():
        line = raw.rstrip()
        if line.startswith("# "):
            flush_para(); flush_list()
            title = line[2:].strip()
            out.append(f"<h1>{html.escape(title)}</h1>")
        elif line.startswith("## "):
            flush_para(); flush_list()
            if meta_open:
                out.append("</div>"); meta_open = False
            seen_h2 = True
            out.append(f"<h2>{inline(line[3:].strip())}</h2>")
        elif line.startswith("- "):
            flush_para()
            items.append(line[2:].strip())
        elif not line.strip():
            flush_para(); flush_list()
        elif line.startswith("**") and title and not seen_h2:
            if not meta_open:
                out.append('<div class="meta">'); meta_open = True
            out.append("<p>" + inline(line) + "</p>")
        else:
            flush_list()
            if meta_open:
                out.append("</div>"); meta_open = False
            para.append(line.strip())
    flush_para(); flush_list()
    if meta_open:
        out.append("</div>")
    return title, "\n".join(out)


def build_legal(src, folder, current_title, desc):
    md = (LEGAL / src).read_text(encoding="utf-8")
    _, content = md_to_html(md)
    body = head(f"{current_title} | {SITE_NAME}", desc, folder + "/", root="../") + header("../") + f"""
<main id="main"><div class="page"><div class="wrap"><article class="doc">
{content}
</article></div></div></main>
""" + footer("../")
    (OUT / folder).mkdir(exist_ok=True)
    (OUT / folder / "index.html").write_text(body, encoding="utf-8")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    build_index()
    build_support()
    build_legal("privacy-policy.md", "privacy", "Privacy Policy",
                "How PDF Scanner & Editor: Folia handles information: documents are processed on your device and never uploaded, there is no account, and ads come from Google AdMob with your consent where required.")
    build_legal("terms-of-use.md", "terms", "Terms of Use", "The terms for using PDF Scanner & Editor: Folia, a free document scanner supported by ads.")
    xml = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for u in ["", "support/", "privacy/", "terms/"]:
        xml.append(f"  <url><loc>{BASE}{u}</loc><lastmod>{UPDATED}</lastmod></url>")
    xml.append("</urlset>")
    (OUT / "sitemap.xml").write_text("\n".join(xml) + "\n", encoding="utf-8")
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {BASE}sitemap.xml\n", encoding="utf-8")
    print("site built in", OUT)


if __name__ == "__main__":
    main()
