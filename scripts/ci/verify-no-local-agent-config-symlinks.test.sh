#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="${script_dir}/verify-no-local-agent-config-symlinks.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -C "$tmp" init -q
printf '# temp\n' >"$tmp/README.md"
git -C "$tmp" add README.md

REPO_ROOT_OVERRIDE="$tmp" bash "$guard" >/dev/null

mkdir -p "$tmp/.antigravitycli"
printf '{}\n' >"$tmp/.antigravitycli/local.json"
git -C "$tmp" add .antigravitycli/local.json
if REPO_ROOT_OVERRIDE="$tmp" bash "$guard" >/dev/null 2>&1; then
  echo "expected tracked local config path to fail" >&2
  exit 1
fi

git -C "$tmp" rm -q --cached .antigravitycli/local.json
rm -rf "$tmp/.antigravitycli"

mkdir -p "$tmp/tracked"
ln -s /Users/example/.gemini/config/projects/example.json "$tmp/tracked/example.json"
git -C "$tmp" add tracked/example.json
if REPO_ROOT_OVERRIDE="$tmp" bash "$guard" >/dev/null 2>&1; then
  echo "expected tracked local-config symlink to fail" >&2
  exit 1
fi

printf '✓ local agent config symlink guard self-test passed\n'
