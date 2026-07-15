#!/usr/bin/env bash
# Build and package the host-native UniFFI Python surface for both Python consumers.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/crates/openburnbar-domain-core"
TARGET_DIR="${CARGO_TARGET_DIR:-${CRATE_DIR}/target}"
if [[ "${TARGET_DIR}" != /* ]]; then
  TARGET_DIR="${CRATE_DIR}/${TARGET_DIR}"
fi
PACKAGE_DIR="${ROOT_DIR}/tools/openburnbar-mcp/vendor/openburnbar-domain-core-python"
HERMES_PACKAGE_DIR="${ROOT_DIR}/tools/hermes-platform-burnbar/vendor/openburnbar-domain-core-python"
HELPER_DIR="${ROOT_DIR}/build/uniffi-bindgen-python-helper"
MANIFEST="${CRATE_DIR}/union-abi-manifest.json"
PROFILE="${DOMAIN_CORE_BUILD_PROFILE:-release}"
PROFILE_FLAG="--release"
PROFILE_DIR="release"

if [[ "${PROFILE}" == "debug" ]]; then
  PROFILE_FLAG=""
  PROFILE_DIR="debug"
fi

command -v cargo >/dev/null 2>&1 || {
  echo "ERROR: cargo is required to package the local MCP domain core." >&2
  exit 1
}

case "$(uname -s)" in
  Darwin) NATIVE_NAME="libopenburnbar_domain_ffi.dylib" ;;
  Linux) NATIVE_NAME="libopenburnbar_domain_ffi.so" ;;
  MINGW*|MSYS*|CYGWIN*) NATIVE_NAME="openburnbar_domain_ffi.dll" ;;
  *) echo "ERROR: unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

mkdir -p "${HELPER_DIR}/src" "${PACKAGE_DIR}" "${HERMES_PACKAGE_DIR}"
cat > "${HELPER_DIR}/Cargo.toml" <<'EOF'
[package]
name = "openburnbar-uniffi-bindgen-python-helper"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
anyhow = "1"
camino = "1"
uniffi_bindgen = "=0.28.3"
EOF
cat > "${HELPER_DIR}/src/main.rs" <<'EOF'
use anyhow::Context;
use camino::Utf8PathBuf;
use uniffi_bindgen::{
    bindings::PythonBindingGenerator, library_mode::generate_bindings, EmptyCrateConfigSupplier,
};

fn main() -> anyhow::Result<()> {
    let library_path = Utf8PathBuf::from(
        std::env::var("UNIFFI_LIBRARY_PATH").context("UNIFFI_LIBRARY_PATH is required")?,
    );
    let out_dir = Utf8PathBuf::from(
        std::env::var("UNIFFI_OUT_DIR").context("UNIFFI_OUT_DIR is required")?,
    );
    generate_bindings(
        &library_path,
        Some("openburnbar_domain_ffi".to_owned()),
        &PythonBindingGenerator,
        &EmptyCrateConfigSupplier,
        None,
        &out_dir,
        false,
    )?;
    Ok(())
}
EOF

if [[ -n "${DOMAIN_CORE_OBSERVED_IDENTITY_REPORT:-}" ]]; then
  : "${DOMAIN_CORE_CANDIDATE_COMMIT:?DOMAIN_CORE_CANDIDATE_COMMIT is required with DOMAIN_CORE_OBSERVED_IDENTITY_REPORT}"
  export OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT="${DOMAIN_CORE_CANDIDATE_COMMIT}"
fi

(
  cd "${CRATE_DIR}"
  cargo build ${PROFILE_FLAG} -p openburnbar-domain-ffi --lib
)

NATIVE_SOURCE="${TARGET_DIR}/${PROFILE_DIR}/${NATIVE_NAME}"
if [[ ! -f "${NATIVE_SOURCE}" ]]; then
  echo "ERROR: expected native library missing: ${NATIVE_SOURCE}" >&2
  exit 1
fi

# Release stripping removes the UniFFI metadata symbols from ELF libraries.
# Generate bindings from an unstripped debug library while packaging the
# requested release library, matching the Android AAR build's metadata path.
BINDGEN_NATIVE_SOURCE="${NATIVE_SOURCE}"
if [[ "${PROFILE}" != "debug" ]]; then
  (
    cd "${CRATE_DIR}"
    cargo build -p openburnbar-domain-ffi --lib
  )
  BINDGEN_NATIVE_SOURCE="${TARGET_DIR}/debug/${NATIVE_NAME}"
  if [[ ! -f "${BINDGEN_NATIVE_SOURCE}" ]]; then
    echo "ERROR: expected UniFFI metadata library missing: ${BINDGEN_NATIVE_SOURCE}" >&2
    exit 1
  fi
fi

rm -f "${PACKAGE_DIR}/openburnbar_domain_ffi.py" "${PACKAGE_DIR}"/*.dylib \
  "${PACKAGE_DIR}"/*.so "${PACKAGE_DIR}"/*.dll
rm -f "${HERMES_PACKAGE_DIR}/openburnbar_domain_ffi.py" "${HERMES_PACKAGE_DIR}"/*.dylib \
  "${HERMES_PACKAGE_DIR}"/*.so "${HERMES_PACKAGE_DIR}"/*.dll
UNIFFI_LIBRARY_PATH="${BINDGEN_NATIVE_SOURCE}" \
UNIFFI_OUT_DIR="${PACKAGE_DIR}" \
  cargo run --manifest-path "${HELPER_DIR}/Cargo.toml" --release --quiet
perl -0pi -e 's/[ \t]+(?=\n)//g; s/\s+\z/\n/' "${PACKAGE_DIR}/openburnbar_domain_ffi.py"
cp "${NATIVE_SOURCE}" "${PACKAGE_DIR}/${NATIVE_NAME}"

SOURCE_SHA="$(python3 "${ROOT_DIR}/scripts/ci/domain-core-union-gate.py" --source-fingerprint)"
printf '%s\n' "${SOURCE_SHA}" > "${PACKAGE_DIR}/openburnbar-domain-core-source.sha256"
printf '%s\n' "${SOURCE_SHA}" > "${CRATE_DIR}/artifact-provenance/python.sha256"

python3 - "${MANIFEST}" "${PACKAGE_DIR}" "${NATIVE_NAME}" <<'PY'
import hashlib
import json
import platform
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
package_dir = Path(sys.argv[2])
native_name = sys.argv[3]
manifest = json.loads(manifest_path.read_text())
native = package_dir / native_name
binding = package_dir / "openburnbar_domain_ffi.py"
source_sha = (package_dir / "openburnbar-domain-core-source.sha256").read_text().strip()
receipt = {
    "schemaVersion": 1,
    "coreVersion": manifest["coreVersion"],
    "abiVersion": manifest["abiVersion"],
    "sourceSha256": source_sha,
    "platform": platform.system().lower(),
    "architecture": platform.machine().lower(),
    "nativeFile": native_name,
    "nativeSha256": hashlib.sha256(native.read_bytes()).hexdigest(),
    "bindingSha256": hashlib.sha256(binding.read_bytes()).hexdigest(),
}
(package_dir / "openburnbar-domain-core-package-receipt.json").write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n"
)
PY

cp "${PACKAGE_DIR}/openburnbar_domain_ffi.py" \
  "${PACKAGE_DIR}/openburnbar-domain-core-source.sha256" \
  "${PACKAGE_DIR}/${NATIVE_NAME}" \
  "${PACKAGE_DIR}/openburnbar-domain-core-package-receipt.json" \
  "${HERMES_PACKAGE_DIR}/"

if [[ -n "${DOMAIN_CORE_OBSERVED_IDENTITY_REPORT:-}" ]]; then
  python3 - "${PACKAGE_DIR}" "${DOMAIN_CORE_OBSERVED_IDENTITY_REPORT}" "${DOMAIN_CORE_CANDIDATE_COMMIT}" <<'PY'
import json
import sys
from pathlib import Path

package = Path(sys.argv[1])
output = Path(sys.argv[2])
expected_candidate_commit = sys.argv[3]
sys.path.insert(0, str(package))
import openburnbar_domain_ffi as core

candidate_commit = core.domain_core_candidate_commit()
if candidate_commit == "0" * 40 or candidate_commit != expected_candidate_commit:
    raise SystemExit("loaded Rust candidate commit does not match the expected candidate")
receipt = json.loads((package / "openburnbar-domain-core-package-receipt.json").read_text())
identity = {
    "candidateCommit": candidate_commit,
    "coreVersion": receipt["coreVersion"],
    "abiVersion": receipt["abiVersion"],
    "sourceSha256": receipt["sourceSha256"],
}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(identity, indent=2, sort_keys=True) + "\n")
PY
fi

PYTHONPATH="${PACKAGE_DIR}" python3 - <<'PY'
import json
from pathlib import Path
import openburnbar_domain_ffi as core

package = Path(core.__file__).resolve().parent
receipt = json.loads((package / "openburnbar-domain-core-package-receipt.json").read_text())
assert core.domain_core_version() == receipt["coreVersion"]
assert core.domain_core_abi_version() == receipt["abiVersion"]
assert core.domain_core_source_fingerprint() == receipt["sourceSha256"]
assert core.cloud_vault_project_memory_doc_id("alpha", bytes(range(32))).startswith("pm_")
agent = "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
phone = "BHzyexiNA09+ilI4AwS1GsPAiWnid/IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E="
request = core.HermesRatchetPrekeyRequest(
    dh1=bytes(range(32)),
    dh2=bytes(range(32, 64)),
    dh3=bytes(range(64, 96)),
    uid="user-python-kat",
    client_id="client-python-kat",
    initiator_role="agent",
    initiator_identity_public_key_base64=agent,
    responder_identity_public_key_base64=phone,
    initiator_signed_prekey_public_key_base64=agent,
    responder_signed_prekey_public_key_base64=phone,
    initiator_initial_ratchet_public_key_base64=agent,
)
assert core.hermes_ratchet_prekey_shared_secret(request).hex() == (
    "106bcf0cd44712e7e9a1e1a6ef91e318e11766588247b831bce9aeaead74ab7d"
)
print(
    "OK: Python consumer domain core "
    f"{receipt['coreVersion']}/ABI-{receipt['abiVersion']} "
    f"({receipt['platform']}-{receipt['architecture']})"
)
PY
