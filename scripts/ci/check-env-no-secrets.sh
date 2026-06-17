#!/usr/bin/env bash
#
# Production env hygiene gate: functions/.env.*.production is intentionally
# tracked, but it must stay public-config only. This script fails closed if
# known production-secret shapes appear in those files.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=()
  while IFS= read -r file; do
    files+=("$file")
  done < <(git ls-files 'functions/.env.*.production')
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "FAIL: no tracked functions/.env.*.production files found" >&2
  exit 1
fi

failures=0
for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "FAIL: env file not found: $file" >&2
    failures=$((failures + 1))
    continue
  fi

  while IFS=: read -r line label; do
    [[ -z "${line}" || -z "${label}" ]] && continue
    echo "FAIL: ${file}:${line} matches ${label}" >&2
    failures=$((failures + 1))
  done < <(python3 - "$file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
patterns = [
    ("Stripe live secret key", re.compile(r"sk_live_[0-9A-Za-z]{16,}")),
    ("Stripe webhook secret", re.compile(r"whsec_[0-9A-Za-z]{16,}")),
    ("private key block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("Firebase/Google API key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
]

for index, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
    for label, pattern in patterns:
        if pattern.search(line):
            print(f"{index}:{label}")
PY
  )
done

if [[ $failures -gt 0 ]]; then
  echo "FAIL: production env files contain secret-shaped values" >&2
  exit 1
fi

echo "PASS: production env files contain no known secret-shaped values"
