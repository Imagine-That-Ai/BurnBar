#!/usr/bin/env bash
#
# tag-release.sh — Create a validated, annotated git tag for an OpenBurnBar release.
#
# Usage:
#   scripts/tag-release.sh <version>       # e.g. scripts/tag-release.sh 0.2.0
#   scripts/tag-release.sh 0.2.0-beta.1    # pre-release variant
#
# What it does:
#   1. Validates the version string is semver-compliant
#   2. Checks that the version in project.yml matches the tag
#   3. Extracts the matching CHANGELOG.md section as the tag body
#   4. Creates an annotated tag with subject "OpenBurnBar VERSION"
#   5. Pushes the tag to origin
#
# Prerequisites:
#   - Clean working tree (or --force flag to skip check)
#   - Version must exist in CHANGELOG.md
#   - Version must match PROJECT_MARKETING_VERSION in project.yml
#
# Options:
#   --force    Skip the clean-working-tree check
#   --dry-run  Show what would be done without creating/pushing the tag
#   -h, --help Show this help

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=0
FORCE=0
VERSION=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)  FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "ERROR: Version already specified as $VERSION" >&2
        exit 1
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "ERROR: Version argument is required" >&2
  echo "Usage: $0 [--force] [--dry-run] <version>" >&2
  echo "Example: $0 0.2.0" >&2
  echo "Example: $0 0.2.0-beta.1" >&2
  exit 1
fi

TAG="v${VERSION}"

# ── 1. Validate semver format ──────────────────────────────────────────

SEMVER_REGEX='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
if [[ ! "$VERSION" =~ $SEMVER_REGEX ]]; then
  echo "ERROR: Version '$VERSION' does not match semver format (MAJOR.MINOR.PATCH[-PRERELEASE])" >&2
  exit 1
fi

# ── 2. Check working tree ──────────────────────────────────────────────

if [[ $FORCE -eq 0 ]]; then
  if ! git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null || \
     ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null || \
     [[ -n "$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    echo "ERROR: Working tree has uncommitted changes. Commit or stash them first, or use --force." >&2
    exit 1
  fi
fi

# ── 3. Verify version in project.yml ───────────────────────────────────

PROJECT_YML="$REPO_ROOT/project.yml"
if [[ -f "$PROJECT_YML" ]]; then
  PROJECT_VERSION="$(grep -E '^\s+MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *//;s/ *//;s/"//g;s/'//g')"
  if [[ -n "$PROJECT_VERSION" && "$PROJECT_VERSION" != "$VERSION" ]]; then
    echo "ERROR: Version mismatch:" >&2
    echo "  Tag version:      $VERSION" >&2
    echo "  project.yml says: $PROJECT_VERSION" >&2
    echo "  Update MARKETING_VERSION in project.yml before tagging." >&2
    exit 1
  fi
fi

# ── 4. Verify version exists in CHANGELOG ──────────────────────────────

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
if [[ ! -f "$CHANGELOG" ]]; then
  echo "ERROR: CHANGELOG.md not found at $CHANGELOG" >&2
  exit 1
fi

# Look for the version heading in CHANGELOG (supports both bracketed and unbracketed)
CHANGELOG_HEADING_REGEX="##\s*\[?\s*${VERSION}\s*\]?"
if ! grep -qE "$CHANGELOG_HEADING_REGEX" "$CHANGELOG"; then
  echo "ERROR: Version $VERSION not found in CHANGELOG.md" >&2
  echo "  Add a '## [$VERSION]' section to CHANGELOG.md before tagging." >&2
  exit 1
fi

# Extract the section for this version as the tag body
# (from the version heading to the next version heading or end of file)
TAG_BODY="$(awk "
  /^[#]{2,} \[?${VERSION}/ { found=1; next }
  found && /^[#]{2,} \[/ { exit }
  found { print }
" "$CHANGELOG" | sed '/^$/d;1,/^$/d' | head -100)"

if [[ -z "$TAG_BODY" ]]; then
  TAG_BODY="Release $VERSION"
fi

# ── 5. Check if tag already exists ─────────────────────────────────────

if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "ERROR: Tag $TAG already exists." >&2
  echo "  To re-tag, delete it first: git tag -d $TAG && git push origin :$TAG" >&2
  exit 1
fi

# ── 6. Summary ─────────────────────────────────────────────────────────

echo "=== Release Tag Summary ==="
echo "  Version:     $VERSION"
echo "  Tag:         $TAG"
echo "  Commit:      $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
echo "  Branch:      $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
echo "  Body:        $(echo "$TAG_BODY" | head -1)"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "DRY RUN — would create tag $TAG and push to origin."
  echo ""
  echo "--- Tag body (first 20 lines) ---"
  echo "$TAG_BODY" | head -20
  echo "--- End tag body ---"
  exit 0
fi

# ── 7. Create and push the annotated tag ───────────────────────────────

git -C "$REPO_ROOT" tag -a "$TAG" -m "OpenBurnBar $VERSION" -m "$TAG_BODY"

echo "Tag $TAG created."
echo ""
echo "Pushing to origin..."
git -C "$REPO_ROOT" push origin "$TAG"

echo ""
echo "✓ Tag $TAG pushed to origin. The release workflow should now trigger."
