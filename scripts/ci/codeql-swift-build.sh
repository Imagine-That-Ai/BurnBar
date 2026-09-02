#!/usr/bin/env bash
# Traced Swift build for CodeQL (W0-10). Invoked by .github/workflows/codeql.yml
# in the "Build Swift (CodeQL)" step AFTER github/codeql-action/init, so the
# CodeQL tracer hooks these xcodebuild invocations.
#
# Conventions (scripts/): set -euo pipefail, absolute repo root, no args.
#
# Disable code signing because hosted macOS runners have no signing identities.
# Retried once because Xcode 27 SwiftPM can crash with "INTERNAL ERROR:
# Uncaught exception" during the package-graph action even after a clean
# resolve (same transient class release.yml classifies and retries,
# 64c7341fbe). The retry stays inside this one script so the CodeQL tracer
# observes whichever attempt compiles.
#
# NOTE: this build stays x86_64 deliberately. The "arm64 cryptex is already
# present" theory is UNCONFIRMED — app-pr-gate run 33326737617 shows no
# CompileMetalFile lines — so do not flip the destination arch without
# dispatch evidence (REMEDIATION_PLAN_2026-09-01.md, W0-10).
set -euo pipefail
cd "$(dirname "$0")/../.."

for attempt in 1 2; do
  if xcodebuild -project OpenBurnBar.xcodeproj \
    -scheme OpenBurnBar \
    -configuration Debug \
    -destination 'platform=macOS,arch=x86_64' \
    -derivedDataPath .codeql-derived-data \
    ARCHS=x86_64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    build; then
    exit 0
  fi
  if [ "$attempt" = "2" ]; then
    exit 1
  fi
  echo "xcodebuild failed (attempt ${attempt}); retrying the traced build once."
  sleep 20
done
