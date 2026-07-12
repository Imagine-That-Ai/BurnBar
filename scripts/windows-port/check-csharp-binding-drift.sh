#!/usr/bin/env bash
# Codegen-drift gate for the committed uniffi C# bindings (Windows native shim).
#
# The Windows port commits the GENERATED C# bindings for the two Rust cdylibs
# (docs/windows-port/decisions/0001-csharp-binding-path.md):
#
#   crates/burnbar-remote/bindings/csharp/BurnBarRemote.Ffi/generated/burnbar_remote.cs
#   crates/openburnbar-iroh/bindings/csharp/OpenBurnBarIroh.Ffi/generated/openburnbar_iroh.cs
#
# This script rebuilds each cdylib, regenerates the binding with the PINNED
# uniffi-bindgen-cs into a temp dir, and diffs it against the committed file.
# A diff means someone changed a `#[uniffi::export]` surface without re-running
# the crate's bindings/csharp/regenerate.sh — fail, with the remedy printed.
#
# Run locally before a PR that touches either crate's export surface, or let
# .github/workflows/csharp-binding-drift.yml run it. Idempotent: running it
# twice (or right after regenerate.sh) is always green.
#
# Usage:
#   scripts/windows-port/check-csharp-binding-drift.sh              # both crates
#   scripts/windows-port/check-csharp-binding-drift.sh burnbar-remote
#   scripts/windows-port/check-csharp-binding-drift.sh iroh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

# ── Toolchain pin ────────────────────────────────────────────────────────────
# Must match the crates' uniffi 0.28.x (see decision 0001). A mismatched
# generator emits a binding whose runtime contract checksum fails on first
# call — catch it here instead.
required_version="uniffi-bindgen 0.9.2+v0.28.3"
install_hint="cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.9.2+v0.28.3"

if ! command -v uniffi-bindgen-cs >/dev/null 2>&1; then
  echo "ERROR: uniffi-bindgen-cs not found. Install the pinned generator:" >&2
  echo "  ${install_hint}" >&2
  exit 1
fi

actual_version="$(uniffi-bindgen-cs --version)"
if [[ "${actual_version}" != "${required_version}" ]]; then
  echo "ERROR: uniffi-bindgen-cs version mismatch." >&2
  echo "  required: ${required_version}" >&2
  echo "  actual:   ${actual_version}" >&2
  echo "Reinstall the pin: ${install_hint}" >&2
  exit 1
fi

# uniffi-bindgen-cs auto-formats its output when `csharpier` is on PATH. The
# committed bindings are the generator's RAW output (no csharpier), so a host
# with csharpier installed would report false drift. Refuse loudly instead.
if command -v csharpier >/dev/null 2>&1; then
  echo "ERROR: 'csharpier' is on PATH. uniffi-bindgen-cs would auto-format its output" >&2
  echo "with it, but the committed bindings are the generator's raw (unformatted) output," >&2
  echo "so the diff below would be pure formatting noise. Remove csharpier from PATH" >&2
  echo "(e.g. 'dotnet tool uninstall -g csharpier') and re-run." >&2
  exit 1
fi

check_binding() {
  local label="$1" crate_dir="$2" package="$3" lib_base="$4" config="$5" committed="$6" regen="$7"
  local lib_file out_dir generated_name

  case "$(uname -s)" in
    Darwin) lib_file="lib${lib_base}.dylib" ;;
    Linux)  lib_file="lib${lib_base}.so" ;;
    *)      lib_file="${lib_base}.dll" ;;
  esac

  echo "==> [${label}] building the cdylib (cargo build -p ${package})"
  ( cd "${repo_root}/${crate_dir}" && cargo build -p "${package}" )

  local target_dir
  target_dir="$(
    cd "${repo_root}/${crate_dir}" && cargo metadata --no-deps --format-version 1 \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])'
  )"
  local lib_path="${target_dir}/debug/${lib_file}"
  if [[ ! -f "${lib_path}" ]]; then
    echo "ERROR: [${label}] cdylib not found after build: ${lib_path}" >&2
    exit 1
  fi

  out_dir="${tmp_root}/${label}"
  mkdir -p "${out_dir}"

  echo "==> [${label}] regenerating the C# binding with the pinned generator"
  # Run from the crate dir: library mode shells out to `cargo metadata`.
  ( cd "${repo_root}/${crate_dir}" && uniffi-bindgen-cs \
      --library "${lib_path}" \
      --config "${repo_root}/${crate_dir}/${config}" \
      --out-dir "${out_dir}" >/dev/null )

  generated_name="$(basename "${committed}")"
  local normalized_committed="${tmp_root}/${label}.committed.normalized.cs"
  local normalized_generated="${tmp_root}/${label}.generated.normalized.cs"
  cp "${repo_root}/${committed}" "${normalized_committed}"
  cp "${out_dir}/${generated_name}" "${normalized_generated}"
  perl -0pi -e 's/[ \t]+$//mg' "${normalized_committed}" "${normalized_generated}"
  if ! diff -u "${normalized_committed}" "${normalized_generated}"; then
    echo "" >&2
    echo "ERROR: [${label}] the committed C# binding is stale — the Rust" >&2
    echo "#[uniffi::export] surface changed without regenerating it." >&2
    echo "Fix: run ${regen} and commit the diff." >&2
    exit 1
  fi
  echo "==> [${label}] committed binding is in sync."
}

selection="${1:-all}"
case "${selection}" in
  all|burnbar-remote|iroh) ;;
  *)
    echo "ERROR: unknown selection '${selection}' (expected: all | burnbar-remote | iroh)" >&2
    exit 1
    ;;
esac

if [[ "${selection}" == "all" || "${selection}" == "burnbar-remote" ]]; then
  check_binding \
    "burnbar-remote" \
    "crates/burnbar-remote" \
    "burnbar-remote-ffi" \
    "burnbar_remote" \
    "burnbar-remote-ffi/uniffi.toml" \
    "crates/burnbar-remote/bindings/csharp/BurnBarRemote.Ffi/generated/burnbar_remote.cs" \
    "crates/burnbar-remote/bindings/csharp/regenerate.sh"
fi

if [[ "${selection}" == "all" || "${selection}" == "iroh" ]]; then
  check_binding \
    "openburnbar-iroh" \
    "crates/openburnbar-iroh" \
    "openburnbar-iroh" \
    "openburnbar_iroh" \
    "uniffi.toml" \
    "crates/openburnbar-iroh/bindings/csharp/OpenBurnBarIroh.Ffi/generated/openburnbar_iroh.cs" \
    "crates/openburnbar-iroh/bindings/csharp/regenerate.sh"
fi

echo "OK: committed C# bindings match the pinned generator's output."
