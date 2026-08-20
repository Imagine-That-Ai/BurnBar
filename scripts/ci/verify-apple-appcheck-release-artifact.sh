#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <.app|.dmg|.zip|.xcarchive|export-dir|plist|pkg> [...]" >&2
  exit 64
fi

tmpdirs=()
mounts=()

cleanup() {
  for mount in "${mounts[@]:-}"; do
    hdiutil detach "$mount" -quiet -force >/dev/null 2>&1 || true
  done
  for tmpdir in "${tmpdirs[@]:-}"; do
    rm -rf "$tmpdir"
  done
}
trap cleanup EXIT

scan_plists() {
  local root="$1"
  python3 - "$root" <<'PY'
from __future__ import annotations

import plistlib
import sys
from pathlib import Path
from typing import Any

root = Path(sys.argv[1])
token_keys = {"FirebaseAppCheckDebugToken", "FIRAAppCheckDebugToken"}
flag_key = "OpenBurnBarUseDebugAppCheck"
direct_feed_key = "OpenBurnBarDirectUpdateFeedURL"
sparkle_feed_key = "SUFeedURL"
expected_direct_feed = "https://downloads.burnbar.ai/latest-macos.json"
expected_sparkle_feed = "https://downloads.burnbar.ai/appcast.xml"
failed = False


def plist_candidates(scan_root: Path) -> list[Path]:
    if scan_root.is_file():
        return [scan_root]
    return [
        path
        for path in scan_root.rglob("*")
        if path.is_file() and (path.suffix.lower() == ".plist" or path.name in {"Info.plist", "GoogleService-Info.plist"})
    ]


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(root if root.is_dir() else root.parent))
    except ValueError:
        return str(path)


def truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y"}
    return False


def inspect(value: Any, path: Path) -> None:
    global failed
    if isinstance(value, dict):
        for key, child in value.items():
            if key in token_keys:
                failed = True
                print(
                    f"::error file={display_path(path)}::Forbidden Apple App Check debug material: "
                    f"{key} is present (value redacted).",
                    file=sys.stderr,
                )
            if key == flag_key and truthy(child):
                failed = True
                print(
                    f"::error file={display_path(path)}::Forbidden Apple App Check debug material: "
                    f"{flag_key} is truthy (value redacted).",
                    file=sys.stderr,
                )
            inspect(child, path)
    elif isinstance(value, list):
        for child in value:
            inspect(child, path)

def inspect_release_feeds(value: Any, path: Path) -> None:
    global failed
    if not isinstance(value, dict) or value.get("CFBundleIdentifier") != "com.openburnbar.app":
        return
    # The iOS app shares this bundle identifier but has no Sparkle feed keys.
    # Built plists carry platform markers: skip anything that is provably not
    # a macOS product (DTPlatformName iphoneos/..., or the iOS-only
    # MinimumOSVersion key). Source plists carry neither and stay enforced.
    platform_name = value.get("DTPlatformName")
    if isinstance(platform_name, str) and platform_name != "macosx":
        return
    if "MinimumOSVersion" in value:
        return
    expected = {
        direct_feed_key: expected_direct_feed,
        sparkle_feed_key: expected_sparkle_feed,
    }
    for key, expected_value in expected.items():
        if value.get(key) != expected_value:
            failed = True
            print(
                f"::error file={display_path(path)}::Release app {key} must equal "
                f"{expected_value}.",
                file=sys.stderr,
            )


for candidate in plist_candidates(root):
    try:
        payload = plistlib.loads(candidate.read_bytes())
    except Exception:
        continue
    inspect(payload, candidate)
    inspect_release_feeds(payload, candidate)

if failed:
    sys.exit(1)
PY
}

scan_archive_children() {
  local root="$1"
  local status=0
  local child

  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' child; do
    scan_path "$child" || status=1
  done < <(
    find "$root" -type f \( -name "*.zip" -o -name "*.ipa" -o -name "*.pkg" \) -print0
  )
  return "$status"
}

extract_zip() {
  local archive="$1"
  local destination="$2"

  if command -v ditto >/dev/null 2>&1; then
    ditto -x -k "$archive" "$destination"
  else
    unzip -q "$archive" -d "$destination"
  fi
}

extract_pkg() {
  local archive="$1"
  local destination="$2"

  if pkgutil --expand-full "$archive" "$destination" >/dev/null 2>&1; then
    return 0
  fi
  pkgutil --expand "$archive" "$destination"
}

scan_path() {
  local path="$1"
  local status=0
  local tmpdir
  local mountpoint
  local lower

  if [[ ! -e "$path" ]]; then
    echo "::error::Artifact path does not exist: $path" >&2
    return 1
  fi

  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.dmg)
      if ! command -v hdiutil >/dev/null 2>&1; then
        echo "::error::hdiutil is required to scan DMG artifacts: $path" >&2
        return 1
      fi
      mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-appcheck-dmg.XXXXXX")"
      tmpdirs+=("$mountpoint")
      hdiutil attach "$path" -mountpoint "$mountpoint" -nobrowse -readonly -quiet
      mounts+=("$mountpoint")
      scan_plists "$mountpoint" || status=1
      scan_archive_children "$mountpoint" || status=1
      ;;
    *.zip|*.ipa)
      tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-appcheck-zip.XXXXXX")"
      tmpdirs+=("$tmpdir")
      extract_zip "$path" "$tmpdir"
      scan_plists "$tmpdir" || status=1
      scan_archive_children "$tmpdir" || status=1
      ;;
    *.pkg)
      tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-appcheck-pkg.XXXXXX")"
      tmpdirs+=("$tmpdir")
      extract_pkg "$path" "$tmpdir"
      scan_plists "$tmpdir" || status=1
      scan_archive_children "$tmpdir" || status=1
      ;;
    *)
      scan_plists "$path" || status=1
      scan_archive_children "$path" || status=1
      ;;
  esac

  return "$status"
}

overall=0
for artifact in "$@"; do
  scan_path "$artifact" || overall=1
done

if [[ "$overall" == "0" ]]; then
  echo "Apple App Check release artifact scan passed."
fi
exit "$overall"
