#!/usr/bin/env bash
#
# update-homebrew.sh — Prepare or publish the exact OpenBurnBar Homebrew cask.
#
# Local preparation (does not publish):
#   scripts/update-homebrew.sh update \
#     --version <X.Y.Z> \
#     --candidate-sha <40-hex release commit>
#
# Backwards-compatible shorthand:
#   OPENBURNBAR_RELEASE_CANDIDATE_SHA=<40-hex> scripts/update-homebrew.sh <X.Y.Z>
#
# Verified tap publication (commits and pushes the authoritative tap):
#   scripts/update-homebrew.sh publish \
#     --version <X.Y.Z> \
#     --candidate-sha <40-hex release commit> \
#     --tap-dir <clean Imagine-That-Ai/homebrew-tap checkout> \
#     --receipt <publication-receipt.json>
#
# Both modes independently verify that:
#   - v<X.Y.Z> is a published Imagine-That-Ai/BurnBar GitHub release
#   - the release tag resolves to the requested candidate commit
#   - the named DMG exists and hashes to a real, non-placeholder SHA-256
#
# `update` changes only homebrew/burnbar.rb. It never publishes the tap.
# `publish` re-verifies the release and cask, audits a clean tap checkout,
# pushes the single cask commit, verifies the remote commit, and writes a
# candidate-bound receipt.
#
# Prerequisites:
#   - bash 3.2+
#   - git
#   - gh authenticated for the authoritative repositories
#   - sha256sum (Linux) or shasum (macOS)
#   - brew (publish mode only)

set -euo pipefail

readonly SOURCE_REPOSITORY="Imagine-That-Ai/BurnBar"
readonly TAP_REPOSITORY="Imagine-That-Ai/homebrew-tap"
readonly TAP_BRANCH="main"
readonly TAP_CASK_RELATIVE_PATH="Casks/openburnbar.rb"
readonly SOURCE_CASK_RELATIVE_PATH="homebrew/burnbar.rb"
readonly ZERO_SHA256="0000000000000000000000000000000000000000000000000000000000000000"

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cask_file="$repo_root/homebrew/burnbar.rb"
exclusive_json_helper="$repo_root/scripts/lib/exclusive_json.py"
work_dir=""

cleanup() {
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_sha256() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{64}$'
}

is_commit_sha() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

is_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$'
}

compute_sha256() {
  local path="$1"
  local digest

  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$path" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "$path" | awk '{print $1}')"
  else
    die "neither sha256sum nor shasum is available"
  fi

  is_sha256 "$digest" || die "SHA-256 tool returned an invalid digest for $path: '$digest'"
  [[ "$digest" != "$ZERO_SHA256" ]] || die "refusing the all-zero placeholder SHA-256 for $path"
  printf '%s\n' "$digest"
}

make_work_dir() {
  local temp_root="${TMPDIR:-/tmp}"
  work_dir="$(mktemp -d "$temp_root/openburnbar-homebrew.XXXXXX")"
}

resolve_release_tag_commit() {
  local tag="$1"
  local object
  local object_type
  local object_sha
  local depth=0

  object="$(
    gh api "repos/$SOURCE_REPOSITORY/git/ref/tags/$tag" \
      --jq '.object.type + " " + .object.sha'
  )"

  while :; do
    object_type="${object%% *}"
    object_sha="${object#* }"
    is_commit_sha "$object_sha" || die "GitHub returned an invalid object SHA for $tag"

    case "$object_type" in
      commit)
        printf '%s\n' "$object_sha"
        return
        ;;
      tag)
        depth=$((depth + 1))
        [[ "$depth" -le 5 ]] || die "annotated tag chain for $tag is unexpectedly deep"
        object="$(
          gh api "repos/$SOURCE_REPOSITORY/git/tags/$object_sha" \
            --jq '.object.type + " " + .object.sha'
        )"
        ;;
      *)
        die "tag $tag resolves to unsupported Git object type '$object_type'"
        ;;
    esac
  done
}

download_and_verify_release() {
  local version="$1"
  local candidate_sha="$2"
  local tag="v$version"
  local dmg_name="OpenBurnBar-$version-macOS.dmg"
  local release_state
  local release_tag
  local release_draft
  local release_commit

  make_work_dir

  release_state="$(
    gh release view "$tag" \
      --repo "$SOURCE_REPOSITORY" \
      --json tagName,isDraft \
      --jq '[.tagName, .isDraft] | @tsv'
  )"
  release_tag="${release_state%%	*}"
  release_draft="${release_state#*	}"
  [[ "$release_tag" == "$tag" ]] || die "GitHub release returned tag '$release_tag', expected '$tag'"
  [[ "$release_draft" == "false" ]] || die "release $tag is still a draft"

  release_commit="$(resolve_release_tag_commit "$tag")"
  [[ "$release_commit" == "$candidate_sha" ]] || {
    die "release tag $tag resolves to $release_commit, not requested candidate $candidate_sha"
  }

  gh release download "$tag" \
    --repo "$SOURCE_REPOSITORY" \
    --pattern "$dmg_name" \
    --dir "$work_dir"

  release_dmg_path="$work_dir/$dmg_name"
  [[ -s "$release_dmg_path" ]] || {
    die "release $tag is missing non-empty asset $dmg_name"
  }
  release_dmg_sha256="$(compute_sha256 "$release_dmg_path")"
}

read_cask_value() {
  local path="$1"
  local key="$2"

  sed -nE "s/^[[:space:]]*$key \"([^\"]+)\".*/\\1/p" "$path" | head -1
}

read_cask_marker() {
  local path="$1"
  local marker="$2"

  sed -nE "s/^# $marker: (.+)$/\\1/p" "$path" | head -1
}

validate_cask_binding() {
  local path="$1"
  local expected_version="$2"
  local expected_candidate="$3"
  local expected_sha256="$4"
  local actual_version
  local actual_candidate
  local actual_tag
  local actual_sha256

  [[ -f "$path" ]] || die "cask file not found: $path"
  actual_version="$(read_cask_value "$path" version)"
  actual_sha256="$(read_cask_value "$path" sha256)"
  actual_candidate="$(read_cask_marker "$path" "Source commit")"
  actual_tag="$(read_cask_marker "$path" "Release tag")"

  [[ "$actual_version" == "$expected_version" ]] || {
    die "cask version '$actual_version' does not match '$expected_version'"
  }
  [[ "$actual_candidate" == "$expected_candidate" ]] || {
    die "cask source commit '$actual_candidate' does not match '$expected_candidate'"
  }
  [[ "$actual_tag" == "v$expected_version" ]] || {
    die "cask release tag '$actual_tag' does not match 'v$expected_version'"
  }
  [[ "$actual_sha256" == "$expected_sha256" ]] || {
    die "cask SHA-256 '$actual_sha256' does not match release asset '$expected_sha256'"
  }
  is_sha256 "$actual_sha256" || die "cask SHA-256 is not a lowercase 64-hex digest"
  [[ "$actual_sha256" != "$ZERO_SHA256" ]] || die "cask still contains the all-zero placeholder"

  ! grep -Eq \
    '^(# (Source commit|Release tag): PENDING_RELEASE_|[[:space:]]*(version|sha256) "PENDING_RELEASE_)' \
    "$path" || die "cask still contains a pending-release value"
  grep -Fq "https://github.com/$SOURCE_REPOSITORY/releases/download/v#{version}/OpenBurnBar-#{version}-macOS.dmg" "$path" || {
    die "cask URL is not bound to $SOURCE_REPOSITORY"
  }
  grep -Fq "homepage \"https://github.com/$SOURCE_REPOSITORY\"" "$path" || {
    die "cask homepage is not bound to $SOURCE_REPOSITORY"
  }
}

assert_clean_candidate_checkout() {
  local candidate_sha="$1"
  local checkout_root
  local checkout_head
  local checkout_status

  checkout_root="$(git -C "$repo_root" rev-parse --show-toplevel)"
  checkout_root="$(cd "$checkout_root" && pwd -P)"
  [[ "$checkout_root" == "$repo_root" ]] || die "script must run from its own Git worktree"

  checkout_head="$(git -C "$repo_root" rev-parse HEAD)"
  [[ "$checkout_head" == "$candidate_sha" ]] || {
    die "checkout HEAD $checkout_head does not match requested candidate $candidate_sha"
  }

  checkout_status="$(git -C "$repo_root" status --porcelain)"
  [[ -z "$checkout_status" ]] || {
    die "candidate checkout is dirty; prepare the cask from a clean exact-candidate worktree"
  }
}

materialize_candidate_cask() {
  local version="$1"
  local candidate_sha="$2"
  local dmg_sha256="$3"
  local destination="$4"
  local candidate_template

  [[ -n "$work_dir" && -d "$work_dir" ]] || die "release work directory is unavailable"
  candidate_template="$work_dir/candidate-burnbar.rb"
  if ! git -C "$repo_root" show \
    "$candidate_sha:$SOURCE_CASK_RELATIVE_PATH" >"$candidate_template"; then
    die "candidate $candidate_sha does not contain $SOURCE_CASK_RELATIVE_PATH"
  fi
  [[ -s "$candidate_template" ]] || {
    die "candidate $candidate_sha contains an empty $SOURCE_CASK_RELATIVE_PATH"
  }

  if ! awk \
    -v version="$version" \
    -v candidate="$candidate_sha" \
    -v tag="v$version" \
    -v sha256="$dmg_sha256" '
      /^# Source commit: / {
        print "# Source commit: " candidate
        source_commit_count++
        next
      }
      /^# Release tag: / {
        print "# Release tag: " tag
        release_tag_count++
        next
      }
      /^[[:space:]]*version "/ {
        print "  version \"" version "\""
        version_count++
        next
      }
      /^[[:space:]]*sha256 "/ {
        print "  sha256 \"" sha256 "\""
        sha256_count++
        next
      }
      { print }
      END {
        if (source_commit_count != 1 || release_tag_count != 1 || version_count != 1 || sha256_count != 1) {
          exit 42
        }
      }
    ' "$candidate_template" >"$destination"; then
    rm -f -- "$destination"
    die "candidate cask template does not contain exactly one expected marker/value for each release field"
  fi

  validate_cask_binding "$destination" "$version" "$candidate_sha" "$dmg_sha256"
}

update_cask() {
  local version="$1"
  local candidate_sha="$2"
  local dmg_sha256="$3"
  local expected_cask
  local temp_cask

  [[ -f "$cask_file" ]] || die "cask template not found: $cask_file"
  expected_cask="$work_dir/expected-burnbar.rb"
  temp_cask="$(mktemp "$cask_file.tmp.XXXXXX")"
  materialize_candidate_cask \
    "$version" \
    "$candidate_sha" \
    "$dmg_sha256" \
    "$expected_cask"
  cp -- "$expected_cask" "$temp_cask"
  mv -- "$temp_cask" "$cask_file"
}

preflight_receipt_path() {
  local receipt_path="$1"

  [[ -n "$receipt_path" ]] || die "--receipt is required in publish mode"
  [[ -f "$exclusive_json_helper" ]] || die "exclusive JSON helper not found: $exclusive_json_helper"

  python3 - "$receipt_path" <<'PY'
import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.name or path.name in {".", ".."}:
    raise SystemExit(f"receipt output must name a file: {path}")

parent = path.parent
try:
    metadata = os.lstat(parent)
except FileNotFoundError:
    raise SystemExit(f"receipt parent must already exist: {parent}") from None

if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
    raise SystemExit(f"receipt parent must be a real directory: {parent}")
if metadata.st_uid != os.geteuid():
    raise SystemExit(f"receipt parent must be owned by the current user: {parent}")
if metadata.st_mode & 0o022:
    raise SystemExit(f"receipt parent must not be group/world writable: {parent}")

try:
    os.lstat(path)
except FileNotFoundError:
    pass
else:
    raise SystemExit(f"receipt output already exists or is a symlink: {path}")
PY
}

write_publication_receipt() {
  local receipt_path="$1"
  local version="$2"
  local candidate_sha="$3"
  local dmg_sha256="$4"
  local tap_commit="$5"
  local cask_sha256="$6"
  local published_at

  published_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  python3 - \
    "$exclusive_json_helper" \
    "$receipt_path" \
    "$version" \
    "$candidate_sha" \
    "$dmg_sha256" \
    "$tap_commit" \
    "$cask_sha256" \
    "$published_at" <<'PY'
import importlib.util
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("exclusive_json", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(f"unable to load exclusive JSON helper: {helper_path}")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

output = Path(sys.argv[2])
version, candidate_sha, dmg_sha256, tap_commit, cask_sha256, published_at = sys.argv[3:]
module.write_exclusive_json(
    output,
    {
        "schemaVersion": 1,
        "channel": "homebrew-cask",
        "sourceRepository": "Imagine-That-Ai/BurnBar",
        "sourceCommit": candidate_sha,
        "releaseTag": f"v{version}",
        "releaseAsset": (
            "https://github.com/Imagine-That-Ai/BurnBar/releases/download/"
            f"v{version}/OpenBurnBar-{version}-macOS.dmg"
        ),
        "releaseAssetSha256": dmg_sha256,
        "tapRepository": "Imagine-That-Ai/homebrew-tap",
        "tapBranch": "main",
        "tapCommit": tap_commit,
        "tapCaskPath": "Casks/openburnbar.rb",
        "tapCaskSha256": cask_sha256,
        "publishedAt": published_at,
    },
)
PY
}

publish_cask() {
  local version="$1"
  local candidate_sha="$2"
  local tap_dir="$3"
  local receipt_path="$4"
  local tap_root
  local tap_remote
  local tap_branch
  local tap_status
  local tap_head
  local tap_remote_head
  local tap_cask
  local staged_paths
  local tap_commit
  local verified_tap_commit
  local cask_sha256
  local expected_cask

  [[ -n "$tap_dir" ]] || die "--tap-dir is required in publish mode"
  [[ -d "$tap_dir" ]] || die "tap checkout does not exist: $tap_dir"
  tap_root="$(cd "$tap_dir" && pwd -P)"
  tap_cask="$tap_root/$TAP_CASK_RELATIVE_PATH"

  preflight_receipt_path "$receipt_path"
  download_and_verify_release "$version" "$candidate_sha"
  validate_cask_binding "$cask_file" "$version" "$candidate_sha" "$release_dmg_sha256"
  expected_cask="$work_dir/expected-burnbar.rb"
  materialize_candidate_cask \
    "$version" \
    "$candidate_sha" \
    "$release_dmg_sha256" \
    "$expected_cask"
  if ! cmp -s "$expected_cask" "$cask_file"; then
    die "prepared cask differs from the exact candidate template after deterministic release substitution"
  fi

  tap_remote="$(git -C "$tap_root" remote get-url origin)"
  case "$tap_remote" in
    "https://github.com/$TAP_REPOSITORY" | \
    "https://github.com/$TAP_REPOSITORY.git" | \
    "git@github.com:$TAP_REPOSITORY.git" | \
    "ssh://git@github.com/$TAP_REPOSITORY.git")
      ;;
    *)
      die "tap origin '$tap_remote' is not the authoritative $TAP_REPOSITORY repository"
      ;;
  esac

  tap_branch="$(git -C "$tap_root" symbolic-ref --short HEAD)"
  [[ "$tap_branch" == "$TAP_BRANCH" ]] || {
    die "tap checkout is on '$tap_branch', expected '$TAP_BRANCH'"
  }
  tap_status="$(git -C "$tap_root" status --porcelain)"
  [[ -z "$tap_status" ]] || die "tap checkout is dirty before publication"

  git -C "$tap_root" fetch --quiet origin "$TAP_BRANCH"
  tap_head="$(git -C "$tap_root" rev-parse HEAD)"
  tap_remote_head="$(git -C "$tap_root" rev-parse "refs/remotes/origin/$TAP_BRANCH")"
  [[ "$tap_head" == "$tap_remote_head" ]] || {
    die "tap checkout HEAD $tap_head is not the fetched origin/$TAP_BRANCH commit $tap_remote_head"
  }

  mkdir -p -- "$(dirname "$tap_cask")"
  cp -- "$cask_file" "$tap_cask"

  brew style --cask "$tap_cask"
  brew audit --cask --strict "$tap_cask"
  git -C "$tap_root" diff --check -- "$TAP_CASK_RELATIVE_PATH"
  git -C "$tap_root" add -- "$TAP_CASK_RELATIVE_PATH"

  if git -C "$tap_root" diff --cached --quiet -- "$TAP_CASK_RELATIVE_PATH"; then
    die "tap cask already matches v$version; no publication commit was created"
  fi
  staged_paths="$(git -C "$tap_root" diff --cached --name-only)"
  [[ "$staged_paths" == "$TAP_CASK_RELATIVE_PATH" ]] || {
    die "publication would commit files other than $TAP_CASK_RELATIVE_PATH: $staged_paths"
  }

  git -C "$tap_root" commit \
    -m "openburnbar: update cask to v$version" \
    -- "$TAP_CASK_RELATIVE_PATH"
  tap_commit="$(git -C "$tap_root" rev-parse HEAD)"
  is_commit_sha "$tap_commit" || die "tap commit has invalid SHA '$tap_commit'"

  git -C "$tap_root" push origin "HEAD:refs/heads/$TAP_BRANCH"
  tap_remote_head="$(
    git -C "$tap_root" ls-remote --exit-code origin "refs/heads/$TAP_BRANCH" |
      awk 'NR == 1 { print $1 }'
  )"
  [[ "$tap_remote_head" == "$tap_commit" ]] || {
    die "tap remote head $tap_remote_head does not match pushed commit $tap_commit"
  }

  verified_tap_commit="$(
    gh api "repos/$TAP_REPOSITORY/commits/$tap_commit" --jq '.sha'
  )"
  [[ "$verified_tap_commit" == "$tap_commit" ]] || {
    die "GitHub did not verify tap commit $tap_commit"
  }

  cask_sha256="$(compute_sha256 "$tap_cask")"
  write_publication_receipt \
    "$receipt_path" \
    "$version" \
    "$candidate_sha" \
    "$release_dmg_sha256" \
    "$tap_commit" \
    "$cask_sha256"

  printf '\nHomebrew tap publication verified.\n'
  printf '  Source:  https://github.com/%s/tree/%s\n' "$SOURCE_REPOSITORY" "$candidate_sha"
  printf '  Release: https://github.com/%s/releases/tag/v%s\n' "$SOURCE_REPOSITORY" "$version"
  printf '  Tap:     https://github.com/%s/commit/%s\n' "$TAP_REPOSITORY" "$tap_commit"
  printf '  Receipt: %s\n' "$receipt_path"
}

mode=""
version=""
candidate_sha="${OPENBURNBAR_RELEASE_CANDIDATE_SHA:-}"
tap_dir=""
receipt_path=""

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  update | publish)
    mode="$1"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    die "unknown mode or option: $1"
    ;;
  *)
    mode="update"
    version="${1#v}"
    shift
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="${2#v}"
      shift 2
      ;;
    --candidate-sha)
      [[ $# -ge 2 ]] || die "--candidate-sha requires a value"
      candidate_sha="$2"
      shift 2
      ;;
    --tap-dir)
      [[ $# -ge 2 ]] || die "--tap-dir requires a value"
      tap_dir="$2"
      shift 2
      ;;
    --receipt)
      [[ $# -ge 2 ]] || die "--receipt requires a value"
      receipt_path="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "$version" ]] || die "--version is required"
is_version "$version" || die "version must be a release version such as 1.2.3 or 1.2.3-beta.1"
[[ -n "$candidate_sha" ]] || die "--candidate-sha or OPENBURNBAR_RELEASE_CANDIDATE_SHA is required"
is_commit_sha "$candidate_sha" || die "candidate SHA must be exactly 40 lowercase hexadecimal characters"

require_command gh
require_command git
require_command awk
require_command sed

case "$mode" in
  update)
    [[ -z "$tap_dir" ]] || die "--tap-dir is valid only in publish mode"
    [[ -z "$receipt_path" ]] || die "--receipt is valid only in publish mode"
    assert_clean_candidate_checkout "$candidate_sha"
    download_and_verify_release "$version" "$candidate_sha"
    update_cask "$version" "$candidate_sha" "$release_dmg_sha256"

    printf '\nHomebrew cask prepared locally; nothing was published.\n'
    printf '  Version:        %s\n' "$version"
    printf '  Source commit:  %s\n' "$candidate_sha"
    printf '  DMG SHA-256:    %s\n' "$release_dmg_sha256"
    printf '  Cask:           %s\n' "$cask_file"
    printf '\nReview and commit the cask separately. Publish only with:\n'
    printf '  %s publish --version %s --candidate-sha %s --tap-dir <tap-checkout> --receipt <receipt.json>\n' \
      "$0" "$version" "$candidate_sha"
    ;;
  publish)
    require_command brew
    require_command python3
    publish_cask "$version" "$candidate_sha" "$tap_dir" "$receipt_path"
    ;;
  *)
    die "unsupported mode: $mode"
    ;;
esac
