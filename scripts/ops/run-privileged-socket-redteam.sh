#!/usr/bin/env bash
# Opt-in privileged socket red-team (P0.c). Requires P0+ daemons and the probe binary.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

export RUN_PRIVILEGED_SOCKET_REDTEAM=1

echo "==> Building OpenBurnBarPrivilegedSocketRedTeamProbe"
swift build \
  --package-path OpenBurnBarDaemon \
  --product OpenBurnBarPrivilegedSocketRedTeamProbe \
  -c debug

echo "==> Running PrivilegedSocketRedTeamIntegrationTests (skips if socket absent)"
xcodebuild test \
  -scheme OpenBurnBarDaemon \
  -destination 'platform=macOS' \
  -only-testing:OpenBurnBarRemoteAccessAgentCoreTests/PrivilegedSocketRedTeamIntegrationTests \
  2>&1 | tail -40

echo "Privileged socket red-team gate finished (see XCTest output above)."