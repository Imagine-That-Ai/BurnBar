#!/usr/bin/env bash
# Shared enumeration of the Vendor binaries that must carry a checksum entry.
# Sourced by refresh-vendor-checksums.sh and verify-vendor-checksums.sh so the
# two can never disagree about coverage.

# Print every binary artifact under the given Vendor directory, one relative
# path per line, sorted. Extend the extension list when a new binary kind is
# vendored; the checksum manifest must then gain an entry for it.
#
# Inside a git work tree the enumeration is TRACKED files only: local build
# outputs (gitignored xcframework slices) and submodule-internal jars vary
# per machine, and the manifest must verify identically on a fresh CI
# checkout and a dev tree that has extra artifacts on disk. Outside a work
# tree (fixture directories under /tmp), fall back to a disk scan so the
# negative-control tests can exercise the tooling in isolation.
list_vendor_binaries() {
  local base_dir="$1"
  if git -C "${base_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${base_dir}" ls-files -- '*.aar' '*.jar' '*.a' '*.so' '*.dylib' '*.xcframework.zip' |
      LC_ALL=C sort
  else
    (
      cd "${base_dir}" &&
        find . -type f \( -name '*.aar' -o -name '*.jar' -o -name '*.a' -o -name '*.so' -o -name '*.dylib' -o -name '*.xcframework.zip' \) \
          -not -path '*/.*' -print
    ) | sed 's#^\./##' | LC_ALL=C sort
  fi
}
