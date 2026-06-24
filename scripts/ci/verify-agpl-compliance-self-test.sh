#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

grep -q 'find crates -type f -name Cargo.toml -print0' \
  "$repo_root/scripts/ci/verify-agpl-compliance.sh" \
  || {
    echo "ERROR: AGPL compliance gate must restrict Cargo.toml scans to regular files." >&2
    exit 1
  }

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-agpl-compliance-selftest.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/crates/regular" "$tmp_dir/crates/symlinked" "$tmp_dir/outside"
printf '[package]\nlicense = "AGPL-3.0-only"\n' > "$tmp_dir/crates/regular/Cargo.toml"
printf '[package]\nlicense = "Apache-2.0 OR MIT"\n' > "$tmp_dir/outside/Cargo.toml"
ln -s ../../outside/Cargo.toml "$tmp_dir/crates/symlinked/Cargo.toml"

(
  cd "$tmp_dir"
  find crates -type f -name Cargo.toml -print0 | tr '\0' '\n' > found-cargo-tomls.txt
)

grep -Fxq 'crates/regular/Cargo.toml' "$tmp_dir/found-cargo-tomls.txt" \
  || {
    echo "ERROR: AGPL compliance Cargo.toml scan missed a regular manifest." >&2
    exit 1
  }

if grep -Fxq 'crates/symlinked/Cargo.toml' "$tmp_dir/found-cargo-tomls.txt"; then
  echo "ERROR: AGPL compliance Cargo.toml scan followed a symlinked manifest." >&2
  exit 1
fi

echo "PASS: AGPL compliance self-test"
