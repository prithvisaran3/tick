#!/usr/bin/env python3
"""design/icons/tally/*.svg and app/assets/icons/tally/ from one table. 24px, stroke only; the app tints them from the theme."""
import pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
ICONS = {
 "home": "M3 11l9-7 9 7|M5 10v10h14V10|M10 20v-6h4v6",
 "trip": "M4 8h16v12H4z|M9 8V5h6v3|M8 8v12|M16 8v12",
 "food": "M7 3v18|M4 3v5a3 3 0 0 0 6 0V3|M17 21V3c-2 2-3 5-3 8h3",
 "drinks": "M6 4h12l-6 8z|M12 12v8|M8 20h8",
 "party": "M4 20l4-12 8 8z|M14 6l1-2|M19 9l2-1|M18 4l1 1",
 "groceries": "M3 4h2l3 12h10l2-8H6|C9 20 1.5|C17 20 1.5",
 "rent": "C8 15 4|M11 12l8-8|M16 7l2 2|M14 9l2 2",
 "utilities": "M13 3L5 14h6l-1 7 8-11h-6z",
 "car": "M4 16v-4l2-5h12l2 5v4z|M4 16v2|M20 16v2|C8 13 1|C16 13 1",
 "gym": "M6 7v10|M18 7v10|M3 10v4|M21 10v4|M6 12h12",
 "movie": "M4 9h16v11H4z|M4 9l15-4 1 4|M8 8l-1-3|M13 7l-1-3",
 "concert": "M9 18V6l10-2v12|C6.5 18 2.5|C16.5 16 2.5",
 "coffee": "M5 9h12v6a5 5 0 0 1-5 5h-2a5 5 0 0 1-5-5z|M17 10h2a2 2 0 0 1 0 5h-2|M9 3v3|M13 3v3",
 "gift": "M4 11h16v9H4z|M3 7h18v4H3z|M12 7v13|M12 7c-2-4-6-3-5 0|M12 7c2-4 6-3 5 0",
 "pets": "C7 10 1.6|C12 7 1.6|C17 10 1.6|M8 17c0-3 2-5 4-5s4 2 4 5c0 2-3 2-4 1-1 1-4 1-4-1z",
 "work": "M4 8h16v11H4z|M9 8V5h6v3|M4 13h16",
 "study": "M12 6c-2-2-5-2-8-2v14c3 0 6 0 8 2 2-2 5-2 8-2V4c-3 0-6 0-8 2z|M12 6v14",
 "game": "M7 9h10a4 4 0 0 1 4 4v2a3 3 0 0 1-5 1l-2-2h-4l-2 2a3 3 0 0 1-5-1v-2a4 4 0 0 1 4-4z|M8 11v3|M6.5 12.5h3|M16 12h.01|M18 14h.01",
 "beach": "M12 4a9 9 0 0 1 9 9H3a9 9 0 0 1 9-9z|M12 13v6|M4 21h16",
 "ski": "M3 20l6-11 4 7 3-4 5 8z|M9 9l2 3",
 "camping": "M12 4L3 20h18z|M9 20l3-6 3 6",
 "wedding": "C9 14 5|C15 14 5|M7 4h4l1 2-3 3-3-3z",
 "baby": "M9 8h6v12a1 1 0 0 1-1 1h-4a1 1 0 0 1-1-1z|M10 8V5a2 2 0 0 1 4 0v3|M9 13h6",
 "misc": "C12 12 9|M8 12h.01|M12 12h.01|M16 12h.01",
}
def part(p):
    if p.startswith("C"):
        x, y, r = p[1:].split()
        return f'<circle cx="{x}" cy="{y}" r="{r}"/>'
    return f'<path d="{p}"/>'
for out in (ROOT / "design/icons/tally", ROOT / "app/assets/icons/tally"):
    out.mkdir(parents=True, exist_ok=True)
    for name, d in ICONS.items():
        (out / f"{name}.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">' + "".join(part(p) for p in d.split("|")) + "</svg>\n")
print(len(ICONS), "icons")
