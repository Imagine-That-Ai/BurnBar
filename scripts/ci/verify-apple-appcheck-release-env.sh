#!/usr/bin/env bash

set -euo pipefail

failures=()

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | xargs)" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

record_failure() {
  failures+=("$1")
}

if truthy "${OPENBURNBAR_USE_DEBUG_APP_CHECK:-}"; then
  record_failure "OPENBURNBAR_USE_DEBUG_APP_CHECK must not be enabled for public Apple release artifacts."
fi

for var in FIREBASE_APP_CHECK_DEBUG_TOKEN FirebaseAppCheckDebugToken FIRAAppCheckDebugToken; do
  if [[ -n "${!var:-}" ]]; then
    record_failure "$var must be unset for public Apple release artifacts."
  fi
done

if [[ -n "${FIREBASE_PLIST_BASE64:-}" ]]; then
  python3 - <<'PY' || record_failure "FIREBASE_PLIST_BASE64 contains Apple App Check debug material."
from __future__ import annotations

import base64
import os
import plistlib
import sys
from typing import Any

debug_keys = {"FirebaseAppCheckDebugToken", "FIRAAppCheckDebugToken"}
flag_key = "OpenBurnBarUseDebugAppCheck"


def truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y", "on"}
    return False


def inspect(value: Any, path: tuple[str, ...] = ()) -> list[str]:
    failures: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key)
            child_path = (*path, key_text)
            if key_text in debug_keys:
                failures.append(".".join(child_path))
            if key_text == flag_key and truthy(child):
                failures.append(".".join(child_path))
            failures.extend(inspect(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            failures.extend(inspect(child, (*path, str(index))))
    return failures


try:
    payload = plistlib.loads(base64.b64decode(os.environ["FIREBASE_PLIST_BASE64"], validate=True))
except Exception as exc:
    print(f"::error::Unable to decode FIREBASE_PLIST_BASE64 for Apple App Check release policy: {exc}", file=sys.stderr)
    raise SystemExit(1)

matches = inspect(payload)
if matches:
    for match in matches:
        print(
            f"::error::FIREBASE_PLIST_BASE64 contains forbidden Apple App Check debug key {match} (value redacted).",
            file=sys.stderr,
        )
    raise SystemExit(1)
PY
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  for failure in "${failures[@]}"; do
    echo "::error::$failure" >&2
  done
  exit 1
fi

echo "Apple App Check public release environment policy passed."
