#!/usr/bin/env bash
# End-to-end proof gate for the Rust burnbar-remote foundation.
#
# Deterministic Rust checks always run. Live relay and physical-device rows are
# evidence gates: they prove current transport/device surfaces are reachable,
# not that native platform media adapters have shipped.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_DIR="${ROOT}/crates/burnbar-remote"

cd "${REMOTE_DIR}"

echo "▶ burnbar-remote fmt"
cargo fmt --check

echo "▶ burnbar-remote clippy"
cargo clippy --workspace --all-targets -- -D warnings

echo "▶ burnbar-remote tests"
cargo test --workspace

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "▶ burnbar-remote macOS Keychain test"
    cargo test -p burnbar-remote-security --features macos-keychain macos_keychain -- --nocapture
fi

echo "▶ burnbar-remote docs"
cargo doc --workspace --no-deps

echo "▶ burnbar-remote synthetic benchmark"
cargo run -p burnbar-remote-bench --bin burnbar-remote-bench

echo "▶ burnbar-remote Iroh smoke"
cargo run -p burnbar-remote-bench --bin iroh-smoke

if [[ -f "${ROOT}/.secrets/iroh-services.env" ]]; then
    echo "▶ existing Iroh Services smoke"
    (cd "${ROOT}" && ./scripts/e2e/iroh-services-smoke.sh)
else
    echo "burnbar_remote_iroh_services status=skipped reason=.secrets/iroh-services.env_missing"
fi

echo "▶ physical device inventory"
if command -v xcrun >/dev/null 2>&1; then
    xcrun devicectl list devices | sed -n '1,120p'
else
    echo "coredevice status=skipped reason=xcrun_missing"
fi

if command -v adb >/dev/null 2>&1; then
    adb devices -l
elif [[ -x "${HOME}/Library/Android/platform-tools/adb" ]]; then
    "${HOME}/Library/Android/platform-tools/adb" devices -l
else
    echo "adb status=skipped reason=adb_missing"
fi

echo "✅ burnbar-remote hardening proof complete"
