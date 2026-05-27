#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${OPENBURNBAR_STARTUP_DERIVED_DATA:-/tmp/openburnbar-startup-profile-dd}"
output_dir="${1:-/tmp/openburnbar-startup-profile-$(date +%Y%m%d-%H%M%S)}"
sample_seconds="${OPENBURNBAR_STARTUP_SAMPLE_SECONDS:-12}"
settle_seconds="${OPENBURNBAR_STARTUP_SETTLE_SECONDS:-15}"

mkdir -p "$output_dir"

echo "==> Building OpenBurnBar macOS debug app"
xcodebuild build \
  -project "$repo_root/OpenBurnBar.xcodeproj" \
  -scheme OpenBurnBar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -quiet

app_path="$derived_data/Build/Products/Debug/OpenBurnBar.app"
exe="$app_path/Contents/MacOS/OpenBurnBar"
if [[ ! -x "$exe" ]]; then
  echo "error: built app executable not found at $exe" >&2
  exit 1
fi

echo "==> Launching profile target"
OPENBURNBAR_STARTUP_PROFILE=1 "$exe" >"$output_dir/stdout.log" 2>"$output_dir/stderr.log" &
pid="$!"

cleanup() {
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sleep 2
echo "==> Capturing sample for ${sample_seconds}s"
sample "$pid" "$sample_seconds" -file "$output_dir/sample.txt" >/dev/null
if ! kill -0 "$pid" 2>/dev/null; then
  wait "$pid" 2>/dev/null || true
  echo "error: OpenBurnBar exited during startup profiling; see $output_dir/stderr.log" >&2
  exit 1
fi

echo "==> Capturing settled CPU after ${settle_seconds}s"
sleep "$settle_seconds"
if ! kill -0 "$pid" 2>/dev/null; then
  wait "$pid" 2>/dev/null || true
  echo "error: OpenBurnBar exited before settled snapshot; see $output_dir/stderr.log" >&2
  exit 1
fi
ps -p "$pid" -o pid,pcpu,pmem,etime,comm >"$output_dir/settled-ps.txt" || true

if [[ "${OPENBURNBAR_STARTUP_PROFILE_XCTRACE:-0}" == "1" ]] && command -v xcrun >/dev/null; then
  echo "==> Optional xctrace capture requested"
  xcrun xctrace record \
    --template 'Time Profiler' \
    --time-limit "${sample_seconds}s" \
    --output "$output_dir/startup.trace" \
    --launch "$exe" >/dev/null 2>"$output_dir/xctrace.log" || true
fi

cat >"$output_dir/README.txt" <<EOF
OpenBurnBar startup profile

App: $app_path
PID: $pid
Sample: $output_dir/sample.txt
Settled process snapshot: $output_dir/settled-ps.txt

Useful follow-ups:
  rg "startup_|OpenBurnBarApp|DataStore|refreshHealth|refreshAll|start[A-Z]" "$output_dir/sample.txt"
  open "$output_dir"
EOF

echo "==> Startup profile written to $output_dir"
