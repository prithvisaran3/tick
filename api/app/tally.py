"""Tally share links and the public read-only page.

A link is one group's balances, for a friend who doesn't have Tick: first names and amounts only. The token is 32 random bytes, only its
SHA-256 is stored, it expires (30 days by default, 90 at most), can be revoked, and every view and "I paid" is rate-limited per token and
per address. "I paid" never changes a balance: it arrives as a PENDING settlement that the owner confirms in the app. Tick never moves money."""
from __future__ import annotations

import base64
import hashlib
import html
import re
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, ConfigDict, Field

from .audit import audit
from .auth import RateLimiter, current_user, hash_token, user_limiter
from .config import settings
from .db import rest
from .security import client_ip

router = APIRouter()
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
view_limiter = RateLimiter(40, 60)
paid_limiter = RateLimiter(6, 3600)
MAX_LINKS_PER_GROUP = 5

def simplify(net: dict[str | None, int]) -> list[tuple[str | None, str | None, int]]:
    """Minimum-ish transfers that settle everyone: greedy largest debtor pays largest creditor. net: person -> cents, positive = is owed.
    Same algorithm and tie-breaking as app/lib/domain/tally.dart (shared test vectors keep them identical)."""
    cred = sorted(((p, c) for p, c in net.items() if c > 0), key=lambda x: (-x[1], "me" if x[0] is None else str(x[0])))
    debt = sorted(((p, -c) for p, c in net.items() if c < 0), key=lambda x: (-x[1], "me" if x[0] is None else str(x[0])))
    cred, debt = [list(x) for x in cred], [list(x) for x in debt]
    out: list[tuple[str | None, str | None, int]] = []
    i = j = 0
    while i < len(debt) and j < len(cred):
        pay = min(debt[i][1], cred[j][1])
        out.append((debt[i][0], cred[j][0], pay))
        debt[i][1] -= pay; cred[j][1] -= pay
        if debt[i][1] == 0: i += 1
        if cred[j][1] == 0: j += 1
    return out

def _money(c: int) -> str:
    return f"${abs(c) / 100:,.2f}"

def _first(name: str | None, fallback: str) -> str:
    return (name or "").strip().split(" ")[0][:24] or fallback

class LinkBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    days: int = Field(default=30, ge=1, le=90)

def _group(user_id: str, group_id: str) -> dict:
    if not re.fullmatch(r"[0-9a-f\-]{36}", group_id):
        raise HTTPException(404, "group not found")
    rows = rest().select("tally_groups", id=f"eq.{group_id}", user_id=f"eq.{user_id}", select="id,name,emoji")
    if not rows:
        raise HTTPException(404, "group not found")
    return rows[0]

@router.post("/tally/groups/{group_id}/links")
def create_link(group_id: str, body: LinkBody, request: Request, user_id: str = Depends(current_user)):
    user_limiter.check(f"tallylink:{user_id}", 10, 60)
    _group(user_id, group_id)
    now = datetime.now(timezone.utc)
    live = [l for l in rest().select("tally_links", group_id=f"eq.{group_id}", user_id=f"eq.{user_id}", revoked_at="is.null", select="id,expires_at")
            if datetime.fromisoformat(l["expires_at"].replace("Z", "+00:00")) > now]
    if len(live) >= MAX_LINKS_PER_GROUP:
        raise HTTPException(409, "This group has enough live links. Revoke one first.")
    token = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
    exp = now + timedelta(days=body.days)
    row = rest().insert("tally_links", {"user_id": user_id, "group_id": group_id, "token_hash": hash_token(token), "expires_at": exp.isoformat()})[0]
    audit(user_id, "tally_share", {"scope": "link_created", "count": body.days})
    if not settings().public_base_url:
        raise HTTPException(503, "Sharing isn't set up yet.")    # never build a link from the Host header
    base = settings().public_base_url.rstrip("/")
    return {"id": row["id"], "url": f"{base}/t/{token}", "expires_at": exp.isoformat(), "note": "Shown once. Tick keeps only a fingerprint of it."}

@router.get("/tally/groups/{group_id}/links")
def list_links(group_id: str, user_id: str = Depends(current_user)):
    _group(user_id, group_id)
    return {"links": rest().select("tally_links", group_id=f"eq.{group_id}", user_id=f"eq.{user_id}", select="id,created_at,expires_at,revoked_at,views,last_viewed_at", order="created_at.desc")}

@router.post("/tally/links/{link_id}/revoke")
def revoke_link(link_id: str, user_id: str = Depends(current_user)):
    if not re.fullmatch(r"[0-9a-f\-]{36}", link_id):
        raise HTTPException(404, "link not found")
    rows = rest().update("tally_links", {"id": link_id, "user_id": user_id}, {"revoked_at": datetime.now(timezone.utc).isoformat()})
    if not rows:
        raise HTTPException(404, "link not found")
    audit(user_id, "tally_share", {"scope": "link_revoked"})
    return {"revoked": True}

# ---------------- public page ----------------
def _link(token: str) -> dict | None:
    if not TOKEN_RE.match(token or ""):
        return None
    rows = rest().select("tally_links", token_hash=f"eq.{hash_token(token)}", select="id,user_id,group_id,expires_at,revoked_at,views")
    if not rows or rows[0].get("revoked_at"):
        return None
    if datetime.fromisoformat(rows[0]["expires_at"].replace("Z", "+00:00")) <= datetime.now(timezone.utc):
        return None
    return rows[0]

def _snapshot(link: dict) -> dict:
    uid, gid = link["user_id"], link["group_id"]
    g = rest().select("tally_groups", id=f"eq.{gid}", user_id=f"eq.{uid}", select="name,emoji")[0]
    people = {p["id"]: p for p in rest().select("people", user_id=f"eq.{uid}", select="id,name")}
    members = {m["person_id"] for m in rest().select("tally_members", group_id=f"eq.{gid}", user_id=f"eq.{uid}", select="person_id")}
    net: dict[str | None, int] = {r["person_id"]: int(r["net_cents"]) for r in rest().rpc("tally_balances", {"p_uid": uid, "p_group": gid})}
    prof = rest().select("profiles", user_id=f"eq.{uid}", select="display_name")
    owner = _first(prof[0].get("display_name") if prof else None, "Your friend")
    names = {None: owner, **{pid: _first(people.get(pid, {}).get("name"), "Someone") for pid in members}}
    return {"group": g, "net": net, "names": names, "owner": owner, "members": members}

_CSS = ("body{margin:0;background:#0E0E12;color:#F5F3EC;font:16px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:grid;place-items:start center}"
        "main{width:100%;max-width:440px;padding:32px 20px 56px}h1{font-size:30px;letter-spacing:-.5px;margin:0 0 4px}p{color:#A3A3AF;margin:4px 0 20px}"
        ".card{background:#1B1B22;border-radius:24px;padding:16px 18px;margin:0 0 12px}.row{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:8px 0}"
        ".amt{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.big{font-size:44px;font-weight:800;letter-spacing:-1px}"
        "button{font:inherit;font-weight:700;border:0;border-radius:999px;padding:10px 16px;background:#C8FF2E;color:#0E0E12;cursor:pointer}"
        ".ok{color:#C8FF2E}.small{font-size:13px;color:#A3A3AF}a{color:#7AA7FF}")

def _page(title: str, body: str, status: int = 200) -> HTMLResponse:
    doc = (f"<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
           f"<meta name=robots content='noindex,nofollow,noarchive'><meta name=referrer content=no-referrer><title>{html.escape(title)}</title><style>{_CSS}</style><main>{body}</main></html>")
    r = HTMLResponse(doc, status_code=status)
    r.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    r.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive"
    r.headers["Cache-Control"] = "no-store"
    return r

def _gone() -> HTMLResponse:
    # One message for unknown, expired and revoked links: nothing to learn about which it was.
    return _page("Tally", "<h1>This link isn't working</h1><p>It may have expired. Ask your friend for a new one.</p>", 404)

@router.get("/t/{token}", response_class=HTMLResponse)
def public_page(token: str, request: Request):
    ip = client_ip(request)
    try:
        view_limiter.check(f"v:{ip}")
    except HTTPException:
        return _page("Tally", "<h1>Slow down a little</h1><p>Try again in a minute.</p>", 429)
    link = _link(token)
    if not link:
        return _gone()
    try:
        view_limiter.check(f"vt:{link['id']}", 120, 60)
    except HTTPException:
        return _page("Tally", "<h1>Slow down a little</h1><p>Try again in a minute.</p>", 429)
    snap = _snapshot(link)
    rest().update("tally_links", {"id": link["id"]}, {"views": int(link.get("views") or 0) + 1, "last_viewed_at": datetime.now(timezone.utc).isoformat()})
    return _page("Tally", _render(snap, token, done=False))

def _render(snap: dict, token: str, done: bool) -> str:
    g, net, names, owner = snap["group"], snap["net"], snap["names"], snap["owner"]
    title = f"{html.escape(g.get('emoji') or '')} {html.escape(g['name'])}".strip()
    owes = {p: -c for p, c in net.items() if p is not None and c < 0}           # friends who owe the group (the owner, here)
    owed = {p: c for p, c in net.items() if p is not None and c > 0}
    me = net.get(None, 0)
    out = [f"<h1>{title}</h1>"]
    if done:
        out.append("<div class=card><b class=ok>Thanks!</b><p style='margin:6px 0 0'>That's sent to " + html.escape(owner) + " to confirm. Nothing was paid from here.</p></div>")
    if not owes and not owed:
        out.append("<p>All square ✓</p><div class=card><span class=big>✓</span><p style='margin:6px 0 0'>Nobody owes anybody.</p></div>")
    else:
        out.append(f"<p>Who owes who, kept by {html.escape(owner)}.</p>")
        for frm, to, c in simplify(net):
            out.append(f"<div class=card><div class=row><span>{html.escape(names.get(frm, 'Someone'))} → {html.escape(names.get(to, 'Someone'))}</span><span class='amt big' style='font-size:26px'>{_money(c)}</span></div>")
            if frm is not None and to is None:
                out.append(f"<form method=post action='/t/{html.escape(token)}/paid'><input type=hidden name=person value='{html.escape(frm)}'>"
                           f"<input type=hidden name=amount value='{c}'><button type=submit>I paid {_money(c)}</button></form>"
                           f"<p class=small style='margin:8px 0 0'>Pay {html.escape(owner)} yourself (Zelle, Venmo or cash), then tap this so they know.</p>")
            out.append("</div>")
    out.append("<p class=small>First names and amounts only. This page can't move money.</p>")
    return "".join(out)

@router.post("/t/{token}/paid", response_class=HTMLResponse)
def i_paid(token: str, request: Request, person: str = Form(..., max_length=40), amount: int = Form(..., ge=1, le=100_000_000)):
    ip = client_ip(request)
    link = _link(token)
    if not link:
        return _gone()
    try:
        paid_limiter.check(f"p:{link['id']}", 6, 3600)
        paid_limiter.check(f"pi:{ip}", 12, 3600)
    except HTTPException:
        return _page("Tally", "<h1>That's plenty for now</h1><p>Try again later.</p>", 429)
    snap = _snapshot(link)
    owed = -snap["net"].get(person, 0)
    if person not in snap["members"] or owed <= 0 or amount > owed:
        return _page("Tally", "<h1>That doesn't match</h1><p>The balance changed. Reload the page and try again.</p>", 409)
    already = rest().select("tally_settlements", user_id=f"eq.{link['user_id']}", group_id=f"eq.{link['group_id']}", from_person=f"eq.{person}", status="eq.pending", deleted_at="is.null", select="id")
    if len(already) >= 3:
        return _page("Tally", "<h1>Already sent</h1><p>You've told them. They'll confirm it soon.</p>", 429)
    rest().insert("tally_settlements", {"user_id": link["user_id"], "group_id": link["group_id"], "from_person": person, "to_person": None, "amount_cents": amount,
                                        "method": "other", "status": "pending", "note": "Marked as paid from the share page"}, returning=False)
    return _page("Tally", _render(snap, token, done=True))
