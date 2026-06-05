#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/upload-macos-downloads-r2.sh

Uploads the current macOS direct-download release artifacts to Cloudflare R2.

Environment:
  OPENBURNBAR_R2_BUCKET           R2 bucket name. Default: openburnbar-downloads
  OPENBURNBAR_R2_PUBLIC_BASE_URL Public download base URL to verify after upload.
  OPENBURNBAR_DOWNLOADS_DIR       Local artifact directory. Default: website/public/downloads
  WRANGLER_BIN                    Optional Wrangler binary path.
EOF
  exit 0
fi

bucket="${OPENBURNBAR_R2_BUCKET:-openburnbar-downloads}"
downloads_dir="${OPENBURNBAR_DOWNLOADS_DIR:-website/public/downloads}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-}"

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

release_file="$(
  node -e 'const fs=require("fs"); const source=fs.readFileSync("website/src/data/site.ts","utf8"); const match=source.match(/macReleaseFile:\s*"([^"]+)"/); if(!match) process.exit(1); console.log(match[1]);'
)"
release_version="$(
  node -e 'const fs=require("fs"); const source=fs.readFileSync("website/src/data/site.ts","utf8"); const match=source.match(/macReleaseLatest:\s*"([^"]+)"/); if(!match) process.exit(1); console.log(match[1]);'
)"

files=(
  "$release_file"
  "${release_file%.dmg}.zip"
  "checksums-v${release_version}.txt"
  "release-metadata.json"
  "sbom-v${release_version}.spdx.json"
  "OpenBurnBar-${release_version}-corresponding-source.tar.gz"
  "OpenBurnBar-${release_version}-corresponding-source.tar.gz.sha256"
)

content_type_for() {
  case "$1" in
    *.dmg) echo "application/x-apple-diskimage" ;;
    *.tar.gz) echo "application/gzip" ;;
    *.zip) echo "application/zip" ;;
    *.txt) echo "text/plain; charset=utf-8" ;;
    *.sha256) echo "text/plain; charset=utf-8" ;;
    *.json) echo "application/json; charset=utf-8" ;;
    *) echo "application/octet-stream" ;;
  esac
}

cache_control_for() {
  case "$1" in
    release-metadata.json) echo "public, max-age=300" ;;
    *) echo "public, max-age=31536000, immutable" ;;
  esac
}

for name in "${files[@]}"; do
  path="$downloads_dir/$name"
  if [[ ! -f "$path" ]]; then
    echo "Missing release artifact: $path" >&2
    exit 1
  fi

  echo "Uploading $name to R2 bucket $bucket"
  "${wrangler[@]}" r2 object put "$bucket/$name" \
    --remote \
    --file "$path" \
    --content-type "$(content_type_for "$name")" \
    --cache-control "$(cache_control_for "$name")"
done

if [[ -n "$public_base_url" ]]; then
  public_base_url="${public_base_url%/}"
  echo "Verifying public download URL: $public_base_url/$release_file"
  curl -fsSI "$public_base_url/$release_file" >/dev/null
fi

echo "Uploaded OpenBurnBar macOS release artifacts to $bucket."
