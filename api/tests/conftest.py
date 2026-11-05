import pytest

from app import security

@pytest.fixture(autouse=True)
def fresh_ip_guard(monkeypatch):
    """Every test starts with clean per-IP counters (TestClient always comes from the same address)."""
    monkeypatch.setattr(security, "ip_guard", security.IpGuard(per_minute=10_000, bad_per_minute=10_000))
