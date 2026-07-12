#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/ci/verify-public-macos-download-trust.sh"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-public-mac-trust-test.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

site_config="$tmpdir/site.ts"
cat >"$site_config" <<'TS'
/*
  Decoy values that previously matched the raw text regex extractor first:
  macReleaseLatest: "0.1.2-beta.1"
  macReleaseFile: "OpenBurnBar-0.1.2-beta.1-macOS.dmg"
  macDownloadBaseUrl: "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v0.1.2-beta.1"
*/
export const SITE = {
  macReleaseLatest: "9.9.9",
  macReleaseFile: "OpenBurnBar-9.9.9-macOS.dmg",
  macDownloadBaseUrl: "https://downloads.example.test/releases",
} as const;
TS

metadata="$(OPENBURNBAR_PRINT_PUBLIC_MACOS_DOWNLOAD_METADATA=1 bash "$verifier" "$site_config")"
expected=$'https://downloads.example.test/releases/OpenBurnBar-9.9.9-macOS.dmg\n9.9.9\nOpenBurnBar-9.9.9-macOS.dmg'
if [[ "$metadata" != "$expected" ]]; then
  echo "expected verifier to read the exported SITE runtime values, got:" >&2
  printf '%s\n' "$metadata" >&2
  exit 1
fi

spoof_config="$tmpdir/spoof-site.ts"
cat >"$spoof_config" <<'TS'
export const SITE = {
  releaseNotes: `
    macReleaseLatest: "0.1.2-beta.1",
    macReleaseFile: "OpenBurnBar-0.1.2-beta.1-macOS.dmg",
    macDownloadBaseUrl: "https://trusted.example.test/releases"
  `,
  macReleaseLatest: "9.9.9",
  macReleaseFile: "OpenBurnBar-9.9.9-macOS.dmg",
  macDownloadBaseUrl: "https://downloads.example.test/releases",
} as const;
TS

spoof_metadata="$(OPENBURNBAR_PRINT_PUBLIC_MACOS_DOWNLOAD_METADATA=1 bash "$verifier" "$spoof_config")"
if [[ "$spoof_metadata" != "$expected" ]]; then
  echo "expected verifier to ignore property-looking decoys inside string literals, got:" >&2
  printf '%s\n' "$spoof_metadata" >&2
  exit 1
fi

bad_config="$tmpdir/bad-site.ts"
cat >"$bad_config" <<'TS'
export const SITE = {
  macReleaseLatest: "9.9.9",
  macReleaseFile: "OpenBurnBar-9.9.9-macOS.dmg",
  macDownloadBaseUrl: "http://downloads.example.test/releases",
};
TS
if OPENBURNBAR_PRINT_PUBLIC_MACOS_DOWNLOAD_METADATA=1 bash "$verifier" "$bad_config" >/dev/null 2>&1; then
  echo "expected verifier to reject non-https exported SITE download URLs" >&2
  exit 1
fi

echo "PASS: public macOS download trust verifier reads exported SITE values"
