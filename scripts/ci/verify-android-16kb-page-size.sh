#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
apk_path="${1:-android/app/build/outputs/apk/debug/app-debug.apk}"
if [[ "${apk_path}" != /* ]]; then
  apk_path="${repo_root}/${apk_path}"
fi

if [[ ! -f "${apk_path}" ]]; then
  echo "Android APK not found: ${apk_path}" >&2
  exit 1
fi

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
if [[ ! -d "${android_sdk}" && -d "${HOME}/Library/Android" ]]; then
  android_sdk="${HOME}/Library/Android"
fi

find_zipalign() {
  if [[ -n "${ZIPALIGN:-}" && -x "${ZIPALIGN}" ]]; then
    printf '%s\n' "${ZIPALIGN}"
    return
  fi
  if [[ -d "${android_sdk}/build-tools" ]]; then
    find "${android_sdk}/build-tools" -path "*/zipalign" -type f -perm -111 2>/dev/null | sort | tail -n 1
  fi
}

find_objdump() {
  if [[ -n "${LLVM_OBJDUMP:-}" && -x "${LLVM_OBJDUMP}" ]]; then
    printf '%s\n' "${LLVM_OBJDUMP}"
    return
  fi
  for ndk_root in \
    "${ANDROID_NDK_HOME:-}" \
    "${ANDROID_NDK_ROOT:-}" \
    "${android_sdk}/ndk"/*; do
    if [[ -d "${ndk_root}" ]]; then
      candidate="$(find "${ndk_root}/toolchains/llvm/prebuilt" -path "*/bin/llvm-objdump" -type f -perm -111 2>/dev/null | sort | tail -n 1 || true)"
      if [[ -n "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return
      fi
    fi
  done
  if command -v xcrun >/dev/null 2>&1; then
    xcrun -f llvm-objdump 2>/dev/null || true
  fi
}

zipalign_bin="$(find_zipalign)"
if [[ -z "${zipalign_bin}" || ! -x "${zipalign_bin}" ]]; then
  echo "zipalign not found. Set ANDROID_HOME/ANDROID_SDK_ROOT or ZIPALIGN." >&2
  exit 1
fi

objdump_bin="$(find_objdump)"
if [[ -z "${objdump_bin}" || ! -x "${objdump_bin}" ]]; then
  echo "llvm-objdump not found. Install Android NDK or set LLVM_OBJDUMP." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
zipalign_log="$(mktemp)"
trap 'rm -rf "${tmpdir}" "${zipalign_log}"' EXIT

if ! "${zipalign_bin}" -c -P 16 -v 4 "${apk_path}" >"${zipalign_log}" 2>&1; then
  cat "${zipalign_log}" >&2
  echo "APK ZIP entries are not 16 KB page-size aligned." >&2
  exit 1
fi
echo "zipalign: OK (${zipalign_bin})"

lib_list="${tmpdir}/native-libs.txt"
unzip -Z1 "${apk_path}" | grep -E '^lib/[^/]+/[^/]+\.so$' | sort >"${lib_list}" || true
if [[ ! -s "${lib_list}" ]]; then
  echo "No packaged native libraries found."
  exit 0
fi

extract_dir="${tmpdir}/apk"
mkdir -p "${extract_dir}"
failures=0

while IFS= read -r lib_entry; do
  unzip -qq "${apk_path}" "${lib_entry}" -d "${extract_dir}"
  so_path="${extract_dir}/${lib_entry}"
  load_alignments="$("${objdump_bin}" -p "${so_path}" | awk '/LOAD/ && /align/ { print $NF }')"
  if [[ -z "${load_alignments}" ]]; then
    echo "FAIL ${lib_entry}: no ELF LOAD segments found" >&2
    failures=$((failures + 1))
    continue
  fi

  while IFS= read -r alignment; do
    [[ -z "${alignment}" ]] && continue
    if [[ "${alignment}" =~ ^2\*\*([0-9]+)$ ]]; then
      exponent="${BASH_REMATCH[1]}"
      if (( exponent < 14 )); then
        echo "FAIL ${lib_entry}: LOAD segment alignment ${alignment} is below 2**14" >&2
        failures=$((failures + 1))
      fi
    elif [[ "${alignment}" =~ ^0x[0-9a-fA-F]+$ || "${alignment}" =~ ^[0-9]+$ ]]; then
      if (( alignment < 16384 )); then
        echo "FAIL ${lib_entry}: LOAD segment alignment ${alignment} is below 16384" >&2
        failures=$((failures + 1))
      fi
    else
      echo "FAIL ${lib_entry}: unrecognized LOAD segment alignment ${alignment}" >&2
      failures=$((failures + 1))
    fi
  done <<<"${load_alignments}"
done <"${lib_list}"

if (( failures > 0 )); then
  echo "Android 16 KB native page-size compatibility failed for ${failures} LOAD segment(s)." >&2
  exit 1
fi

echo "ELF LOAD alignment: OK ($(wc -l <"${lib_list}" | tr -d ' ') native libraries, ${objdump_bin})"
