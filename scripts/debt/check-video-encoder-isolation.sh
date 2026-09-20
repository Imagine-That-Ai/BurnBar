#!/usr/bin/env bash
# VideoEncoder must not be MainActor-isolated; capture/encode runs off the UI actor.
set -euo pipefail
cd "$(dirname "$0")/../.."
if rg -n "^@MainActor$" -A1 AgentLens/Services/Media/VideoEncoder.swift | rg -q "protocol VideoEncoding|final class VideoEncoder"; then
  echo "VideoEncoder/VideoEncoding is still @MainActor" >&2
  exit 1
fi
if ! rg -q "stateLock" AgentLens/Services/Media/VideoEncoder.swift; then
  echo "VideoEncoder lost its off-MainActor state lock" >&2
  exit 1
fi
echo "VideoEncoder isolation OK (not @MainActor; stateLock present)"
