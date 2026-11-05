#!/usr/bin/env python3
"""Which Plaid products do my banks support? Uses ONLY the free institution-metadata endpoints (/institutions/search,
/institutions/get_by_id). Never creates, reads or removes an Item. Prints names, ids and product lists, never secrets.
Usage: python3 tools/plaid_institutions.py [--sandbox] "SoFi" "Discover" ..."""
import json, os, sys, urllib.request

def post(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "tick-tools"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())

def main(argv):
    sandbox = "--sandbox" in argv
    names = [a for a in argv if not a.startswith("--")] or ["SoFi", "Discover", "Bank of America", "Capital One", "Chase"]
    env = "sandbox" if sandbox else os.environ.get("PLAID_ENV", "production")
    base = {"production": "https://production.plaid.com", "sandbox": "https://sandbox.plaid.com"}.get(env, "https://production.plaid.com")
    secret = os.environ["PLAID_SANDBOX_SECRET" if env == "sandbox" else "PLAID_SECRET"]
    auth = {"client_id": os.environ["PLAID_CLIENT_ID"], "secret": secret}
    out = []
    for n in names:
        res = post(base, "/institutions/search", {**auth, "query": n, "country_codes": ["US"], "products": None,
                                                  "options": {"include_optional_metadata": False}})
        for inst in res.get("institutions", [])[:3]:
            full = post(base, "/institutions/get_by_id", {**auth, "institution_id": inst["institution_id"], "country_codes": ["US"],
                                                         "options": {"include_status": False}})["institution"]
            out.append({"query": n, "name": full["name"], "institution_id": full["institution_id"], "products": sorted(full.get("products", [])),
                        "oauth": full.get("oauth")})
    print(json.dumps(out, indent=1))

if __name__ == "__main__":
    main(sys.argv[1:])
