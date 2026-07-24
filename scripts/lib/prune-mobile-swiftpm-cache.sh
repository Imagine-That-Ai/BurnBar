#!/usr/bin/env bash
# Remove binary SwiftPM artifacts that are not part of the mobile test host.
#
# OpenBurnBarMobile links the static `Sentry` product. The Sentry package also
# publishes four other binary products (dynamic and headless variants); Xcode
# can materialize all five into the package cache even when the selected
# target only needs the static product. Those copies are large enough to push
# a physical-device build over the repository's local hygiene ceiling.
#
# This helper is deliberately narrow and opt-in. The caller must validate that
# the cache is an owned scratch path before invoking it.

set -euo pipefail

usage() {
  echo "usage: $0 <swiftpm-cache-root>" >&2
  exit 64
}

[[ $# -eq 1 ]] || usage
cache_root="$1"
[[ "$cache_root" == /* ]] || {
  echo "error: SwiftPM cache root must be absolute: $cache_root" >&2
  exit 64
}

cache_root="$(python3 - "$cache_root" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"

sentry_root="$cache_root/artifacts/sentry-cocoa"
[[ -d "$sentry_root" ]] || exit 0

kept=0
removed=0
for artifact in "$sentry_root"/*; do
  [[ -d "$artifact" ]] || continue
  if [[ "$(basename "$artifact")" == "Sentry" ]]; then
    kept=$((kept + 1))
    continue
  fi
  rm -rf "$artifact"
  removed=$((removed + 1))
done

if [[ "$removed" -gt 0 ]]; then
  echo ">>> Pruned $removed unused Sentry SwiftPM artifact variant(s); retained static Sentry=${kept}"
fi
