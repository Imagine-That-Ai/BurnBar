#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/dev-mac.sh"

if grep -F 'cd "$REPO_ROOT"' "$script" >/dev/null; then
  echo "scripts/dev-mac.sh must not embed REPO_ROOT inside the tmux shell command." >&2
  exit 1
fi

if grep -F '&& "$ABS_APP_PATH' "$script" >/dev/null; then
  echo "scripts/dev-mac.sh must not embed ABS_APP_PATH inside the tmux shell command." >&2
  exit 1
fi

if ! grep -F -- '-c "$REPO_ROOT"' "$script" >/dev/null; then
  echo "scripts/dev-mac.sh must pass the tmux start directory with -c." >&2
  exit 1
fi

if ! grep -F -- '-e "OPENBURNBAR_DEV_APP_EXEC=$OPENBURNBAR_DEV_APP_EXEC"' "$script" >/dev/null; then
  echo "scripts/dev-mac.sh must pass the app executable path through tmux environment." >&2
  exit 1
fi

if ! grep -F -- "'exec \"\$OPENBURNBAR_DEV_APP_EXEC\"'" "$script" >/dev/null; then
  echo "scripts/dev-mac.sh tmux shell command must remain constant and quote the env-expanded app path." >&2
  exit 1
fi
