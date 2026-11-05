"""Tiny PostgREST client using the server-side secret key. Never exposes the key; only used from api/."""
from __future__ import annotations

import httpx

from .config import settings

class Rest:
    def __init__(self) -> None:
        s = settings()
        self.base = s.supabase_url.rstrip("/") + "/rest/v1"
        self.h = {"apikey": s.supabase_secret_key, "Content-Type": "application/json"}
        self.c = httpx.Client(timeout=15)

    def select(self, table: str, **params) -> list[dict]:
        r = self.c.get(f"{self.base}/{table}", headers=self.h, params={k.replace("__", "."): v for k, v in params.items()})
        r.raise_for_status()
        return r.json()

    def insert(self, table: str, row: dict | list[dict], *, upsert_on: str | None = None, returning: bool = True, ignore_duplicates: bool = False, missing_default: bool = False) -> list[dict]:
        res = ",resolution=ignore-duplicates" if ignore_duplicates else (",resolution=merge-duplicates" if upsert_on else "")
        h = {**self.h, "Prefer": ("return=representation" if returning else "return=minimal") + res + (",missing=default" if missing_default else "")}
        r = self.c.post(f"{self.base}/{table}", headers=h, json=row, params={"on_conflict": upsert_on} if upsert_on else None)
        r.raise_for_status()
        return r.json() if returning else []

    def update(self, table: str, match: dict, patch: dict, *, where: dict | None = None) -> list[dict]:
        """PATCH rows matching `match` (equality) and `where` (raw PostgREST filters such as {"claimed_at": "is.null"}).
        Returns the updated rows, so a conditional update doubles as an atomic compare-and-set."""
        h = {**self.h, "Prefer": "return=representation"}
        params = {k: f"eq.{v}" for k, v in match.items()} | (where or {})
        r = self.c.patch(f"{self.base}/{table}", headers=h, json=patch, params=params)
        r.raise_for_status()
        return r.json()

    def delete(self, table: str, match: dict) -> None:
        r = self.c.delete(f"{self.base}/{table}", headers=self.h, params={k: f"eq.{v}" for k, v in match.items()})
        r.raise_for_status()

    def rpc(self, fn: str, args: dict) -> object:
        r = self.c.post(f"{self.base}/rpc/{fn}", headers=self.h, json=args)
        r.raise_for_status()
        return r.json()

_rest: Rest | None = None

def rest() -> Rest:
    global _rest
    if _rest is None:
        _rest = Rest()
    return _rest
