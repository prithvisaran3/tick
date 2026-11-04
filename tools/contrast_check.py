#!/usr/bin/env python3
"""Verify every colour pair declared in design/tokens.json. Exit 1 on any miss."""
import json, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]

def lin(c):
    c /= 255
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

def lum(h):
    h = h.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)

def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)

def load():
    return json.loads((ROOT / "design/tokens.json").read_text())

def resolve(tokens, theme, role):
    return tokens["palette"][tokens["themes"][theme][role]]

def results(tokens=None):
    t = tokens or load()
    out = []
    for p in t["contrast"]:
        fg, bg = resolve(t, p["theme"], p["fg"]), resolve(t, p["theme"], p["bg"])
        r = ratio(fg, bg)
        out.append((p, fg, bg, r, r >= p["min"]))
    for f in t.get("forbidden", []):
        r = ratio(t["palette"][f["fg"]], t["palette"][f["bg"]])
        out.append(({"theme": "-", "fg": f["fg"], "bg": f["bg"], "min": 0, "note": f["note"]},
                    t["palette"][f["fg"]], t["palette"][f["bg"]], r, True))
    return out

if __name__ == "__main__":
    bad = 0
    for p, fg, bg, r, ok in results():
        print(f"{'ok  ' if ok else 'FAIL'} {p['theme']:5} {p['fg']:14} on {p['bg']:9} {r:5.2f}:1 (min {p['min']}) {p['note']}")
        bad += not ok
    sys.exit(1 if bad else 0)
