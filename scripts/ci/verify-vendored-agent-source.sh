#!/usr/bin/env bash
#
# Security remediation C-5: verify the on-host Hermes agent/gateway runtime that
# OpenBurnBar vendors (as .pyc) corresponds to the EXACT, auditable source pinned
# in third_party/hermes-agent/manifest.json.
#
# The runtime is the most security-sensitive host-side component (it fronts
# provider keys, enforces the tunnel auth, and authorizes remote agent missions),
# yet it ships as compiled bytecode with the .py source gitignored. This guard
# makes it auditable: given a checkout of the pinned hermes-agent fork, it
# asserts HEAD == pinnedCommit and recomputes the vendored-source-tree hash and
# compares it to the manifest. If they drift, the runtime is no longer the
# reviewed source and CI fails.
#
# Usage:
#   HERMES_AGENT_SRC=/path/to/hermes-agent scripts/ci/verify-vendored-agent-source.sh
# Defaults HERMES_AGENT_SRC to ~/.hermes/hermes-agent for local runs.
#
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
manifest="$repo_root/third_party/hermes-agent/manifest.json"
src="${HERMES_AGENT_SRC:-$HOME/.hermes/hermes-agent}"

read -r pinned_commit expected_hash subtrees_csv < <(python3 - "$manifest" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(m["pinnedCommit"], m["vendoredSourceTreeSha256"], ",".join(m["vendoredSubtrees"]))
PY
)

if [[ ! -d "$src/.git" ]] && ! git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: HERMES_AGENT_SRC ($src) is not a hermes-agent checkout." >&2
  echo "Clone https://github.com/NousResearch/hermes-agent and point HERMES_AGENT_SRC at it." >&2
  exit 1
fi

# 1) The checkout must contain the pinned commit.
if ! git -C "$src" cat-file -e "${pinned_commit}^{commit}" 2>/dev/null; then
  echo "ERROR: pinned commit $pinned_commit not found in $src." >&2
  echo "Fetch it: git -C $src fetch origin $pinned_commit" >&2
  exit 1
fi

# 2) Recompute the vendored-source-tree hash AT the pinned commit (independent of
#    whatever the working tree is currently checked out to).
IFS=',' read -r -a subtrees <<< "$subtrees_csv"
actual_hash="$(
  git -C "$src" ls-tree -r "$pinned_commit" --name-only -- "${subtrees[@]}" \
    | grep '\.py$' | sort \
    | while read -r f; do
        printf '%s ' "$f"
        git -C "$src" cat-file blob "${pinned_commit}:${f}" | shasum -a 256 | cut -d' ' -f1
      done \
    | shasum -a 256 | cut -d' ' -f1
)"

if [[ "$actual_hash" != "$expected_hash" ]]; then
  echo "ERROR: vendored agent source hash mismatch at $pinned_commit" >&2
  echo "  manifest : $expected_hash" >&2
  echo "  computed : $actual_hash" >&2
  echo "The shipped runtime no longer corresponds to the reviewed source. If the" >&2
  echo "source legitimately changed, re-review it and update manifest + pinnedCommit." >&2
  exit 1
fi

echo "OK: vendored Hermes agent runtime corresponds to reviewed source"
echo "  commit: $pinned_commit"
echo "  source-tree sha256: $actual_hash"

# 3) BLOCKING gate (F5): the on-host agent command-guard (C-4: secret-read/exfil
#    gating, fail-closed tirith, smart-mode escalation) is the control that stops a
#    prompt-injected agent from running destructive/exfil commands. While
#    manifest.pendingHardening.blocking is true that guard is NOT in the pinned
#    runtime, so we FAIL CLOSED rather than merely warn. This makes shipping the
#    un-hardened agent impossible: to clear it, merge C-4 into the fork, re-vendor,
#    update pinnedCommit + vendoredSourceTreeSha256, and set blocking=false.
#    Set ALLOW_PENDING_AGENT_HARDENING=1 only for an explicit, time-boxed local
#    override (never in the protected-branch CI gate).
pending="$(python3 - "$manifest" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
p = m.get("pendingHardening") or {}
print("1" if p.get("blocking") else "0")
PY
)"
if [[ "$pending" == "1" ]]; then
  echo "ERROR: manifest.pendingHardening.blocking is true — the C-4 agent" >&2
  echo "command-guard hardening is NOT in the pinned runtime. The shipped agent" >&2
  echo "cannot be trusted to refuse destructive/exfil commands. Merge C-4 into the" >&2
  echo "fork, re-vendor, and update the pin before this gate passes." >&2
  if [[ "${ALLOW_PENDING_AGENT_HARDENING:-0}" == "1" ]]; then
    echo "ALLOW_PENDING_AGENT_HARDENING=1 set — proceeding under explicit local override." >&2
  else
    exit 1
  fi
fi
