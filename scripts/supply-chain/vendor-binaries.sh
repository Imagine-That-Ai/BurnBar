#!/usr/bin/env bash
# Shared enumeration of the Vendor binaries that must carry a checksum entry.
# Sourced by refresh-vendor-checksums.sh and verify-vendor-checksums.sh so the
# two can never disagree about coverage.

# Print every binary artifact under the given Vendor directory, one relative
# path per line, sorted. Extend the extension list when a new binary kind is
# vendored; the checksum manifest must then gain an entry for it.
list_vendor_binaries() {
  local base_dir="$1"
  (
    cd "${base_dir}" &&
      find . -type f \( -name '*.aar' -o -name '*.jar' -o -name '*.a' -o -name '*.so' -o -name '*.dylib' -o -name '*.xcframework.zip' \) \
        -not -path '*/.*' -print
  ) | sed 's#^\./##' | LC_ALL=C sort
}
