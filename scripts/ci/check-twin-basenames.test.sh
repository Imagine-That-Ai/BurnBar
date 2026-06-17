#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p \
  "$tmp/docs" \
  "$tmp/AgentLens/Views" \
  "$tmp/OpenBurnBarMobile/Views" \
  "$tmp/AgentLens/Assets" \
  "$tmp/OpenBurnBarMobile/Assets"

cat >"$tmp/docs/LINT_RATIONALE.md" <<'EOF'
# Test rationale

<!-- BEGIN:twin-basename-allowlist -->
```text
AgentLens/Views/Allowed.swift | OpenBurnBarMobile/Views/Allowed.swift | platform-ui
AgentLens/Views/Missing.swift | OpenBurnBarMobile/Views/Missing.swift | platform-ui
```
<!-- END:twin-basename-allowlist -->
EOF

touch "$tmp/AgentLens/Views/Allowed.swift"
touch "$tmp/OpenBurnBarMobile/Views/Allowed.swift"
touch "$tmp/AgentLens/Assets/Icon.png"
touch "$tmp/OpenBurnBarMobile/Assets/Icon.png"

git -C "$tmp" init -q
git -C "$tmp" config user.email "ci@example.invalid"
git -C "$tmp" config user.name "CI"
git -C "$tmp" add .
git -C "$tmp" commit -qm init

TWIN_BASELINE_ROOT="$tmp" bash scripts/ci/check-twin-basenames.sh >/tmp/check-twin-clean.out 2>/tmp/check-twin-clean.err
grep -q "stale twin allowlist entry" /tmp/check-twin-clean.err

touch "$tmp/AgentLens/Views/NewTwin.swift"
touch "$tmp/OpenBurnBarMobile/Views/NewTwin.swift"
git -C "$tmp" add .

if TWIN_BASELINE_ROOT="$tmp" bash scripts/ci/check-twin-basenames.sh >/tmp/check-twin-bad.out 2>/tmp/check-twin-bad.err; then
  echo "FAIL: unallowlisted Swift twin basename was accepted" >&2
  exit 1
fi

grep -q "NewTwin.swift" /tmp/check-twin-bad.err

echo "PASS: twin-basename guard positive controls"
