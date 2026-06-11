#!/usr/bin/env bash
# SOTASIGNAL Phase F / Rule-0 — ownership guard.
#
# The plan forbids the Signal implementation branch from touching legally/ownership
# sensitive paths without an explicit handoff. This gate diffs the current branch
# against a base ref and FAILS if any changed file matches a Rule-0 glob. Run it in
# the Signal producer CI (and locally before pushing).
#
# Usage: scripts/ci/verify-signal-rule0.sh [base-ref]   (default: origin/main)
set -euo pipefail
cd "$(dirname "$0")/../.."

BASE="${1:-origin/main}"

# Resolve a usable base; fall back to merge-base, then to a no-op (empty diff).
if git rev-parse --verify --quiet "$BASE" >/dev/null; then
  MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"
else
  echo "note: base ref '$BASE' not found; comparing against HEAD~1 if present."
  MERGE_BASE="$(git rev-parse --verify --quiet HEAD~1 || true)"
fi

if [[ -z "${MERGE_BASE:-}" ]]; then
  echo "note: no base commit to diff against; treating working tree as the change set."
  CHANGED="$(git status --porcelain | awk '{print $2}')"
else
  CHANGED="$(git diff --name-only "$MERGE_BASE"...HEAD; git status --porcelain | awk '{print $2}')"
fi
CHANGED="$(printf '%s\n' "$CHANGED" | sort -u | sed '/^$/d')"

# Rule-0 protected globs (extended regex over repo-relative paths). Includes the
# vendored AGPL libsignal submodule + its FFI binary + .gitmodules (so a branch
# cannot repoint the submodule at a hostile fork and pass), and de-anchors the
# license/notice/third-party names so subdirectory copies are also protected.
#
# Remediation R2: the Vendor paths are SLASH-OPTIONAL — `(/|$)` — because a
# registered submodule gitlink (mode 160000) is reported by `git diff --name-only` /
# `git status --porcelain` as the BARE path with no trailing slash. The old
# `Vendor/libsignal/` (slash-required) form let a gitlink pointer-bump escape.
#
# Scope: LEGAL / SUPPLY-CHAIN tamper vectors only. The trust CLAIMS surface
# (website/src/data/trust*, trust.generated.*) is intentionally NOT protected here:
# it legitimately changes whenever the trust page is regenerated from registry.json,
# and it is already gated by the registry drift gate (git diff --exit-code) plus
# verify-signal-honesty-copy.sh. Hard-forbidding it via Rule-0 would block every
# honest trust-page update — which is precisely why this guard could not previously
# run as a wired, fail-closed PR gate. Keeping Rule-0 focused on ownership/legal
# paths lets it enforce on every PR (its actual purpose: block a hostile libsignal
# submodule/FFI swap or a license/third-party edit) without false-blocking copy.
RULE0='(^|/)(Vendor/libsignal(/|$)|Vendor/OpenBurnBarSignalFfi\.xcframework(/|$)|packages/libsignal-bridge/|third_party/|LICENSES/|THIRD_PARTY|REUSE\.toml|LICENSE|NOTICE)|(^|/)\.gitmodules$'

# Owner-routed exception (exactly one path): third_party/hermes-agent/
# manifest.json is the provenance PIN that the C-5 gate REQUIRES updating on
# every vendored-agent bump — an unconditional block here is why a previous
# bump was kept out of its PR entirely, splitting the attestation from the
# gate (diligence 2026-06-11 LB-4). The handoff Rule-0 demands ("route
# through the legal/ownership owner") is expressed as an explicit, auditable
# `Rule0-Ack: <reason>` trailer in a branch commit message: the owner writes
# the ack, the trailer is permanent history, and the C-5 verifier
# (verify-vendored-agent-source.sh, required on PRs) independently validates
# the manifest's pin+hash in the same run. Every OTHER protected path —
# libsignal submodule, FFI binary, .gitmodules, LICENSES — remains
# unconditional, and in degraded no-base mode the exception is disabled.
ack_present=0
if [[ -n "${MERGE_BASE:-}" ]] && git log "$MERGE_BASE..HEAD" --format=%B 2>/dev/null | grep -Eq '^Rule0-Ack: \S'; then
  ack_present=1
fi

violations=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if printf '%s' "$f" | grep -Eq "$RULE0"; then
    if [[ "$f" == "third_party/hermes-agent/manifest.json" && "$ack_present" == "1" ]]; then
      echo "  RULE-0 ACK (owner-routed): $f — Rule0-Ack trailer present; C-5 verifier validates the pin in this run."
      continue
    fi
    echo "  RULE-0 VIOLATION: $f"
    violations=$((violations + 1))
  fi
done <<< "$CHANGED"

# Defense-in-depth (Remediation R2): diff the vendored submodule/xcframework contents
# directly against the base. A pointer advance to a malicious commit on the SAME
# upstream URL leaves .gitmodules untouched and changes only the bare gitlink — the
# slash-optional regex above now catches the bare path, and this content-diff is a
# second, path-form-independent guard. Skipped only in the degraded no-base mode.
if [[ -n "${MERGE_BASE:-}" ]]; then
  for sub in Vendor/libsignal Vendor/OpenBurnBarSignalFfi.xcframework; do
    if git diff "$MERGE_BASE"...HEAD -- "$sub" 2>/dev/null | grep -q .; then
      echo "  RULE-0 VIOLATION: $sub (submodule/vendor pointer or contents changed vs base)"
      violations=$((violations + 1))
    fi
  done
fi

# License fields inside package manifests are also Rule-0; flag a changed manifest
# whose 'license' line differs from the base (best-effort; informational hard-fail).
for manifest in $(printf '%s\n' "$CHANGED" | grep -E 'package\.json$' || true); do
  [[ -f "$manifest" ]] || continue
  if [[ -n "${MERGE_BASE:-}" ]] && git show "$MERGE_BASE:$manifest" >/dev/null 2>&1; then
    base_lic="$(git show "$MERGE_BASE:$manifest" | grep -E '"license"' || true)"
    head_lic="$(grep -E '"license"' "$manifest" || true)"
    if [[ "$base_lic" != "$head_lic" ]]; then
      echo "  RULE-0 VIOLATION: license field changed in $manifest"
      violations=$((violations + 1))
    fi
  fi
done

if [[ "$violations" -eq 0 ]]; then
  echo "Rule-0 OK — no protected path modified by this branch."
  exit 0
fi
echo "Rule-0 FAILED — $violations protected path(s) modified. Route through the legal/ownership owner."
exit 1
