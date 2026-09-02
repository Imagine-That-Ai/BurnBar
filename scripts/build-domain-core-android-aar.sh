#!/usr/bin/env bash
# Build the shared domain-core UniFFI Android artifact.
#
# Outputs:
#   Vendor/openburnbar-domain-core.aar
#   android/openburnbar-domain-core/src/main/java/uniffi/openburnbar_domain_ffi/openburnbar_domain_ffi.kt
#
# Environment:
#   DOMAIN_CORE_BUILD_PROFILE=debug|release (default release)
#   DOMAIN_CORE_ANDROID_ABIS="arm64-v8a x86_64 ..." (default all Play ABIs)
#   DOMAIN_CORE_ANDROID_NDK_VERSION=<sdk NDK version>

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/crates/openburnbar-domain-core"
TARGET_DIR="${CARGO_TARGET_DIR:-${CRATE_DIR}/target}"
VENDOR_DIR="${ROOT_DIR}/Vendor"
AAR_PATH="${VENDOR_DIR}/openburnbar-domain-core.aar"
GENERATED_DIR="${ROOT_DIR}/android/openburnbar-domain-core/src/main/java/uniffi/openburnbar_domain_ffi"
PROVENANCE_DIR="${CRATE_DIR}/artifact-provenance"
BUILD_DIR="${ROOT_DIR}/build/domain-core-aar"
JNI_DIR="${BUILD_DIR}/jni"
HELPER_DIR="${ROOT_DIR}/build/uniffi-bindgen-domain-core-kotlin-helper"
ANDROID_TOOLCHAIN_CONFIG="${ROOT_DIR}/config/domain-core-android-ndk-version.txt"
RUST_TOOLCHAIN_CONFIG="${CRATE_DIR}/rust-toolchain.toml"
ZIP_TIME="${DOMAIN_CORE_AAR_ZIP_TIME:-202401010000.00}"
ARTIFACT_EXPORT_DIR="${DOMAIN_CORE_ARTIFACT_EXPORT_DIR:-}"

[[ -f "${ANDROID_TOOLCHAIN_CONFIG}" ]] || {
  echo "missing Android toolchain config: ${ANDROID_TOOLCHAIN_CONFIG}" >&2
  exit 1
}
CANONICAL_NDK_VERSION="$(sed -nE \
  's/^([0-9]+(\.[0-9]+)+)$/\1/p' \
  "${ANDROID_TOOLCHAIN_CONFIG}")"
[[ "${CANONICAL_NDK_VERSION}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || {
  echo "invalid canonical Android NDK version in ${ANDROID_TOOLCHAIN_CONFIG}" >&2
  exit 1
}
RUST_TOOLCHAIN="$(sed -nE \
  's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' \
  "${RUST_TOOLCHAIN_CONFIG}")"
[[ "${RUST_TOOLCHAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "invalid pinned Rust channel in ${RUST_TOOLCHAIN_CONFIG}" >&2
  exit 1
}
NDK_VERSION="${DOMAIN_CORE_ANDROID_NDK_VERSION:-${ANDROID_NDK_VERSION:-${CANONICAL_NDK_VERSION}}}"
[[ "${NDK_VERSION}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || {
  echo "invalid Android NDK version: ${NDK_VERSION}" >&2
  exit 1
}

PROFILE="${DOMAIN_CORE_BUILD_PROFILE:-release}"
case "${PROFILE}" in
  debug) PROFILE_FLAG=(); PROFILE_DIR=debug ;;
  release) PROFILE_FLAG=(--release); PROFILE_DIR=release ;;
  *) echo "[domain-core-aar] FATAL: unsupported profile: ${PROFILE}" >&2; exit 64 ;;
esac

DEFAULT_ABIS=(arm64-v8a x86_64 armeabi-v7a x86)
if [[ -n "${DOMAIN_CORE_ANDROID_ABIS:-}" ]]; then
  read -r -a ABIS <<< "${DOMAIN_CORE_ANDROID_ABIS}"
else
  ABIS=("${DEFAULT_ABIS[@]}")
fi

DRY_RUN=0
CHECK_SOURCE=0
CHECK_ARTIFACT=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --check-source) CHECK_SOURCE=1 ;;
    --check-artifact) CHECK_ARTIFACT=1 ;;
    *) echo "unknown arg: ${arg}" >&2; exit 64 ;;
  esac
done
if (( CHECK_SOURCE + CHECK_ARTIFACT + DRY_RUN > 1 )); then
  echo "--dry-run, --check-source, and --check-artifact are mutually exclusive" >&2
  exit 64
fi

log() { printf '[domain-core-aar] %s\n' "$*" >&2; }
abort() { log "FATAL: $*"; exit 1; }

source_fingerprint() {
  python3 "${ROOT_DIR}/scripts/ci/domain-core-union-gate.py" --source-fingerprint
}

abi_to_target() {
  case "$1" in
    arm64-v8a) echo aarch64-linux-android ;;
    x86_64) echo x86_64-linux-android ;;
    armeabi-v7a) echo armv7-linux-androideabi ;;
    x86) echo i686-linux-android ;;
    *) abort "unknown Android ABI: $1" ;;
  esac
}

write_stored_zip() {
  local output="$1" base="$2"
  shift 2
  python3 - "${output}" "${base}" "$@" <<'PY'
import pathlib
import stat
import sys
import zipfile

output = pathlib.Path(sys.argv[1])
base = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(output, "w") as archive:
    for name in sys.argv[3:]:
        path = base / name
        info = zipfile.ZipInfo(name, date_time=(2024, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED
        info.external_attr = (stat.S_IMODE(path.stat().st_mode) or 0o644) << 16
        info.create_system = 3
        archive.writestr(info, path.read_bytes())
PY
}

compare_aar_entries() {
  local committed="$1" rebuilt="$2"
  python3 - "${committed}" "${rebuilt}" <<'PY'
import hashlib
import sys
import zipfile

def inventory(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise SystemExit(f"duplicate ZIP entry in {path}")
        return {
            name: hashlib.sha256(archive.read(name)).hexdigest()
            for name in sorted(names)
            if not name.endswith("/")
        }

committed = inventory(sys.argv[1])
rebuilt = inventory(sys.argv[2])
if committed != rebuilt:
    for name in sorted(set(committed) | set(rebuilt)):
        if committed.get(name) != rebuilt.get(name):
            print(
                f"AAR entry {name}: committed={committed.get(name, 'missing')} "
                f"rebuilt={rebuilt.get(name, 'missing')}",
                file=sys.stderr,
            )
    raise SystemExit("rebuilt AAR normalized entry tree differs")
PY
}

RUSTUP_BIN="${HOME}/.cargo/bin/rustup"
[[ -x "${RUSTUP_BIN}" ]] || RUSTUP_BIN="$(command -v rustup || true)"
[[ -x "${RUSTUP_BIN}" ]] || abort "rustup not found"
CARGO_BIN="${HOME}/.cargo/bin/cargo"
[[ -x "${CARGO_BIN}" ]] || CARGO_BIN="$(command -v cargo || true)"
[[ -x "${CARGO_BIN}" ]] || abort "cargo not found"
RUSTC_BIN="${HOME}/.cargo/bin/rustc"
[[ -x "${RUSTC_BIN}" ]] || RUSTC_BIN="$(command -v rustc || true)"
[[ -x "${RUSTC_BIN}" ]] || abort "rustc not found"
ACTUAL_RUST_TOOLCHAIN="$(
  cd "${CRATE_DIR}"
  "${RUSTC_BIN}" --version | awk 'NR == 1 { print $2 }'
)"
[[ "${ACTUAL_RUST_TOOLCHAIN}" == "${RUST_TOOLCHAIN}" ]] || \
  abort "selected Rust ${ACTUAL_RUST_TOOLCHAIN:-unknown} does not match pinned ${RUST_TOOLCHAIN}"

SOURCE_FINGERPRINT="$(source_fingerprint)"
if [[ "${CHECK_SOURCE}" -eq 1 ]]; then
  [[ -f "${AAR_PATH}" ]] || abort "missing committed AAR: ${AAR_PATH}"
  COMMITTED_FINGERPRINT="$(python3 - "${AAR_PATH}" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    try:
        print(archive.read("META-INF/openburnbar-domain-core-source.sha256").decode().strip())
    except KeyError:
        raise SystemExit("committed AAR has no source fingerprint")
PY
)"
  [[ "${COMMITTED_FINGERPRINT}" == "${SOURCE_FINGERPRINT}" ]] || \
    abort "committed AAR source fingerprint is stale"
  COMMITTED_TOOLCHAIN="$(python3 - "${AAR_PATH}" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    try:
        print(
            archive.read("META-INF/openburnbar-domain-core-android-toolchain.env")
            .decode("ascii"),
            end="",
        )
    except KeyError:
        raise SystemExit("committed AAR has no Android toolchain provenance")
PY
)"
  EXPECTED_TOOLCHAIN="$(printf 'rust=%s\nndk=%s' "${ACTUAL_RUST_TOOLCHAIN}" "${NDK_VERSION}")"
  [[ "${COMMITTED_TOOLCHAIN}" == "${EXPECTED_TOOLCHAIN}" ]] || \
    abort "committed AAR Android toolchain provenance is stale"
  log "committed AAR matches domain-core source ${SOURCE_FINGERPRINT} and Rust ${ACTUAL_RUST_TOOLCHAIN}/NDK ${NDK_VERSION}"
  exit 0
fi

EXPECTED_AAR=""
restore_committed_aar() {
  if [[ -n "${EXPECTED_AAR}" && -f "${EXPECTED_AAR}" ]]; then
    cp "${EXPECTED_AAR}" "${AAR_PATH}"
    rm -f "${EXPECTED_AAR}"
  fi
}
if [[ "${CHECK_ARTIFACT}" -eq 1 ]]; then
  [[ -f "${AAR_PATH}" ]] || abort "missing committed AAR: ${AAR_PATH}"
  EXPECTED_AAR="$(mktemp "${TMPDIR:-/tmp}/openburnbar-domain-core.aar.XXXXXX")"
  cp "${AAR_PATH}" "${EXPECTED_AAR}"
  trap restore_committed_aar EXIT
fi

ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[[ -d "${ANDROID_SDK}" ]] || abort "Android SDK not found at ${ANDROID_SDK}; export ANDROID_HOME"
NDK_HOME="${ANDROID_SDK}/ndk/${NDK_VERSION}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "dry run: SDK=${ANDROID_SDK} NDK=${NDK_VERSION} ABIs=${ABIS[*]} profile=${PROFILE}"
  log "dry run: would write ${AAR_PATH} and ${GENERATED_DIR}"
  exit 0
fi

if [[ ! -d "${NDK_HOME}" ]]; then
  SDKMANAGER=""
  for candidate in \
    "${ANDROID_SDK}/cmdline-tools/latest/bin/sdkmanager" \
    "${ANDROID_SDK}/cmdline-tools/bin/sdkmanager" \
    "${ANDROID_SDK}/tools/bin/sdkmanager"; do
    if [[ -x "${candidate}" ]]; then SDKMANAGER="${candidate}"; break; fi
  done
  [[ -n "${SDKMANAGER}" ]] || abort "NDK ${NDK_VERSION} missing and sdkmanager unavailable"
  log "installing NDK ${NDK_VERSION}"
  yes | "${SDKMANAGER}" --licenses >/dev/null 2>&1 || true
  "${SDKMANAGER}" "ndk;${NDK_VERSION}" >&2
fi
[[ -d "${NDK_HOME}" ]] || abort "NDK install failed: ${NDK_HOME}"
export ANDROID_NDK_HOME="${NDK_HOME}" ANDROID_NDK_ROOT="${NDK_HOME}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"
export TZ=UTC

if ! command -v cargo-ndk >/dev/null 2>&1; then
  log "installing cargo-ndk"
  "${CARGO_BIN}" install cargo-ndk --locked --version '^3.5'
fi

RUSTFLAGS_16KB="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
REMAP_FLAGS="--remap-path-prefix=${ROOT_DIR}=. --remap-path-prefix=${HOME}=~"
BUILD_RUSTFLAGS="${RUSTFLAGS:-} ${REMAP_FLAGS} ${RUSTFLAGS_16KB}"

CARGO_NDK_ARGS=()
for abi in "${ABIS[@]}"; do
  target="$(abi_to_target "${abi}")"
  # Scope target queries/installs to the PINNED toolchain. The unscoped form
  # acts on rustup's default toolchain, while cargo resolves the crate's
  # rust-toolchain.toml pin — on a host whose default differs, the std for
  # these targets lands in the wrong toolchain and the build dies with E0463.
  if ! "${RUSTUP_BIN}" target list --installed --toolchain "${RUST_TOOLCHAIN}" | grep -qx "${target}"; then
    "${RUSTUP_BIN}" target add --toolchain "${RUST_TOOLCHAIN}" "${target}"
  fi
  CARGO_NDK_ARGS+=(-t "${abi}")
done

rm -rf "${BUILD_DIR}"
mkdir -p "${JNI_DIR}" "${VENDOR_DIR}"
log "building domain FFI for ${ABIS[*]} (${PROFILE})"
(
  cd "${CRATE_DIR}"
  RUSTFLAGS="${BUILD_RUSTFLAGS}" PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" ndk "${CARGO_NDK_ARGS[@]}" -o "${JNI_DIR}" \
      build -p openburnbar-domain-ffi "${PROFILE_FLAG[@]}" --lib
)

for abi in "${ABIS[@]}"; do
  [[ -f "${JNI_DIR}/${abi}/libopenburnbar_domain_ffi.so" ]] || \
    abort "missing ${abi} native library"
done

EXPECTED_CANDIDATE_COMMIT="${OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT:-0000000000000000000000000000000000000000}"
python3 - \
  "${EXPECTED_CANDIDATE_COMMIT}" \
  "${SOURCE_FINGERPRINT}" \
  "${CRATE_DIR}/union-abi-manifest.json" \
  "${CRATE_DIR}/Cargo.toml" \
  "${JNI_DIR}" \
  "${ABIS[@]}" <<'PY'
import json
import pathlib
import sys
import tomllib

candidate_commit, source_sha256, manifest_path, cargo_path, jni_dir, *abis = sys.argv[1:]
manifest = json.loads(pathlib.Path(manifest_path).read_text())
with pathlib.Path(cargo_path).open("rb") as handle:
    core_version = tomllib.load(handle)["workspace"]["package"]["version"]
marker = (
    "openburnbar-domain-core-identity-v1"
    f"|candidateCommit={candidate_commit.lower()}"
    f"|coreVersion={core_version}"
    f"|abiVersion={manifest['abiVersion']}"
    f"|sourceSha256={source_sha256}"
).encode("ascii")
for abi in abis:
    library = pathlib.Path(jni_dir, abi, "libopenburnbar_domain_ffi.so")
    count = library.read_bytes().count(marker)
    if count != 1:
        raise SystemExit(
            f"{abi}: native library must contain exactly one canonical embedded identity; found {count}"
        )
PY
log "verified one canonical embedded identity in every Android ABI"

mkdir -p "${HELPER_DIR}/src"
cat > "${HELPER_DIR}/Cargo.toml" <<'EOF'
[package]
name = "openburnbar-domain-core-bindgen-kotlin-helper"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
anyhow = "1"
camino = "1"
cargo_metadata = "0.15"
uniffi_bindgen = "=0.28.3"
EOF
cat > "${HELPER_DIR}/src/main.rs" <<'EOF'
use anyhow::Context;
use camino::Utf8PathBuf;
use cargo_metadata::MetadataCommand;
use uniffi_bindgen::{
    bindings::KotlinBindingGenerator,
    cargo_metadata::CrateConfigSupplier,
    library_mode::generate_bindings,
};

fn main() -> anyhow::Result<()> {
    let library = Utf8PathBuf::from(std::env::var("UNIFFI_LIBRARY_PATH")?);
    let output = Utf8PathBuf::from(std::env::var("UNIFFI_OUT_DIR")?);
    let metadata = MetadataCommand::new().exec().context("cargo metadata failed")?;
    let supplier = CrateConfigSupplier::from(metadata);
    generate_bindings(
        &library,
        None,
        &KotlinBindingGenerator,
        &supplier,
        None,
        &output,
        false,
    )?;
    Ok(())
}
EOF

BINDGEN_ABI="${ABIS[0]}"
BINDGEN_TARGET="$(abi_to_target "${BINDGEN_ABI}")"
BINDGEN_LIBRARY="${TARGET_DIR}/${BINDGEN_TARGET}/${PROFILE_DIR}/libopenburnbar_domain_ffi.so"
[[ -f "${BINDGEN_LIBRARY}" ]] || BINDGEN_LIBRARY="${JNI_DIR}/${BINDGEN_ABI}/libopenburnbar_domain_ffi.so"
if [[ "${PROFILE}" != "debug" ]]; then
  # UniFFI metadata is reliably present in the debug cdylib even when release
  # profile settings evolve to strip symbols. The generated API is identical.
  log "building debug metadata library for Kotlin bindgen (${BINDGEN_ABI})"
  (
    cd "${CRATE_DIR}"
    RUSTFLAGS="${BUILD_RUSTFLAGS}" PATH="${HOME}/.cargo/bin:${PATH}" \
      "${CARGO_BIN}" ndk -t "${BINDGEN_ABI}" -o "${BUILD_DIR}/bindgen-jni" \
        build -p openburnbar-domain-ffi --lib
  )
  BINDGEN_LIBRARY="${TARGET_DIR}/${BINDGEN_TARGET}/debug/libopenburnbar_domain_ffi.so"
fi
[[ -f "${BINDGEN_LIBRARY}" ]] || abort "missing bindgen metadata library: ${BINDGEN_LIBRARY}"
rm -rf "${BUILD_DIR}/kotlin-out" "${GENERATED_DIR}"
mkdir -p "${GENERATED_DIR}"
(
  cd "${CRATE_DIR}"
  UNIFFI_LIBRARY_PATH="${BINDGEN_LIBRARY}" UNIFFI_OUT_DIR="${BUILD_DIR}/kotlin-out" \
    PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" run --manifest-path "${HELPER_DIR}/Cargo.toml" --release --quiet
)
SOURCE_BINDINGS="${BUILD_DIR}/kotlin-out/uniffi/openburnbar_domain_ffi"
[[ -d "${SOURCE_BINDINGS}" ]] || abort "UniFFI Kotlin bindings were not generated"
cp -R "${SOURCE_BINDINGS}/." "${GENERATED_DIR}/"

# Generated suppressions are neither reviewed nor accepted by the repository's
# no-new-suppressions gate. Normalize trailing whitespace while removing them.
find "${GENERATED_DIR}" -name '*.kt' -type f | while IFS= read -r file; do
  awk '
    /^@file:Suppress\(/ { next }
    /^[[:space:]]*@Suppress\(/ { next }
    { sub(/[[:space:]]+$/, ""); lines[++count] = $0 }
    END {
      while (count > 0 && lines[count] == "") count--
      for (line = 1; line <= count; line++) print lines[line]
    }
  ' "${file}" > "${file}.normalized"
  mv "${file}.normalized" "${file}"
done
mkdir -p "${PROVENANCE_DIR}"
printf '%s\n' "${SOURCE_FINGERPRINT}" > "${PROVENANCE_DIR}/kotlin.sha256"

STAGING="${BUILD_DIR}/staging"
mkdir -p "${STAGING}/jni"
for abi in "${ABIS[@]}"; do
  mkdir -p "${STAGING}/jni/${abi}"
  cp "${JNI_DIR}/${abi}/libopenburnbar_domain_ffi.so" \
    "${STAGING}/jni/${abi}/libopenburnbar_domain_ffi.so"
  cp "${JNI_DIR}/${abi}/libopenburnbar_domain_ffi.so" \
    "${STAGING}/jni/${abi}/libuniffi_openburnbar_domain_ffi.so"
done

cat > "${STAGING}/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="com.openburnbar.domaincore.native_">
  <uses-sdk android:minSdkVersion="26" />
</manifest>
EOF
mkdir -p "${BUILD_DIR}/empty-classes/META-INF"
cat > "${BUILD_DIR}/empty-classes/META-INF/MANIFEST.MF" <<'EOF'
Manifest-Version: 1.0
Created-By: OpenBurnBar

EOF
find "${BUILD_DIR}/empty-classes" -exec touch -h -t "${ZIP_TIME}" {} +
write_stored_zip "${STAGING}/classes.jar" "${BUILD_DIR}/empty-classes" META-INF/MANIFEST.MF
: > "${STAGING}/proguard.txt"
: > "${STAGING}/R.txt"
mkdir -p "${STAGING}/META-INF"
printf '%s\n' "${SOURCE_FINGERPRINT}" > \
  "${STAGING}/META-INF/openburnbar-domain-core-source.sha256"
printf 'rust=%s\nndk=%s\n' "${ACTUAL_RUST_TOOLCHAIN}" "${NDK_VERSION}" > \
  "${STAGING}/META-INF/openburnbar-domain-core-android-toolchain.env"

find "${STAGING}" -exec touch -h -t "${ZIP_TIME}" {} +
AAR_ENTRIES=()
while IFS= read -r entry; do
  AAR_ENTRIES+=("${entry}")
done < <(cd "${STAGING}" && find . -type f -print | sed 's#^./##' | LC_ALL=C sort)
rm -f "${AAR_PATH}"
write_stored_zip "${AAR_PATH}" "${STAGING}" "${AAR_ENTRIES[@]}"

log "verifying 16 KB ELF LOAD alignment"
for abi in "${ABIS[@]}"; do
  objdump="$(find "${NDK_HOME}/toolchains/llvm/prebuilt" -path '*/bin/llvm-objdump' -type f -perm -111 | head -1)"
  [[ -x "${objdump}" ]] || abort "llvm-objdump not found in NDK"
  alignments="$("${objdump}" -p "${JNI_DIR}/${abi}/libopenburnbar_domain_ffi.so" | awk '/LOAD/ && /align/ { print $NF }')"
  [[ -n "${alignments}" ]] || abort "${abi}: no ELF LOAD segments found"
  while IFS= read -r alignment; do
    if [[ "${alignment}" =~ ^2\*\*([0-9]+)$ ]]; then
      (( BASH_REMATCH[1] >= 14 )) || abort "${abi}: LOAD alignment ${alignment} is below 16 KB"
    elif [[ "${alignment}" =~ ^0x[0-9a-fA-F]+$ || "${alignment}" =~ ^[0-9]+$ ]]; then
      (( alignment >= 16384 )) || abort "${abi}: LOAD alignment ${alignment} is below 16 KB"
    else
      abort "${abi}: unrecognized LOAD alignment ${alignment}"
    fi
  done <<< "${alignments}"
  log "${abi}: 16 KB compatible"
done

if [[ -n "${ARTIFACT_EXPORT_DIR}" ]]; then
  rm -rf "${ARTIFACT_EXPORT_DIR}"
  mkdir -p \
    "${ARTIFACT_EXPORT_DIR}/generated-kotlin" \
    "${ARTIFACT_EXPORT_DIR}/artifact-provenance"
  cp "${AAR_PATH}" "${ARTIFACT_EXPORT_DIR}/openburnbar-domain-core.aar"
  cp -R "${GENERATED_DIR}/." "${ARTIFACT_EXPORT_DIR}/generated-kotlin/"
  cp "${PROVENANCE_DIR}/kotlin.sha256" \
    "${ARTIFACT_EXPORT_DIR}/artifact-provenance/kotlin.sha256"
  log "exported rebuilt AAR and bindings to ${ARTIFACT_EXPORT_DIR}"
fi

if [[ "${CHECK_ARTIFACT}" -eq 1 ]]; then
  compare_aar_entries "${EXPECTED_AAR}" "${AAR_PATH}" || \
    abort "rebuilt AAR entry tree differs from the committed artifact"
  if ! cmp -s "${EXPECTED_AAR}" "${AAR_PATH}"; then
    expected_sha="$(shasum -a 256 "${EXPECTED_AAR}" | awk '{print $1}')"
    actual_sha="$(shasum -a 256 "${AAR_PATH}" | awk '{print $1}')"
    abort "rebuilt AAR differs byte-for-byte (committed=${expected_sha} rebuilt=${actual_sha})"
  fi
  log "rebuilt AAR is byte-identical to the committed artifact"
  restore_committed_aar
  trap - EXIT
fi

log "DONE: ${AAR_PATH}"
log "Kotlin bindings: ${GENERATED_DIR}"

CHECKSUM_MANIFEST="${VENDOR_DIR}/CHECKSUMS.sha256"
CHECKSUM_NAME="$(basename "${AAR_PATH}")"
CHECKSUM_SHA256="$(shasum -a 256 "${AAR_PATH}" | awk '{print $1}')"
[[ "${CHECKSUM_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || \
  abort "unable to compute SHA-256 for ${AAR_PATH}"
CHECKSUM_TMP="$(mktemp "${CHECKSUM_MANIFEST}.XXXXXX")"
if [[ -f "${CHECKSUM_MANIFEST}" ]]; then
  awk -v target="${CHECKSUM_NAME}" '
    /^[[:space:]]*#/ || NF == 0 { print; next }
    {
      path = $2
      sub(/^\*/, "", path)
      if (path != target) print
    }
  ' "${CHECKSUM_MANIFEST}" > "${CHECKSUM_TMP}"
else
  : > "${CHECKSUM_TMP}"
fi
printf '%s  %s\n' "${CHECKSUM_SHA256}" "${CHECKSUM_NAME}" >> "${CHECKSUM_TMP}"
mv "${CHECKSUM_TMP}" "${CHECKSUM_MANIFEST}"
