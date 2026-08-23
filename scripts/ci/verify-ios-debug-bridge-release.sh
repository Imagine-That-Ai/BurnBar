#!/bin/bash
#
# Fail closed when an OpenBurnBar iOS Release product contains the physical-
# device QA bridge. Source guards are necessary but insufficient: this scans
# the assembled .app and its Mach-O executable so the App Store artifact is
# the authority.

set -euo pipefail

app_path="${1:-${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-}}"
configuration="${CONFIGURATION:-Release}"
swift_conditions="${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-}"

if [[ "${configuration}" != "Release" && "${OPENBURNBAR_VERIFY_RELEASE_BINARY:-0}" != "1" ]]; then
  echo "iOS QA release guard: skipped for ${configuration}"
  exit 0
fi

fail() {
  echo "error: iOS QA release guard: $*" >&2
  exit 1
}

[[ -d "${app_path}" ]] || fail "app bundle not found at ${app_path}"

case " ${swift_conditions} " in
  *" DEBUG "*)
    fail "Release SWIFT_ACTIVE_COMPILATION_CONDITIONS contains DEBUG"
    ;;
esac

case " ${swift_conditions} " in
  *" GSTACK_IOS_QA "*)
    fail "Release SWIFT_ACTIVE_COMPILATION_CONDITIONS contains GSTACK_IOS_QA"
    ;;
esac

forbidden_artifact="$(
  find "${app_path}" \
    \( -iname '*DebugBridge*' -o -iname '*gstack*ios*qa*' \) \
    -print -quit
)"
[[ -z "${forbidden_artifact}" ]] || fail "forbidden QA artifact is bundled: ${forbidden_artifact}"

plist_path="${app_path}/Info.plist"
[[ -f "${plist_path}" ]] || fail "Info.plist not found in ${app_path}"

executable_name="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${plist_path}" 2>/dev/null || true
)"
[[ -n "${executable_name}" ]] || fail "CFBundleExecutable is missing"

executable_path="${app_path}/${executable_name}"
[[ -f "${executable_path}" ]] || fail "app executable not found at ${executable_path}"

forbidden_pattern='DebugBridge(Core|UI|Touch)?|gstack[.-]ios[.-]qa|StateServer|DebugOverlayWindow|ScreenshotBridge|ElementsBridge|MutationBridge|session/acquire|auth/rotate|Driven by Claude Code|AGENT DEMO|_UIHitTestContext|IOHIDEvent'

# Swift emits a `__swift_FORCE_LOAD_$_<shim>_$_<library>` marker symbol for
# every linked library that pulls in a back-deployment shim. The marker carries
# no code — its NAME merely encodes the library name — so an otherwise-empty
# Release build of a DebugBridge* module still produces one. Exempt ONLY a
# complete marker: anchored, shim segment must start with "swift", nothing
# after the library name. A QA symbol that merely embeds the marker text
# (e.g. swift_FORCE_LOAD_StateServer) stays banned.
force_load_marker='^_{1,2}swift_FORCE_LOAD_\$_swift[A-Za-z0-9_]*_\$_[A-Za-z0-9_]+$'

symbol_hits="$(
  nm -j "${executable_path}" 2>/dev/null \
    | LC_ALL=C grep -E -i "${forbidden_pattern}" \
    | LC_ALL=C grep -E -v "${force_load_marker}" \
    | head -n 20 \
    || true
)"
[[ -z "${symbol_hits}" ]] || fail "forbidden QA symbols found in Release executable: ${symbol_hits}"

string_hits="$(
  strings -a "${executable_path}" \
    | LC_ALL=C grep -E -i "${forbidden_pattern}" \
    | LC_ALL=C grep -E -v "${force_load_marker}" \
    | head -n 20 \
    || true
)"
[[ -z "${string_hits}" ]] || fail "forbidden QA strings found in Release executable: ${string_hits}"

echo "iOS QA release guard: PASS (${executable_path})"
