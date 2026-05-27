#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/setup-macos-downloads-r2.sh

Creates/configures the Cloudflare R2 bucket used for macOS direct-download
release artifacts.

Environment:
  OPENBURNBAR_R2_BUCKET        R2 bucket name. Default: openburnbar-downloads
  OPENBURNBAR_R2_CUSTOM_DOMAIN Optional custom domain, e.g. downloads.burnbar.ai
  OPENBURNBAR_R2_ZONE_ID       Required when adding a custom domain.
  WRANGLER_BIN                 Optional Wrangler binary path.
EOF
  exit 0
fi

bucket="${OPENBURNBAR_R2_BUCKET:-openburnbar-downloads}"
custom_domain="${OPENBURNBAR_R2_CUSTOM_DOMAIN:-}"
zone_id="${OPENBURNBAR_R2_ZONE_ID:-}"

if [[ -d "$HOME/.homebrew/opt/node@22/bin" ]]; then
  export PATH="$HOME/.homebrew/opt/node@22/bin:$PATH"
fi

if [[ -f "$HOME/.homebrew/etc/ca-certificates/cert.pem" ]]; then
  export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.homebrew/etc/ca-certificates/cert.pem}"
  export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$SSL_CERT_FILE}"
fi

if [[ -n "${WRANGLER_BIN:-}" ]]; then
  wrangler=("$WRANGLER_BIN")
elif command -v wrangler >/dev/null 2>&1; then
  wrangler=(wrangler)
else
  wrangler=(npm exec --yes wrangler@latest --)
fi

if "${wrangler[@]}" r2 bucket info "$bucket" >/dev/null 2>&1; then
  echo "R2 bucket already exists: $bucket"
else
  echo "Creating R2 bucket: $bucket"
  "${wrangler[@]}" r2 bucket create "$bucket"
fi

echo "Enabling public r2.dev URL for $bucket"
"${wrangler[@]}" r2 bucket dev-url enable "$bucket" || true
"${wrangler[@]}" r2 bucket dev-url get "$bucket"

if [[ -n "$custom_domain" ]]; then
  if [[ -z "$zone_id" ]]; then
    echo "OPENBURNBAR_R2_ZONE_ID is required to attach $custom_domain." >&2
    exit 1
  fi

  echo "Attaching $custom_domain to $bucket"
  "${wrangler[@]}" r2 bucket domain add "$bucket" \
    --domain "$custom_domain" \
    --zone-id "$zone_id" \
    --min-tls 1.2 \
    --force
fi
