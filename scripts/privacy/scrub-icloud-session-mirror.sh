#!/usr/bin/env bash
set -euo pipefail

apply=false

for arg in "$@"; do
  case "$arg" in
    --apply)
      apply=true
      ;;
    --dry-run)
      apply=false
      ;;
    --help|-h)
      cat <<'USAGE'
Usage:
  scripts/privacy/scrub-icloud-session-mirror.sh
  scripts/privacy/scrub-icloud-session-mirror.sh --apply

Dry-run by default. Removes legacy raw OpenBurnBar SessionMirror folders from
this Mac's iCloud Drive app-container paths when --apply is passed.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

paths=(
  "$HOME/Library/Mobile Documents/iCloud~com~openburnbar~app/Documents/OpenBurnBar/SessionMirror"
  "$HOME/Library/Mobile Documents/iCloud.com.openburnbar.app/Documents/OpenBurnBar/SessionMirror"
)

found=false

for mirror_path in "${paths[@]}"; do
  if [[ ! -e "$mirror_path" ]]; then
    echo "Not found: $mirror_path"
    continue
  fi

  found=true
  echo "Inspecting legacy raw iCloud mirror: $mirror_path"
  file_count="$(find "$mirror_path" -type f 2>/dev/null | wc -l | tr -d ' ')"
  dir_count="$(find "$mirror_path" -type d 2>/dev/null | wc -l | tr -d ' ')"
  size_kb="$(du -sk "$mirror_path" 2>/dev/null | awk '{print $1}')"
  size_kb="${size_kb:-0}"

  echo "Found legacy raw iCloud mirror:"
  echo "  path: $mirror_path"
  echo "  files: $file_count"
  echo "  dirs: $dir_count"
  echo "  size_kb: $size_kb"

  if [[ "$apply" == true ]]; then
    rm -rf "$mirror_path"
    echo "  removed"
  else
    echo "  dry-run only; pass --apply to remove"
  fi
done

if [[ "$found" == false ]]; then
  echo "No legacy raw iCloud SessionMirror folders found."
fi
