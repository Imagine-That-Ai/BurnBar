#!/usr/bin/env bash
# Verifies the Cure53 supply-chain / CI hardening invariants (T-SC-02..T-SC-10)
# are present in the workflow + CODEOWNERS surface this repo ships. Each check
# asserts the *file-local* control that the remediation added, so a future edit
# that reverts a control (re-introducing a fail-open path) turns this red.
#
# This is a static, network-free assertion harness: it greps the committed
# workflow/CODEOWNERS text rather than executing GitHub Actions. Run it locally
# or wire it into a CI lane:
#   bash scripts/ci/verify-supply-chain-hardening.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

fail=0
pass_count=0

require() {
  # require <description> <file> <grep-args...>
  local desc="$1" file="$2"
  shift 2
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $desc — file not found: $file"
    fail=1
    return
  fi
  if grep -Eq "$@" "$file"; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (pattern not found in $file)"
    fail=1
  fi
}

refute() {
  # refute <description> <file> <grep-args...>  (pattern must be ABSENT)
  local desc="$1" file="$2"
  shift 2
  if [[ -f "$file" ]] && grep -Eq "$@" "$file"; then
    echo "FAIL: $desc (forbidden pattern present in $file)"
    fail=1
  else
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  fi
}

echo "=== Supply-chain / CI hardening invariants ==="

PROV=".github/workflows/supply-chain-provenance.yml"
REL=".github/workflows/release.yml"
DEPLOY=".github/workflows/deploy-production.yml"
SAST=".github/workflows/rust-sast.yml"
CODEOWNERS=".github/CODEOWNERS"
DROID=".github/workflows/droid-wiki-refresh.yml"
LOOPBACK=".github/workflows/computer-use-loopback-test.yml"

# T-SC-02: ecosystem-deny actually installs cargo-deny + osv-scanner and asserts
# they are present (fail closed) before invoking the script.
require "T-SC-02 installs cargo-deny for ecosystem-deny" "$PROV" 'cargo install cargo-deny'
require "T-SC-02 installs osv-scanner for ecosystem-deny" "$PROV" 'osv-scanner/releases/download'
require "T-SC-02 fail-closed assert on missing scanners" "$PROV" 'refusing to run a fail-open ecosystem-deny check'

# T-SC-03: CODEOWNERS adds a second required reviewer on sensitive paths.
require "T-SC-03 second owner on workflows dir" "$CODEOWNERS" '^\.github/workflows/ +@Ajnunezg +@Ajnunezg/security-reviewers'
require "T-SC-03 second owner on firestore.rules" "$CODEOWNERS" '^firestore\.rules +@Ajnunezg +@Ajnunezg/security-reviewers'
require "T-SC-03 second owner on release.yml" "$CODEOWNERS" 'release\.yml +@Ajnunezg +@Ajnunezg/security-reviewers'

# T-SC-04: OSV-Scanner fed the Rust Cargo.lock graphs. (SwiftPM Package.resolved
# OSV coverage is pending a scanner version with a working SwiftPM extractor —
# OSV-Scanner v2.3.8 cannot determine an extractor for Package.resolved; see the
# NOTE in rust-sast.yml. Assert only the Rust lockfiles so the verifier matches
# what the scanner can actually parse.)
require "T-SC-04 osv scans iroh Cargo.lock" "$SAST" 'crates/openburnbar-iroh/Cargo.lock'
require "T-SC-04 osv scans burnbar-remote Cargo.lock" "$SAST" 'crates/burnbar-remote/Cargo.lock'

# T-SC-06: RELEASE_SIGNING_KEY in the fail-closed strict-secret gate + publish
# refuses an unsigned-checksum release.
require "T-SC-06 RELEASE_SIGNING_KEY in strict gate loop" "$REL" '^ +RELEASE_SIGNING_KEY \\$'
require "T-SC-06 publish fails closed on missing signature" "$REL" 'refusing to publish an unsigned-checksum release'

# T-SC-07: predeploy build runs unprivileged BEFORE auth; privileged deploy
# strips the predeploy hook and verifies the build fingerprint.
require "T-SC-07 unprivileged pre-auth build step" "$DEPLOY" 'Build Functions and verifiers \(unprivileged, pre-auth\)'
require "T-SC-07 strips predeploy hook at deploy time" "$DEPLOY" 'del\(\.predeploy\)'
require "T-SC-07 verifies build fingerprint post-auth" "$DEPLOY" 'functions/lib changed after GCP auth'

# T-SC-08: SBOM/attestation bound to downloaded published artifacts, fail closed
# when artifacts are missing.
require "T-SC-08 fails closed on missing artifacts" "$PROV" 'refusing to attest a release with no as-shipped bytes'
# shellcheck disable=SC2016 # literal grep pattern — $subject must NOT expand here.
require "T-SC-08 attests over published artifact subjects" "$PROV" 'attesting \$subject'

# T-SC-09: workflow_run gate verifies triggering run identity/provenance.
require "T-SC-09 gate checks triggering workflow name" "$PROV" "workflow_run.name == 'OpenBurnBar Release'"
require "T-SC-09 gate rejects forks" "$PROV" 'head_repository.full_name == github.repository'
require "T-SC-09 re-verifies run provenance via API" "$PROV" 'Verify triggering run provenance'

# T-SC-10: explicit least-privilege top-level permissions on the workflows that
# lacked one (esp. the agentic droid/exec workflow).
require "T-SC-10 droid workflow has top-level permissions" "$DROID" '^permissions:'
require "T-SC-10 droid workflow is contents: read" "$DROID" '^  contents: read'
require "T-SC-10 loopback workflow has top-level permissions" "$LOOPBACK" '^permissions:'
require "T-SC-10 loopback workflow is contents: read" "$LOOPBACK" '^  contents: read'

# Belt-and-suspenders: NO workflow should be left without a top-level
# permissions block (the file-local no-write-token guarantee must be universal).
echo "--- every workflow declares a top-level permissions block ---"
for wf in .github/workflows/*.yml; do
  if grep -Eq '^permissions:' "$wf"; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $wf has no top-level permissions block"
    fail=1
  fi
done
wf_count="$(find .github/workflows -maxdepth 1 -name '*.yml' -type f | wc -l | tr -d ' ')"
echo "PASS: all ${wf_count} workflows checked for a top-level permissions block"

echo ""
if [[ "$fail" -ne 0 ]]; then
  echo "=== supply-chain hardening verification FAILED ==="
  exit 1
fi
echo "=== supply-chain hardening verification PASSED ($pass_count assertions) ==="
