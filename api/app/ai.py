"""Gemini helpers. Every call has a short timeout, never raises, logs tokens to ai_usage, and returns None on any failure
so callers fall back gracefully (the app never blocks on AI)."""
from __future__ import annotations

import json
import time
from typing import Any

from .config import GEMINI_MODEL, settings
from .db import rest
from .parsers import ParsedAlert

_client = None

def client():
    global _client
    if _client is None:
        from google import genai
        from google.genai import types
        _client = genai.Client(api_key=settings().gemini_api_key, http_options=types.HttpOptions(timeout=8000))
    return _client

def log_usage(user_id: str | None, feature: str, in_tok: int, out_tok: int, ms: int, ok: bool) -> None:
    try:
        rest().insert("ai_usage", {"user_id": user_id, "feature": feature, "model": GEMINI_MODEL, "input_tokens": in_tok, "output_tokens": out_tok, "latency_ms": ms, "ok": ok})
    except Exception:
        pass

def generate(feature: str, user_id: str | None, contents: Any, *, json_out: bool = False, system: str | None = None, temperature: float = 0.2, max_tokens: int = 400) -> str | None:
    """Returns the text (or JSON string), or None on any failure."""
    if not settings().gemini_api_key:
        return None
    t0 = time.time()
    try:
        from google.genai import types
        cfg = types.GenerateContentConfig(temperature=temperature, max_output_tokens=max_tokens, system_instruction=system,
                                          response_mime_type="application/json" if json_out else None)
        r = client().models.generate_content(model=GEMINI_MODEL, contents=contents, config=cfg)
        u = r.usage_metadata
        log_usage(user_id, feature, getattr(u, "prompt_token_count", 0) or 0, getattr(u, "candidates_token_count", 0) or 0, int((time.time() - t0) * 1000), True)
        return r.text
    except Exception:
        log_usage(user_id, feature, 0, 0, int((time.time() - t0) * 1000), False)
        return None

PARSE_SYSTEM = ("You extract a purchase from a bank alert text. Reply with JSON only: "
                '{"amount": number, "merchant": string, "card_last4": string|null, "direction": "out"|"in", "confidence": number between 0 and 1}. '
                "Use confidence below 0.8 if the merchant or amount is unclear. If the text is not a transaction alert, reply {\"amount\": 0}.")

def parse_alert_ai(user_id: str, text: str) -> ParsedAlert | None:
    out = generate("parse_alert", user_id, text[:600], json_out=True, system=PARSE_SYSTEM, temperature=0)
    if not out:
        return None
    try:
        d = json.loads(out)
        amt = float(d.get("amount") or 0)
        if amt <= 0:
            return None
        cents = round(amt * 100)
        return ParsedAlert(-cents if d.get("direction", "out") == "out" else cents, str(d.get("merchant") or ""), None, d.get("card_last4"), None,
                           min(float(d.get("confidence", 0.7)), 0.9), "gemini")
    except Exception:
        return None

def categorize_ai(user_id: str, merchant: str, categories: list[str]) -> tuple[str, str] | None:
    out = generate("categorize", user_id, f"Merchant: {merchant}\nCategories: {', '.join(categories)}", json_out=True,
                   system='Clean the merchant name and pick exactly one category from the list. JSON only: {"merchant": string, "category": string}', temperature=0, max_tokens=100)
    if not out:
        return None
    try:
        d = json.loads(out)
        return (str(d["merchant"]), str(d["category"])) if d.get("category") in categories else None
    except Exception:
        return None

def receipt_extract(user_id: str, image: bytes, mime: str) -> dict | None:
    from google.genai import types
    out = generate("receipt", user_id, [types.Part.from_bytes(data=image, mime_type=mime),
                   "Extract this receipt."], json_out=True, max_tokens=600,
                   system='JSON only: {"merchant": string, "total": number, "date": "YYYY-MM-DD"|null, "tax": number|null, "tip": number|null, "confidence": number 0..1}. total is the amount paid in dollars.')
    if not out:
        return None
    try:
        return json.loads(out)
    except Exception:
        return None
