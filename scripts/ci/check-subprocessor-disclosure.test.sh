#!/usr/bin/env bash
# Positive + negative controls for check-subprocessor-disclosure.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHECK="scripts/ci/check-subprocessor-disclosure.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

controls=0

# 1) Positive control: the real repo state must pass after the disclosure edits.
if ! bash "$CHECK" >"$tmpdir/real.out" 2>&1; then
  echo "FAIL: real repo state did not pass the subprocessor disclosure check" >&2
  cat "$tmpdir/real.out" >&2
  exit 1
fi
controls=$((controls + 1))

# Fixture egress dir holding one operator-held provider secret (Perplexity).
egress="$tmpdir/functions-src"
mkdir -p "$egress"
cat >"$egress/hostedSearch.ts" <<'EOF'
import { defineSecret } from "firebase-functions/params";
const PERPLEXITY_API_KEY = defineSecret("PERPLEXITY_API_KEY");
export const endpoint = "https://api.perplexity.ai/search";
EOF

# 2) Negative control: egress live, but subprocessor missing from the table.
undisclosed="$tmpdir/PRIVACY-undisclosed.md"
cat >"$undisclosed" <<'EOF'
# Privacy
| Service | Purpose | Data shared | Privacy Policy |
|---------|---------|-------------|----------------|
| Firebase / Google Cloud | infra | metadata | link |
EOF
if SUBPROC_EGRESS_DIR="$egress" SUBPROC_PRIVACY_DOC="$undisclosed" \
    bash "$CHECK" >"$tmpdir/undisclosed.out" 2>&1; then
  echo "FAIL: undisclosed Perplexity egress unexpectedly passed" >&2
  cat "$tmpdir/undisclosed.out" >&2
  exit 1
fi
if ! grep -qi "Perplexity" "$tmpdir/undisclosed.out"; then
  echo "FAIL: failure output did not name the undisclosed subprocessor" >&2
  cat "$tmpdir/undisclosed.out" >&2
  exit 1
fi
controls=$((controls + 1))

# 3) Positive control: same egress, disclosed in a table row -> pass.
disclosed="$tmpdir/PRIVACY-disclosed.md"
cat >"$disclosed" <<'EOF'
# Privacy
| Service | Purpose | Data shared | Privacy Policy |
|---------|---------|-------------|----------------|
| Perplexity | hosted Fusion search | query text | link |
EOF
if ! SUBPROC_EGRESS_DIR="$egress" SUBPROC_PRIVACY_DOC="$disclosed" \
    bash "$CHECK" >"$tmpdir/disclosed.out" 2>&1; then
  echo "FAIL: disclosed Perplexity egress unexpectedly failed" >&2
  cat "$tmpdir/disclosed.out" >&2
  exit 1
fi
controls=$((controls + 1))

# 4) Drift guard: a new operator-held *_API_KEY with no mapping must fail.
drift="$tmpdir/functions-drift"
mkdir -p "$drift"
cat >"$drift/newProvider.ts" <<'EOF'
import { defineSecret } from "firebase-functions/params";
export const COHERE_API_KEY = defineSecret("COHERE_API_KEY");
EOF
if SUBPROC_EGRESS_DIR="$drift" SUBPROC_PRIVACY_DOC="$disclosed" \
    bash "$CHECK" >"$tmpdir/drift.out" 2>&1; then
  echo "FAIL: unmapped COHERE_API_KEY provider secret unexpectedly passed" >&2
  cat "$tmpdir/drift.out" >&2
  exit 1
fi
if ! grep -q "COHERE_API_KEY" "$tmpdir/drift.out"; then
  echo "FAIL: drift-guard output did not name the unmapped secret" >&2
  cat "$tmpdir/drift.out" >&2
  exit 1
fi
controls=$((controls + 1))

echo "PASS: check-subprocessor-disclosure.test.sh (${controls} controls)."
