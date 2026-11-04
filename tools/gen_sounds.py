#!/usr/bin/env python3
"""Synthesize Tick's two sounds as .caf (16-bit PCM, 44.1 kHz mono, <300 ms) into app/assets/sounds/ and app/ios/Runner/."""
import math, struct, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
SR = 44100

def tone(freq, dur, amp, attack=0.004, decay=0.06, pitch_drop=0.0):
    n = int(SR * dur); out = []; ph = 0.0
    for i in range(n):
        t = i / SR
        f = freq * (1 - pitch_drop * t / dur)
        ph += 2 * math.pi * f / SR
        env = min(1, t / attack) * math.exp(-t / decay)
        out.append(amp * env * (math.sin(ph) + 0.25 * math.sin(2 * ph)))
    return out

def mix(*tracks):
    n = max(len(a) + o for a, o in tracks)
    out = [0.0] * n
    for a, o in tracks:
        for i, v in enumerate(a): out[o + i] += v
    return out

def fade_tail(x, ms=12):
    n = int(SR * ms / 1000)
    for i in range(n): x[-1 - i] *= i / n
    return x

def caf(path, samples):
    peak = max(abs(s) for s in samples) or 1
    data = b"".join(struct.pack("<h", int(max(-1, min(1, s / peak * 0.85)) * 32767)) for s in samples)
    desc = struct.pack(">dIIIIII", float(SR), int.from_bytes(b"lpcm", "big"), 2, 2, 1, 1, 16)  # LE flag=2
    blob = b"caff" + struct.pack(">HH", 1, 0)
    blob += b"desc" + struct.pack(">q", len(desc)) + desc
    blob += b"data" + struct.pack(">q", len(data) + 4) + struct.pack(">I", 0) + data
    path.write_bytes(blob)

pop = fade_tail(mix((tone(520, 0.14, 1.0, decay=0.035, pitch_drop=0.35), 0), (tone(1040, 0.06, 0.25, decay=0.02), 0)))
chime = fade_tail(mix((tone(784, 0.26, 0.8, decay=0.09), 0), (tone(1175, 0.22, 0.8, decay=0.09), int(SR * 0.075))))
for d in (ROOT / "app/assets/sounds",):
    d.mkdir(parents=True, exist_ok=True)
    caf(d / "capture_pop.caf", pop); caf(d / "landed_chime.caf", chime)
    print("sounds ms:", round(len(pop) / SR * 1000), round(len(chime) / SR * 1000))
