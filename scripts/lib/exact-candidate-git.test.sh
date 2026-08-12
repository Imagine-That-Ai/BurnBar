#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/exact-candidate-git.sh
source "$repo_root/scripts/lib/exact-candidate-git.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-exact-candidate-git.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
fixture_repo="$fixture_root/repo"
mkdir -p "$fixture_repo"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name "OpenBurnBar Fixture"
git -C "$fixture_repo" config user.email "fixture@openburnbar.invalid"
printf 'one\n' > "$fixture_repo/candidate.txt"
git -C "$fixture_repo" add candidate.txt
git -C "$fixture_repo" commit -qm "fixture"

(
  unset \
    OPENBURNBAR_CANDIDATE_GIT_DIR \
    OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE \
    GIT_DIR \
    GIT_WORK_TREE \
    GIT_INDEX_FILE
  openburnbar_configure_exact_candidate_git "$fixture_repo"
  [[ "$OPENBURNBAR_EXACT_CANDIDATE_GIT_MODE" == "checkout" ]]
  [[ "$(openburnbar_candidate_git rev-parse HEAD)" == "$(git -C "$fixture_repo" rev-parse HEAD)" ]]
  [[ -z "$(openburnbar_candidate_git status --porcelain=v1 --untracked-files=all)" ]]
)

alternate_git_dir="$fixture_root/alternate.git"
git clone --bare -q "$fixture_repo" "$alternate_git_dir"
alternate_index="$alternate_git_dir/candidate-index"
GIT_DIR="$alternate_git_dir" \
GIT_WORK_TREE="$fixture_repo" \
GIT_INDEX_FILE="$alternate_index" \
  git read-tree HEAD

printf 'two\n' > "$fixture_repo/candidate.txt"
GIT_DIR="$alternate_git_dir" \
GIT_WORK_TREE="$fixture_repo" \
GIT_INDEX_FILE="$alternate_index" \
  git add candidate.txt
alternate_tree="$(
  GIT_DIR="$alternate_git_dir" \
  GIT_WORK_TREE="$fixture_repo" \
  GIT_INDEX_FILE="$alternate_index" \
    git write-tree
)"
alternate_commit="$(
  printf 'alternate\n' \
    | GIT_DIR="$alternate_git_dir" \
      GIT_WORK_TREE="$fixture_repo" \
      GIT_INDEX_FILE="$alternate_index" \
      git commit-tree "$alternate_tree" -p HEAD
)"
GIT_DIR="$alternate_git_dir" git update-ref refs/heads/candidate "$alternate_commit"
GIT_DIR="$alternate_git_dir" git symbolic-ref HEAD refs/heads/candidate

(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  export OPENBURNBAR_CANDIDATE_GIT_DIR="$alternate_git_dir"
  export OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE="$alternate_index"
  openburnbar_configure_exact_candidate_git "$fixture_repo"
  [[ "$OPENBURNBAR_EXACT_CANDIDATE_GIT_MODE" == "alternate-index" ]]
  [[ "$(openburnbar_candidate_git rev-parse HEAD)" == "$alternate_commit" ]]
  [[ "$(openburnbar_candidate_git rev-parse 'HEAD^{tree}')" == "$alternate_tree" ]]
  [[ -z "$(openburnbar_candidate_git status --porcelain=v1 --untracked-files=all)" ]]
  [[ "$GIT_DIR" == "$alternate_git_dir" ]]
  [[ "$GIT_WORK_TREE" == "$fixture_repo" ]]
  [[ "$GIT_INDEX_FILE" == "$alternate_index" ]]
  index_sha256_before="$(shasum -a 256 "$alternate_index" | awk '{print $1}')"
  linked_worktree="$fixture_root/linked-worktree"
  openburnbar_candidate_repository_git worktree add --detach "$linked_worktree" "$alternate_commit" >/dev/null
  [[ -z "$(git -C "$linked_worktree" status --porcelain=v1 --untracked-files=all)" ]]
  [[ "$(git -C "$linked_worktree" rev-parse HEAD)" == "$alternate_commit" ]]
  openburnbar_candidate_repository_git worktree remove --force "$linked_worktree"
  [[ "$(shasum -a 256 "$alternate_index" | awk '{print $1}')" == "$index_sha256_before" ]]
  python3 - <<'PY'
import os
for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    assert os.environ.get(name), name
PY

  openburnbar_without_candidate_git_environment \
    python3 - <<'PY'
import os

for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    assert name not in os.environ, name
assert os.environ["OPENBURNBAR_CANDIDATE_GIT_DIR"]
assert os.environ["OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE"]
PY

  dependency_repo="$fixture_root/dependency"
  openburnbar_without_candidate_git_environment \
    git -C "$fixture_root" init -q dependency
  openburnbar_without_candidate_git_environment \
    git -C "$dependency_repo" config user.name "OpenBurnBar Dependency Fixture"
  openburnbar_without_candidate_git_environment \
    git -C "$dependency_repo" config user.email "dependency@openburnbar.invalid"
  printf 'dependency\n' >"$dependency_repo/dependency.txt"
  openburnbar_without_candidate_git_environment \
    git -C "$dependency_repo" add dependency.txt
  openburnbar_without_candidate_git_environment \
    git -C "$dependency_repo" commit -qm "dependency fixture"
  dependency_head="$(
    openburnbar_without_candidate_git_environment \
      git -C "$dependency_repo" rev-parse HEAD
  )"
  [[ "$(
    openburnbar_without_candidate_git_environment \
      git -C "$dependency_repo" rev-parse HEAD
  )" == "$dependency_head" ]]
  [[ "$dependency_head" != "$alternate_commit" ]]
)

if env \
  -u GIT_DIR \
  -u GIT_WORK_TREE \
  -u GIT_INDEX_FILE \
  -u OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE \
  OPENBURNBAR_CANDIDATE_GIT_DIR="$alternate_git_dir" \
  bash -c "source \"\$1\"; openburnbar_configure_exact_candidate_git \"\$2\"" \
    _ "$repo_root/scripts/lib/exact-candidate-git.sh" "$fixture_repo" \
    >"$fixture_root/partial.stdout" 2>"$fixture_root/partial.stderr"; then
  echo "ERROR: Partial exact-candidate Git configuration was accepted." >&2
  exit 1
fi
grep -Fq "must be provided together" "$fixture_root/partial.stderr"

if env \
  -u OPENBURNBAR_CANDIDATE_GIT_DIR \
  -u OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE \
  GIT_DIR="$alternate_git_dir" \
  bash -c "source \"\$1\"; openburnbar_configure_exact_candidate_git \"\$2\"" \
    _ "$repo_root/scripts/lib/exact-candidate-git.sh" "$fixture_repo" \
    >"$fixture_root/generic.stdout" 2>"$fixture_root/generic.stderr"; then
  echo "ERROR: Implicit generic Git authority was accepted." >&2
  exit 1
fi
grep -Fq "not accepted implicitly" "$fixture_root/generic.stderr"

echo "Exact-candidate Git adapter tests passed."
