#!/usr/bin/env python3
"""Generate wordmark + app icon SVGs and the iOS icon PNG set + splash from Cabinet Grotesk."""
import pathlib, sys, json
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
LOGO = ROOT / "design/logo"; LOGO.mkdir(parents=True, exist_ok=True)
INK, VOLT, PAPER = "#0E0E12", "#C8FF2E", "#F5F3EC"

font = TTFont(ROOT / "app/assets/fonts/CabinetGrotesk-Extrabold.ttf")
gs, cmap, upm = font.getGlyphSet(), font.getBestCmap(), font["head"].unitsPerEm

def word_paths(text, size, x0=0, y0=0, tracking=-0.02):
    """Return list of (char, svg path d) laid out left to right, baseline at y0."""
    s = size / upm; x = x0; out = []
    for ch in text:
        g = cmap[ord(ch)]
        pen = SVGPathPen(gs)
        gs[g].draw(TransformPen(pen, (s, 0, 0, -s, x, y0)))
        out.append((ch, pen.getCommands()))
        x += gs[g].width * s + tracking * size
    return out, x - x0

def wordmark_svg(fg, dotc, size=200, pad=30):
    parts, w = word_paths("tick", size, pad, pad + size * 0.78)
    h = size * 1.2 + pad
    paths = []
    for ch, d in parts:
        paths.append(f'<path d="{d}" fill="{fg}"/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w + pad*2:.0f} {h:.0f}" width="{w+pad*2:.0f}" height="{h:.0f}">' + "".join(paths) + "</svg>", (w + pad * 2, h)

# Wordmark: all letters in fg; the dot of the i is overpainted in Volt by drawing it separately.
# Simplest robust approach: draw full word, then a Volt circle over the i's dot region.
def wordmark_with_volt_dot(fg, size=200, pad=30, bg=None):
    parts, w = word_paths("tick", size, pad, pad + size * 0.78)
    # locate i glyph dot bounds from the glyph (second contour, topmost)
    s = size / upm; x = pad
    for ch, g in ((c, cmap[ord(c)]) for c in "tick"):
        if ch == "i":
            from fontTools.pens.boundsPen import BoundsPen
            # find the dot: contour with highest yMax
            from fontTools.pens.recordingPen import RecordingPen
            rp = RecordingPen(); gs[g].draw(rp)
            contours, cur = [], []
            for op, args in rp.value:
                cur.append((op, args))
                if op in ("closePath", "endPath"): contours.append(cur); cur = []
            def bounds(c):
                pts = [p for op, a in c for p in a]
                xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
                return min(xs), min(ys), max(xs), max(ys)
            dot = max(contours, key=lambda c: bounds(c)[3])
            bx0, by0, bx1, by1 = bounds(dot)
            cx = x + (bx0 + bx1) / 2 * s; cy = pad + size * 0.78 - (by0 + by1) / 2 * s
            r = (bx1 - bx0) / 2 * s * 1.08
            idot = (cx, cy, r, dot)
        x += gs[g].width * s + (-0.02) * size
    # redraw i without its dot
    out = []
    x = pad
    for ch in "tick":
        g = cmap[ord(ch)]
        pen = SVGPathPen(gs)
        if ch == "i":
            from fontTools.pens.recordingPen import RecordingPen
            rp = RecordingPen(); gs[g].draw(rp)
            contours, cur = [], []
            for op, args in rp.value:
                cur.append((op, args))
                if op in ("closePath", "endPath"): contours.append(cur); cur = []
            body = [c for c in contours if bounds(c) != bounds(idot[3])]
            rp2 = RecordingPen()
            for c in body: rp2.value.extend(c)
            rp2.replay(TransformPen(pen, (s, 0, 0, -s, x, pad + size * 0.78)))
        else:
            gs[g].draw(TransformPen(pen, (s, 0, 0, -s, x, pad + size * 0.78)))
        out.append(f'<path d="{pen.getCommands()}" fill="{fg}"/>')
        x += gs[g].width * s + (-0.02) * size
    cx, cy, r, _ = idot
    out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{VOLT}"/>')
    W, H = x - (-0.02) * size + pad, size * 1.0 + pad
    bgrect = f'<rect width="100%" height="100%" fill="{bg}"/>' if bg else ""
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" width="{W:.0f}" height="{H:.0f}">{bgrect}{"".join(out)}</svg>', (W, H)

for name, fg, bg in (("wordmark-on-ink", PAPER, INK), ("wordmark-on-paper", INK, PAPER)):
    svg, _ = wordmark_with_volt_dot(fg, bg=bg); (LOGO / f"{name}.svg").write_text(svg)
svg, _ = wordmark_with_volt_dot(PAPER); (LOGO / "wordmark-light.svg").write_text(svg)
svg, _ = wordmark_with_volt_dot(INK); (LOGO / "wordmark-dark.svg").write_text(svg)

def icon_svg(rounded=True, size=1024):
    rx = 224 if rounded else 0
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="{size}" height="{size}">
<rect width="1024" height="1024" rx="{rx}" fill="{INK}"/>
<g fill="none" stroke="{VOLT}" stroke-width="116" stroke-linecap="round" stroke-linejoin="round">
<path d="M 340 548 L 474 700 L 772 314"/></g>
<circle cx="326" cy="534" r="80" fill="{VOLT}"/>
</svg>'''
(LOGO / "app-icon.svg").write_text(icon_svg(True))
(LOGO / "app-icon-square.svg").write_text(icon_svg(False))
# splash 1170x2532 ink with wordmark centred
wm, (ww, wh) = wordmark_with_volt_dot(PAPER, size=260, pad=20)
splash = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1170 2532" width="1170" height="2532"><rect width="1170" height="2532" fill="{INK}"/><g transform="translate({(1170-ww)/2:.0f},{(2532-wh)/2:.0f})">{wm.split(">",1)[1].rsplit("</svg>",1)[0]}</g></svg>'
(LOGO / "splash.svg").write_text(splash)

if "--png" in sys.argv:
    from playwright.sync_api import sync_playwright
    import pw
    sizes = {"1024": 1024, "180": 180, "167": 167, "152": 152, "120": 120, "87": 87, "80": 80, "76": 76, "60": 60, "58": 58, "40": 40, "29": 29, "20": 20}
    (LOGO / "ios").mkdir(exist_ok=True)
    with sync_playwright() as p:
        b = pw.launch(p); pg = b.new_page()
        sq = (LOGO / "app-icon-square.svg").read_text()
        for n, s in sizes.items():
            pg.set_viewport_size({"width": s, "height": s})
            pg.set_content(f'<body style="margin:0">{sq.replace("width=\"1024\" height=\"1024\"", f"width=\"{s}\" height=\"{s}\"", 1)}</body>')
            pg.screenshot(path=str(LOGO / "ios" / f"icon-{n}.png"), omit_background=False)
        pg.set_viewport_size({"width": 1170, "height": 2532})
        pg.set_content(f'<body style="margin:0">{(LOGO/"splash.svg").read_text()}</body>')
        pg.screenshot(path=str(LOGO / "splash.png"))
        pg.set_viewport_size({"width": 512, "height": 512})
        pg.set_content(f'<body style="margin:0;background:#888">{(LOGO/"app-icon.svg").read_text().replace("width=\"1024\" height=\"1024\"", "width=\"512\" height=\"512\"", 1)}</body>')
        pg.screenshot(path=str(LOGO / "app-icon-preview.png"), omit_background=True)
        b.close()
print("logo done")
