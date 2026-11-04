#!/usr/bin/env python3
"""AI smoke test: listing models is free; exactly 3 tiny real calls (categorize, parse, tool call), max_tokens 64 each.
Prints models used and results; never prints keys."""
import json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "api"))
from app import ai
p = ai.provider()
print("provider", p.name, "available", p.available())
st = p.status(); print("free models:", json.dumps(st["models"]), "| used today:", st["used"], "of", st["limit"])
if "--list-only" in sys.argv: sys.exit(0)
def show(name, r):
    print(name, "->", None if r is None else {"model": r.model, "text": (r.text or "")[:160], "tool_calls": r.tool_calls})
r1 = p.chat("json", [{"role": "system", "content": ai.CAT_SYSTEM}, {"role": "user", "content": json.dumps({"categories": ["Coffee", "Groceries", "Rideshare", "Other"], "merchants": ["SQ *BLUE BOTTLE COFFEE"]})}], json_out=True, max_tokens=64, feature="smoke_categorize")
show("1 categorize", r1)
r2 = p.chat("json", [{"role": "system", "content": ai.PARSE_SYSTEM}, {"role": "user", "content": ai.scrub("Chase: A $18.40 transaction was made at UBER *TRIP on card ending in 4421.")}], json_out=True, max_tokens=64, feature="smoke_parse")
show("2 parse", r2)
tools = [{"type": "function", "function": {"name": "spend_by_category", "description": "Spending by category this month (cents).", "parameters": {"type": "object", "properties": {}}}}]
r3 = p.chat("tools", [{"role": "user", "content": "How much did I spend by category this month? Use the tool."}], tools=tools, max_tokens=64, feature="smoke_tool")
show("3 tool call", r3)
