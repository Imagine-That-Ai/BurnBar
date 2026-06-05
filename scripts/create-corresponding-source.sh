#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

version=""
output=""

usage() {
  cat <<'EOF'
Usage: scripts/create-corresponding-source.sh --version VERSION --output PATH

Builds an AGPL corresponding-source tarball for the current OpenBurnBar commit.

By default the working tree must be clean so the archive exactly matches HEAD.
For local verification before committing, set OPENBURNBAR_ALLOW_DIRTY_SOURCE=1;
the manifest will mark the archive as dirty.
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

commit="$(git rev-parse HEAD)"
dirty="false"
if ! git diff --quiet --ignore-submodules -- || ! git diff --cached --quiet --ignore-submodules -- || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  dirty="true"
fi

if [[ "$dirty" == "true" && "${OPENBURNBAR_ALLOW_DIRTY_SOURCE:-0}" != "1" ]]; then
  echo "ERROR: working tree is dirty; commit changes before building corresponding source." >&2
  echo "Set OPENBURNBAR_ALLOW_DIRTY_SOURCE=1 only for local verification archives." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

prefix="OpenBurnBar-${version}-source"
archive_root="$tmpdir/$prefix"
mkdir -p "$archive_root"

if [[ "$dirty" == "true" ]]; then
  python3 - "$archive_root" <<'PY'
import shutil
import subprocess
import sys
from pathlib import Path

destination = Path(sys.argv[1])
raw = subprocess.check_output(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
)
for item in raw.split(b"\0"):
    if not item:
        continue
    rel = Path(item.decode("utf-8"))
    src = Path(rel)
    if not src.is_file():
        continue
    out = destination / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, out)
PY
else
  git archive --format=tar HEAD | tar -x -C "$archive_root"
fi

required=(
  "LICENSE"
  "NOTICE"
  "THIRD_PARTY_NOTICES.md"
  "LICENSES/MIT-legacy.txt"
  "docs/legal/agpl-compliance.md"
  "scripts/create-corresponding-source.sh"
)

for rel in "${required[@]}"; do
  if [[ ! -f "$archive_root/$rel" ]]; then
    echo "ERROR: corresponding source archive is missing $rel" >&2
    exit 1
  fi
done

python3 - "$archive_root/CORRESPONDING_SOURCE_MANIFEST.json" "$version" "$commit" "$dirty" <<'PY'
import datetime
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
commit = sys.argv[3]
dirty = sys.argv[4] == "true"

manifest = {
    "product": "OpenBurnBar",
    "version": version,
    "license": "AGPL-3.0-only",
    "repository": "https://github.com/Imagine-That-Ai/BurnBar",
    "commit": commit,
    "dirtySourceArchive": dirty,
    "correspondingSource": "https://burnbar.ai/legal/source",
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "includes": [
        "source tree",
        "build scripts",
        "release scripts",
        "dependency lockfiles",
        "SPDX SBOM inputs",
        "AGPL compliance docs",
        "official Signal libsignal pin"
    ],
}
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

mkdir -p "$(dirname "$output")"
tar -czf "$output" -C "$tmpdir" "$prefix"
shasum -a 256 "$output" > "${output}.sha256"

echo "Corresponding source archive: $output"
echo "SHA256: ${output}.sha256"
