#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/pinned-xcodegen.sh
source "$repo_root/scripts/lib/pinned-xcodegen.sh"
# shellcheck source=scripts/lib/exact-candidate-git.sh
source "$repo_root/scripts/lib/exact-candidate-git.sh"

readonly expected_original_pbx_sha256="84cfb5ee1607479837e75a4338eef39470f7ac7dc60aa077b7d2db6c66727e69"
readonly project_relative="OpenBurnBar.xcodeproj"
readonly transition_verifier_relative="scripts/ci/verify-openburnbar-safari-xcodegen-transition.py"
readonly semantic_verifier_relative="scripts/ci/verify-xcodegen-pbxproj-drift.py"
readonly -a generated_info_paths=(
  "AgentLens/Resources/OpenBurnBar-Info.plist"
  "OpenBurnBarSafariExtension/Info.plist"
  "OpenBurnBarMobile/Info.plist"
  "OpenBurnBarWidget/Info.plist"
  "OpenBurnBarKeyboard/Info.plist"
)
readonly -a required_transition_sources=(
  "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/GatewayRequestAttribution.swift"
  "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/SafariHandoffProcessSupervisor.swift"
  "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/Safari/SafariHandoffProcessSupervisorTests.swift"
  "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/Safari/SafariHandoffProcessWatchdogTests.swift"
)

candidate_git_dir="${OPENBURNBAR_CANDIDATE_GIT_DIR:-}"
candidate_git_index="${OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE:-}"
expected_commit="${OPENBURNBAR_CANDIDATE_COMMIT:-}"
expected_tree="${OPENBURNBAR_CANDIDATE_TREE:-}"
project_path="$repo_root/$project_relative"
pbx_path="$project_path/project.pbxproj"
transition_verifier="$repo_root/$transition_verifier_relative"
semantic_verifier="$repo_root/$semantic_verifier_relative"
preserved_project_paths=()

usage() {
  cat >&2 <<'EOF'
usage:
  OPENBURNBAR_CANDIDATE_GIT_DIR=/absolute/path/to/.git \
  OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE=/absolute/path/to/index \
  OPENBURNBAR_CANDIDATE_COMMIT=<40-char lowercase commit> \
  OPENBURNBAR_CANDIDATE_TREE=<40-char lowercase tree> \
  OPENBURNBAR_XCODEGEN_BIN=/absolute/path/to/xcodegen \
    scripts/materialize-openburnbar-safari-xcode-project.sh

This one-time certification transition accepts only the audited source change:
OpenBurnBarDaemon Sources 230->232 and OpenBurnBarDaemonTests Sources 119->121.
It performs two independent pinned XcodeGen passes, compares their complete
semantic project graphs, restores every generated Info.plist byte-for-byte,
preserves every tracked project-bundle artifact except the audited
project.pbxproj transition, and keeps the generated project only if all checks
pass.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_lowercase_git_oid() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[0-9a-f]{40}$ ]]; then
    fail "$label must be a lowercase 40-character Git object ID."
  fi
}

require_real_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" || -L "$path" ]]; then
    fail "$label must be a real file: $path"
  fi
}

require_real_directory() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" || -L "$path" ]]; then
    fail "$label must be a real directory: $path"
  fi
}

if [[ $# -ne 0 ]]; then
  usage
  exit 64
fi
require_real_directory "$repo_root" "repository root"
require_real_directory "$candidate_git_dir" "candidate Git directory"
require_real_file "$candidate_git_index" "candidate Git index"
export OPENBURNBAR_CANDIDATE_GIT_DIR="$candidate_git_dir"
export OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE="$candidate_git_index"
openburnbar_configure_exact_candidate_git "$repo_root"
require_lowercase_git_oid "$expected_commit" "OPENBURNBAR_CANDIDATE_COMMIT"
require_lowercase_git_oid "$expected_tree" "OPENBURNBAR_CANDIDATE_TREE"
require_real_directory "$project_path" "committed Xcode project"
require_real_file "$pbx_path" "committed project.pbxproj"
require_real_file "$repo_root/project.yml" "XcodeGen specification"
require_real_file "$transition_verifier" "Safari XcodeGen transition verifier"
require_real_file "$semantic_verifier" "semantic XcodeGen drift verifier"
for relative_path in "${generated_info_paths[@]}"; do
  require_real_file "$repo_root/$relative_path" "XcodeGen-managed Info.plist"
done
for relative_path in "${required_transition_sources[@]}"; do
  require_real_file "$repo_root/$relative_path" "audited Safari transition source"
done

actual_commit="$(openburnbar_candidate_git rev-parse 'HEAD^{commit}')"
actual_tree="$(openburnbar_candidate_git rev-parse 'HEAD^{tree}')"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  fail "candidate commit mismatch: expected $expected_commit, found $actual_commit."
fi
if [[ "$actual_tree" != "$expected_tree" ]]; then
  fail "candidate tree mismatch: expected $expected_tree, found $actual_tree."
fi
worktree_state="$(
  openburnbar_candidate_git status \
    --porcelain=v1 \
    --untracked-files=all \
    --ignore-submodules=none
)"
if [[ -n "$worktree_state" ]]; then
  echo "ERROR: Safari XcodeGen materialization requires a clean exact source checkpoint:" >&2
  printf '%s\n' "$worktree_state" >&2
  exit 1
fi

original_pbx_sha256="$(shasum --algorithm 256 "$pbx_path" | awk '{print $1}')"
if [[ "$original_pbx_sha256" != "$expected_original_pbx_sha256" ]]; then
  fail "historical project.pbxproj checksum mismatch: expected $expected_original_pbx_sha256, found $original_pbx_sha256. Do not regenerate from an unreviewed base."
fi
while IFS= read -r -d '' relative_path; do
  if [[ "$relative_path" == "$project_relative/project.pbxproj" ]]; then
    continue
  fi
  case "$relative_path" in
    "$project_relative/"*) ;;
    *) fail "tracked project artifact escaped the project bundle: $relative_path" ;;
  esac
  require_real_file "$repo_root/$relative_path" "tracked project artifact"
  preserved_project_paths+=("$relative_path")
done < <(
  openburnbar_candidate_git ls-tree \
    -r \
    -z \
    --name-only \
    "$expected_commit" \
    -- \
    "$project_relative"
)
if ((${#preserved_project_paths[@]} == 0)); then
  fail "exact candidate contains no tracked project artifacts to preserve."
fi

xcodegen_bin="$(openburnbar_resolve_pinned_xcodegen)"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-safari-xcodegen-transition.XXXXXX")"
chmod 700 "$work_root"
original_project="$work_root/original.xcodeproj"
first_project="$work_root/first.xcodeproj"
second_project="$work_root/second.xcodeproj"
original_project_moved=0
installed_generated_project=0

restore_original_state() {
  local exit_status=$?
  local relative_path
  local backup_path

  set +e
  if [[ "$original_project_moved" == "1" && "$installed_generated_project" != "1" ]]; then
    if [[ -d "$project_path" || -L "$project_path" ]]; then
      rm -rf "$project_path"
    fi
    if [[ -d "$original_project" ]]; then
      mv "$original_project" "$project_path"
    fi
  fi
  for relative_path in "${generated_info_paths[@]}"; do
    backup_path="$work_root/info/$relative_path"
    if [[ -f "$backup_path" ]]; then
      cp -p "$backup_path" "$repo_root/$relative_path"
    fi
  done
  for relative_path in "${preserved_project_paths[@]}"; do
    backup_path="$work_root/project/$relative_path"
    if [[ -f "$backup_path" ]]; then
      mkdir -p "$(dirname "$repo_root/$relative_path")"
      cp -p "$backup_path" "$repo_root/$relative_path"
    fi
  done
  rm -rf "$work_root"
  exit "$exit_status"
}
trap restore_original_state EXIT

mkdir -p "$work_root/info" "$work_root/project"
for relative_path in "${generated_info_paths[@]}"; do
  mkdir -p "$work_root/info/$(dirname "$relative_path")"
  cp -p "$repo_root/$relative_path" "$work_root/info/$relative_path"
done
for relative_path in "${preserved_project_paths[@]}"; do
  mkdir -p "$work_root/project/$(dirname "$relative_path")"
  cp -p "$repo_root/$relative_path" "$work_root/project/$relative_path"
done
mv "$project_path" "$original_project"
original_project_moved=1

restore_preserved_project_artifacts() {
  local relative_path
  local backup_path
  local destination_path

  for relative_path in "${preserved_project_paths[@]}"; do
    backup_path="$work_root/project/$relative_path"
    destination_path="$repo_root/$relative_path"
    mkdir -p "$(dirname "$destination_path")"
    cp -p "$backup_path" "$destination_path"
    if ! cmp -s "$backup_path" "$destination_path"; then
      fail "tracked project artifact was not restored byte-for-byte: $relative_path"
    fi
  done
}

generate_pass() {
  local destination="$1"
  local relative_path

  (
    cd "$repo_root"
    "$xcodegen_bin" generate --spec project.yml
  )
  require_real_file "$pbx_path" "pinned XcodeGen output"
  restore_preserved_project_artifacts
  mv "$project_path" "$destination"
  for relative_path in "${generated_info_paths[@]}"; do
    cp -p "$work_root/info/$relative_path" "$repo_root/$relative_path"
  done
}

generate_pass "$first_project"
python3 "$transition_verifier" \
  "$original_project/project.pbxproj" \
  "$first_project/project.pbxproj"

generate_pass "$second_project"
python3 "$transition_verifier" \
  "$original_project/project.pbxproj" \
  "$second_project/project.pbxproj"
python3 "$semantic_verifier" \
  "$first_project/project.pbxproj" \
  "$second_project/project.pbxproj"

mv "$second_project" "$project_path"
restore_preserved_project_artifacts
for relative_path in "${generated_info_paths[@]}"; do
  cp -p "$work_root/info/$relative_path" "$repo_root/$relative_path"
  if ! cmp -s "$work_root/info/$relative_path" "$repo_root/$relative_path"; then
    fail "XcodeGen-managed Info.plist was not restored byte-for-byte: $relative_path"
  fi
done
final_worktree_state="$(
  openburnbar_candidate_git status \
    --porcelain=v1 \
    --untracked-files=all \
    --ignore-submodules=none
)"
expected_worktree_state=" M $project_relative/project.pbxproj"
if [[ "$final_worktree_state" != "$expected_worktree_state" ]]; then
  echo "ERROR: Safari XcodeGen materialization produced an unexpected repository delta:" >&2
  printf '%s\n' "${final_worktree_state:-<clean>}" >&2
  exit 1
fi
installed_generated_project=1
original_project_moved=0

echo "PASS: materialized the exact two-pass Safari XcodeGen transition."
echo "  Original project SHA-256: $expected_original_pbx_sha256"
echo "  OpenBurnBarDaemon Sources: 230 -> 232"
echo "  OpenBurnBarDaemonTests Sources: 119 -> 121"
echo "  Preserved tracked project artifacts: ${#preserved_project_paths[@]}"
echo "  Candidate checkpoint: $expected_commit"
echo "  Candidate checkpoint tree: $expected_tree"
