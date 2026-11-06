"""Append-only audit trail (who, what, when). No PII: never amounts, merchants, emails, tokens or account numbers.
Best effort: an audit write must never break the action it records."""
from __future__ import annotations

import logging

from .db import rest

EVENTS = {"sign_in", "token_created", "token_revoked", "tokens_revoked_all", "bank_linked", "bank_removed", "data_deleted",
          "sessions_revoked", "bad_token_burst", "plaid_item_removed", "import_batch", "import_undone", "tally_edit", "tally_share", "tally_deleted"}
_SAFE_KEYS = {"institution", "count", "token_last4", "reason", "scope"}
log = logging.getLogger("tick.audit")

def audit(user_id: str | None, event: str, detail: dict | None = None) -> None:
    if event not in EVENTS:
        raise ValueError(f"unknown audit event {event}")
    clean = {k: v for k, v in (detail or {}).items() if k in _SAFE_KEYS and isinstance(v, (str, int, bool, type(None)))}
    try:
        rest().insert("audit_log", {"user_id": user_id, "event": event, "detail": clean}, returning=False)
    except Exception:
        log.warning("audit write failed for %s", event)
