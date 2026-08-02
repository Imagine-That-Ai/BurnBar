#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <.app|.dmg|.zip|.xcarchive|export-dir> [...]" >&2
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

scan_apps_for_firebase_config() {
  local root="$1"
  python3 - "$root" <<'PY'
from __future__ import annotations

import plistlib
import sys
from pathlib import Path
from typing import Any

root = Path(sys.argv[1])
required = ("GOOGLE_APP_ID", "PROJECT_ID", "REVERSED_CLIENT_ID", "CLIENT_ID", "API_KEY")
forbidden = ("FirebaseAppCheckDebugToken", "FIRAAppCheckDebugToken", "OpenBurnBarUseDebugAppCheck")
placeholder_markers = (
    "YOUR_",
    "REPLACE_",
    "EXAMPLE_",
    "PLACEHOLDER",
    "CHANGEME",
    "CHANGE_ME",
    "TODO",
    "TBD",
)


def app_bundles(scan_root: Path) -> list[Path]:
    if scan_root.is_dir() and scan_root.suffix == ".app":
        return [scan_root]
    if not scan_root.is_dir():
        return []
    return sorted(path for path in scan_root.rglob("*.app") if path.is_dir())


def display(path: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y", "on"}
    return False


def is_placeholder(value: str) -> bool:
    normalized = value.strip().upper()
    return not normalized or any(marker in normalized for marker in placeholder_markers)


failed = False
apps = app_bundles(root)
if not apps:
    print(f"::error::No .app bundle found under {root}", file=sys.stderr)
    raise SystemExit(1)

for app in apps:
    # macOS app resources live under Contents/Resources, while iOS/iPadOS
    # app resources are copied directly into the bundle root.
    if (app / "Contents").is_dir():
        plist = app / "Contents" / "Resources" / "GoogleService-Info.plist"
    else:
        plist = app / "GoogleService-Info.plist"
    if not plist.is_file():
        failed = True
        print(
            f"::error file={display(app)}::GoogleService-Info.plist is missing from the app bundle.",
            file=sys.stderr,
        )
        continue

    try:
        payload = plistlib.loads(plist.read_bytes())
    except Exception as exc:
        failed = True
        print(
            f"::error file={display(plist)}::GoogleService-Info.plist is not a valid plist: {exc}",
            file=sys.stderr,
        )
        continue

    missing = []
    for key in required:
        value = str(payload.get(key, "")).strip()
        if is_placeholder(value):
            missing.append(key)
    if missing:
        failed = True
        print(
            f"::error file={display(plist)}::GoogleService-Info.plist is missing required release keys: "
            + ", ".join(missing),
            file=sys.stderr,
        )

    for key in forbidden:
        if key in payload and (key != "OpenBurnBarUseDebugAppCheck" or truthy(payload[key])):
            failed = True
            print(
                f"::error file={display(plist)}::GoogleService-Info.plist contains forbidden release key {key} (value redacted).",
                file=sys.stderr,
            )

if failed:
    raise SystemExit(1)

print(f"PASS: Firebase release config present in {len(apps)} app bundle(s).")
PY
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

scan_path() {
  local path="$1"
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
      mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-firebase-dmg.XXXXXX")"
      tmpdirs+=("$mountpoint")
      hdiutil attach "$path" -mountpoint "$mountpoint" -nobrowse -readonly -quiet
      mounts+=("$mountpoint")
      scan_apps_for_firebase_config "$mountpoint"
      ;;
    *.zip|*.ipa)
      tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-firebase-zip.XXXXXX")"
      tmpdirs+=("$tmpdir")
      extract_zip "$path" "$tmpdir"
      scan_apps_for_firebase_config "$tmpdir"
      ;;
    *)
      scan_apps_for_firebase_config "$path"
      ;;
  esac
}

for path in "$@"; do
  scan_path "$path"
done
