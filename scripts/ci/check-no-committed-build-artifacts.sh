#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

violations=()
while IFS= read -r -d '' path; do
  case "$path" in
    .lane-modulecache/*|*.pcm|*/ModuleCache/*|*/ModuleCache.noindex/*|DerivedData/*|*/DerivedData/*|.derived-data/*|*/.derived-data/*)
      violations+=("$path")
      ;;
  esac
done < <(git ls-files -z)

if (( ${#violations[@]} > 0 )); then
  echo "FAIL: tracked compiler/build artifacts are not allowed:" >&2
  printf '  %s\n' "${violations[@]:0:50}" >&2
  if (( ${#violations[@]} > 50 )); then
    echo "  ... ${#violations[@]} total violations" >&2
  fi
  echo "Remove them from git and keep them covered by .gitignore." >&2
  exit 1
fi

echo "PASS: no tracked compiler/build artifacts"
