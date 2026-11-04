#!/usr/bin/env python3
"""design/haptics.json -> app/assets/haptics/*.ahap + manifest.json (Core Haptics AHAP v1)."""
import json, pathlib, random
ROOT = pathlib.Path(__file__).resolve().parents[1]
src = json.loads((ROOT / "design/haptics.json").read_text())
OUT = ROOT / "app/assets/haptics"; OUT.mkdir(parents=True, exist_ok=True)
for f in OUT.glob("*.ahap"): f.unlink()

def r(x): return round(x, 3)
def ev_params(i, s): return [{"ParameterID": "HapticIntensity", "ParameterValue": r(i)},
                             {"ParameterID": "HapticSharpness", "ParameterValue": r(s)}]
def transient(t_ms, i, s):
    return {"Event": {"Time": r(t_ms / 1000), "EventType": "HapticTransient", "EventParameters": ev_params(i, s)}}
def continuous(t_ms, dur_ms, i, s):
    return {"Event": {"Time": r(t_ms / 1000), "EventType": "HapticContinuous",
                      "EventDuration": r(dur_ms / 1000), "EventParameters": ev_params(i, s)}}
def curve(param, points):
    return {"ParameterCurve": {"ParameterID": param, "Time": 0.0,
            "ParameterCurveControlPoints": [{"Time": r(t / 1000), "ParameterValue": r(v)} for t, v in points]}}

def from_events(events):
    pat = []
    for e in events:
        if e["type"] == "transient":
            pat.append(transient(e["t"], e["i"], e["s"]))
        else:
            pat.append(continuous(e["t"], e["duration"], 1.0, e["s"]))
            fade = e.get("fade_to")
            if fade is not None:
                pat.append(curve("HapticIntensityControl", [(e["t"], e["i"]), (e["t"] + e["duration"], fade)]))
            else:
                pat.append(curve("HapticIntensityControl", [(e["t"], e["i"]), (e["t"] + e["duration"], e["i"])]))
    return pat

def lerp(a, b, x): return a + (b - a) * x

def generate(g):
    pat = []
    if g["kind"] == "accelerating_ticks":
        t, n = 0.0, g["count"]
        for k in range(n):
            x = k / (n - 1)
            pat.append(transient(t, lerp(g["i_start"], g["i_end"], x), lerp(g["s_start"], g["s_end"], x)))
            t += lerp(g["interval_start_ms"], g["interval_end_ms"], x)
        f = g["final"]
        pat.append(transient(t - lerp(g["interval_start_ms"], g["interval_end_ms"], 1) + f["gap_ms"], f["i"], f["s"]))
    elif g["kind"] == "randomized_transients":
        rng = random.Random(g["seed"])
        times = sorted(rng.uniform(0, g["span_ms"]) for _ in range(g["count"]))
        for t in times:
            pat.append(transient(t, rng.uniform(g["i_min"], g["i_max"]), rng.uniform(g["s_min"], g["s_max"])))
    else:
        raise ValueError(g["kind"])
    return pat

def write(name, pattern, desc):
    (OUT / f"{name}.ahap").write_text(json.dumps(
        {"Version": 1.0, "Metadata": {"Project": "Tick", "Description": desc}, "Pattern": pattern}, indent=1) + "\n")

manifest = {}
for pid, p in src["patterns"].items():
    def emit(name, body):
        if "events" in body: pat = from_events(body["events"])
        elif "generator" in body: pat = generate(body["generator"])
        elif "continuous_curve" in body:
            c = body["continuous_curve"]
            pat = [continuous(0, c["duration"], 1.0, c["sharpness"]),
                   curve("HapticIntensityControl", [(0, c["from"]), (c["duration"], c["to"])])]
        else: raise ValueError(name)
        write(name, pat, f"{p['name']} / {name}")
        manifest.setdefault(pid, {})[name] = f"haptics/{name}.ahap"
    if "tiers" in p:
        for tier, body in p["tiers"].items(): emit(f"{pid}_{tier}", body)
    elif "variants" in p:
        for v, body in p["variants"].items(): emit(f"{pid}_{v}", body)
    elif "generator" in p: emit(pid, p)
    else: emit(pid, p)
# flat manifest: key = "pattern" or "pattern_variant" -> asset path
flat = {k: v for d in manifest.values() for k, v in d.items()}
(OUT / "manifest.json").write_text(json.dumps({"modes": src["modes"], "patterns": flat}, indent=1) + "\n")
print(f"compiled {len(flat)} AHAP files")
