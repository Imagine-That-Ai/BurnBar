#!/usr/bin/env bash
set -euo pipefail

repo_root="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root"

violations=()

is_local_agent_config_path() {
  case "$1" in
    .antigravitycli/*|*/.antigravitycli/*|\
    .gemini/*|*/.gemini/*|\
    .codex/*|*/.codex/*|\
    .claude/agent-memory/*|*/.claude/agent-memory/*|\
    .claude/settings.local.json|*/.claude/settings.local.json|\
    .claude/*.lock|*/.claude/*.lock|\
    .claude/worktrees/*|*/.claude/worktrees/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while IFS= read -r -d '' path; do
  if is_local_agent_config_path "$path"; then
    violations+=("tracked local agent config path: ${path}")
  fi
done < <(git ls-files -z)

while IFS= read -r -d '' entry; do
  meta="${entry%%$'\t'*}"
  path="${entry#*$'\t'}"
  read -r mode object _stage <<<"$meta"
  [[ "$mode" == "120000" ]] || continue

  target="$(git cat-file -p "$object")"
  case "$target" in
    /Users/*|/home/*|~/*|\
    .antigravitycli/*|*/.antigravitycli/*|\
    .gemini/*|*/.gemini/*|\
    .claude/*|*/.claude/*|\
    .codex/*|*/.codex/*)
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
