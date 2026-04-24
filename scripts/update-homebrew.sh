#!/usr/bin/env bash
#
# update-homebrew.sh — Update the Homebrew cask formula with the release DMG checksum.
#
# Usage:
#   scripts/update-homebrew.sh <version>
#
# What it does:
#   1. Downloads the DMG from the GitHub release for the given version
#   2. Computes the SHA256 checksum
#   3. Updates homebrew/burnbar.rb with the version and checksum
#
# Prerequisites:
#   - gh (GitHub CLI) authenticated
#   - curl
#   - shasum (macOS) or sha256sum (Linux)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK_FILE="$REPO_ROOT/homebrew/burnbar.rb"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
  exit 0
}

if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  usage
fi

VERSION="${1#v}"  # Strip leading 'v' if present
TAG="v${VERSION}"
OWNER="Ajnunezg"
REPO="BurnBar"
DMG_NAME="OpenBurnBar-${VERSION}-macOS.dmg"
RELEASE_URL="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/${DMG_NAME}"
CASK_URL="https://github.com/${OWNER}/${REPO}/releases/download/v#{version}/${DMG_NAME%DMG_NAME#*$VERSION}#{version}-macOS.dmg"

echo "=== Updating Homebrew Cask for ${VERSION} ==="

# ── 1. Verify the release exists ───────────────────────────────────────

echo "Checking release ${TAG} exists..."
if ! gh release view "$TAG" --repo "$OWNER/$REPO" >/dev/null 2>&1; then
  echo "ERROR: Release $TAG not found on GitHub." >&2
  echo "  Create the release first with the release workflow." >&2
  exit 1
fi

# ── 2. Download the DMG ─────────────────────────────────────────────────

TMPDIR="$(mktemp -d)"
DMG_PATH="$TMPDIR/$DMG_NAME"

echo "Downloading ${DMG_NAME}..."
curl --fail --location --output "$DMG_PATH" "$RELEASE_URL"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: Failed to download DMG from $RELEASE_URL" >&2
  rm -rf "$TMPDIR"
  exit 1
fi

# ── 3. Compute SHA256 ──────────────────────────────────────────────────

echo "Computing SHA256 checksum..."
if command -v shasum >/dev/null 2>&1; then
  SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  SHA256="$(sha256sum "$DMG_PATH" | awk '{print $1}')"
else
  echo "ERROR: Neither shasum nor sha256sum found." >&2
  rm -rf "$TMPDIR"
  exit 1
fi

echo "  SHA256: $SHA256"

# Clean up the downloaded file
rm -rf "$TMPDIR"

# ── 4. Update the cask file ────────────────────────────────────────────

if [[ ! -f "$CASK_FILE" ]]; then
  echo "ERROR: Cask file not found at $CASK_FILE" >&2
  exit 1
fi

echo "Updating $CASK_FILE..."

# Use a temp file for atomic update
TMP_CASK="$(mktemp)"
cp "$CASK_FILE" "$TMP_CASK"

# Update version line
sed -i '' "s|version \".*\"|version \"${VERSION}\"|" "$TMP_CASK"

# Update sha256 line — replace :no_check or existing hash
sed -i '' "s|sha256 .*|sha256 \"${SHA256}\"|" "$TMP_CASK"

# Update URL line — ensure it uses the #{version} template
sed -i '' "s|url \".*/releases/download/v.*\"|url \"https://github.com/${OWNER}/${REPO}/releases/download/v#{version}/OpenBurnBar-#{version}-macOS.dmg\"|" "$TMP_CASK"

mv "$TMP_CASK" "$CASK_FILE"

echo ""
echo "✓ Homebrew cask updated:"
echo "  Version: ${VERSION}"
echo "  SHA256:  ${SHA256}"
echo "  File:    ${CASK_FILE}"
echo ""
echo "Next steps:"
echo "  1. Review the changes: git diff homebrew/burnbar.rb"
echo "  2. Commit: git commit homebrew/burnbar.rb -m 'chore: update homebrew cask for v${VERSION}'"
echo "  3. Push and publish the tap."
