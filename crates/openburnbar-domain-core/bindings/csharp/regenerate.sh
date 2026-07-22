#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
crate_dir="$(cd "${here}/../.." && pwd)"
out_dir="${here}/OpenBurnBarDomainCore.Ffi/generated"
repo_root="$(cd "${crate_dir}/../.." && pwd)"
provenance_dir="${crate_dir}/artifact-provenance"
profile="${OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE:-debug}"
build_flag=()
[[ "${profile}" == "release" ]] && build_flag=(--release)

case "$(uname -s)" in
  Darwin) libname="libopenburnbar_domain_ffi.dylib" ;;
  Linux) libname="libopenburnbar_domain_ffi.so" ;;
  *) libname="openburnbar_domain_ffi.dll" ;;
esac

echo "==> Building openburnbar-domain-ffi (${profile})"
( cd "${crate_dir}" && cargo build -p openburnbar-domain-ffi ${build_flag[@]+"${build_flag[@]}"} )

lib_path="${crate_dir}/target/${profile}/${libname}"
[[ -f "${lib_path}" ]] || { echo "cdylib not found: ${lib_path}" >&2; exit 1; }

echo "==> Generating C# bindings from ${lib_path}"
mkdir -p "${out_dir}"
( cd "${crate_dir}" && uniffi-bindgen-cs \
    --library "${lib_path}" \
    --config "${crate_dir}/domain-ffi/uniffi.toml" \
    --out-dir "${out_dir}" )
perl -0pi -e 's/[ \t]+$//mg; s/\n+\z/\n/' "${out_dir}/openburnbar_domain_ffi.cs"
mkdir -p "${provenance_dir}"
python3 "${repo_root}/scripts/ci/domain-core-union-gate.py" --source-fingerprint > \
  "${provenance_dir}/csharp.sha256"

echo "==> Done. Review and commit ${out_dir} plus ${provenance_dir}/csharp.sha256"
