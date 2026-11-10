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

if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1] / "api/tests/data"
    (root / "paystub_adp.pdf").write_bytes(pdf(LINES.splitlines()))
    (root / "paystub_blank.pdf").write_bytes(pdf([]))
    print("wrote fixtures")
