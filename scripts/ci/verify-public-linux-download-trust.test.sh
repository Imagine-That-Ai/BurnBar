#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/ci/verify-public-linux-download-trust.sh"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-public-linux-trust-test.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

site_config="$tmpdir/site.ts"
cat >"$site_config" <<'TS'
/* Decoy values must not beat the exported SITE object. */
export const SITE = {
  releaseNotes: `linuxReleaseLatest: "0.1.0"`,
  linuxReleaseLatest: "9.9.9",
  linuxReleaseFile: "OpenBurnBar_9.9.9_aarch64.AppImage",
  linuxDebFile: "OpenBurnBar_9.9.9_arm64.deb",
  linuxRpmFile: "OpenBurnBar-9.9.9-1.aarch64.rpm",
  linuxPubKeyFile: "openburnbar-linux-ed25519.pub.pem",
  linuxDownloadBaseUrl: "https://downloads.example.test/linux-v9.9.9",
} as const;
TS

metadata="$(OPENBURNBAR_PRINT_PUBLIC_LINUX_DOWNLOAD_METADATA=1 OPENBURNBAR_LINUX_UPDATE_FEED_URL=https://downloads.example.test/latest-linux.json bash "$verifier" "$site_config")"
expected=$'https://downloads.example.test/linux-v9.9.9\n9.9.9\nOpenBurnBar_9.9.9_aarch64.AppImage\nOpenBurnBar_9.9.9_arm64.deb\nOpenBurnBar-9.9.9-1.aarch64.rpm\nopenburnbar-linux-ed25519.pub.pem\nhttps://downloads.example.test/latest-linux.json'
if [[ "$metadata" != "$expected" ]]; then
  echo "expected verifier to read exported Linux SITE values, got:" >&2
  printf '%s\n' "$metadata" >&2
  exit 1
fi

metadata_offline="$(OPENBURNBAR_PRINT_PUBLIC_LINUX_DOWNLOAD_METADATA=1 bash "$verifier" "$site_config")"
offline_feed_line="$(printf '%s\n' "$metadata_offline" | sed -n '7p')"
if [[ -n "$offline_feed_line" ]]; then
  echo "expected an empty feed URL (skip) when SITE.linuxUpdateBaseUrl is absent and no env override is set, got: $offline_feed_line" >&2
  exit 1
fi

with_update_base="$tmpdir/with-update-base.ts"
sed 's#linuxDownloadBaseUrl: "https://downloads.example.test/linux-v9.9.9",#linuxDownloadBaseUrl: "https://downloads.example.test/linux-v9.9.9",\n  linuxUpdateBaseUrl: "https://updates.example.test/",#' "$site_config" >"$with_update_base"
metadata_feed="$(OPENBURNBAR_PRINT_PUBLIC_LINUX_DOWNLOAD_METADATA=1 bash "$verifier" "$with_update_base")"
derived_feed_line="$(printf '%s\n' "$metadata_feed" | sed -n '7p')"
if [[ "$derived_feed_line" != "https://updates.example.test/latest-linux.json" ]]; then
  echo "expected feed URL derived from SITE.linuxUpdateBaseUrl, got: $derived_feed_line" >&2
  exit 1
fi

insecure_update_base="$tmpdir/insecure-update-base.ts"
sed 's#linuxUpdateBaseUrl: "https://updates.example.test/",#linuxUpdateBaseUrl: "http://updates.example.test/",#' "$with_update_base" >"$insecure_update_base"
if OPENBURNBAR_PRINT_PUBLIC_LINUX_DOWNLOAD_METADATA=1 bash "$verifier" "$insecure_update_base" >/dev/null 2>&1; then
  echo "expected verifier to reject non-https Linux update feed hosts" >&2
  exit 1
fi

bad_scheme="$tmpdir/bad-scheme.ts"
sed 's#https://downloads.example.test#http://downloads.example.test#' "$site_config" >"$bad_scheme"
if OPENBURNBAR_PRINT_PUBLIC_LINUX_DOWNLOAD_METADATA=1 bash "$verifier" "$bad_scheme" >/dev/null 2>&1; then
  echo "expected verifier to reject non-https Linux download URLs" >&2
  exit 1
fi

bad_name="$tmpdir/bad-name.ts"
sed 's#OpenBurnBar_9.9.9_arm64.deb#../OpenBurnBar_9.9.9_arm64.deb#' "$site_config" >"$bad_name"
if OPENBURNBAR_PRINT_PUBLIC_LINUX_DOWNLOAD_METADATA=1 bash "$verifier" "$bad_name" >/dev/null 2>&1; then
  echo "expected verifier to reject path traversal in Linux asset names" >&2
  exit 1
fi

echo "PASS: public Linux download trust verifier validates exported SITE metadata"
