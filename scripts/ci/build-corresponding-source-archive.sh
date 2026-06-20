#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

version=""
output=""

usage() {
  cat <<'EOF'
Usage: scripts/ci/build-corresponding-source-archive.sh --version VERSION --output PATH

Builds the publishable AGPL corresponding-source archive from a clean detached
worktree at HEAD. The caller's working tree may contain CI-injected configs,
build products, or other uncommitted files; those must not contaminate the
release source archive or weaken the clean-source manifest.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
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

if [[ -z "$version" || -z "$output" ]]; then
  usage >&2
  exit 2
fi

mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
commit="$(git rev-parse HEAD)"
tmpdir="$(mktemp -d)"
worktree="$tmpdir/worktree"

cleanup() {
  if [[ -d "$worktree" ]]; then
    git worktree remove --force "$worktree" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

git worktree add --detach "$worktree" "$commit" >/dev/null

(
  cd "$worktree"
  env \
    HERMES_AGENT_SRC="${HERMES_AGENT_SRC:-}" \
    OPENBURNBAR_REQUIRE_HERMES_AGENT_SOURCE="${OPENBURNBAR_REQUIRE_HERMES_AGENT_SOURCE:-0}" \
    scripts/create-corresponding-source.sh --version "$version" --output "$output"
)

python3 - "$output" "$version" "$commit" <<'PY'
import json
import sys
import tarfile

archive_path, version, commit = sys.argv[1:4]
manifest_name = f"OpenBurnBar-{version}-source/CORRESPONDING_SOURCE_MANIFEST.json"

with tarfile.open(archive_path, "r:gz") as archive:
    try:
        manifest_file = archive.extractfile(manifest_name)
    except KeyError:
        raise SystemExit(f"ERROR: source archive is missing {manifest_name}")
    if manifest_file is None:
        raise SystemExit(f"ERROR: source archive manifest is unreadable: {manifest_name}")
    manifest = json.load(manifest_file)

if manifest.get("commit") != commit:
    raise SystemExit(
        f"ERROR: source archive commit {manifest.get('commit')} does not match HEAD {commit}"
    )
if manifest.get("dirtySourceArchive") is not False:
    raise SystemExit("ERROR: release source archive must be generated from a clean worktree")
PY

echo "Publishable corresponding source archive: $output"
