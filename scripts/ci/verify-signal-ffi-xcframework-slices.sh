#!/usr/bin/env bash
# Assert an .xcframework really contains the slices we are about to publish to
# the shared cache.
#
# Why this is load-bearing: ci-cache-warm.yml writes the Signal FFI artifact to a
# cache entry on the DEFAULT branch, which every PR then restores. The signal-ffi
# cache key covers the vendored libsignal SHA and the build scripts but NOT
# SIGNAL_FFI_BUILD_TARGETS, so consumers wanting different slices share one entry.
# The warm job deliberately builds the five-target superset so any consumer is
# satisfied -- but "deliberately" is a comment, not a guarantee. If the build ever
# emitted a thinner artifact and still exited 0, we would publish a thin superset
# and break every macOS PR gate at once, which is strictly worse than the cold
# rebuild we are replacing.
#
# actions/cache declares `post-if: success()`, so failing here prevents the bad
# entry from ever being saved. That makes cache warming fail-closed.
#
# Usage:
#   verify-signal-ffi-xcframework-slices.sh <xcframework> <min-libraries> <arch>[,<arch>...]
#
# Example:
#   verify-signal-ffi-xcframework-slices.sh Vendor/OpenBurnBarSignalFfiMac.xcframework 1 arm64,x86_64
#
# Uses python3 + plistlib rather than plutil so the accompanying test runs on the
# Linux workflow-lint runner as well as on macOS.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <xcframework> <min-libraries> <comma-separated-archs>" >&2
  exit 2
fi

framework="$1"
min_libraries="$2"
required_archs="$3"

if [[ ! -d "$framework" ]]; then
  echo "::error::${framework} does not exist. It was neither restored from cache nor built, so consumers would still rebuild cold." >&2
  exit 1
fi

plist="${framework}/Info.plist"
if [[ ! -f "$plist" ]]; then
  echo "::error::${framework} has no Info.plist -- it is not a valid xcframework (a partial or interrupted build produces exactly this)." >&2
  exit 1
fi

python3 - "$plist" "$framework" "$min_libraries" "$required_archs" <<'PY'
import plistlib, sys

plist_path, framework, min_libraries, required = sys.argv[1:5]
min_libraries = int(min_libraries)
required_archs = {a.strip() for a in required.split(",") if a.strip()}

try:
    with open(plist_path, "rb") as fh:
        info = plistlib.load(fh)
except Exception as exc:  # malformed/truncated plist from an interrupted build
    print(f"::error::{plist_path} could not be parsed as a plist: {exc}", file=sys.stderr)
    sys.exit(1)

libraries = info.get("AvailableLibraries") or []
if not libraries:
    print(f"::error::{framework} declares no AvailableLibraries.", file=sys.stderr)
    sys.exit(1)

present = set()
rows = []
for lib in libraries:
    ident = lib.get("LibraryIdentifier", "<unknown>")
    archs = sorted(lib.get("SupportedArchitectures") or [])
    platform = lib.get("SupportedPlatform", "?")
    variant = lib.get("SupportedPlatformVariant")
    present.update(archs)
    rows.append((ident, platform, variant or "device", archs, lib.get("LibraryPath", "?")))

print(f"{framework}:")
for ident, platform, variant, archs, path in sorted(rows):
    print(f"    {ident:<34} {platform}/{variant:<10} archs={','.join(archs) or '-'}  {path}")

problems = []
if len(libraries) < min_libraries:
    problems.append(
        f"expected at least {min_libraries} library slice(s), found {len(libraries)}"
    )
missing = sorted(required_archs - present)
if missing:
    problems.append(
        f"missing required architecture(s): {', '.join(missing)} (present: {', '.join(sorted(present)) or 'none'})"
    )

if problems:
    for p in problems:
        print(f"::error::{framework} {p}", file=sys.stderr)
    print(
        "::error::Refusing to publish this artifact to the shared default-branch cache; "
        "every pull request would restore it.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"    OK: {len(libraries)} slice(s), architectures {', '.join(sorted(present))} "
    f"cover the required {', '.join(sorted(required_archs))}."
)
PY
