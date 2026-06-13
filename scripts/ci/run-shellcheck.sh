#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck is required" >&2
  exit 127
fi

shell_scripts=()
zsh_scripts=()

while IFS= read -r -d '' script; do
  shebang="$(head -n 1 "$script" 2>/dev/null || true)"
  case "$shebang" in
    *zsh*)
      zsh_scripts+=("$script")
      ;;
    *)
      shell_scripts+=("$script")
      ;;
  esac
done < <(find scripts/ -name '*.sh' -print0)

if ((${#shell_scripts[@]} > 0)); then
  shellcheck --severity=warning "${shell_scripts[@]}"
fi

if ((${#zsh_scripts[@]} > 0)); then
  if ! command -v zsh >/dev/null 2>&1; then
    echo "zsh is required to syntax-check zsh scripts: ${zsh_scripts[*]}" >&2
    exit 127
  fi
  for script in "${zsh_scripts[@]}"; do
    zsh -n "$script"
  done
fi
