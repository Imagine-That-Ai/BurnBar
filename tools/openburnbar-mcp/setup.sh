#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -m venv .venv
./.venv/bin/pip install -U pip
./.venv/bin/pip install -r requirements.txt

# --- Install burnbar-operator Hermes skill ---
HERMES_SKILLS_DIR="$HOME/.hermes/skills/software-development/burnbar-operator"
REPO_SKILL="$(pwd)/hermes-skill/SKILL.md"
TARGET="$HERMES_SKILLS_DIR/SKILL.md"

if [ -d "$HOME/.hermes" ]; then
  mkdir -p "$HERMES_SKILLS_DIR"
  # Symlink repo SKILL.md → ~/.hermes/skills/... (repo is source of truth)
  if [ -L "$TARGET" ]; then
    rm "$TARGET"
  fi
  # Remove stale plain file if present
  if [ -f "$TARGET" ] && [ ! -L "$TARGET" ]; then
    rm "$TARGET"
  fi
  ln -sf "$REPO_SKILL" "$TARGET"
  echo "OK: Hermes skill linked → $TARGET"
else
  echo "NOTE: ~/.hermes not found — skipping Hermes skill install. Re-run after Hermes setup."
fi

echo ""
echo "OK: use $(pwd)/.venv/bin/python $(pwd)/server.py in MCP config"
