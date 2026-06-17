#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

safe_file="$tmpdir/functions.env.burnbar.production"
cat >"$safe_file" <<'EOF'
OPENBURNBAR_OTS_VERIFY_URL=https://openburnbar-ots-verifier.example.run.app/verify
STRIPE_BURNBAR_PRO_PRICE_ID=price_1TcsUfCFamvUJU7yjeIJ5f79
ENFORCE_APP_CHECK=true
EOF

bash scripts/ci/check-env-no-secrets.sh "$safe_file" >/dev/null

bad_file="$tmpdir/functions.env.bad.production"
{
  printf 'STRIPE_SECRET_KEY=%s\n' "sk_live_""1234567890abcdefghijklmnop"
} >"$bad_file"

if bash scripts/ci/check-env-no-secrets.sh "$bad_file" >/tmp/check-env-no-secrets.out 2>/tmp/check-env-no-secrets.err; then
  echo "FAIL: secret-shaped env value was accepted" >&2
  exit 1
fi

if ! grep -q "Stripe live secret key" /tmp/check-env-no-secrets.err; then
  echo "FAIL: positive control did not name the matched secret pattern" >&2
  cat /tmp/check-env-no-secrets.err >&2
  exit 1
fi

echo "PASS: env secret guard positive controls"
