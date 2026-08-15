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
  OPENBURNBAR_RELEASE_VERSION     Exact release version. Default: project.yml MARKETING_VERSION
  WRANGLER_BIN                    Optional Wrangler binary path.
EOF
  exit 0
fi

bucket="${OPENBURNBAR_R2_BUCKET:-openburnbar-downloads}"
downloads_dir="${OPENBURNBAR_DOWNLOADS_DIR:-website/public/downloads}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-https://downloads.burnbar.ai}"
release_version="${OPENBURNBAR_RELEASE_VERSION:-$(
  grep -E '^[[:space:]]+MARKETING_VERSION:' project.yml \
    | head -1 \
    | sed 's/.*: *//' \
    | tr -d ' "'
)}"

if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid OpenBurnBar release version: ${release_version:-<empty>}" >&2
  exit 1
fi

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

release_file="OpenBurnBar-${release_version}-macOS.dmg"
appcast_file="appcast.xml"
latest_file="latest-macos.json"

files=(
  "$release_file"
  "${release_file%.dmg}.zip"
  "$appcast_file"
  "$latest_file"
  "checksums-v${release_version}.txt"
  "release-metadata.json"
  "sbom-v${release_version}.spdx.json"
  "OpenBurnBar-${release_version}-corresponding-source.tar.gz"
  "OpenBurnBar-${release_version}-corresponding-source.tar.gz.sha256"
)

node --input-type=module - \
  "$downloads_dir/$latest_file" \
  "$downloads_dir/release-metadata.json" \
  "$release_version" \
  "$release_file" <<'NODE'
import { readFileSync } from "node:fs";

const [latestPath, releaseMetadataPath, expectedVersion, expectedDmg] = process.argv.slice(2);
const latest = JSON.parse(readFileSync(latestPath, "utf8"));
const releaseMetadata = JSON.parse(readFileSync(releaseMetadataPath, "utf8"));

if (latest.version !== expectedVersion || latest.dmg !== expectedDmg) {
  throw new Error(`${latestPath} must bind version ${expectedVersion} and DMG ${expectedDmg}`);
}
if (
  releaseMetadata.version !== expectedVersion ||
  releaseMetadata.tag !== `v${expectedVersion}`
) {
  throw new Error(
    `${releaseMetadataPath} must bind version ${expectedVersion} and tag v${expectedVersion}`,
  );
}
NODE

content_type_for() {
  case "$1" in
    *.dmg) echo "application/x-apple-diskimage" ;;
    *.tar.gz) echo "application/gzip" ;;
    *.zip) echo "application/zip" ;;
    *.xml) echo "application/xml; charset=utf-8" ;;
    *.txt) echo "text/plain; charset=utf-8" ;;
    *.sha256) echo "text/plain; charset=utf-8" ;;
    *.json) echo "application/json; charset=utf-8" ;;
    *) echo "application/octet-stream" ;;
  esac
}

cache_control_for() {
  case "$1" in
    "$appcast_file" | "$latest_file" | release-metadata.json) echo "public, max-age=300" ;;
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
  echo "Verifying public appcast URL: $public_base_url/$appcast_file"
  curl -fsSL "$public_base_url/$appcast_file" | grep -q "sparkle:version"
  echo "Verifying public latest metadata URL: $public_base_url/$latest_file"
  curl -fsSL "$public_base_url/$latest_file" | grep -q "\"downloadUrl\""
fi

echo "Uploaded OpenBurnBar macOS release artifacts to $bucket."
