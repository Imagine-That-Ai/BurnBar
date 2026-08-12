#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_under_test="$repo_root/scripts/materialize-openburnbar-safari-xcode-project.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-safari-xcodegen-materialize-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

required_fragments=(
  'OPENBURNBAR_CANDIDATE_GIT_DIR'
  'OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE'
  'OPENBURNBAR_CANDIDATE_COMMIT'
  'OPENBURNBAR_CANDIDATE_TREE'
  'openburnbar_resolve_pinned_xcodegen'
  'status'
  '--porcelain=v1'
  '--untracked-files=all'
  '--ignore-submodules=none'
  'requires a clean exact source checkpoint'
  'ls-tree'
  'tracked project artifact'
  'project/$relative_path'
  'restore_preserved_project_artifacts'
  'unexpected repository delta'
  'expected_worktree_state=" M $project_relative/project.pbxproj"'
  '84cfb5ee1607479837e75a4338eef39470f7ac7dc60aa077b7d2db6c66727e69'
  'verify-openburnbar-safari-xcodegen-transition.py'
  'verify-xcodegen-pbxproj-drift.py'
  'GatewayRequestAttribution.swift'
  'SafariHandoffProcessSupervisor.swift'
  'SafariHandoffProcessSupervisorTests.swift'
  'SafariHandoffProcessWatchdogTests.swift'
  'cmp -s'
  'original_project_moved=0'
  'original_project_moved=1'
)
for fragment in "${required_fragments[@]}"; do
  if ! grep -Fq -- "$fragment" "$script_under_test"; then
    echo "ERROR: materialization script is missing required contract fragment: $fragment" >&2
    exit 1
  fi
done

if grep -Eq '(^|[[:space:]])xcodegen([[:space:]]|$)' "$script_under_test"; then
  echo "ERROR: materialization script bypasses the pinned XcodeGen resolver." >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(rev-parse|status|diff|cat-file)' "$script_under_test"; then
  echo "ERROR: materialization script contains a candidate Git call outside the exact-candidate adapter." >&2
  exit 1
fi
grep -Fq "openburnbar_configure_exact_candidate_git" "$script_under_test"
grep -Fq "openburnbar_candidate_git rev-parse" "$script_under_test"

set +e
"$script_under_test" unexpected-argument \
  >"$fixture_root/usage.stdout" \
  2>"$fixture_root/usage.stderr"
usage_status=$?
set -e
if [[ "$usage_status" -ne 64 ]]; then
  echo "ERROR: unexpected arguments must fail with EX_USAGE 64; found $usage_status." >&2
  exit 1
fi
grep -Fq "usage:" "$fixture_root/usage.stderr"

set +e
OPENBURNBAR_CANDIDATE_GIT_DIR="$fixture_root/missing.git" \
OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE="$fixture_root/missing.index" \
OPENBURNBAR_CANDIDATE_COMMIT="not-an-object-id" \
OPENBURNBAR_CANDIDATE_TREE="not-an-object-id" \
  "$script_under_test" \
  >"$fixture_root/missing.stdout" \
  2>"$fixture_root/missing.stderr"
missing_status=$?
set -e
if [[ "$missing_status" -eq 0 ]]; then
  echo "ERROR: missing candidate authority inputs were accepted." >&2
  exit 1
fi
grep -Fq "candidate Git directory must be a real directory" "$fixture_root/missing.stderr"

echo "Safari XcodeGen materialization contract tests passed."
