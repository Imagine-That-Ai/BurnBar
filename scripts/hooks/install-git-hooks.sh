#!/usr/bin/env bash
# Install repo git hooks into this clone's .git/hooks. Idempotent; run once per
# clone. Coexists with the wiki post-commit hook (scripts/wiki/install-hooks.sh)
# by installing a distinct pre-push hook rather than taking over core.hooksPath.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook_dir="$(git -C "${repo_root}" rev-parse --git-path hooks)"
mkdir -p "${hook_dir}"

src="${repo_root}/scripts/hooks/pre-push"
dest="${hook_dir}/pre-push"

if [[ -f "${dest}" ]] && ! grep -q "preserve/\* tags" "${dest}" 2>/dev/null; then
  echo "warning: an unrelated pre-push hook already exists at ${dest}; leaving it in place." >&2
  echo "         Merge in scripts/hooks/pre-push manually to keep the preserve-tag guard." >&2
  exit 0
fi

cp "${src}" "${dest}"
chmod +x "${dest}"
echo "Installed pre-push guard -> ${dest}"
