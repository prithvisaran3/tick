#!/usr/bin/env python3
"""Writes api/tests/data/paystub_adp.pdf: a text-layer PDF in ADP's standard earnings-statement layout (ASSUMED; all values made up, no real person)."""
import pathlib
LINES = """ACME ROBOTICS INC
Company: ACME ROBOTICS INC
Earnings Statement
Period Starting: 10/26/2026
Period Ending: 11/08/2026
Pay Date: 11/13/2026
Taxable Marital Status: Single
Employee ID: 004512
Social Security Number: XXX-XX-1234
JORDAN SAMPLE
123 MAPLE STREET APT 4
ALBANY, NY 12207
Earnings rate hours this period year to date
Regular 45.0000 80.00 3,600.00 72,000.00
Overtime 67.5000 2.00 135.00 810.00
Gross Pay $3,735.00 72,810.00
Statutory Deductions this period year to date
Federal Income Tax -412.50 8,250.00
Social Security Tax -231.57 4,514.22
Medicare Tax -54.16 1,055.75
NY State Income Tax -180.00 3,600.00
NY SDI Tax -0.60 12.00
Other Deductions
401(K) -224.10 4,368.60
Medical -95.00 1,900.00
Dental -8.00 160.00
Vision -2.00 40.00
HSA -50.00 1,000.00
Net Pay $2,477.07
Your federal taxable wages this period are $3,206.90"""

def esc(l: str) -> str:
    return l.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')

def pdf(lines: list[str]) -> bytes:
    content = "BT /F1 10 Tf 40 760 Td 12 TL " + " ".join(f"({esc(l)}) Tj T*" for l in lines) + " ET"
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            f"<< /Length {len(content)} >>\nstream\n{content}\nendstream", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offs = b"%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += f"{i} 0 obj\n{o}\nendobj\n".encode()
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode() + b"".join(f"{o:010d} 00000 n \n".encode() for o in offs)
    return out + f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n".encode()

# ---- ADP's real layout, placed by position (all values made up, no real person) ----
# Left column: earnings, deductions, net pay, where it was deposited. Right column: benefits and notes that share rows with the left.
# Bottom: the non-negotiable advice with masked account numbers. Items are (x, y, text); a PDF may draw them in any order.
L, RATE, HRS, CUR, YTD, R1, R2, R3 = 36, 150, 200, 250, 310, 380, 500, 550

def adp_items(deposits=((197707, "Checking 1", "1234"), (50000, "Savings 1", "5678")), ytd=True) -> list[tuple[int, int, str]]:
    money = lambda c: f"{c / 100:,.2f}"
    it = [(L, 760, "CO."), (70, 760, "FILE"), (110, 760, "DEPT."), (150, 760, "CLOCK"), (200, 760, "VCHR. NO."), (L, 748, "ABC"), (70, 748, "004512"), (110, 748, "000100"), (200, 748, "0000451201"),
          (380, 760, "Earnings Statement"), (L, 724, "ACME ROBOTICS INC"), (L, 712, "500 FACTORY ROAD"), (L, 700, "ALBANY, NY 12207"),
          (380, 724, "Period Beginning:"), (480, 724, "10/26/2026"), (380, 712, "Period Ending:"), (480, 712, "11/08/2026"), (380, 700, "Pay Date:"), (480, 700, "11/13/2026"),
          (L, 676, "Taxable Marital Status: Single"), (L, 664, "Exemptions/Allowances:"), (L, 652, "Federal: Standard Withholding Table"),
          (380, 664, "JORDAN SAMPLE"), (380, 652, "123 MAPLE STREET APT 4"), (380, 640, "ALBANY, NY 12207"),
          (L, 616, "Earnings"), (RATE, 616, "rate"), (HRS, 616, "hours"), (CUR, 616, "this period"), (YTD, 616, "year to date"),
          (R1, 616, "Other Benefits and"), (R1, 604, "Information"), (R2, 604, "this period"), (R3, 604, "total to date")]
    y = 604
    def row(label, cur, ytd_c=None, rate=None, hrs=None, star=False, right=None):
        nonlocal y
        y -= 12
        it.append((L, y, label))
        if rate: it.append((RATE, y, rate))
        if hrs: it.append((HRS, y, hrs))
        if cur is not None: it.append((CUR, y, cur + ("*" if star else "")))
        if ytd and ytd_c: it.append((YTD, y, ytd_c))
        if right: it.extend([(R1, y, right[0]), (R2, y, right[1]), (R3, y, right[2])])
    row("Regular", "3,600.00", "72,000.00", rate="45.0000", hrs="80.00", right=("Group Term Life", "1.25", "25.00"))
    row("Overtime", "135.00", "810.00", rate="67.5000", hrs="2.00", right=("Vac Bal", "12.00", "40.00"))
    row("Bonus", None, "5,000.00")                                  # paid earlier this year: year to date only
    y -= 12; it.extend([(110, y, "Gross Pay"), (CUR - 6, y, "$3,735.00"), (YTD, y, "77,810.00")] if ytd else [(110, y, "Gross Pay"), (CUR - 6, y, "$3,735.00")])
    y -= 18; it.extend([(L, y, "Deductions"), (110, y, "Statutory")])
    row("Federal Income Tax", "-412.50", "8,250.00", right=("Important Notes", "", ""))
    row("Social Security Tax", "-231.57", "4,514.22")
    row("Medicare Tax", "-54.16", "1,055.75")
    row("NY State Income Tax", "-180.00", "3,600.00")
    row("NY SDI Tax", "-0.60", "12.00")
    y -= 14; it.append((110, y, "Other"))
    row("401(K)", "-224.10", "4,368.60", star=True)
    row("Medical", "-95.00", "1,900.00", star=True)
    row("Dental", "-8.00", "160.00", star=True)
    row("Vision", "-2.00", "40.00", star=True)
    row("HSA", "-50.00", "1,000.00", star=True)
    y -= 16; it.extend([(110, y, "Net Pay"), (CUR - 6, y, "$2,477.07")])
    for cents, label, _ in deposits:
        y -= 12; it.extend([(110, y, label), (CUR, y, "-" + money(cents))])
    y -= 12; it.extend([(110, y, "Net Check"), (CUR, y, "$0.00")])
    y -= 24; it.append((L, y, "* Excluded from federal taxable wages"))
    y -= 12; it.append((L, y, "Your federal taxable wages this period are $3,355.90"))
    # the advice
    it.extend([(L, 150, "ACME ROBOTICS INC"), (380, 150, "Advice number:"), (480, 150, "00000451201"), (380, 138, "Pay date:"), (480, 138, "11/13/2026"),
               (L, 114, "Deposited to the account of"), (L, 102, "JORDAN SAMPLE"), (300, 114, "account number"), (400, 114, "transit ABA"), (520, 114, "amount")])
    for i, (cents, _, mask) in enumerate(deposits):
        it.extend([(300, 102 - 12 * i, "xxxxxx" + mask), (400, 102 - 12 * i, "xxxx xxxx"), (520, 102 - 12 * i, "$" + money(cents))])
    it.append((L, 60, "NON-NEGOTIABLE"))
    return it

def placed(pages: list[list[tuple[int, int, str]]], order="rows", symbol_page: int | None = None) -> bytes:
    """order "rows": drawn top to bottom, left to right. "columns": drawn column by column, the way ADP's own files come out."""
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", None, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Symbol /Encoding /SymbolEncoding >>"]
    kids = []
    for n, items in enumerate(pages):
        seq = sorted(items, key=(lambda t: (-t[1], t[0])) if order == "rows" else (lambda t: (t[0], -t[1])))
        content = " ".join(f"BT /F1 9 Tf 1 0 0 1 {x} {y} Tm ({esc(t)}) Tj ET" for x, y, t in seq)
        if symbol_page == n:
            content += " BT /F2 9 Tf 1 0 0 1 560 60 Tm (\\267) Tj ET"
        objs.append(f"<< /Length {len(content)} >>\nstream\n{content}\nendstream")
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {len(objs)} 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> >>")
        kids.append(len(objs))
    objs[1] = f"<< /Type /Pages /Kids [{' '.join(f'{k} 0 R' for k in kids)}] /Count {len(kids)} >>"
    out, offs = b"%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += f"{i} 0 obj\n{o}\nendobj\n".encode("latin-1")
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode() + b"".join(f"{o:010d} 00000 n \n".encode() for o in offs)
    return out + f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n".encode()

def two_pages() -> list[list[tuple[int, int, str]]]:
    """The statement runs over: everything from the Other deductions down moves to page 2, and the advice stays on page 1."""
    items = adp_items()
    cut = next(y for x, y, t in items if t == "Other")
    body = [i for i in items if i[1] > 200]
    p1 = [i for i in body if i[1] > cut] + [i for i in items if i[1] <= 200]
    p2 = [(x, y + 300, t) for x, y, t in body if y <= cut] + [(380, 760, "Earnings Statement"), (500, 760, "Page 2 of 2")]
    return [p1, p2]

if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1] / "api/tests/data"
    (root / "paystub_adp.pdf").write_bytes(pdf(LINES.splitlines()))
    (root / "paystub_blank.pdf").write_bytes(pdf([]))
    (root / "paystub_adp_rows.pdf").write_bytes(placed([adp_items()], "rows"))
    (root / "paystub_adp_columns.pdf").write_bytes(placed([adp_items()], "columns", symbol_page=0))
    (root / "paystub_adp_2page.pdf").write_bytes(placed(two_pages(), "columns"))
    (root / "paystub_adp_noytd.pdf").write_bytes(placed([adp_items(deposits=((247707, "Checking 1", "1234"),), ytd=False)], "columns"))
    second = [(x, y, t.replace("11/13/2026", "11/27/2026")) for x, y, t in adp_items()]
    (root / "paystub_adp_two_statements.pdf").write_bytes(placed([adp_items(), second], "columns"))
    print("wrote fixtures")
