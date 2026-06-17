#!/usr/bin/env bash
# Fail closed if committed production env files gain secret-looking values.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ "$#" -gt 0 ]]; then
  files=("$@")
else
  files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(git ls-files 'functions/.env.*.production')
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "FAIL: no production env files found to scan" >&2
  exit 1
fi

python3 - "$@" <<'PY'
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

if len(sys.argv) > 1:
    files = [Path(value) for value in sys.argv[1:]]
else:
    result = subprocess.run(
        ["git", "ls-files", "functions/.env.*.production"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    files = [Path(line) for line in result.stdout.splitlines() if line.strip()]

patterns = [
    ("Stripe secret key", re.compile(r"\bsk_(?:live|test)_[A-Za-z0-9_]{12,}\b")),
    ("Stripe webhook secret", re.compile(r"\bwhsec_[A-Za-z0-9_]{12,}\b")),
    ("private key block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{20,}\b")),
    ("raw service-account JSON key", re.compile(r'"private_key"\s*:')),
    ("runtime secret variable", re.compile(r"^(?:STRIPE_SECRET_KEY|STRIPE_WEBHOOK_SECRET|FIREBASE_TOKEN|GCP_SA_KEY|GOOGLE_APPLICATION_CREDENTIALS_JSON|APNS_AUTH_KEY|PERPLEXITY_API_KEY|TAVILY_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY)\s*=", re.MULTILINE)),
]

failures: list[str] = []
for path in files:
    if not path.is_file():
        failures.append(f"{path}: file is missing")
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for label, pattern in patterns:
        for match in pattern.finditer(text):
            line_no = text.count("\n", 0, match.start()) + 1
            failures.append(f"{path}:{line_no}: secret-like value matched {label}")

if failures:
    print("FAIL: production env files must contain non-secret config only:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: scanned {len(files)} production env file(s); no secret-like values found.")
PY
