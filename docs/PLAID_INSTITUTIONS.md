# Plaid product support for my banks

Checked 2026-11-06 with `python3 tools/plaid_institutions.py` (only `/institutions/search` and `/institutions/get_by_id`:
free metadata endpoints, no Item created, read or removed).

| Bank | Plaid institution | OAuth | Transactions | Liabilities | Notes |
|---|---|---|---|---|---|
| SoFi (checking, savings, student loan) | SoFi `ins_126339` | no (credentials in Link) | yes | yes | One link covers all three SoFi accounts. |
| Discover (credit card) | Discover `ins_33` | yes | yes | yes (`credit_details` too) | Pick "Discover", not "Discover - Student Loans" or the credit union. |
| Bank of America (credit card) | Bank of America `ins_127989` | yes | yes | yes | Pick the plain "Bank of America" entry. |
| Capital One (Savor) | Capital One `ins_128026` | yes | yes | yes | |
| Chase (already linked) | Chase `ins_56` | yes | yes | yes | Existing link was made with transactions only. |
| Apple Card | not on Plaid | | | | FinanceKit only. Tick uses Wallet capture plus the statement CSV import. |

Whether the **Trial plan** may use Liabilities can't be read from these endpoints. Tick asks for Liabilities as an
*optional* product when it creates a link token. If Plaid refuses the product, Tick quietly creates the link token without
it (creating a link token never creates an Item), and cards fall back to balance and limit from `/accounts/get`: owed,
available credit, limit and utilisation still work, but statement balance, minimum payment and due date stay empty
and the due-date nudge stays off.

The Chase Item was linked before this change, so it has no Liabilities consent. That's fine: Chase is checking only.
