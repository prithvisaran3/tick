#!/usr/bin/env python3
import json, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import contrast_check as cc
t = cc.load(); H = json.loads((ROOT / "design/haptics.json").read_text()); M = json.loads((ROOT / "design/motion.json").read_text())
P = t["palette"]
sw = [("Ink","ink","Background; text in light mode",P["paper"]),("Volt","volt","Money in, safe to spend, primary actions. A fill, never text on Paper",P["ink"]),
      ("Paper","paper","Light background, the Morning Receipt",P["ink"]),("Graphite","graphite","Secondary text on Paper",P["paper"]),
      ("Clay","clay","Outgoing, bills, overspend",P["ink"]),("Sky","sky","Incoming, expected",P["ink"])]
def r(a,b): return f"{cc.ratio(P[a],P[b]):.1f}:1"
cards = "".join(f'<div class="sw" style="background:{P[k]};color:{fg}"><b>{n}</b><span class="m">{P[k]}</span><small>{d}</small></div>' for n,k,d,fg in sw)
pairs = "".join(f'<tr><td>{p["theme"]}</td><td>{p["fg"]} on {p["bg"]}</td><td class="m">{rr:.2f}:1</td><td>{"pass" if ok else "FAIL"}</td></tr>' for p,_,_,rr,ok in cc.results() if p["theme"]!="-")
scale = "".join(f'<div class="row"><span class="m k">{k}</span><span class="t-{k}">{"$214" if v["family"]!="text" else "Safe to spend until Friday"}</span></div>' for k,v in t["type"]["scale"].items())
spr = "".join(f'<tr><td>{k}</td><td class="m">stiffness {v["stiffness"]} · damping {v["damping"]} · mass {v["mass"]}</td></tr>' for k,v in M["springs"].items())
def hrow(k,p):
    ev = p.get("events") or (p.get("tiers") and "3 tiers by amount") or (p.get("variants") and ", ".join(p["variants"])) or p.get("generator",{}).get("kind","")
    return f'<tr><td>{p["number"]}</td><td><b>{p["name"]}</b></td><td>{p["meaning"]}</td></tr>'
hap = "".join(hrow(k,p) for k,p in H["patterns"].items())
html = f'''<!doctype html><html data-theme="dark"><head><meta charset="utf-8"><title>tick brand sheet</title><link rel="stylesheet" href="tokens.css"><style>
*{{box-sizing:border-box;margin:0}}body{{background:var(--ink);color:var(--paper);font-family:Satoshi;font-weight:500;padding:48px;width:1100px}}
h2{{font-family:CabinetGrotesk;font-weight:800;font-size:28px;margin:48px 0 16px;letter-spacing:-.5px}}.m{{font-family:GeistMono;font-size:13px}}
.sws{{display:grid;grid-template-columns:repeat(6,1fr);gap:12px}}.sw{{border-radius:24px;padding:18px;height:170px;display:flex;flex-direction:column;justify-content:flex-end;gap:4px}}.sw small{{font-size:12px;opacity:.85}}
table{{border-collapse:collapse;width:100%;font-size:14px}}td{{padding:7px 10px;border-bottom:1px solid var(--line-dark);vertical-align:top}}
.row{{display:flex;gap:20px;align-items:baseline;padding:6px 0}}.k{{width:90px;color:var(--mist)}}
.sticker{{display:inline-flex;background:var(--volt);color:var(--ink);border-radius:999px;padding:18px 44px;transform:rotate(-2.5deg);font-family:CabinetGrotesk;font-weight:800;font-size:72px;letter-spacing:-2px}}
.grid2{{display:grid;grid-template-columns:1fr 1fr;gap:24px}}.card{{background:var(--ink2);border-radius:24px;padding:24px}}
</style></head><body>
<div style="display:flex;gap:32px;align-items:center"><img src="logo/wordmark-light.svg" height="110"><img src="logo/app-icon.svg" width="140"><img src="logo/ios/icon-180.png" width="90" style="border-radius:20px"></div>
<p style="margin-top:16px;color:var(--mist);width:640px">Night mode meets receipt paper. A deep Ink canvas, one electric Volt, chunky friendly type, round stickers that slap onto things. The name is "Tick" in sentences; the logo is always lowercase.</p>
<h2>Color</h2><div class="sws">{cards}</div>
<p class="m" style="margin-top:12px;color:var(--mist)">Volt on Ink {r("volt","ink")} · Clay on Ink {r("clay","ink")} · Sky on Ink {r("sky","ink")} · Graphite on Paper {r("graphite","paper")} · Volt on Paper {r("volt","paper")} (fill only)</p>
<h2>Every contrast pair (CI-enforced)</h2><div class="card"><table>{pairs}</table></div>
<h2>Type</h2><div class="grid2"><div class="card">{scale}</div><div class="card"><p class="m" style="color:var(--mist)">Display · Cabinet Grotesk Extrabold</p><p class="t-displayL">Hero numbers, headlines, the wordmark.</p><br><p class="m" style="color:var(--mist)">Text · Satoshi</p><p class="t-bodyL">Everything you read. Quick, warm, a little cheeky.</p><br><p class="m" style="color:var(--mist)">Numbers · Geist Mono, tabular</p><p class="t-monoL">−$18.40  +$2,310.00  $1,850.00</p></div></div>
<h2>Sticker</h2><div class="sticker">$214</div>
<h2>Motion</h2><div class="card"><table>{spr}</table><p class="m" style="margin-top:12px;color:var(--mist)">Sticker tilt 2.5°. Stamps slam 1.15 → 1.0. Count-up 1.1 s. Reduce Motion: 150 ms fades.</p></div>
<h2>Haptic language</h2><div class="card"><table>{hap}</table></div>
<h2>Voice</h2><div class="card" style="font-size:18px;line-height:1.7">“Good morning. $214 safe to spend until Friday.”<br>“Caught: $18.40 at Uber.”<br>“Landed. $2,310 from payroll.”<br>“Food is running hot: on pace for $520 vs your $400.”<br>“That didn't go through. Try again, nothing was lost.”<br><span class="m" style="color:var(--mist)">Safe to spend · Morning Receipt · Caught · Landed · Payday plan · Ask Tick</span></div>
</body></html>'''
(ROOT/"design/brand-sheet.html").write_text(html)
from playwright.sync_api import sync_playwright
import pw
with sync_playwright() as p:
    b = pw.launch(p); pg = b.new_page(viewport={"width":1196,"height":900})
    pg.goto(f"file://{ROOT}/design/brand-sheet.html"); pg.wait_for_timeout(400)
    pg.screenshot(path=str(ROOT/"design/exports/brand-sheet.png"), full_page=True); b.close()
print("brand sheet ok")
