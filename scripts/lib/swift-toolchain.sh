#!/usr/bin/env bash
# Deterministic `swift` resolution for repo scripts.
#
# WHY THIS EXISTS
# ---------------
# Bare `swift` from PATH is not a stable toolchain reference. On a developer
# machine with swiftly installed, PATH resolves to ~/.swiftly/bin/swift, whose
# SwiftPM driver compiles package manifests against
# /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk instead of the SDK that
# belongs to the active Xcode. When those two disagree, EVERY `swift package`
# call dies with "this SDK is not supported by the compiler" — and a script that
# captured the output with `2>/dev/null` reports a bare non-zero exit with no
# explanation. That is exactly how
# scripts/debt/check-engine-closure-ui-purity.sh sat red on main for days while
# the invariant it guards was actually intact.
#
# RESOLUTION ORDER (first hit wins)
#   1. $OPENBURNBAR_SWIFT       explicit override / escape hatch
#   2. $DEVELOPER_DIR toolchain the Xcode selected for this shell
#   3. `xcrun --find swift`     the machine's active Xcode (CI runners)
#   4. `swift` on PATH          Linux hosts and toolchain-only images
#
# No Xcode path is hardcoded. On CI, DEVELOPER_DIR is unset and rule 3 resolves
# whichever Xcode the runner image ships, which is exactly the float that ADR
# docs/architecture/011-toolchain-pins.md requires (the .xcode-version file is a
# drift tripwire on the major version, not a path pin).
#
# CONTRACT
#   obb_swift_init  sets $OBB_SWIFT (absolute path) and $OBB_SWIFT_SOURCE (the
#                   rule that matched), prints a toolchain banner to stderr, and
#                   returns non-zero with an actionable message if nothing
#                   resolves. The banner is stderr-only so callers can keep
#                   using `out="$("${OBB_SWIFT}" ...)"`.
#
#   $OBB_SWIFT may contain spaces (the repo and Xcode both live under such a
#   path on the maintainer's machine) — always quote it.
#
# USAGE
#   source "${repo_root}/scripts/lib/swift-toolchain.sh"
#   obb_swift_init || exit 1
#   "${OBB_SWIFT}" package dump-package
#
# Deliberately free of external commands (no head/sed/grep) so it also works
# under a scrubbed PATH.

obb_swift_resolve() {
  local candidate

  if [[ -n "${OPENBURNBAR_SWIFT:-}" ]]; then
    if [[ ! -x "${OPENBURNBAR_SWIFT}" ]]; then
      echo "ERROR: OPENBURNBAR_SWIFT is set to '${OPENBURNBAR_SWIFT}', which is not an executable file." >&2
      echo "       Point it at an absolute path to a swift binary, or unset it to auto-detect." >&2
      return 1
    fi
    OBB_SWIFT="${OPENBURNBAR_SWIFT}"
    OBB_SWIFT_SOURCE="OPENBURNBAR_SWIFT"
    return 0
  fi

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    candidate="${DEVELOPER_DIR%/}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    if [[ -x "${candidate}" ]]; then
      OBB_SWIFT="${candidate}"
      OBB_SWIFT_SOURCE="DEVELOPER_DIR"
      return 0
    fi
  fi

  if command -v xcrun >/dev/null 2>&1; then
    candidate="$(xcrun --find swift 2>/dev/null)" || candidate=""
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
      OBB_SWIFT="${candidate}"
      OBB_SWIFT_SOURCE="xcrun --find swift"
      return 0
    fi
  fi

  candidate="$(command -v swift 2>/dev/null)" || candidate=""
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    OBB_SWIFT="${candidate}"
    OBB_SWIFT_SOURCE="PATH"
    return 0
  fi

  echo "ERROR: no swift toolchain found." >&2
  echo "       Tried, in order: \$OPENBURNBAR_SWIFT, \$DEVELOPER_DIR toolchain," >&2
  echo "       'xcrun --find swift', and 'swift' on PATH." >&2
  echo "       Install Xcode (macOS) or a Swift toolchain (Linux), or set" >&2
  echo "       OPENBURNBAR_SWIFT to an absolute path to a swift binary." >&2
  return 1
}

obb_swift_init() {
  OBB_SWIFT=""
  OBB_SWIFT_SOURCE=""
  obb_swift_resolve || return 1

  # Report the version even when the toolchain is broken: for the SDK/compiler
  # mismatch this helper exists to prevent, the version line IS the diagnosis.
  local version=""
  version="$("${OBB_SWIFT}" --version 2>&1)" || true
  version="${version%%$'\n'*}"
  if [[ -z "${version}" ]]; then
    version="(no output from '${OBB_SWIFT} --version')"
  fi

  echo "==> swift toolchain: ${OBB_SWIFT}" >&2
  echo "    resolved via: ${OBB_SWIFT_SOURCE}" >&2
  echo "    version: ${version}" >&2
  return 0
}
