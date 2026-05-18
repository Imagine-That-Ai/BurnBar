#!/usr/bin/env bash
# Build Vendor/opus-android.aar from libopus 1.5 for 4 ABIs.
#
# Usage:
#   ./scripts/build_opus_android.sh                # release, all ABIs
#   OPUS_ABIS="arm64-v8a x86_64" ./scripts/build_opus_android.sh
#   ./scripts/build_opus_android.sh --dry-run
#
# Requires:
#   * Android NDK (auto-installs via sdkmanager if ANDROID_HOME is set)
#   * autoconf, automake, libtool, make (Ubuntu / macOS)
#
# Output:
#   Vendor/opus-android.aar  (multi-ABI libopus.so + headers)
#   android/openburnbar-iroh-relay/src/main/cpp/opus/include/opus.h (re-exposed)
#
# Bumped libopus version → bump OPUS_VERSION below. CI will rebuild the AAR.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor"
AAR_PATH="${VENDOR_DIR}/opus-android.aar"
BUILD_DIR="${ROOT_DIR}/build/opus-android"
SRC_DIR="${BUILD_DIR}/opus-src"
STAGING="${BUILD_DIR}/aar-staging"

OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUS_TARBALL_SHA256="${OPUS_TARBALL_SHA256:-65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1}"

DEFAULT_ABIS=(arm64-v8a x86_64 armeabi-v7a x86)
if [[ -n "${OPUS_ABIS:-}" ]]; then
  # shellcheck disable=SC2206
  ABIS=(${OPUS_ABIS})
else
  ABIS=("${DEFAULT_ABIS[@]}")
fi

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 64 ;;
  esac
done

log() { printf '[opus-aar] %s\n' "$*"; }
abort() { echo "[opus-aar] FATAL: $*" >&2; exit 1; }

ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android}}"
[[ -d "${ANDROID_SDK}" ]] || abort "Android SDK not found at ${ANDROID_SDK}"

ensure_ndk() {
  local v="${OPUS_NDK_VERSION:-26.3.11579264}"
  local ndk="${ANDROID_SDK}/ndk/${v}"
  if [[ -d "${ndk}" ]]; then
    echo "${ndk}"; return
  fi
  local sdkmanager_bin=""
  for c in \
    "${ANDROID_SDK}/cmdline-tools/latest/bin/sdkmanager" \
    "${ANDROID_SDK}/cmdline-tools/bin/sdkmanager"; do
    [[ -x "${c}" ]] && { sdkmanager_bin="${c}"; break; }
  done
  [[ -n "${sdkmanager_bin}" ]] || abort "NDK missing and sdkmanager unavailable"
  yes | "${sdkmanager_bin}" --licenses >/dev/null 2>&1 || true
  "${sdkmanager_bin}" "ndk;${v}"
  echo "${ndk}"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "dry run: ANDROID_SDK=${ANDROID_SDK} ABIs=${ABIS[*]} version=${OPUS_VERSION}"
  log "dry run: would write ${AAR_PATH}"
  exit 0
fi

NDK_HOME="$(ensure_ndk)"
HOST_TAG="darwin-x86_64"
[[ "$(uname)" == "Linux" ]] && HOST_TAG="linux-x86_64"
TOOLCHAIN="${NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}"
[[ -d "${TOOLCHAIN}" ]] || abort "NDK toolchain not at ${TOOLCHAIN}"

mkdir -p "${BUILD_DIR}" "${VENDOR_DIR}" "${STAGING}/jni"

if [[ ! -d "${SRC_DIR}" ]]; then
  log "fetching libopus ${OPUS_VERSION}"
  curl -fsSL "${OPUS_URL}" -o "${BUILD_DIR}/opus.tar.gz"
  if command -v sha256sum >/dev/null; then
    echo "${OPUS_TARBALL_SHA256}  ${BUILD_DIR}/opus.tar.gz" | sha256sum -c -
  else
    echo "${OPUS_TARBALL_SHA256}  ${BUILD_DIR}/opus.tar.gz" | shasum -a 256 -c -
  fi
  mkdir -p "${SRC_DIR}"
  tar -xzf "${BUILD_DIR}/opus.tar.gz" -C "${SRC_DIR}" --strip-components=1
fi

api_min() { echo "26"; }

abi_target() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "armv7a-linux-androideabi" ;;
    x86) echo "i686-linux-android" ;;
    x86_64) echo "x86_64-linux-android" ;;
    *) abort "unknown abi: $1" ;;
  esac
}

build_one_abi() {
  local abi="$1"
  local target
  target="$(abi_target "${abi}")"
  local api
  api="$(api_min)"
  local out_dir="${BUILD_DIR}/${abi}"
  rm -rf "${out_dir}"; mkdir -p "${out_dir}"
  local sysroot="${TOOLCHAIN}/sysroot"
  local cc="${TOOLCHAIN}/bin/${target}${api}-clang"
  local ar="${TOOLCHAIN}/bin/llvm-ar"
  local ranlib="${TOOLCHAIN}/bin/llvm-ranlib"
  log "configure libopus for ${abi}"
  (
    cd "${SRC_DIR}"
    make distclean >/dev/null 2>&1 || true
    CC="${cc}" AR="${ar}" RANLIB="${ranlib}" \
    CFLAGS="-O3 -fPIC --sysroot=${sysroot} -DANDROID" \
      ./configure \
        --host="${target}" \
        --prefix="${out_dir}" \
        --disable-static \
        --enable-shared \
        --disable-doc \
        --disable-extra-programs >/dev/null
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)" >/dev/null
    make install >/dev/null
  )
  mkdir -p "${STAGING}/jni/${abi}"
  cp "${out_dir}/lib/libopus.so" "${STAGING}/jni/${abi}/libopus.so"
}

for abi in "${ABIS[@]}"; do
  build_one_abi "${abi}"
done

# Ship a copy of opus.h next to the JNI module for the Android Studio build to
# find #include "opus.h" without bridging headers.
INCLUDE_DST="${ROOT_DIR}/android/openburnbar-iroh-relay/src/main/cpp/opus/include"
mkdir -p "${INCLUDE_DST}"
cp -R "${BUILD_DIR}/${ABIS[0]}/include/opus/." "${INCLUDE_DST}/"

cat > "${STAGING}/AndroidManifest.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="com.openburnbar.opus.native_">
  <uses-sdk android:minSdkVersion="26" />
</manifest>
EOF

EMPTY_JAR_DIR="${BUILD_DIR}/empty-classes"
rm -rf "${EMPTY_JAR_DIR}"; mkdir -p "${EMPTY_JAR_DIR}"
(cd "${EMPTY_JAR_DIR}" && jar cf "${STAGING}/classes.jar" -C "${EMPTY_JAR_DIR}" .)
: > "${STAGING}/proguard.txt"
: > "${STAGING}/R.txt"

rm -f "${AAR_PATH}"
(cd "${STAGING}" && zip -rq "${AAR_PATH}" .)

log "DONE: ${AAR_PATH}"
log "headers staged: ${INCLUDE_DST}"
