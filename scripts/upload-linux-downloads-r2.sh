#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

release_out="${OPENBURNBAR_LINUX_RELEASE_OUT:-$repo_root/.linux-release}"
bucket="${OPENBURNBAR_R2_BUCKET:-openburnbar-downloads}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-https://downloads.burnbar.ai}"
feed="$release_out/latest-linux.draft.json"
signature="$release_out/sidecars/latest-linux.json.ed25519.sig"
verification="$release_out/release-verification.json"
public_key="packaging/linux/openburnbar-linux-ed25519.pub.pem"

for required in "$feed" "$signature" "$verification" "$public_key"; do
  if [[ ! -f "$required" ]]; then
    echo "required Linux release file is missing: $required" >&2
    exit 1
  fi
done

node -e '
  const fs = require("node:fs");
  const report = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (report.phase !== "final" || report.passed !== true || report.failures?.length) {
    throw new Error("Linux release verification is not final and green");
  }
' "$verification"

if [[ -n "${WRANGLER_BIN:-}" ]]; then
  wrangler=("$WRANGLER_BIN")
elif command -v wrangler >/dev/null 2>&1; then
  wrangler=(wrangler)
else
  wrangler=(npm exec --yes wrangler@latest --)
fi

# Publish the detached signature first and the signed feed pointer last. Each R2
# object replacement is atomic, so clients never observe a new feed with the old signature.
"${wrangler[@]}" r2 object put "$bucket/latest-linux.json.ed25519.sig" \
  --remote \
  --file "$signature" \
  --content-type 'application/octet-stream' \
  --cache-control 'public, max-age=60, must-revalidate'
"${wrangler[@]}" r2 object put "$bucket/latest-linux.json" \
  --remote \
  --file "$feed" \
  --content-type 'application/json; charset=utf-8' \
  --cache-control 'public, max-age=60, must-revalidate'

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
for attempt in 1 2 3 4 5 6; do
  if curl -fsS "$public_base_url/latest-linux.json" -o "$tmp_dir/latest-linux.json" \
    && curl -fsS "$public_base_url/latest-linux.json.ed25519.sig" -o "$tmp_dir/latest-linux.json.ed25519.sig"; then
    break
  fi
  if [[ "$attempt" -eq 6 ]]; then
    echo "branded Linux update origin did not become readable" >&2
    exit 1
  fi
  sleep 10
done

cmp "$feed" "$tmp_dir/latest-linux.json"
cmp "$signature" "$tmp_dir/latest-linux.json.ed25519.sig"
openssl pkeyutl -verify \
  -pubin \
  -inkey "$public_key" \
  -rawin \
  -in "$tmp_dir/latest-linux.json" \
  -sigfile "$tmp_dir/latest-linux.json.ed25519.sig"
node scripts/linux-port/check-linux-update-feed.mjs --url "$public_base_url/latest-linux.json"

echo "Linux update feed published and verified at $public_base_url/latest-linux.json"
