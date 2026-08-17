#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${OPENBURNBAR_REMOTE_SWIFT_SMOKE_ROOT:-}" ]]; then
  SMOKE_DIR="${OPENBURNBAR_REMOTE_SWIFT_SMOKE_ROOT%/}/BurnBarRemoteSwiftSmoke"
elif [[ -n "${OPENBURNBAR_SWIFT_SCRATCH_ROOT:-}" ]]; then
  SMOKE_DIR="${OPENBURNBAR_SWIFT_SCRATCH_ROOT%/}/BurnBarRemoteSwiftSmoke"
else
  SMOKE_DIR="${ROOT_DIR}/build/burnbar-remote-swift-smoke"
fi
XCFRAMEWORK="${ROOT_DIR}/Vendor/BurnBarRemote.xcframework"
FILTER="${OPENBURNBAR_REMOTE_SWIFT_FILTER:-BurnBarRemoteEngineSupportTests}"

if [[ ! -d "${XCFRAMEWORK}" ]]; then
  echo "Missing ${XCFRAMEWORK}; run scripts/build-burnbar-remote-xcframework.sh first." >&2
  exit 1
fi

rm -rf "${SMOKE_DIR}"
mkdir -p \
  "${SMOKE_DIR}/Sources/BurnBarRemoteFFI" \
  "${SMOKE_DIR}/Sources/BurnBarRemoteEngine" \
  "${SMOKE_DIR}/Tests/BurnBarRemoteEngineTests"

ln -s "${XCFRAMEWORK}" "${SMOKE_DIR}/BurnBarRemote.xcframework"
cp "${ROOT_DIR}/OpenBurnBarCore/Sources/BurnBarRemote/Generated/"* "${SMOKE_DIR}/Sources/BurnBarRemoteFFI/"
cp "${ROOT_DIR}/OpenBurnBarCore/Sources/BurnBarRemoteEngine/"*.swift "${SMOKE_DIR}/Sources/BurnBarRemoteEngine/"
cp "${ROOT_DIR}/OpenBurnBarCore/Tests/BurnBarRemoteEngineTests/"*.swift "${SMOKE_DIR}/Tests/BurnBarRemoteEngineTests/"

cat > "${SMOKE_DIR}/Package.swift" <<'EOF'
// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "BurnBarRemoteSwiftSmoke",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    targets: [
        .binaryTarget(
            name: "BurnBarRemote",
            path: "BurnBarRemote.xcframework"
        ),
        .target(
            name: "BurnBarRemoteFFI",
            dependencies: ["BurnBarRemote"],
            path: "Sources/BurnBarRemoteFFI",
            exclude: [
                "burnbar_remote.modulemap",
                "burnbar_remoteFFI.h"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BurnBarRemoteEngine",
            dependencies: ["BurnBarRemoteFFI"],
            path: "Sources/BurnBarRemoteEngine"
        ),
        .testTarget(
            name: "BurnBarRemoteEngineTests",
            dependencies: ["BurnBarRemoteEngine"],
            path: "Tests/BurnBarRemoteEngineTests"
        )
    ]
)
EOF

swift test --package-path "${SMOKE_DIR}" --filter "${FILTER}"
