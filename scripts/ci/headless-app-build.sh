#!/usr/bin/env bash
#
# headless-app-build.sh — build the macOS AgentLens app (scheme OpenBurnBar)
# HEADLESS, with no human at an Xcode GUI.
#
# WHY THIS EXISTS (Core-decomposition packet S-H):
#   K4 / P-16 (the Views -> OpenBurnBarUI extraction) was deferred in the prior
#   program because there was NO merge-blocking, PR-triggerable signal that the
#   macOS APP still COMPILES after a UI move. The full app suite
#   (app-pr-gate.yml `app-build-test`) runs `xcodebuild test` — heavy (a 120 min
#   cap, XCTest host launch, simulator/Firestore lifecycle). P-16 does not need
#   the tests to RUN; it needs proof the app graph still BUILDS. This script is
#   that lean, build-only precondition. It is wired into
#   .github/workflows/headless-app-build.yml on `pull_request` for the paths that
#   P-16 touches (OpenBurnBarCore/** and AgentLens/**), and each P-16 sub-packet
#   PR body names this job as a required gate.
#
# THE HEADLESS-BUILD RECIPE (repo memory "Headless xcodebuild blocked (Xcode 27
# Beta)"): a NAIVE `xcodebuild` from a checkout under ~/Documents fails on Xcode
# 27 beta because
#   (a) the build-task SANDBOX treats the in-repo `.spm-cache` as a read-only
#       source tree, so ProcessXCFramework cannot extract the vendored binary
#       xcframeworks, and
#   (b) pointing the cache outside the repo then trips macOS TCC on ~/Documents
#       during a fresh package resolve.
# Neither blocker bites on a FRESH CI RUNNER: its checkout lives OUTSIDE
# ~/Documents (a writable, TCC-unrestricted path), so a normal in-tree resolve +
# build succeeds — which is how app-pr-gate.yml already builds the app. This
# script therefore has TWO modes:
#
#   * CI / non-Documents checkout (the default on GitHub runners): build IN-TREE.
#     A fresh SwiftPM resolve is allowed (the runner has network + a warm cache),
#     Vendor artifacts extract normally, no sandbox/TCC hit.
#
#   * LOCAL developer checkout under ~/Documents (auto-detected, or forced with
#     HEADLESS_APP_BUILD_LOCAL_REUSE=1): reuse a sibling primary checkout's
#     already-populated `.spm-cache` + Vendor xcframeworks via symlinks and
#     `-disableAutomaticPackageResolution`, so the build never triggers a fresh
#     resolve/extract in the sandboxed source tree. Point the reuse source with
#     HEADLESS_APP_BUILD_CACHE_SOURCE=/path/to/primary/checkout.
#
# In BOTH modes the terminal command is `xcodebuild build -scheme OpenBurnBar`
# for `platform=macOS,arch=arm64` with code signing off — the same scheme the
# app gate ships. Exit 0 == BUILD SUCCEEDED.
#
# Usage:
#   scripts/ci/headless-app-build.sh
#
# Environment knobs:
#   FIREBASE_SOURCE_FIRESTORE   Forced to 1 (iOS 27 gRPC/Firestore source-build
#                               requirement; guards the resolve path).
#   HEADLESS_APP_BUILD_LOCAL_REUSE=1
#                               Force the local cache-reuse mode even outside
#                               ~/Documents (e.g. a dev machine that mirrors the
#                               sandbox constraint).
#   HEADLESS_APP_BUILD_CACHE_SOURCE=<dir>
#                               Primary checkout to borrow `.spm-cache` + Vendor
#                               artifacts from in local-reuse mode. Default:
#                               $HOME/Documents/Developer/BurnBar.
#   HEADLESS_APP_BUILD_DERIVED_DATA=<dir>
#                               Override the derived-data path.
#
# Exit status: 0 on BUILD SUCCEEDED; the xcodebuild exit code otherwise.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source "$repo_root/scripts/lib/libsignal-swift-compat.sh"
# shellcheck source=scripts/lib/xcode-source-classification.sh
source "$repo_root/scripts/lib/xcode-source-classification.sh"
openburnbar_configure_xcode_process_tmpdir

cleanup() {
  local original_status="${1:-0}"
  local google_restore_status=0
  local libsignal_restore_status=0
  openburnbar_restore_google_sign_in_macos_compat || google_restore_status=$?
  openburnbar_restore_libsignal_swift_compat || libsignal_restore_status=$?
  local restore_status="$google_restore_status"
  if ((restore_status == 0)); then
    restore_status="$libsignal_restore_status"
  fi
  if ((original_status == 0 && restore_status != 0)); then
    return "$restore_status"
  fi
  return "$original_status"
}
cleanup_on_exit() {
  local original_status=$?
  trap - EXIT
  cleanup "$original_status"
  exit $?
}
trap cleanup_on_exit EXIT

# iOS 27 gRPC/Firestore source-build requirement: keep any resolve on the
# source-built Firestore graph (docs/FIREBASE_IOS27_GRPC.md). Harmless for a
# macOS-only build, mandatory if resolution reintroduces the grpc-binary path.
export FIREBASE_SOURCE_FIRESTORE="${FIREBASE_SOURCE_FIRESTORE:-1}"

project="$repo_root/OpenBurnBar.xcodeproj"
scheme="OpenBurnBar"
destination="platform=macOS,arch=arm64"
derived_data="${HEADLESS_APP_BUILD_DERIVED_DATA:-$repo_root/.derived-data/headless-app-build}"

if [[ ! -d "$project" ]]; then
  echo "::error::OpenBurnBar.xcodeproj not found at $project" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Mode selection: in-tree (CI) vs local cache-reuse (~/Documents sandbox dodge).
# ---------------------------------------------------------------------------
local_reuse=0
if [[ "${HEADLESS_APP_BUILD_LOCAL_REUSE:-}" == "1" ]]; then
  local_reuse=1
elif [[ "$repo_root" == "$HOME/Documents/"* ]]; then
  # A checkout under ~/Documents hits the Xcode 27 sandbox/TCC blockers on a
  # fresh resolve; borrow a sibling primary checkout's populated cache instead.
  local_reuse=1
fi

log() { printf '>>> %s\n' "$*"; }

log "Headless app build"
log "  repo_root:   $repo_root"
log "  scheme:      $scheme"
log "  destination: $destination"
log "  mode:        $([[ $local_reuse -eq 1 ]] && echo 'local cache-reuse' || echo 'in-tree (CI)')"

# ---------------------------------------------------------------------------
# Signal FFI: the app target's Package.swift attaches OpenBurnBarSignalFfiMac /
# OpenBurnBarSignalFfiIOS as binary targets; materialize them before the build
# so the manifest's has*XCFramework flags flip on and linking uses the same
# path production ships. In local-reuse mode the sibling checkout already
# carries them (linked below), so only run the prep when they are absent.
# ---------------------------------------------------------------------------
prepare_signal_ffi() {
  local prep="$repo_root/scripts/lib/prepare-signal-ffi-xcframework.sh"
  openburnbar_prepare_libsignal_swift_compat "$repo_root"
  if [[ -x "$prep" ]]; then
    log "Preparing Signal FFI XCFramework"
    "$prep"
  fi
}

xcodebuild_common_args=(
  -project "$project"
  -scheme "$scheme"
  -configuration Debug
  -destination "$destination"
  -derivedDataPath "$derived_data"
  SWIFT_ENABLE_EXPLICIT_MODULES=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  -disableAutomaticPackageResolution
  "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}"
)

if [[ $local_reuse -eq 1 ]]; then
  # --- LOCAL cache-reuse mode ---------------------------------------------
  cache_source="${HEADLESS_APP_BUILD_CACHE_SOURCE:-$HOME/Documents/Developer/BurnBar}"
  primary_cache="$cache_source/.spm-cache"

  if [[ ! -d "$primary_cache" ]]; then
    echo "::error::local-reuse mode needs a populated $primary_cache" >&2
    echo "         set HEADLESS_APP_BUILD_CACHE_SOURCE to a primary checkout" >&2
    echo "         whose app scheme has been resolved+built once via Xcode." >&2
    exit 3
  fi

  # Link the gitignored, multi-GB Vendor artifacts this checkout lacks from the
  # primary checkout so ProcessXCFramework finds pre-extracted binaries and the
  # manifest flags flip (mirrors scripts/lane-setup.sh's Vendor-linking).
  if [[ -e "$cache_source/Vendor" && "$cache_source" != "$repo_root" ]]; then
    for artifact in \
      OpenBurnBarIroh.xcframework \
      OpenBurnBarSignalFfiIOS.xcframework \
      OpenBurnBarSignalFfiMac.xcframework \
      OpenBurnBarSignalFfi.xcframework \
      BurnBarRemote.xcframework; do
      src="$cache_source/Vendor/$artifact"
      dst="$repo_root/Vendor/$artifact"
      if [[ -e "$src" && ! -e "$dst" ]]; then
        ln -s "$src" "$dst" && log "Linked Vendor/$artifact"
      fi
    done
    # libsignal is a submodule; an empty checkout dir gets the primary's tree.
    if [[ -d "$cache_source/Vendor/libsignal" && -z "$(ls -A "$repo_root/Vendor/libsignal" 2>/dev/null)" ]]; then
      rmdir "$repo_root/Vendor/libsignal" 2>/dev/null \
        && ln -s "$cache_source/Vendor/libsignal" "$repo_root/Vendor/libsignal" \
        && log "Linked Vendor/libsignal"
    fi
  fi

  prepare_signal_ffi
  openburnbar_prepare_google_sign_in_macos_compat "$primary_cache"

  # Reuse the already-resolved cache and forbid a fresh resolve (the TCC hit).
  log "Building (reusing $primary_cache, resolution disabled)"
  xcodebuild build \
    "${xcodebuild_common_args[@]}" \
    -clonedSourcePackagesDirPath "$primary_cache"
else
  # --- IN-TREE (CI) mode --------------------------------------------------
  # A fresh CI runner is outside ~/Documents: a normal resolve + extract works.
  # Keep the cache in the workspace so actions/cache can persist it between runs.
  cache_dir="$repo_root/.spm-cache"
  mkdir -p "$cache_dir"

  prepare_signal_ffi

  log "Resolving packages in-tree (cache at $cache_dir)"
  xcodebuild -resolvePackageDependencies \
    -project "$project" \
    -scheme "$scheme" \
    -clonedSourcePackagesDirPath "$cache_dir" \
    -derivedDataPath "$derived_data"
  openburnbar_prepare_google_sign_in_macos_compat "$cache_dir"

  log "Building in-tree (locked package graph, cache at $cache_dir)"
  xcodebuild build \
    "${xcodebuild_common_args[@]}" \
    -clonedSourcePackagesDirPath "$cache_dir"
fi

log "BUILD SUCCEEDED — app binary at:"
log "  $derived_data/Build/Products/Debug/OpenBurnBar.app/Contents/MacOS/OpenBurnBar"
