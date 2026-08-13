#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

verifier="scripts/ci/verify-release-attestations.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/release-attest-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

pass=0
fail=0

write_stubs() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "release" || "${2:-}" != "download" ]]; then
  echo "unexpected gh invocation: $*" >&2
  exit 2
fi
tag="$3"
shift 3
pattern=""
dest=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --pattern)
      pattern="$2"
      shift 2
      ;;
    --dir)
      dest="$2"
      shift 2
      ;;
    --repo|--clobber)
      if [[ "$1" == "--repo" ]]; then shift 2; else shift 1; fi
      ;;
    *)
      shift 1
      ;;
  esac
done
if [[ -z "$pattern" || -z "$dest" ]]; then
  echo "missing --pattern or --dir" >&2
  exit 2
fi
release_dir="${FIXTURE_RELEASE_DIR:?}/$tag"
shopt -s nullglob
matches=("$release_dir"/$pattern)
if [[ "${#matches[@]}" -eq 0 ]]; then
  exit 1
fi
cp -f "${matches[@]}" "$dest/"
SH
  chmod +x "$bin_dir/gh"

  cat >"$bin_dir/cosign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "verify-blob-attestation" ]]; then
  echo "unexpected cosign invocation: $*" >&2
  exit 2
fi
exit 0
SH
  chmod +x "$bin_dir/cosign"
}

safe_name() {
  python3 - "$1" <<'PY'
import re
import sys
print(re.sub(r"[^A-Za-z0-9._-]", "_", sys.argv[1]))
PY
}

write_asset_with_sidecars() {
  local release_dir="$1" tag="$2" name="$3" sidecar_runner_environment="$4" signed_runner_environment="$5"
  local version="${tag#v}"
  local asset="$release_dir/$name"
  local safe
  safe="$(safe_name "$name")"
  printf 'fixture asset: %s\n' "$name" >"$asset"
  python3 - "$asset" "$release_dir/${safe}.predicate.json" "$release_dir/${safe}.sigstore.json" "$tag" "$version" "$name" "$sidecar_runner_environment" "$signed_runner_environment" <<'PY'
import base64
import hashlib
import json
import sys
from pathlib import Path
asset = Path(sys.argv[1])
predicate_path = Path(sys.argv[2])
bundle_path = Path(sys.argv[3])
tag = sys.argv[4]
version = sys.argv[5]
name = sys.argv[6]
sidecar_runner_environment = sys.argv[7]
signed_runner_environment = sys.argv[8]
predicate = {
    "predicateType": "https://openburnbar.dev/attestations/release-artifact/v1",
    "artifact": {
        "fileName": name,
        "sha256": hashlib.sha256(asset.read_bytes()).hexdigest(),
        "sizeBytes": asset.stat().st_size,
    },
    "release": {
        "version": version,
        "tag": tag,
        "repository": "Imagine-That-Ai/BurnBar",
        "ref": f"refs/tags/{tag}",
    },
    "runner": {
        "environment": sidecar_runner_environment,
    },
}
predicate_path.write_text(json.dumps(predicate, indent=2, sort_keys=True) + "\n", encoding="utf-8")
signed_predicate = dict(predicate)
signed_predicate["runner"] = {"environment": signed_runner_environment}
statement = {
    "_type": "https://in-toto.io/Statement/v1",
    "predicateType": "https://openburnbar.dev/attestations/release-artifact/v1",
    "predicate": signed_predicate,
}
bundle = {
    "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
    "dsseEnvelope": {
        "payloadType": "application/vnd.in-toto+json",
        "payload": base64.b64encode(json.dumps(statement, sort_keys=True).encode("utf-8")).decode("ascii"),
        "signatures": [{"keyid": "", "sig": "fixture"}],
    },
}
bundle_path.write_text(json.dumps(bundle, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

new_release_fixture() {
  local tag="$1"
  local sidecar_runner_environment="${2:-github-hosted}"
  local signed_runner_environment="${3:-${sidecar_runner_environment}}"
  local release_dir="$tmp_root/releases/$tag"
  mkdir -p "$release_dir"
  write_asset_with_sidecars "$release_dir" "$tag" "OpenBurnBar-${tag#v}-macOS.dmg" "$sidecar_runner_environment" "$signed_runner_environment"
  write_asset_with_sidecars "$release_dir" "$tag" "OpenBurnBar-${tag#v}-macOS.zip" "$sidecar_runner_environment" "$signed_runner_environment"
  write_asset_with_sidecars "$release_dir" "$tag" "checksums-${tag}.txt" "$sidecar_runner_environment" "$signed_runner_environment"
  write_asset_with_sidecars "$release_dir" "$tag" "sbom-${tag}.spdx.json" "$sidecar_runner_environment" "$signed_runner_environment"
  write_asset_with_sidecars "$release_dir" "$tag" "openburnbar-${tag}.vex.json" "$sidecar_runner_environment" "$signed_runner_environment"
  write_asset_with_sidecars "$release_dir" "$tag" "OpenBurnBar-${tag#v}-corresponding-source.tar.gz" "$sidecar_runner_environment" "$signed_runner_environment"
  write_asset_with_sidecars "$release_dir" "$tag" "appcast.xml" "$sidecar_runner_environment" "$signed_runner_environment"
  write_asset_with_sidecars "$release_dir" "$tag" "latest-macos.json" "$sidecar_runner_environment" "$signed_runner_environment"
  write_asset_with_sidecars "$release_dir" "$tag" "developer-id-signing-receipt.json" "$sidecar_runner_environment" "$signed_runner_environment"
  printf '%s' "$release_dir"
}

run_case() {
  local want="$1" label="$2"
  shift 2
  local output="$tmp_root/${label}.out"
  local got
  set +e
  "$@" >"$output" 2>&1
  got=$?
  set -e
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    printf '  ok   (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL (exit %s, want %s) %s\n' "$got" "$want" "$label" >&2
    cat "$output" >&2
  fi
}

echo "verify-release-attestations self-test"

bin_dir="$tmp_root/bin"
write_stubs "$bin_dir"
tag="v9.9.9"
new_release_fixture "$tag" >/dev/null

run_case 0 default-required-patterns-present \
  env PATH="$bin_dir:/usr/bin:/bin" FIXTURE_RELEASE_DIR="$tmp_root/releases" "$verifier" "$tag"

run_case 0 all-required-patterns-present \
  env PATH="$bin_dir:/usr/bin:/bin" FIXTURE_RELEASE_DIR="$tmp_root/releases" "$verifier" "$tag" "*macOS.dmg" "*macOS.zip" "checksums-${tag}.txt"

run_case 0 overlapping-required-patterns-pass \
  env PATH="$bin_dir:/usr/bin:/bin" FIXTURE_RELEASE_DIR="$tmp_root/releases" "$verifier" "$tag" "*macOS.*" "*macOS.zip"

run_case 1 missing-required-pattern-fails \
  env PATH="$bin_dir:/usr/bin:/bin" FIXTURE_RELEASE_DIR="$tmp_root/releases" "$verifier" "$tag" "*macOS.dmg" "*missing.zip"

missing_sidecar_tag="v9.9.12"
missing_sidecar_dir="$(new_release_fixture "$missing_sidecar_tag")"
rm -f "$missing_sidecar_dir/$(safe_name "OpenBurnBar-${missing_sidecar_tag#v}-macOS.dmg").sigstore.json"
run_case 1 missing-required-sidecar-fails \
  env PATH="$bin_dir:/usr/bin:/bin" FIXTURE_RELEASE_DIR="$tmp_root/releases" "$verifier" "$missing_sidecar_tag" "*macOS.dmg"

bad_tag="v9.9.10"
new_release_fixture "$bad_tag" "self-hosted" >/dev/null
run_case 1 self-hosted-runner-predicate-fails \
  env PATH="$bin_dir:/usr/bin:/bin" FIXTURE_RELEASE_DIR="$tmp_root/releases" "$verifier" "$bad_tag" "*macOS.dmg"

tampered_tag="v9.9.11"
new_release_fixture "$tampered_tag" "github-hosted" "self-hosted" >/dev/null
run_case 1 unsigned-sidecar-runner-tamper-fails \
  env PATH="$bin_dir:/usr/bin:/bin" FIXTURE_RELEASE_DIR="$tmp_root/releases" "$verifier" "$tampered_tag" "*macOS.dmg"

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: ${fail} release attestation verifier self-test(s) failed" >&2
  exit 1
fi

echo "PASS: ${pass} release attestation verifier positive controls"
