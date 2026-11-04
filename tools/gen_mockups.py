#!/usr/bin/env python3
"""Generate design/mockups/*.html (393x852) and render dark+light PNGs to design/exports/."""
import pathlib, sys, re
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
MOCK = ROOT / "design/mockups"; EXP = ROOT / "design/exports"
MOCK.mkdir(exist_ok=True); EXP.mkdir(exist_ok=True)

def icon(name, size=24):
    s = (ROOT / f"design/icons/{name}.svg").read_text()
    s = re.sub(r'width="\d+"', f'width="{size}"', s, 1); s = re.sub(r'height="\d+"', f'height="{size}"', s, 1)
    return s

CSS = """
*{box-sizing:border-box;margin:0;padding:0}

html,body{width:393px;height:852px;overflow:hidden}
body{background:var(--bg);color:var(--text);font-family:'Satoshi';font-weight:500;font-size:15px;-webkit-font-smoothing:antialiased;position:relative}
.display{font-family:'CabinetGrotesk';font-weight:800;letter-spacing:-.8px}
.mono{font-family:'GeistMono';font-variant-numeric:tabular-nums}
.sec{color:var(--textSecondary)}
.status{height:54px;display:flex;justify-content:space-between;align-items:flex-end;padding:0 30px 8px;font-weight:700;font-size:15px}
.status .r{display:flex;gap:6px;align-items:center}
.status i{display:block;width:17px;height:11px;border-radius:3px;background:currentColor;opacity:.9}
.screen{padding:0 20px;position:absolute;top:54px;left:0;right:0;bottom:0}
.card{background:var(--surface1);border-radius:24px;padding:16px}
.card2{background:var(--surface2);border-radius:24px;padding:16px}
.pill{border-radius:999px}
.sticker{display:inline-flex;align-items:center;justify-content:center;background:var(--accent);color:var(--onAccent);border-radius:999px;transform:rotate(-2.5deg);position:relative;box-shadow:0 10px 30px -10px rgba(200,255,46,.45)}
[data-theme=light] .sticker{box-shadow:0 10px 24px -10px rgba(14,14,18,.35);outline:2px solid var(--ink)}
.sticker.hole::before{content:'';position:absolute;left:22px;top:50%;width:10px;height:10px;margin-top:-5px;border-radius:50%;background:var(--bg)}
.label{font-weight:700;font-size:13px;letter-spacing:.2px;color:var(--textSecondary)}
.row{display:flex;align-items:center}
.tab{position:absolute;left:16px;right:16px;bottom:24px;height:72px;border-radius:999px;background:var(--surface2);display:flex;align-items:center;justify-content:space-around;padding:0 10px;box-shadow:0 12px 30px -12px rgba(0,0,0,.5)}
.tab .t{display:flex;flex-direction:column;align-items:center;gap:3px;font-size:11px;font-weight:700;color:var(--textSecondary);width:58px}
.tab .t.on{color:var(--text)}
.tab .t.on::after{content:'';width:5px;height:5px;border-radius:50%;background:var(--accent);margin-top:1px}
[data-theme=light] .tab .t.on::after{background:var(--ink)}
.tab .t.off::after{display:none}
.fab{width:56px;height:56px;border-radius:50%;background:var(--accent);color:var(--onAccent);display:flex;align-items:center;justify-content:center;transform:translateY(-8px)}
.av{width:40px;height:40px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-family:'CabinetGrotesk';font-weight:800;font-size:17px;flex:none}
.c-food{background:rgba(255,184,77,.18);color:#FFB84D}.c-ride{background:rgba(122,167,255,.18);color:#7AA7FF}
.c-sub{background:rgba(200,160,255,.18);color:#C8A0FF}.c-home{background:rgba(255,107,74,.16);color:#FF8A6E}
.c-biz{background:rgba(163,163,175,.16);color:#A3A3AF}.c-inc{background:rgba(122,167,255,.16);color:#7AA7FF}.c-shop{background:rgba(255,140,200,.16);color:#FF8CC8}
[data-theme=light] .c-food{background:#F7E3C4;color:#8A5200}[data-theme=light] .c-ride{background:#D9E3FA;color:#2A57C0}
[data-theme=light] .c-sub{background:#E8DDF8;color:#6A3DB8}[data-theme=light] .c-home{background:#F6DCD3;color:#B8381A}
[data-theme=light] .c-biz{background:#E6E4DC;color:#3A3A44}[data-theme=light] .c-inc{background:#D9E3FA;color:#2A57C0}[data-theme=light] .c-shop{background:#F6D8E8;color:#9A2F68}
.tx{display:flex;align-items:center;gap:12px;padding:10px 0}
.tx .m{flex:1;min-width:0}.tx .n{font-weight:700;font-size:16px}.tx .s{font-size:13px;color:var(--textSecondary)}
.amt{font-family:'GeistMono';font-weight:500;font-size:16px}
.in{color:var(--moneyIn)}
[data-theme=light] .in{color:var(--ink);font-weight:700}
.exp{color:var(--incoming)}
.chip{white-space:nowrap;flex:none;display:inline-flex;align-items:center;gap:6px;height:34px;padding:0 14px;border-radius:999px;background:var(--surface1);font-weight:700;font-size:13.5px;color:var(--text);border:1px solid var(--hairline)}
.chip.on{background:var(--text);color:var(--bg);border-color:transparent}
.scroll{margin:0 -20px;padding:0 20px;overflow:hidden;white-space:nowrap}
.btn{height:56px;border-radius:999px;background:var(--accent);color:var(--onAccent);display:flex;align-items:center;justify-content:center;font-weight:800;font-size:17px;gap:10px}
.btn.ghost{background:transparent;border:1.5px solid var(--hairline);color:var(--text)}
.h1{font-family:'CabinetGrotesk';font-weight:800;font-size:36px;letter-spacing:-.8px;line-height:1.05}
.sky{color:var(--incoming)}.clay{color:var(--alert)}
.hair{height:1px;background:var(--hairline)}
.seg{display:flex;background:var(--surface2);border-radius:999px;padding:4px;gap:2px}
.seg span{flex:1;text-align:center;height:34px;line-height:34px;border-radius:999px;font-weight:700;font-size:13.5px;color:var(--textSecondary)}
.seg span.on{background:var(--text);color:var(--bg)}
.tog{width:50px;height:30px;border-radius:999px;background:var(--surface2);border:1px solid var(--hairline);position:relative;flex:none}
.tog::after{content:'';position:absolute;top:3px;left:3px;width:22px;height:22px;border-radius:50%;background:var(--textSecondary)}
.tog.on{background:var(--accent);border-color:transparent}.tog.on::after{left:23px;background:var(--onAccent)}
.ic{display:inline-flex}
"""

def page(theme, body, title=""):
    rbg = 'var(--paper)' if theme=='dark' else 'var(--paper2)'
    return f"""<!doctype html><html data-theme="{theme}"><head><meta charset="utf-8"><title>{title}</title>
<link rel="stylesheet" href="../tokens.css"><style>{CSS}[data-theme=dark]{{--rbg:var(--paper)}}[data-theme=light]{{--rbg:var(--paper2)}}</style></head><body data-theme="{theme}">{body}</body></html>"""

def status(): return '<div class="status"><span>9:41</span><span class="r"><i></i><i style="width:22px"></i></span></div>'

def tabbar(active):
    def t(k, name, label):
        return f'<div class="t {"on" if k==active else ""}">{icon(name,24)}<span>{label}</span></div>'
    return f'<div class="tab">{t("today","today","Today")}{t("activity","activity","Activity")}<div class="fab">{icon("plus",28)}</div>{t("flows","flows","Flows")}{t("ask","ask","Ask Tick")}</div>'

def tx(initial, cls, name, sub, amt, inc=False, exp=False, sticker=False):
    sign = "+" if inc else "−"
    a = f'<span class="sticker" style="height:30px;padding:0 12px;font:600 15px GeistMono">{sign}${amt}</span>' if sticker else f'<div class="amt {"exp" if exp else ("in" if inc else "")}">{sign}${amt}</div>'
    return f'<div class="tx"><div class="av {cls}">{initial}</div><div class="m"><div class="n">{name}</div><div class="s">{sub}</div></div>{a}</div>'

def wm(h=26):
    return f'<span class="display" style="font-size:{h}px;letter-spacing:-.6px">t<span style="position:relative">ı<span style="position:absolute;left:50%;top:.02em;width:.2em;height:.2em;margin-left:-.1em;border-radius:50%;background:var(--accent);"></span></span>ck</span>'

# ---------- screens ----------
def back(title): return f'<div class="row" style="height:46px;gap:8px"><span style="font-size:26px;line-height:1">‹</span><span class="sec" style="font-weight:700">{title}</span></div>'

def today():
    return status() + f'''<div class="screen">
<div class="row" style="justify-content:space-between;height:48px">{wm()}<div class="av c-biz" style="width:40px;height:40px;font-size:15px">P</div></div>
<div style="margin-top:8px" class="sec">Good morning, Prithvi.</div>
<div style="margin-top:16px;position:relative;height:144px">
 <div class="sticker hole" style="width:304px;height:128px;flex-direction:column;margin-left:12px;padding-left:16px">
  <div class="display" style="font-size:72px;line-height:.95;letter-spacing:-2.2px">$214</div>
  <div style="font-weight:800;font-size:14.5px;margin-top:4px">Safe to spend until Friday</div></div>
</div>
<div class="row" style="gap:6px;white-space:nowrap"><span class="chip mono" style="font-size:12px;font-weight:500;padding:0 11px">$678 cash</span><span class="chip mono" style="font-size:12px;font-weight:500;padding:0 11px">−$64 bills</span><span class="chip mono" style="font-size:12px;font-weight:500;padding:0 11px">−$400 goals</span></div>
<div class="label" style="margin-top:16px">Today · 2 caught</div>
<div class="card" style="margin-top:8px;padding:0 16px">{tx("B","c-food","Blue Bottle","Chase ••4421 · just now","5.75",sticker=True)}<div class="hair"></div>{tx("U","c-ride","Uber","Apple Pay · 9:12 AM","18.40")}</div>
<div class="row" style="gap:8px;margin-top:8px">
 <div class="card" style="flex:1;padding:12px 16px"><div class="label" style="color:var(--incoming)">Incoming</div><div class="mono" style="font-size:20px;font-weight:600;margin-top:4px">$2,310</div><div class="sec" style="font-size:13px">Payroll · Friday</div></div>
 <div class="card" style="flex:1;padding:12px 16px"><div class="label" style="color:var(--alert)">Upcoming</div><div class="mono" style="font-size:20px;font-weight:600;margin-top:4px">$64</div><div class="sec" style="font-size:13px">Internet · tomorrow</div></div>
</div>
<div class="card2 row" style="margin-top:8px;gap:12px;padding:12px 16px"><div style="flex:1"><div style="font-weight:800;font-size:15.5px">Food is running hot</div><div class="sec" style="font-size:13.5px;margin-top:2px">On pace for $520 vs your $400.</div></div><div style="position:relative;width:72px;height:8px;border-radius:99px;background:var(--hairline)"><div style="width:100%;height:100%;border-radius:99px;background:var(--alert)"></div><div style="position:absolute;left:77%;top:-4px;width:2px;height:16px;background:var(--text)"></div></div><span class="sec" style="font-size:22px">›</span></div>
</div>{tabbar("today")}'''

def receipt():
    lines = [("Whole Foods","42.18"),("Cursor","22.00"),("Chipotle","13.85"),("Trader Joe's","19.40"),("Spotify","10.99")]
    L = "".join(f'<div class="row" style="justify-content:space-between;padding:5px 0"><span>{a}</span><span>−${b}</span></div>' for a,b in lines)
    return status() + f'''<div class="screen" style="padding:0 28px">
<div class="row" style="justify-content:space-between;height:48px"><span class="label">Morning Receipt</span><span class="sec" style="font-size:13px">Yesterday</span></div>
<div style="position:relative;margin-top:8px;background:var(--rbg);color:var(--ink);padding:24px 24px 34px;border-radius:6px 6px 0 0;transform:rotate(-.6deg);box-shadow:0 24px 50px -20px rgba(0,0,0,.6)">
 <div class="display" style="font-size:30px;letter-spacing:-.6px">Yesterday, Tue Nov 3</div>
 <div class="mono" style="font-size:12px;color:var(--graphite);margin-top:4px">5 captures · 2 cards</div>
 <div style="border-top:2px dashed var(--graphite);margin:16px 0 8px;opacity:.5"></div>
 <div class="mono" style="font-size:14.5px;line-height:1.3">{L}</div>
 <div style="border-top:2px dashed var(--graphite);margin:8px 0 16px;opacity:.5"></div>
 <div class="row" style="justify-content:space-between;align-items:baseline"><span class="mono" style="font-size:13px;color:var(--graphite)">Total spent</span><span class="display" style="font-size:44px;letter-spacing:-1.2px">$108.42</span></div>
 <div class="row" style="justify-content:space-between;align-items:baseline;margin-top:8px"><span class="mono" style="font-size:13px;color:var(--graphite)">Safe to spend</span><span class="mono" style="font-size:20px;font-weight:600;background:var(--accent);padding:2px 12px;border-radius:99px">$214</span></div>
 <div style="margin-top:16px;margin-bottom:48px;font-size:15px;line-height:1.4">Groceries led the day. Skip one coffee run and Friday gets easier.</div>
 <div class="sticker" style="position:absolute;right:16px;bottom:28px;height:44px;padding:0 20px;transform:rotate(-8deg);font-family:'CabinetGrotesk';font-weight:800;font-size:22px;box-shadow:none;outline:3px solid var(--ink);outline-offset:-3px">Ticked.</div>
 <div style="position:absolute;left:0;right:0;bottom:-12px;height:12px;background:conic-gradient(from -45deg at bottom,#0000 90deg,var(--rbg) 0) 50%/14px 100%;transform:scaleY(-1)"></div>
</div>
<div style="margin-top:28px;text-align:center" class="sec"><span class="row" style="justify-content:center;gap:8px">{icon("share",20)} Tear off to share</span></div>
<div style="position:absolute;left:28px;right:28px;bottom:44px" class="btn">Show me today</div>
</div>'''

def activity():
    return status() + f'''<div class="screen">
<div class="row" style="justify-content:space-between;height:48px"><div class="h1">Activity</div><div class="chip" style="height:36px">{icon("caught",18)} 3 to check</div></div>
<div class="row pill" style="margin-top:8px;height:48px;background:var(--surface1);padding:0 16px;gap:8px;color:var(--textSecondary)">{icon("search",20)}<span>Search merchants, notes</span></div>
<div class="scroll" style="margin-top:12px"><div class="row" style="gap:8px"><span class="chip on">All</span><span class="chip">Business</span><span class="chip">Needs review</span><span class="chip">Food</span><span class="chip">Chase</span><span class="chip">Apple Card</span></div></div>
<div class="row" style="justify-content:space-between;margin-top:16px"><span class="label">Today</span><span class="mono sec" style="font-size:13px">−$24.15</span></div>
{tx("B","c-food","Blue Bottle","Coffee · Chase ••4421","5.75")}{tx("U","c-ride","Uber","Rideshare · Apple Pay","18.40")}
<div class="row" style="justify-content:space-between;margin-top:8px"><span class="label">Yesterday</span><span class="mono sec" style="font-size:13px">−$108.42</span></div>
{tx("W","c-food","Whole Foods","Groceries · Chase ••4421","42.18")}{tx("C","c-biz","Cursor","Business · Subscriptions","22.00")}{tx("C","c-food","Chipotle","Restaurants · Apple Card","13.85")}
<div class="row" style="justify-content:space-between;margin-top:8px"><span class="label">Fri Oct 23</span><span class="mono sec" style="font-size:13px">+$2,310.00</span></div>
{tx("P","c-inc","Payroll","Income · Checking ••1180","2,310.00",True)}
</div>{tabbar("activity")}'''

def caught():
    return status() + f'''<div class="screen">
<div class="row" style="justify-content:space-between;height:48px"><div class="row" style="gap:6px"><span style="font-size:30px;line-height:1">‹</span><div class="h1">Caught</div></div><span class="sec">3 to check</span></div>
<div style="position:relative;margin-top:24px;height:452px">
 <div class="card2" style="position:absolute;left:0;right:0;top:0;height:410px;transform:translateY(32px) scale(.90) rotate(-2deg);opacity:.55"></div>
 <div class="card2" style="position:absolute;left:0;right:0;top:0;height:410px;transform:translateY(16px) scale(.95) rotate(2deg);opacity:.8"></div>
 <div class="card" style="position:absolute;left:0;right:0;top:0;height:410px;background:var(--surface2);padding:24px;border:1px solid var(--hairline);box-shadow:0 30px 50px -24px rgba(0,0,0,.6)">
  <div class="label">Apple Pay · 9:12 AM</div>
  <div style="margin-top:16px"><div class="sticker hole" style="height:100px;padding:0 40px 0 52px"><span class="display" style="font-size:54px;letter-spacing:-1.5px">$18.40</span></div></div>
  <div class="display" style="font-size:30px;margin-top:24px">Uber</div>
  <div class="sec" style="margin-top:4px">Chase ••4421</div>
  <div class="row" style="gap:8px;margin-top:16px"><span class="chip">Rideshare</span><span class="chip">+ Business</span></div>
  <div class="card" style="margin-top:24px;padding:12px 16px;background:var(--surface1)"><div class="label">Why check</div><div style="margin-top:4px;font-size:14.5px">Merchant text was messy. 72% sure it's Uber.</div></div>
 </div></div>
<div class="row" style="justify-content:space-around;margin-top:16px">
 <div style="text-align:center"><div class="av" style="width:56px;height:56px;background:var(--surface2);color:var(--text)">{icon("edit",24)}</div><div class="sec" style="font-size:13px;margin-top:8px;font-weight:700">Fix it</div></div>
 <div style="text-align:center"><div class="av" style="width:56px;height:56px;background:var(--surface2);color:var(--text)">{icon("briefcase",24)}</div><div class="sec" style="font-size:13px;margin-top:8px;font-weight:700">Business</div></div>
 <div style="text-align:center"><div class="av" style="width:56px;height:56px;background:var(--accent);color:var(--onAccent)">{icon("check",26)}</div><div class="sec" style="font-size:13px;margin-top:8px;font-weight:700">Looks right</div></div>
</div></div>'''

def ask():
    bars = "".join(f'<div style="flex:1;height:{h}px;border-radius:8px;background:var(--text);opacity:{o}"></div>' for h,o in [(22,.25),(40,.25),(30,.25),(56,.25),(70,.25),(44,1)])
    return status() + f'''<div class="screen">
<div class="row" style="justify-content:space-between;height:48px"><div class="h1">Ask Tick</div></div>
<div style="display:flex;justify-content:flex-end;margin-top:8px"><div style="background:var(--surface2);padding:12px 16px;max-width:270px;border-radius:22px 22px 8px 22px">How much did I spend on food this month?</div></div>
<div style="margin-top:16px">
 <div class="display" style="font-size:52px;letter-spacing:-1.5px">$412</div>
 <div style="font-size:16.5px;margin-top:2px">on food so far this month. That's $58 over last month at this point.</div>
 <div class="card" style="margin-top:16px"><div class="row" style="align-items:flex-end;gap:8px;height:80px">{bars}</div><div class="row mono sec" style="justify-content:space-between;font-size:11.5px;margin-top:8px"><span>Wk 1</span><span>Wk 2</span><span>Wk 3</span><span>Wk 4</span><span>Wk 5</span><span>Now</span></div></div>
 <div class="card" style="margin-top:8px;padding:0 16px">{tx("W","c-food","Whole Foods","Biggest · Tue","42.18")}<div class="hair"></div>{tx("C","c-food","Chipotle","Tue","13.85")}</div>
</div>
<div class="scroll" style="margin-top:16px"><div class="row" style="gap:8px"><span class="chip">What's due this week?</span><span class="chip">Business total</span><span class="chip">Subscriptions</span></div></div>
<div class="row pill" style="position:absolute;left:20px;right:20px;bottom:112px;height:52px;background:var(--surface2);padding:0 8px 0 16px;color:var(--textSecondary)"><span style="flex:1">Ask anything about your money</span><div class="av" style="width:40px;height:40px;background:var(--accent);color:var(--onAccent)">{icon("arrow-up",20)}</div></div>
</div>{tabbar("ask")}'''

def flows():
    cats = [("Rent","$1,850",100),("Food","$412",22),("Subscriptions","$146",8),("Rideshare","$96",5)]
    B = "".join(f'<div style="margin-top:12px"><div class="row" style="justify-content:space-between;font-weight:700"><span>{n}</span><span class="mono" style="font-weight:500">{a}</span></div><div style="height:8px;border-radius:99px;background:var(--surface2);margin-top:8px"><div style="width:{w}%;height:100%;border-radius:99px;background:var(--text);opacity:.85"></div></div></div>' for n,a,w in cats)
    lv=[.25,.5,.2,.4,.9,.3,0,.6]
    cells=[]
    for d in range(1,31):
        if d<=4:
            v=lv[(d*3)%8]; st=f'background:var(--text);opacity:{max(v,.15)}'
        else: st='border:1px dashed var(--hairline)'
        if d==4: st+=';outline:2px solid var(--text);outline-offset:1px'
        cells.append(f'<div style="aspect-ratio:1.9;border-radius:7px;{st}"></div>')
    wk="".join(f'<span class="sec" style="font-size:11px;text-align:center">{c}</span>' for c in "SMTWTFS")
    heat="".join(cells)
    return status() + f'''<div class="screen">
<div class="row" style="justify-content:space-between;height:48px"><div class="h1">Flows</div><span class="chip">November</span></div>
<div style="margin-top:8px"><div class="label">Left this month</div><div class="display" style="font-size:56px;letter-spacing:-1.5px;line-height:1.05">+$1,440</div>
<div class="row mono" style="gap:16px;font-size:14px;margin-top:4px"><span>In <span class="in">$4,620</span></span><span>Out $3,180</span></div></div>
<div class="card" style="margin-top:16px"><div class="row" style="justify-content:space-between"><span style="font-weight:800">Where it went</span><span class="sec" style="font-size:13px">vs Oct: −6%</span></div>{B}</div>
<div class="card" style="margin-top:8px;padding:12px 16px"><div style="display:grid;grid-template-columns:repeat(7,1fr);gap:5px">{wk}{heat}</div></div>
<div class="card2 row" style="margin-top:8px;justify-content:space-between;padding:12px 16px"><div class="row" style="gap:8px">{icon("briefcase",22)}<span style="font-weight:800">Business</span></div><span class="mono" style="font-size:20px;font-weight:600">$184</span></div>
</div>{tabbar("flows")}'''

def incoming():
    return status() + f'''<div class="screen">
<div class="row" style="justify-content:space-between;height:48px"><div class="row" style="gap:6px"><span style="font-size:30px;line-height:1">‹</span><div class="h1">Coming up</div></div></div>
<div class="card row" style="margin-top:8px;gap:16px;background:var(--accent);color:var(--onAccent)"><div style="transform:rotate(-6deg);border:3px solid var(--onAccent);border-radius:999px;padding:6px 16px;font-family:'CabinetGrotesk';font-weight:800;font-size:20px">Landed.</div><div style="font-weight:800;font-size:15.5px">$40 from Alex.</div></div>
<div class="label" style="margin-top:24px;color:var(--incoming)">Incoming · $2,334</div>
<div class="card" style="margin-top:8px;padding:0 16px">
{tx("P","c-inc","Payroll","Fri Nov 6 · biweekly","2,310.00",True,True)}<div class="hair"></div>{tx("A","c-inc","Amazon refund","Expected Nov 8","24.00",True,True)}</div>
<div class="label" style="margin-top:24px;color:var(--alert)">Upcoming · $1,934</div>
<div class="card" style="margin-top:8px;padding:0 16px">
{tx("R","c-home","Rent","Mon Nov 9","1,850.00")}<div class="hair"></div>{tx("I","c-home","Internet","Tomorrow","64.00")}<div class="hair"></div>
<div class="tx"><div class="av c-sub">C</div><div class="m"><div class="n">Claude</div><div class="s" style="color:var(--alert)">Price went up · was $18</div></div><div class="amt">−$20.00</div></div></div>
</div>'''

def settings(theme="dark"):
    def r(icn, t, right): return f'<div class="row" style="justify-content:space-between;height:48px"><div class="row" style="gap:12px">{icon(icn,22)}<span style="font-weight:700">{t}</span></div>{right}</div>'
    th = ["","",""]; th[{"dark":1,"light":2}[theme]] = "on"
    return status() + f'''<div class="screen">
<div class="row" style="height:48px"><div class="h1">Settings</div></div>
<div class="card row" style="margin-top:8px;gap:16px;padding:12px 16px"><div class="av c-biz" style="width:48px;height:48px;font-size:20px">P</div><div><div style="font-weight:800;font-size:18px">Prithvi</div><div class="sec" style="font-size:13.5px">Signed in with Google</div></div></div>
<div class="card" style="margin-top:8px;padding:0 16px">{r("lock","Face ID lock",'<div class="tog on"></div>')}<div class="hair"></div>{r("eye-off","Privacy blur",'<div class="tog on"></div>')}</div>
<div class="card" style="margin-top:8px;padding:12px 16px"><div class="label">Haptics</div><div class="seg" style="margin-top:8px"><span class="on">Full</span><span>Subtle</span><span>Off</span></div><div class="row" style="justify-content:space-between;height:44px;margin-top:8px"><span style="font-weight:700">Sound</span><div class="tog on"></div></div><div class="label" style="margin-top:4px">Theme</div><div class="seg" style="margin-top:8px"><span class="{th[0]}">System</span><span class="{th[1]}">Dark</span><span class="{th[2]}">Light</span></div></div>
<div class="card" style="margin-top:8px;padding:0 16px">{r("bank","Bank connections",'<span class="mono sec" style="font-size:13px">3 of 10 used</span>')}<div class="hair"></div>{r("receipt","Capture token",'<span class="mono sec" style="font-size:13px">tk_••••9f2a</span>')}<div class="hair"></div>{r("settings","Categories and rules",'<span class="sec">›</span>')}</div>
<div class="card" style="margin-top:8px;padding:0 16px">{r("share","Export CSV",'<span class="sec">›</span>')}<div class="hair"></div>{r("trash","Delete all data",'<span style="color:var(--alert);font-weight:700;font-size:13px">Hold</span>')}<div class="hair"></div>{r("play","Demo mode",'<div class="tog"></div>')}</div>
</div>'''

def pad():
    keys = "".join(f'<div class="row" style="justify-content:center;height:52px;font-family:GeistMono;font-size:26px;font-weight:500">{k}</div>' for k in "123456789.0⌫")
    return f'<div style="display:grid;grid-template-columns:repeat(3,1fr);margin-top:8px">{keys}</div>'

def onb(step):
    dots = "".join(f'<span style="width:{24 if i==step else 8}px;height:8px;border-radius:99px;background:{"var(--text)" if i==step else "var(--hairline)"}"></span>' for i in range(3))
    head = f'<div class="row" style="justify-content:space-between;height:48px">{wm(24)}<div class="row" style="gap:6px">{dots}</div></div>'
    if step == 0:
        body = f'''<div style="margin:56px auto 0;width:300px"><div class="sticker hole" style="width:300px;height:140px;flex-direction:column;padding-left:16px"><div class="display" style="font-size:70px;letter-spacing:-2px;line-height:.95">$214</div><div style="font-weight:800;font-size:14px;margin-top:4px">Safe to spend until Friday</div></div></div>
<div class="h1" style="font-size:42px;margin-top:48px">Know where you stand in three seconds.</div>
<div class="sec" style="margin-top:16px;font-size:16.5px">Tick catches every purchase and tells you what's safe to spend until payday.</div>
<div style="position:absolute;left:20px;right:20px;bottom:44px"><div class="btn" style="background:var(--text);color:var(--bg)"><b style="font-family:CabinetGrotesk;font-size:22px">G</b> Continue with Google</div><div class="sec" style="text-align:center;font-size:13px;margin-top:16px">Your data stays yours. Only you can read it.</div></div>'''
    elif step == 1:
        body = f'''<div class="h1" style="margin-top:24px">When do you get paid?</div>
<div class="seg" style="margin-top:16px"><span>Weekly</span><span class="on">Biweekly</span><span>Twice a month</span><span>Monthly</span></div>
<div class="row" style="gap:8px;margin-top:16px"><span class="chip on">Fri Nov 6</span><span class="chip">Fri Nov 13</span><span class="chip">Pick date</span></div>
<div style="text-align:center;margin-top:16px"><div class="sticker" style="height:88px;padding:0 40px"><span class="display" style="font-size:52px;letter-spacing:-1.5px">$2,310</span></div><div class="sec" style="margin-top:8px;font-size:13px">Take-home per paycheck</div></div>
{pad()}<div class="btn" style="position:absolute;left:20px;right:20px;bottom:44px">Add</div>'''
    else:
        body = f'''<div class="h1" style="margin-top:24px">The big stuff.</div><div class="sec" style="margin-top:8px">Rent and a goal is plenty. Add the rest any time.</div>
<div class="card" style="margin-top:24px;padding:0 16px"><div class="tx"><div class="av c-home">R</div><div class="m"><div class="n">Rent</div><div class="s">Monthly · the 1st</div></div><div class="amt">−$1,850</div></div><div class="hair"></div><div class="tx"><div class="av" style="border:1.5px dashed var(--hairline);color:var(--text)">{icon("plus",20)}</div><div class="m"><div class="n sec">Add a bill or subscription</div></div></div><div class="hair"></div><div class="tx"><div class="av c-biz">{icon("goal",20)}</div><div class="m"><div class="n">Savings</div><div class="s">Each payday</div></div><div class="amt">$400</div></div></div>
<div style="position:absolute;left:20px;right:20px;bottom:44px"><div class="btn">Add</div><div class="btn ghost" style="margin-top:8px;height:52px">Start with demo data</div><div class="sec" style="text-align:center;margin-top:16px;font-weight:700">Skip for now</div></div>'''
    return status() + f'<div class="screen">{head}{body}</div>'

SCREENS = {"today": today, "morning-receipt": receipt, "activity": activity, "caught": caught, "ask-tick": ask,
           "flows": flows, "incoming-upcoming": incoming, "settings": settings,
           "onboarding-1": lambda: onb(0), "onboarding-2": lambda: onb(1), "onboarding-3": lambda: onb(2)}

if __name__ == "__main__":
    from playwright.sync_api import sync_playwright
    import pw
    only = sys.argv[1:] 
    with sync_playwright() as p:
        b = pw.launch(p)
        pg = b.new_page(viewport={"width": 393, "height": 852}, device_scale_factor=2)
        for name, fn in SCREENS.items():
            if only and name not in only: continue
            for theme in ("dark", "light"):
                html = page(theme, fn(theme) if name=="settings" else fn(), name)
                f = MOCK / f"{name}.{theme}.html"; f.write_text(html)
                pg.goto(f"file://{f}"); pg.wait_for_timeout(250)
                pg.screenshot(path=str(EXP / f"{name}.{theme}.png"))
        b.close()
    print("mockups rendered")
