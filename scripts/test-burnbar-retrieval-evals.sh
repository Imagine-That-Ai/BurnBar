#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

xcodebuild test \
  -project "$repo_root/BurnBar.xcodeproj" \
  -scheme "BurnBar" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:"BurnBarTests/BurnBarRetrievalReplayGoldenTests" \
  -only-testing:"BurnBarTests/BurnBarAuthoringReplayGoldenTests"
