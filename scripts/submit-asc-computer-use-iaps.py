#!/usr/bin/env python3
"""
Submit the Computer Use IAPs to App Store Connect.

Creates / updates the two SKUs from the master plan:
  * com.openburnbar.hostedComputerUseSync.monthly  $14.99 / month
  * com.openburnbar.proMax.monthly                  $24.99 / month

Uses the App Store Connect REST API. Requires three environment vars:
  ASC_KEY_ID         issuer's key id (10-char)
  ASC_ISSUER_ID      team's issuer id (uuid)
  ASC_KEY_PATH       path to the AuthKey_<KEY_ID>.p8 file
  ASC_APP_ID         App Store Connect numeric app id for OpenBurnBar

Dry-runs by default. Pass `--apply` to actually call the API. Pass
`--dry-run` (default) to print the request bodies without sending.

Reference: https://developer.apple.com/documentation/appstoreconnectapi/in-app_purchases_and_subscriptions
"""
from __future__ import annotations
import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any


SUBSCRIPTIONS = [
    {
        "productId": "com.openburnbar.hostedComputerUseSync.monthly",
        "name": "OpenBurnBar Computer Use Monthly",
        "groupReferenceName": "OpenBurnBar Computer Use",
        "groupLocalizedDisplayName": "OpenBurnBar Computer Use",
        "subscriptionPeriod": "ONE_MONTH",
        "tier": "USD_14_99",
        "localizations": [
            {
                "locale": "en-US",
                "name": "OpenBurnBar Computer Use",
                "description": (
                    "Let an AI agent drive your Mac with your approval. Watch live "
                    "on your iPhone or iPad, intervene at any time, and review a "
                    "tamper-evident audit log of every action."
                ),
            }
        ],
        "reviewNote": (
            "OpenBurnBar Computer Use lets a user run an AI agent that operates "
            "their Mac with explicit consent. Every action passes through an "
            "approval gate visible on the Mac and the paired iPhone/iPad. The "
            "agent can be halted by global hotkey (Ctrl+Option+Cmd+.), by a "
            "three-finger gesture on the paired phone, or by locking the Mac. "
            "Path B (Browser) runs sandboxed inside Chromium and ships in the "
            "MAS build. Path C (System) requires the macOS Accessibility "
            "permission and ships only via direct download outside MAS."
        ),
    },
    {
        "productId": "com.openburnbar.proMax.monthly",
        "name": "OpenBurnBar Pro Max Monthly",
        "groupReferenceName": "OpenBurnBar Pro Max",
        "groupLocalizedDisplayName": "OpenBurnBar Pro Max",
        "subscriptionPeriod": "ONE_MONTH",
        "tier": "USD_24_99",
        "localizations": [
            {
                "locale": "en-US",
                "name": "OpenBurnBar Pro Max",
                "description": (
                    "Everything in OpenBurnBar Cloud (quota sync, Hermes hosted "
                    "relay) + Mercury Media (file transfer, screen share, video "
                    "calling) + Computer Use, bundled in a single subscription."
                ),
            }
        ],
        "reviewNote": (
            "Umbrella subscription that bundles three previously-separate SKUs."
        ),
    },
]


def jwt_for_asc(key_id: str, issuer_id: str, key_path: Path) -> str:
    """Mint a 20-minute ES256 JWT for the App Store Connect API."""
    try:
        import jwt as pyjwt
    except ImportError:
        sys.exit("pip install pyjwt[crypto] to use --apply")
    headers = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    claims = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 20 * 60,
        "aud": "appstoreconnect-v1",
        "scope": [
            "GET /v1/apps",
            "GET /v1/inAppPurchases",
            "POST /v1/inAppPurchases",
            "POST /v1/subscriptionGroups",
            "POST /v1/subscriptions",
            "POST /v1/subscriptionLocalizations",
            "POST /v1/subscriptionPrices",
        ],
    }
    private_pem = key_path.read_bytes()
    return pyjwt.encode(claims, private_pem, algorithm="ES256", headers=headers)


def request(method: str, path: str, body: Any, token: str, dry_run: bool) -> dict:
    import urllib.request
    url = f"https://api.appstoreconnect.apple.com{path}"
    if dry_run:
        print(f"[DRY-RUN] {method} {url}")
        if body is not None:
            print(json.dumps(body, indent=2))
        return {"dry_run": True}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            text = resp.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        body_text = e.read().decode() if hasattr(e, "read") else ""
        sys.exit(f"ASC API {e.code}: {body_text}")


def submit(app_id: str, token: str | None, dry_run: bool) -> None:
    print(f"Submitting {len(SUBSCRIPTIONS)} subscription products to app {app_id}")
    for sub in SUBSCRIPTIONS:
        print(f"\n→ {sub['productId']}  {sub['tier']}  {sub['subscriptionPeriod']}")
        group_body = {
            "data": {
                "type": "subscriptionGroups",
                "attributes": {"referenceName": sub["groupReferenceName"]},
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}},
                },
            }
        }
        group_resp = request("POST", "/v1/subscriptionGroups", group_body,
                             token or "", dry_run)
        group_id = group_resp.get("data", {}).get("id", "<dry-run>")

        sub_body = {
            "data": {
                "type": "subscriptions",
                "attributes": {
                    "name": sub["name"],
                    "productId": sub["productId"],
                    "subscriptionPeriod": sub["subscriptionPeriod"],
                    "reviewNote": sub["reviewNote"],
                },
                "relationships": {
                    "group": {"data": {"type": "subscriptionGroups", "id": group_id}}
                },
            }
        }
        sub_resp = request("POST", "/v1/subscriptions", sub_body,
                           token or "", dry_run)
        sub_record_id = sub_resp.get("data", {}).get("id", "<dry-run>")

        for loc in sub["localizations"]:
            loc_body = {
                "data": {
                    "type": "subscriptionLocalizations",
                    "attributes": {
                        "locale": loc["locale"],
                        "name": loc["name"],
                        "description": loc["description"],
                    },
                    "relationships": {
                        "subscription": {
                            "data": {"type": "subscriptions", "id": sub_record_id}
                        }
                    },
                }
            }
            request("POST", "/v1/subscriptionLocalizations", loc_body,
                    token or "", dry_run)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true",
                        help="Actually call ASC. Without it, dry-runs.")
    parser.add_argument("--app-id", default=os.environ.get("ASC_APP_ID"))
    parser.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID"))
    parser.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER_ID"))
    parser.add_argument("--key-path", default=os.environ.get("ASC_KEY_PATH"))
    args = parser.parse_args(argv)

    dry_run = not args.apply
    token = None
    if not dry_run:
        if not all([args.app_id, args.key_id, args.issuer_id, args.key_path]):
            sys.exit("--apply requires ASC_APP_ID, ASC_KEY_ID, ASC_ISSUER_ID, "
                     "ASC_KEY_PATH (env vars or flags)")
        token = jwt_for_asc(args.key_id, args.issuer_id, Path(args.key_path))

    submit(app_id=args.app_id or "<DRY-RUN-APP-ID>", token=token, dry_run=dry_run)
    print("\nDone." if dry_run else "\nSubmitted. Verify in App Store Connect.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
