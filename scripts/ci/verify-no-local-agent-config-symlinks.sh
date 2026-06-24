#!/usr/bin/env bash
set -euo pipefail

repo_root="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root"

violations=()

while IFS= read -r -d '' path; do
  violations+=("tracked local agent config path: ${path}")
done < <(git ls-files -z -- .antigravitycli .gemini)

while IFS= read -r -d '' entry; do
  meta="${entry%%$'\t'*}"
  path="${entry#*$'\t'}"
  read -r mode object _stage <<<"$meta"
  [[ "$mode" == "120000" ]] || continue

  target="$(git cat-file -p "$object")"
  case "$target" in
    /Users/*|/home/*|~/*|*/.gemini/config/*|*/.claude/*|*/.codex/*)
      violations+=("tracked symlink points at local agent state: ${path} -> ${target}")
      ;;
  esac
done < <(git ls-files -s -z)

if ((${#violations[@]} > 0)); then
  printf 'Local agent config must not be tracked:\n' >&2
  printf ' - %s\n' "${violations[@]}" >&2
  exit 1
fi

printf '✓ no tracked local agent config symlinks or paths\n'
