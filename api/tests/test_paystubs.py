"""Pay statements: the ADP parser on an authored fixture (layout ASSUMED), the to-the-cent check, personal details out before any AI call, dedupe, deposit matching."""
import pathlib
from datetime import date

import pytest
from fastapi.testclient import TestClient

from app import ai, audit as audit_mod, imports as I, paystubs as P
from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

D = pathlib.Path(__file__).parent / "data"
RAW = (D / "paystub_adp.pdf").read_bytes()
U = "11111111-1111-1111-1111-111111111111"

def test_adp_layout_is_read_line_by_line():
    s = P.parse_adp(P.pdf_text(RAW))
    assert (s.employer, s.pay_date, s.period_start, s.period_end) == ("ACME ROBOTICS INC", date(2026, 11, 13), date(2026, 10, 26), date(2026, 11, 8))
    assert (s.gross_cents, s.taxes_cents, s.deductions_cents, s.net_cents) == (373500, 87883, 37910, 247707)
    assert [l.label for l in s.lines if l.kind == "tax"] == ["Federal Income Tax", "Social Security Tax", "Medicare Tax", "NY State Income Tax", "NY SDI Tax"]
    assert [l.label for l in s.lines if l.kind == "deduction"] == ["401(K)", "Medical", "Dental", "Vision", "HSA"]
    assert next(l for l in s.lines if l.label == "401(K)").ytd_cents == 436860
    assert s.ytd["gross"] == 7281000 and s.adds_up

def test_a_statement_that_does_not_add_up_is_flagged():
    s = P.parse_adp(P.pdf_text(RAW))
    s.net_cents += 2
    assert not s.adds_up
    s.net_cents -= 1
    assert s.adds_up                                                    # within a cent

def test_detects_a_pay_statement_and_not_a_bank_statement():
    assert P.looks_like_paystub(P.pdf_text(RAW))
    assert not P.looks_like_paystub("CHASE checking statement Beginning balance Ending balance Deposits")

def test_personal_details_never_reach_the_ai():
    t = P.strip_pii(P.pdf_text(RAW), ["Jordan Sample"])
    for leak in ("JORDAN", "SAMPLE", "123 MAPLE", "ALBANY", "12207", "004512", "1234"):
        assert leak not in t
    assert "Federal Income Tax" in t and "3,735.00" in t

def test_the_ai_path_sends_stripped_text_only(monkeypatch):
    sent = {}
    def gen(feature, user_id, contents, **k):
        sent["c"] = contents
        return '{"employer": "Other Co", "pay_date": "2026-11-13", "gross": 1000, "net": 700, "earnings": [{"label": "Regular", "amount": 1000}], "taxes": [{"label": "Federal", "amount": 200}], "deductions": [{"label": "401k", "amount": 100}]}'
    monkeypatch.setattr(ai, "generate", gen)
    s = P.parse_with_ai(U, "Pay Statement Jordan Sample SSN 123-45-6789 Employee ID 9 Gross 1000 Net 700", ["Jordan Sample"])
    assert s.adds_up and s.source == "ai" and s.net_cents == 70000
    assert "123-45-6789" not in sent["c"] and "Jordan" not in sent["c"]

def test_no_text_layer_is_refused_rather_than_sent_as_an_image():
    with pytest.raises(P.PaystubError, match="no text"):
        P.read(U, (D / "paystub_blank.pdf").read_bytes(), [])

def test_deposit_matching():
    s = P.Statement(employer="ACME", pay_date=date(2026, 11, 13), net_cents=247707)
    rows = [{"id": "a", "amount_cents": 247707, "occurred_at": "2026-11-17T15:00:00+00:00", "account_id": "chase"},
            {"id": "b", "amount_cents": 247650, "occurred_at": "2026-11-13T15:00:00+00:00", "account_id": "chase"},
            {"id": "c", "amount_cents": 247707, "occurred_at": "2026-11-13T15:00:00+00:00", "account_id": "sofi"}]
    assert P.match_deposit(s, rows, "chase")["id"] == "b"                  # within $1 and 3 days, in the pay account
    assert P.match_deposit(s, rows, None)["id"] == "c"                     # no pay account set: the exact one wins
    assert P.match_deposit(s, rows[:1], "chase") is None                   # 4 days out

@pytest.fixture
def api(monkeypatch):
    f = FakeRest()
    for m in (I, audit_mod):
        monkeypatch.setattr(m, "rest", lambda: f)
    from app.auth import user_limiter
    user_limiter.hits.clear()
    f.insert("profiles", {"user_id": U, "display_name": "Jordan Sample"})
    f.insert("settings", {"user_id": U, "payday_rule": {"frequency": "biweekly", "next_date": "2026-11-13", "account_id": "chase"}, "keep_pay_pdfs": False})
    f.insert("transactions", {"id": "dep", "user_id": U, "amount_cents": 247707, "occurred_at": "2026-11-13T15:00:00+00:00", "account_id": "chase"})
    f.insert("expected", {"id": "e", "user_id": U, "kind": "paycheck", "status": "expected", "expected_date": "2026-11-27", "amount_cents": 231000})
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def post(c, raw=RAW, **form):
    return c.post("/import/statement", files={"file": ("statement.pdf", raw, "application/pdf")}, data=form)

def test_preview_then_commit_links_the_deposit_and_sets_the_next_expected_pay(api):
    f, c = api
    j = post(c).json()
    assert (j["source"], j["net_cents"], j["adds_up"]) == ("paystub", 247707, True) and f.rows("pay_statements") == []
    j = post(c, mode="commit").json()
    st = f.rows("pay_statements")[0]
    assert j["imported"] == 1 and st["matched_txn"] == "dep" and st["status"] == "ok"
    assert len(f.rows("pay_statement_lines")) == 12
    assert next(t for t in f.rows("transactions") if t["id"] == "dep")["note"] == "Paycheck · Nov 13"
    assert f.rows("expected")[0]["amount_cents"] == 247707
    assert "JORDAN" not in str(f.t).upper().replace("JORDAN SAMPLE", "") and "MAPLE" not in str(f.t).upper()

def test_reimporting_the_same_statement_adds_nothing(api):
    f, c = api
    post(c, mode="commit")
    j = post(c, mode="commit").json()
    assert (j["imported"], j["already_imported"]) == (0, 1) and len(f.rows("pay_statements")) == 1

def test_a_pdf_that_is_not_a_pay_statement_says_so(api, monkeypatch):
    _, c = api
    monkeypatch.setattr(P, "pdf_pages", lambda raw: [{"plain": "CHASE checking statement Beginning balance", "rows": "", "layout": ""}])
    monkeypatch.setattr(P, "parse_with_ai", lambda *a, **k: None)
    r = post(c)
    assert r.status_code == 422 and "isn't a pay statement" in r.json()["detail"]


# ---------- ADP's real layout, in the variants its PDFs come in (synthetic: tools/make_paystub_fixture.py, no real values) ----------
import json
import logging

WANT = (373500, 87883, 37910, 247707)

@pytest.mark.parametrize("name", ["paystub_adp_rows", "paystub_adp_columns", "paystub_adp_2page", "paystub_adp_noytd", "paystub_adp_two_statements"])
def test_real_layout_variants_read_to_the_cent(name):
    s = P.read(U, (D / f"{name}.pdf").read_bytes(), ["Jordan Sample"])
    assert (s.gross_cents, s.taxes_cents, s.deductions_cents, s.net_cents) == WANT and s.adds_up and s.problems == []
    assert (s.employer, s.pay_date, s.period_start, s.period_end) == ("ACME ROBOTICS INC", date(2026, 11, 13), date(2026, 10, 26), date(2026, 11, 8))
    assert [l.label for l in s.lines if l.kind == "earning"] == ["Regular", "Overtime"]          # the year-to-date-only Bonus row isn't this paycheck
    assert [l.label for l in s.lines if l.kind == "tax"] == ["Federal Income Tax", "Social Security Tax", "Medicare Tax", "NY State Income Tax", "NY SDI Tax"]
    assert not any("Group Term" in l.label or "Vac" in l.label for l in s.lines)                 # the benefits box on the right is not pay

def test_columns_drawn_out_of_order_need_the_position_view():
    raw = (D / "paystub_adp_columns.pdf").read_bytes()
    plain = P.parse_adp(P.pdf_text(raw), [])
    assert plain is None or not plain.adds_up                # the text stream alone has labels and numbers apart
    assert P.read(U, raw, []).adds_up

def test_several_direct_deposit_lines_with_their_account_endings():
    s = P.read(U, (D / "paystub_adp_2page.pdf").read_bytes(), [])
    assert [(d.label, d.cents, d.mask) for d in s.deposits] == [("Checking", 197707, "1234"), ("Savings", 50000, "5678")]
    assert sum(d.cents for d in s.deposits) == s.net_cents
    one = P.read(U, (D / "paystub_adp_noytd.pdf").read_bytes(), [])
    assert [(d.cents, d.mask) for d in one.deposits] == [(247707, "1234")] and one.ytd.get("gross") is None

def test_a_file_with_two_statements_reads_the_first_and_says_so():
    s = P.read(U, (D / "paystub_adp_two_statements.pdf").read_bytes(), [])
    assert s.statements_in_file == 2 and s.pay_date == date(2026, 11, 13) and s.adds_up

def test_amounts_and_hours_are_told_apart():
    assert P._amounts("Regular 46.6875 80.00 3,735.00 78,435.00") == [8000, 373500, 7843500]       # the rate isn't money
    assert P._amounts("Federal Income Tax 412.50- (8.00) -$2.00 11/13/2026") == [-41250, -800, -200]
    t = "Earnings Statement\nPay Date: 11/13/2026\nEarnings\nRegular 46.6875 80.00 3,735.00\nGross Pay $3,735.00\nTaxes\nFederal Income Tax -735.00\nNet Pay $3,000.00"
    s = P.parse_adp(t)
    assert (s.gross_cents, s.taxes_cents, s.net_cents) == (373500, 73500, 300000) and s.adds_up       # 80.00 hours never became pay

def test_a_missing_field_is_named_not_guessed():
    t = "Earnings Statement\nEarnings\nRegular 3,735.00\nGross Pay $3,735.00\nTaxes\nFederal Income Tax -735.00\nNet Pay $3,000.00"
    assert P.parse_adp(t).problems == ["pay_date"]
    t2 = "Earnings Statement\nPay Date: Nov 13, 2026\nGross Pay $3,735.00\nTaxes\nFederal Income Tax -700.00\nNet Pay $3,000.00"
    s = P.parse_adp(t2)
    assert s.pay_date == date(2026, 11, 13) and s.problems == ["adds_up"] and s.off_by_cents == 3500

def test_logs_carry_field_names_and_counts_never_values(caplog):
    with caplog.at_level(logging.INFO, logger="tick"):
        P.read(U, (D / "paystub_adp_columns.pdf").read_bytes(), ["Jordan Sample"])
    text = caplog.text
    assert "pay_date=True" in text and "deposits=2" in text
    for leak in ("3,735", "373500", "2477", "JORDAN", "ACME", "1234", "11/13"):
        assert leak not in text

def test_preview_names_what_to_fix_and_commit_takes_the_fix(api, monkeypatch):
    f, c = api
    pages = P.pdf_pages(RAW)
    monkeypatch.setattr(P, "pdf_pages", lambda raw: [{k: v.replace("Pay Date: 11/13/2026", "") for k, v in p.items()} for p in pages])
    j = post(c).json()
    assert j["pay_date"] is None and [p["field"] for p in j["problems"]] == ["pay_date"] and "pay date" in j["problems"][0]["message"]
    r = post(c, mode="commit")
    assert r.status_code == 422 and "pay date" in r.json()["detail"] and f.rows("pay_statements") == []
    j = post(c, mode="commit", fixes=json.dumps({"pay_date": "2026-11-13"})).json()
    st = f.rows("pay_statements")[0]
    assert j["imported"] == 1 and st["pay_date"] == "2026-11-13" and st["problems"] == ["pay_date"] and st["matched_txn"] == "dep"

def test_a_corrected_total_replaces_that_groups_lines(api):
    f, c = api
    j = post(c, mode="commit", fixes=json.dumps({"taxes_cents": 87900})).json()
    st = f.rows("pay_statements")[0]
    assert (j["taxes_cents"], j["adds_up"], st["status"]) == (87900, False, "review")
    assert [l["label"] for l in f.rows("pay_statement_lines") if l["kind"] == "tax"] == ["Taxes"]
    assert post(c, mode="commit", fixes="[1]").status_code == 422
    assert post(c, mode="commit", fixes=json.dumps({"net_cents": -5})).status_code == 422

def test_deposit_lines_are_saved_with_the_statement(api):
    f, c = api
    j = post(c, raw=(D / "paystub_adp_columns.pdf").read_bytes(), mode="commit").json()
    assert [d["mask"] for d in j["deposits"]] == ["1234", "5678"]
    assert f.rows("pay_statements")[0]["deposits"] == j["deposits"]
