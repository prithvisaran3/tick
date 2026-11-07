"""In-memory stand-in for app.db.Rest with the PostgREST semantics the API relies on: eq/is/in/lt/gte/lte/or filters, unique keys
(409 on conflict, ignore-duplicates, merge upserts) and atomic conditional PATCH. Every call holds one lock, like a single DB statement."""
from __future__ import annotations

import threading
import uuid
from datetime import date, datetime, timedelta

import httpx

UNIQUE = {"ask_memory": [("user_id", "kind", "key")], "connections": [("provider", "item_id")], "plaid_items": [("item_id",)], "plaid_link_sessions": [("link_token",)],
          "plaid_slots": [("user_id",)], "accounts": [("user_id", "provider_account_id")], "ingest_tokens": [("token_hash",)]}
PK = {"plaid_items": "item_id", "plaid_link_sessions": "link_token", "plaid_slots": "user_id"}

def _conflict() -> httpx.HTTPStatusError:
    req = httpx.Request("POST", "http://fake")
    return httpx.HTTPStatusError("409", request=req, response=httpx.Response(409, request=req))

def _cmp(a, b):
    try:
        return datetime.fromisoformat(str(a)) , datetime.fromisoformat(str(b))
    except ValueError:
        return a, b

def _match_one(row: dict, key: str, cond: str) -> bool:
    op, _, val = cond.partition(".")
    v = row.get(key)
    if op == "not":
        return not _match_one(row, key, val)
    if op == "eq":
        return str(v) == val if v is not None else False
    if op == "neq":
        return str(v) != val
    if op == "is":
        return v is None if val == "null" else str(v).lower() == val
    if op == "in":
        return str(v) in val.strip("()").split(",")
    if op == "like":
        return v is not None and str(v).startswith(val.rstrip("*"))
    if v is None:
        return False
    x, y = _cmp(v, val)
    return {"lt": x < y, "lte": x <= y, "gt": x > y, "gte": x >= y}[op]

def _match(row: dict, params: dict) -> bool:
    for k, cond in params.items():
        if k in ("select", "order", "limit", "on_conflict"):
            continue
        if k == "or":
            parts = cond.strip("()").split(",")
            if not any(_match_one(row, p.split(".", 1)[0], p.split(".", 1)[1]) for p in parts):
                return False
        elif not _match_one(row, k, cond):
            return False
    return True

class FakeRest:
    def __init__(self) -> None:
        self.t: dict[str, list[dict]] = {}
        self.lock = threading.RLock()
        self.vault: dict[str, tuple[str, str]] = {}      # id -> (name, value)
        self.rpcs: list[str] = []

    def rows(self, table: str) -> list[dict]:
        return self.t.setdefault(table, [])

    def select(self, table: str, **params) -> list[dict]:
        with self.lock:
            out = [dict(r) for r in self.rows(table) if _match(r, {k.replace("__", "."): v for k, v in params.items()})]
            sel = params.get("select")
            if sel and sel != "*" and "(" not in sel:
                cols = sel.split(",")
                out = [{c: r.get(c) for c in cols} for r in out]
            return out

    def _dupe(self, table: str, row: dict) -> dict | None:
        for cols in UNIQUE.get(table, []):
            if any(row.get(c) is None for c in cols):
                continue
            for r in self.rows(table):
                if all(r.get(c) == row.get(c) for c in cols):
                    return r
        return None

    def insert(self, table, row, *, upsert_on=None, returning=True, ignore_duplicates=False, missing_default=False):
        with self.lock:
            out = []
            if isinstance(row, list) and row and not missing_default:
                # PostgREST: a bulk insert whose objects carry different keys is refused (PGRST102). Reproduced so the sync can't regress.
                if any(set(r) != set(row[0]) for r in row):
                    req = httpx.Request("POST", "http://fake")
                    raise httpx.HTTPStatusError("400", request=req, response=httpx.Response(400, request=req))
            for r in (row if isinstance(row, list) else [row]):
                r = dict(r)
                if table not in PK:
                    r.setdefault("id", str(uuid.uuid4()))
                d = self._dupe(table, r)
                if d is not None:
                    if ignore_duplicates:
                        continue
                    if upsert_on:
                        d.update(r); out.append(dict(d)); continue
                    raise _conflict()
                self.rows(table).append(r)
                out.append(dict(r))
            return out if returning else []

    def update(self, table, match, patch, *, where=None):
        with self.lock:
            params = {k: f"eq.{v}" for k, v in match.items()} | (where or {})
            out = []
            for r in self.rows(table):
                if _match(r, params):
                    r.update(patch); out.append(dict(r))
            return out

    def delete(self, table, match):
        with self.lock:
            self.t[table] = [r for r in self.rows(table) if not _match(r, {k: f"eq.{v}" for k, v in match.items()})]

    def rpc(self, fn, args):
        with self.lock:
            self.rpcs.append(fn)
            if fn == "pay_period":                  # biweekly only: the real maths is in SQL and tested there
                st = next((s for s in self.rows("settings") if s.get("user_id") == args["p_user"]), None)
                r = (st or {}).get("payday_rule")
                if not r:
                    return []
                a, on = date.fromisoformat(r["next_date"]), date.fromisoformat(args["p_date"])
                prev = a + timedelta(days=((on - a).days // 14) * 14)
                return [{"period_start": prev.isoformat(), "period_end": (prev + timedelta(days=13)).isoformat(), "next_payday": (prev + timedelta(days=14)).isoformat()}]
            if fn in ("tick_vault_put", "tick_vault_upsert"):
                for sid, (name, _) in self.vault.items():
                    if name == args["secret_name"]:
                        if fn == "tick_vault_put":
                            raise _conflict()
                        self.vault[sid] = (name, args["secret_value"]); return sid
                sid = str(uuid.uuid4()); self.vault[sid] = (args["secret_name"], args["secret_value"]); return sid
            if fn == "tick_vault_get":
                return self.vault.get(args["secret_id"], (None, None))[1]
            raise NotImplementedError(fn)
