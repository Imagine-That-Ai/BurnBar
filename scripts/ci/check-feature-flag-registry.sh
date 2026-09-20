#!/usr/bin/env bash
# Fail if config/feature-flags.json is missing, invalid, or lists a flag
# without owner. Zero-consumer flags must have an expiry.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import json
from datetime import date
from pathlib import Path
path = Path("config/feature-flags.json")
if not path.exists():
    raise SystemExit("missing config/feature-flags.json")
doc = json.loads(path.read_text())
flags = doc.get("flags")
if not isinstance(flags, list) or not flags:
    raise SystemExit("feature-flags.json must list flags")
today = date.today().isoformat()
for flag in flags:
    ident = flag.get("id")
    owner = flag.get("owner")
    if not ident or not owner:
        raise SystemExit(f"flag missing id/owner: {flag}")
    consumers = flag.get("consumers") or []
    expiry = flag.get("expiry")
    if not consumers and not expiry:
        raise SystemExit(f"{ident}: zero consumers require an expiry date")
    if expiry and expiry < today:
        raise SystemExit(f"{ident}: expiry {expiry} is in the past — remove or renew")
print(f"feature-flag registry OK ({len(flags)} flags)")
PY
