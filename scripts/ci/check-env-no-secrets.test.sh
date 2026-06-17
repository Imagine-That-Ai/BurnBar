#!/usr/bin/env bash
# Positive controls for check-env-no-secrets.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

safe="$tmpdir/.env.safe.production"
cat >"$safe" <<'EOF'
# NON-SECRET VALUES ONLY
ENFORCE_APP_CHECK=true
BURNBAR_PRO_PRODUCT_ID=com.openburnbar.pro.monthly
STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID=price_1TcsUfCFamvUJU7yjeIJ5f79
OPENBURNBAR_OTS_VERIFY_URL=https://openburnbar-ots-verifier.example.test/verify
EOF

bash scripts/ci/check-env-no-secrets.sh "$safe" >/tmp/check-env-no-secrets-safe.out

for fixture in stripe webhook private-key google-key secret-var service-account-json; do
  bad="$tmpdir/.env.${fixture}.production"
  cp "$safe" "$bad"
  case "$fixture" in
    stripe)
      expected="Stripe secret key"
      printf '%s%s\n' 'STRIPE_SECRET_KEY=sk_live_' '1234567890abcdef' >>"$bad"
      ;;
    webhook)
      expected="Stripe webhook secret"
      printf '%s%s\n' 'STRIPE_WEBHOOK_SECRET=whsec_' '1234567890abcdef' >>"$bad"
      ;;
    private-key)
      expected="private key block"
      printf 'APNS_AUTH_KEY=-----BEGIN PRIVATE KEY-----\\n' >>"$bad"
      ;;
    google-key)
      expected="Firebase/Google API key"
      printf '%s%s\n' 'FIREBASE_WEB_API_KEY=AIza' '1234567890abcdef1234567890abc' >>"$bad"
      ;;
    secret-var)
      expected="runtime secret variable"
      echo "PERPLEXITY_API_KEY=not-allowed-here" >>"$bad"
      ;;
    service-account-json)
      expected="raw service-account JSON key"
      echo 'SERVICE_ACCOUNT={"private_key":"-----BEGIN PRIVATE KEY-----"}' >>"$bad"
      ;;
  esac
  if bash scripts/ci/check-env-no-secrets.sh "$bad" >/tmp/check-env-no-secrets-bad.out 2>&1; then
    echo "FAIL: $fixture fixture unexpectedly passed" >&2
    cat /tmp/check-env-no-secrets-bad.out >&2
    exit 1
  fi
  if ! grep -q "$expected" /tmp/check-env-no-secrets-bad.out; then
    echo "FAIL: $fixture fixture did not name expected secret pattern: $expected" >&2
    cat /tmp/check-env-no-secrets-bad.out >&2
    exit 1
  fi
done

echo "PASS: check-env-no-secrets positive controls"
