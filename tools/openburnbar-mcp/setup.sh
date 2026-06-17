#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"

if [ -d .venv ] && ! ./.venv/bin/python -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
  echo "WARN: existing .venv is broken or path-stale; recreating it."
  rm -rf .venv
fi
python3 -m venv .venv
./.venv/bin/python -m pip install -U pip
./.venv/bin/python -m pip install -r requirements.txt

# --- Build/verify Project Code Memory static parser helper ---
PARSER_MANIFEST="$REPO_ROOT/crates/project-code-static-parser/Cargo.toml"
PARSER_BIN="$REPO_ROOT/crates/project-code-static-parser/target/release/project-code-static-parser"
PARSER_STALE="false"
if [ -x "$PARSER_BIN" ] && find "$REPO_ROOT/crates/project-code-static-parser/src" "$REPO_ROOT/crates/project-code-static-parser/tests" -type f -newer "$PARSER_BIN" | grep -q .; then
  PARSER_STALE="true"
fi

if [ ! -x "$PARSER_BIN" ] || [ "$PARSER_STALE" = "true" ]; then
  if [ "${OPENBURNBAR_MCP_ALLOW_LEXICAL_ONLY:-}" = "true" ]; then
    echo "WARN: project-code-static-parser missing/stale; continuing with lexical-only Project Code Memory setup."
  else
    command -v cargo >/dev/null 2>&1 || {
      echo "ERROR: cargo is required to build project-code-static-parser." >&2
      echo "Install Rust or set OPENBURNBAR_MCP_ALLOW_LEXICAL_ONLY=true to skip the static tier explicitly." >&2
      exit 1
    }
    if [ "$PARSER_STALE" = "true" ]; then
      echo "INFO: project-code-static-parser source changed; rebuilding release helper."
    fi
    cargo build --manifest-path "$PARSER_MANIFEST" --release
  fi
fi

if [ -x "$PARSER_BIN" ]; then
  PARSER_BIN="$PARSER_BIN" ./.venv/bin/python - <<'PY'
import hashlib
import json
import os
import subprocess
import sys

text = "func setupProbe() { print(\"project-code-static-parser\") }\n"
blob = hashlib.sha1(f"blob {len(text.encode())}\0".encode() + text.encode()).hexdigest()
request = {
    "requestId": "setup-smoke",
    "filePath": "SetupProbe.swift",
    "language": "swift",
    "blobSha": blob,
    "text": text,
}
completed = subprocess.run(
    [os.environ["PARSER_BIN"]],
    input=json.dumps(request, separators=(",", ":")) + "\n",
    capture_output=True,
    text=True,
    check=False,
    timeout=5,
)
if completed.returncode != 0:
    sys.stderr.write(completed.stderr)
    raise SystemExit("project-code-static-parser smoke failed")
line = next((line for line in completed.stdout.splitlines() if line.strip()), "")
payload = json.loads(line)
names = {symbol.get("name") for symbol in payload.get("symbols", [])}
if not payload.get("ok") or payload.get("blobSha") != blob or "setupProbe" not in names:
    raise SystemExit(f"project-code-static-parser smoke returned unexpected payload: {payload!r}")
PY
  echo "OK: project-code-static-parser verified → $PARSER_BIN"
fi

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
