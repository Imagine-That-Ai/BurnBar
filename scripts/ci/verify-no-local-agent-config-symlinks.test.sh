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

expect_guard_failure() {
  local message="$1"
  if REPO_ROOT_OVERRIDE="$tmp" bash "$guard" >/dev/null 2>&1; then
    echo "$message" >&2
    exit 1
  fi
}

mkdir -p "$tmp/.antigravitycli"
printf '{}\n' >"$tmp/.antigravitycli/local.json"
git -C "$tmp" add .antigravitycli/local.json
expect_guard_failure "expected root tracked local config path to fail"

git -C "$tmp" rm -q --cached .antigravitycli/local.json
rm -rf "$tmp/.antigravitycli"

mkdir -p "$tmp/nested/.gemini"
printf '{}\n' >"$tmp/nested/.gemini/local.json"
git -C "$tmp" add nested/.gemini/local.json
expect_guard_failure "expected nested tracked local config path to fail"

git -C "$tmp" rm -q --cached nested/.gemini/local.json
rm -rf "$tmp/nested"

mkdir -p "$tmp/.codex" "$tmp/.claude"
printf '{}\n' >"$tmp/.codex/auth.json"
printf '{}\n' >"$tmp/.claude/settings.local.json"
git -C "$tmp" add -f .codex/auth.json .claude/settings.local.json
expect_guard_failure "expected tracked Codex/Claude local config paths to fail"

git -C "$tmp" rm -q --cached .codex/auth.json .claude/settings.local.json
rm -rf "$tmp/.codex" "$tmp/.claude"

mkdir -p "$tmp/tracked"
ln -s /Users/example/.gemini/config/projects/example.json "$tmp/tracked/example.json"
git -C "$tmp" add tracked/example.json
expect_guard_failure "expected tracked absolute local-config symlink to fail"

git -C "$tmp" rm -q --cached tracked/example.json
rm -f "$tmp/tracked/example.json"

ln -s .gemini/config/projects/example.json "$tmp/tracked/relative-gemini.json"
git -C "$tmp" add tracked/relative-gemini.json
expect_guard_failure "expected tracked relative Gemini symlink to fail"

git -C "$tmp" rm -q --cached tracked/relative-gemini.json
rm -f "$tmp/tracked/relative-gemini.json"

ln -s .claude/settings.local.json "$tmp/tracked/relative-claude.json"
git -C "$tmp" add tracked/relative-claude.json
expect_guard_failure "expected tracked relative Claude symlink to fail"

printf '✓ local agent config symlink guard self-test passed\n'
