#!/usr/bin/env python3
"""Read-only probe: mints an ASC JWT and lists apps + existing IAPs.
Use to confirm credentials work before submitting new SKUs."""
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

KEY_ID = os.environ.get("ASC_KEY_ID", "79P9X769N9")
KEY_PATH = Path(os.environ.get(
    "ASC_KEY_PATH",
    str(Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{KEY_ID}.p8"),
))
ISSUER_ID = os.environ.get("ASC_ISSUER_ID")  # required


def mint_token() -> str:
    if not ISSUER_ID:
        sys.exit("ASC_ISSUER_ID env var required. Find it at https://appstoreconnect.apple.com/access/integrations/api")
    import jwt as pyjwt
    now = int(time.time())
    claims = {"iss": ISSUER_ID, "iat": now, "exp": now + 20 * 60,
              "aud": "appstoreconnect-v1"}
    return pyjwt.encode(claims, KEY_PATH.read_bytes(),
                        algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def get(path: str, token: str) -> dict:
    req = urllib.request.Request(f"https://api.appstoreconnect.apple.com{path}",
                                 method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if hasattr(e, "read") else ""
        sys.exit(f"HTTP {e.code}: {body[:500]}")


def main() -> int:
    token = mint_token()
    apps = get("/v1/apps?limit=200&fields[apps]=name,bundleId,sku", token)
    found = False
    for app in apps.get("data", []):
        attrs = app.get("attributes", {})
        if attrs.get("bundleId", "").startswith("com.openburnbar"):
            found = True
            print(f"app id={app['id']}  bundle={attrs['bundleId']}  name={attrs.get('name')}")
            # IAPs for this app
            iaps = get(
                f"/v1/apps/{app['id']}/inAppPurchasesV2?limit=200"
                "&fields[inAppPurchases]=productId,name,state,inAppPurchaseType",
                token,
            )
            for iap in iaps.get("data", []):
                a = iap.get("attributes", {})
                print(f"    IAP {a.get('productId')}  type={a.get('inAppPurchaseType')}  state={a.get('state')}")
    if not found:
        print("No com.openburnbar app found under this ASC team.")
        for app in apps.get("data", []):
            a = app.get("attributes", {})
            print(f"  available: {a.get('bundleId')}  ({a.get('name')})  id={app['id']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
