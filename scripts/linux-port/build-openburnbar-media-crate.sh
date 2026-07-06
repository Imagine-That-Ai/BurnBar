#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROFILE="${OPENBURNBAR_MEDIA_CAPTURE_PROFILE:-debug}"
MANIFEST="$ROOT/crates/openburnbar-media/Cargo.toml"

args=(cargo build --manifest-path "$MANIFEST")
if [[ "$PROFILE" == "release" ]]; then
  args+=(--release)
elif [[ "$PROFILE" != "debug" ]]; then
  echo "OPENBURNBAR_MEDIA_CAPTURE_PROFILE must be debug or release." >&2
  exit 2
fi

"${args[@]}"

target_dir="$ROOT/crates/openburnbar-media/target/$PROFILE"
test -f "$target_dir/libopenburnbar_media.a" || test -f "$target_dir/libopenburnbar_media.so"
printf '%s\n' "$target_dir"
