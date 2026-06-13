#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck is required." >&2
  exit 127
fi

scripts=()
while IFS= read -r -d '' script; do
  first_line="$(sed -n '1p' "$script")"
  case "$first_line" in
    "#!"*"/zsh"|"#!"*"/env zsh")
      echo "Skipping $script: zsh is not supported by ShellCheck."
      ;;
    *)
      scripts+=("$script")
      ;;
  esac
done < <(find scripts/ -name '*.sh' -print0)

if [[ "${#scripts[@]}" -eq 0 ]]; then
  echo "No ShellCheck-compatible shell scripts found."
  exit 0
fi

shellcheck --severity=warning "${scripts[@]}"
