#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exporter="$ROOT/scripts/linux-port/export-linux-swift-coverage.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-linux-coverage-export.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/bin" "$tmp_root/profiles" "$tmp_root/out"
primary="$tmp_root/current-core.xctest"
secondary="$tmp_root/current-daemon.xctest"
stale="$tmp_root/stale-unowned.xctest"
printf '#!/bin/sh\n' > "$primary"
printf '#!/bin/sh\n' > "$secondary"
printf '#!/bin/sh\n' > "$stale"
chmod +x "$primary" "$secondary" "$stale"

cat > "$tmp_root/bin/llvm-profdata" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    shift
    : > "$1"
    exit 0
  fi
  shift
done
exit 2
EOF
cat > "$tmp_root/bin/llvm-cov" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_LLVM_COV_ARGS"
cat "$FAKE_LCOV"
EOF
cat > "$tmp_root/bin/llvm-cov-fail" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
chmod +x "$tmp_root/bin/llvm-profdata" "$tmp_root/bin/llvm-cov" "$tmp_root/bin/llvm-cov-fail"

fake_lcov="$tmp_root/fake.lcov"
cat > "$fake_lcov" <<EOF
SF:$ROOT/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxCloudAuthHTTPClient.swift
DA:16,1
end_of_record
EOF
export PATH="$tmp_root/bin:$PATH"
export FAKE_LCOV="$fake_lcov"
export FAKE_LLVM_COV_ARGS="$tmp_root/llvm-cov.args"

rc=0
"$exporter" "$tmp_root/profiles" "$tmp_root/out/zero.lcov" "$tmp_root/out/zero.json" "$primary" \
  > /dev/null 2> "$tmp_root/zero.err" || rc=$?
[[ "$rc" -eq 1 ]]
grep -q 'no non-empty LLVM profiles' "$tmp_root/zero.err"

printf 'profile\n' > "$tmp_root/profiles/current.profraw"
"$exporter" "$tmp_root/profiles" "$tmp_root/out/current.lcov" "$tmp_root/out/current.json" \
  "$primary" "$secondary"
args="$(cat "$FAKE_LLVM_COV_ARGS")"
[[ "$args" == *"$primary -object $secondary"* ]]
[[ "$args" != *"$stale"* ]]
[[ -s "$tmp_root/out/current.lcov" && -s "$tmp_root/out/current.json" ]]
python3 - "$tmp_root/out/current.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload["files"]
PY

rc=0
mv "$tmp_root/bin/llvm-cov-fail" "$tmp_root/bin/llvm-cov"
env LLVM_COV_BIN="$tmp_root/bin/llvm-cov" \
  "$exporter" "$tmp_root/profiles" "$tmp_root/out/failed.lcov" "$tmp_root/out/failed.json" "$primary" \
  > /dev/null 2> "$tmp_root/failed.err" || rc=$?
[[ "$rc" -eq 1 ]]
[[ ! -e "$tmp_root/out/failed.lcov" && ! -e "$tmp_root/out/failed.json" ]]

echo "Linux Swift coverage export self-test: all assertions passed"
