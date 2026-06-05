#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

version="ci-proof"

usage() {
  cat <<'EOF'
Usage: scripts/ci/verify-corresponding-source-archive.sh [--version VERSION]

Builds the AGPL corresponding-source archive from a clean detached worktree at
HEAD, extracts it, and verifies the source-offer manifest and required files.
This proves the committed source release path without relying on the caller's
dirty working tree.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$version" ]]; then
  echo "ERROR: --version cannot be empty" >&2
  exit 2
fi

commit="$(git rev-parse HEAD)"
tmpdir="$(mktemp -d)"
worktree="$tmpdir/worktree"
archive="$tmpdir/OpenBurnBar-${version}-corresponding-source.tar.gz"
extract="$tmpdir/extract"

cleanup() {
  if [[ -d "$worktree" ]]; then
    git worktree remove --force "$worktree" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

git worktree add --detach "$worktree" HEAD >/dev/null

(
  cd "$worktree"
  scripts/create-corresponding-source.sh --version "$version" --output "$archive" >/dev/null
)

[[ -f "$archive" ]] || { echo "ERROR: missing source archive" >&2; exit 1; }
[[ -f "${archive}.sha256" ]] || { echo "ERROR: missing source archive sha256" >&2; exit 1; }

mkdir -p "$extract"
tar -xzf "$archive" -C "$extract"

archive_root="$extract/OpenBurnBar-${version}-source"
if [[ ! -d "$archive_root" ]]; then
  echo "ERROR: archive root OpenBurnBar-${version}-source is missing" >&2
  exit 1
fi

required=(
  "LICENSE"
  "LICENSES/MIT-legacy.txt"
  "NOTICE"
  "THIRD_PARTY_NOTICES.md"
  "REUSE.toml"
  "docs/legal/agpl-compliance.md"
  "scripts/create-corresponding-source.sh"
  "scripts/generate-sbom.py"
  "scripts/supply-chain/generate-vex.py"
  "scripts/supply-chain/run-ecosystem-deny-checks.sh"
  "third_party/libsignal/manifest.json"
  "third_party/libsignal/runtime-readiness.json"
  "packages/libsignal-bridge/package-lock.json"
  "functions/package-lock.json"
  "website/package-lock.json"
)

for rel in "${required[@]}"; do
  if [[ ! -f "$archive_root/$rel" ]]; then
    echo "ERROR: corresponding source archive is missing $rel" >&2
    exit 1
  fi
done

node - "$archive_root/CORRESPONDING_SOURCE_MANIFEST.json" "$version" "$commit" <<'NODE'
const fs = require('node:fs');

const manifestPath = process.argv[2];
const expectedVersion = process.argv[3];
const expectedCommit = process.argv[4];
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

if (manifest.product !== 'OpenBurnBar') fail('manifest product drifted');
if (manifest.version !== expectedVersion) fail(`manifest version ${manifest.version} != ${expectedVersion}`);
if (manifest.license !== 'AGPL-3.0-only') fail(`manifest license ${manifest.license} != AGPL-3.0-only`);
if (manifest.commit !== expectedCommit) fail(`manifest commit ${manifest.commit} != ${expectedCommit}`);
if (manifest.dirtySourceArchive !== false) fail('source archive must be built from a clean worktree');
if (manifest.correspondingSource !== 'https://burnbar.ai/legal/source') fail('corresponding source URL drifted');
if (!Array.isArray(manifest.includes) || !manifest.includes.includes('official Signal libsignal pin')) {
  fail('manifest must record the official Signal libsignal pin');
}
NODE

tar -tzf "$archive" | grep -q "^OpenBurnBar-${version}-source/CORRESPONDING_SOURCE_MANIFEST.json$" \
  || { echo "ERROR: archive listing is missing CORRESPONDING_SOURCE_MANIFEST.json" >&2; exit 1; }

echo "PASS: corresponding source archive builds cleanly from HEAD ${commit}"
