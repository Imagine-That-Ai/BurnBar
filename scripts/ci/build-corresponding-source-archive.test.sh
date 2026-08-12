#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-corresponding-source-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

repo="$fixture_root/repo"
mkdir -p \
  "$repo/scripts/ci" \
  "$repo/scripts/lib" \
  "$repo/docs/legal" \
  "$repo/LICENSES"

cp "$source_root/scripts/lib/exact-candidate-git.sh" "$repo/scripts/lib/"
cp "$source_root/scripts/create-corresponding-source.sh" "$repo/scripts/"
cp "$source_root/scripts/ci/build-corresponding-source-archive.sh" "$repo/scripts/ci/"
chmod +x \
  "$repo/scripts/create-corresponding-source.sh" \
  "$repo/scripts/ci/build-corresponding-source-archive.sh"

printf 'fixture license\n' > "$repo/LICENSE"
printf 'fixture notice\n' > "$repo/NOTICE"
printf 'fixture third-party notices\n' > "$repo/THIRD_PARTY_NOTICES.md"
printf 'fixture MIT legacy license\n' > "$repo/LICENSES/MIT-legacy.txt"
printf 'fixture Hermes MIT license\n' > "$repo/LICENSES/Nous-hermes-agent-MIT.txt"
printf 'fixture AGPL compliance\n' > "$repo/docs/legal/agpl-compliance.md"
printf 'base\n' > "$repo/candidate-marker.txt"

git -C "$repo" init -q
git -C "$repo" config user.name "OpenBurnBar Fixture"
git -C "$repo" config user.email "fixture@openburnbar.invalid"
git -C "$repo" add .
git -C "$repo" commit -qm "base"
base_commit="$(git -C "$repo" rev-parse HEAD)"

candidate_git_dir="$fixture_root/candidate.git"
candidate_index="$candidate_git_dir/candidate-index"
git clone --bare -q "$repo" "$candidate_git_dir"
GIT_DIR="$candidate_git_dir" \
GIT_WORK_TREE="$repo" \
GIT_INDEX_FILE="$candidate_index" \
  git read-tree HEAD

printf 'candidate\n' > "$repo/candidate-marker.txt"
printf 'candidate only\n' > "$repo/candidate-only.txt"
GIT_DIR="$candidate_git_dir" \
GIT_WORK_TREE="$repo" \
GIT_INDEX_FILE="$candidate_index" \
  git add candidate-marker.txt candidate-only.txt
candidate_tree="$(
  GIT_DIR="$candidate_git_dir" \
  GIT_WORK_TREE="$repo" \
  GIT_INDEX_FILE="$candidate_index" \
    git write-tree
)"
candidate_commit="$(
  printf 'candidate\n' \
    | GIT_DIR="$candidate_git_dir" \
      GIT_WORK_TREE="$repo" \
      GIT_INDEX_FILE="$candidate_index" \
      git commit-tree "$candidate_tree" -p "$base_commit"
)"
GIT_DIR="$candidate_git_dir" git update-ref refs/heads/candidate "$candidate_commit"
GIT_DIR="$candidate_git_dir" git symbolic-ref HEAD refs/heads/candidate

archive="$fixture_root/OpenBurnBar-1.2.3-corresponding-source.tar.gz"
env \
  -u GIT_DIR \
  -u GIT_WORK_TREE \
  -u GIT_INDEX_FILE \
  OPENBURNBAR_CANDIDATE_GIT_DIR="$candidate_git_dir" \
  OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE="$candidate_index" \
  bash "$repo/scripts/ci/build-corresponding-source-archive.sh" \
    --version 1.2.3 \
    --output "$archive"

python3 - "$archive" "$candidate_commit" <<'PY'
import json
import sys
import tarfile

archive_path, candidate_commit = sys.argv[1:]
prefix = "OpenBurnBar-1.2.3-source"
with tarfile.open(archive_path, "r:gz") as archive:
    manifest_file = archive.extractfile(f"{prefix}/CORRESPONDING_SOURCE_MANIFEST.json")
    if manifest_file is None:
        raise SystemExit("missing corresponding-source manifest")
    manifest = json.load(manifest_file)
    marker = archive.extractfile(f"{prefix}/candidate-marker.txt")
    candidate_only = archive.extractfile(f"{prefix}/candidate-only.txt")
    if marker is None or candidate_only is None:
        raise SystemExit("archive did not contain alternate-index candidate files")
    if marker.read() != b"candidate\n" or candidate_only.read() != b"candidate only\n":
        raise SystemExit("archive content did not come from the alternate-index candidate")

if manifest.get("commit") != candidate_commit:
    raise SystemExit(
        f"manifest commit {manifest.get('commit')!r} did not match candidate {candidate_commit}"
    )
if manifest.get("dirtySourceArchive") is not False:
    raise SystemExit("publishable corresponding source was not clean")
PY

echo "PASS: corresponding-source builder binds a clean detached archive to the explicit alternate-index candidate."
