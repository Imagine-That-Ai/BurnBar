#!/usr/bin/env bash
# Verify Sigstore blob attestations for published OpenBurnBar release assets.
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() {
  cat <<'EOF'
Usage: scripts/ci/verify-release-attestations.sh <tag> [asset-glob ...]

Examples:
  scripts/ci/verify-release-attestations.sh v1.0.5
  scripts/ci/verify-release-attestations.sh v1.0.5 '*macOS.dmg' '*macOS.zip'

Verifies each matching GitHub Release asset with cosign verify-blob-attestation,
pinned by default to:
  - repo: Imagine-That-Ai/BurnBar
  - signer identity: https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/release.yml@refs/tags/<tag>
  - OIDC issuer: https://token.actions.githubusercontent.com

Accepted predicate identities:
  - https://slsa.dev/provenance/v1
  - https://openburnbar.dev/attestations/release-artifact/v1, only through
    LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG below

Override identity/issuer/type (for a permitted one-off verification) with:
  OPENBURNBAR_RELEASE_CERTIFICATE_IDENTITY
  OPENBURNBAR_RELEASE_CERTIFICATE_OIDC_ISSUER
  OPENBURNBAR_RELEASE_PREDICATE_TYPE
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

tag="${1:-}"
if [[ -z "$tag" ]]; then
  usage >&2
  exit 2
fi
shift || true

repo="${OPENBURNBAR_GITHUB_REPO:-Imagine-That-Ai/BurnBar}"
version="${tag#v}"
SLSA_PREDICATE_TYPE="https://slsa.dev/provenance/v1"
LEGACY_PREDICATE_TYPE="https://openburnbar.dev/attestations/release-artifact/v1"
# Sunset: legacy release-artifact predicates are accepted only through this
# last known release. From the next tagged release, SLSA is the sole accepted
# identity and this compatibility branch is deleted.
LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG="v1.0.40+repair.37"
predicate_type="${OPENBURNBAR_RELEASE_PREDICATE_TYPE:-}"
requested_predicate_type="$predicate_type"
certificate_identity="${OPENBURNBAR_RELEASE_CERTIFICATE_IDENTITY:-https://github.com/${repo}/.github/workflows/release.yml@refs/tags/${tag}}"
certificate_issuer="${OPENBURNBAR_RELEASE_CERTIFICATE_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
expected_runner_environment="${OPENBURNBAR_RELEASE_RUNNER_ENVIRONMENT:-github-hosted}"

tag_at_or_before() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

semver = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$"
)


def identifiers(value):
    return [] if value is None else value.split(".")


def compare_identifiers(left, right):
    for left_id, right_id in zip(identifiers(left), identifiers(right)):
        if left_id == right_id:
            continue
        left_numeric = left_id.isdigit()
        right_numeric = right_id.isdigit()
        if left_numeric and right_numeric:
            return (int(left_id) > int(right_id)) - (int(left_id) < int(right_id))
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return (left_id > right_id) - (left_id < right_id)
    return (len(identifiers(left)) > len(identifiers(right))) - (
        len(identifiers(left)) < len(identifiers(right))
    )


def compare(left_tag, right_tag):
    left = semver.fullmatch(left_tag)
    right = semver.fullmatch(right_tag)
    if left is None or right is None:
        raise SystemExit(2)
    left_core = tuple(int(part) for part in left.groups()[:3])
    right_core = tuple(int(part) for part in right.groups()[:3])
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)

    left_prerelease, right_prerelease = left.group(4), right.group(4)
    if left_prerelease != right_prerelease:
        if left_prerelease is None:
            return 1
        if right_prerelease is None:
            return -1
        return compare_identifiers(left_prerelease, right_prerelease)

    # SemVer build metadata normally does not affect precedence. BurnBar's
    # repair tags use it as the release train sequence, so compare it for the
    # explicit compatibility sunset.
    return compare_identifiers(left.group(5), right.group(5))


sys.exit(0 if compare(sys.argv[1], sys.argv[2]) <= 0 else 1)
PY
}

predicate_types=("$SLSA_PREDICATE_TYPE")
if tag_at_or_before "$tag" "$LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG"; then
  predicate_types=("$LEGACY_PREDICATE_TYPE" "$SLSA_PREDICATE_TYPE")
fi

if [[ -n "$requested_predicate_type" ]]; then
  if [[ "$requested_predicate_type" != "$SLSA_PREDICATE_TYPE" \
    && "$requested_predicate_type" != "$LEGACY_PREDICATE_TYPE" ]]; then
    echo "FAIL: unsupported release predicate identity: $requested_predicate_type" >&2
    exit 1
  fi
  if [[ "$requested_predicate_type" == "$LEGACY_PREDICATE_TYPE" ]]; then
    if ! tag_at_or_before "$tag" "$LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG"; then
      echo "FAIL: legacy release predicate is not accepted for tag $tag (sunset: $LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG)." >&2
      exit 1
    fi
  fi
  predicate_types=("$requested_predicate_type")
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "FAIL: gh CLI is required." >&2
  exit 1
fi

if ! command -v cosign >/dev/null 2>&1; then
  echo "FAIL: cosign CLI is required." >&2
  exit 1
fi

patterns=("$@")
if [[ "${#patterns[@]}" -eq 0 ]]; then
  patterns=(
    "*macOS.dmg"
    "*macOS.zip"
    "checksums-v${version}.txt"
    "sbom-v${version}.spdx.json"
    "openburnbar-v${version}.vex.json"
    "OpenBurnBar-${version}-corresponding-source.tar.gz"
    "appcast.xml"
    "latest-macos.json"
  )
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-release-attest.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

downloaded=0
download_required_pattern() {
  local pattern="$1"
  local pattern_dir
  pattern_dir="$(mktemp -d "$tmp_dir/pattern.XXXXXX")"
  gh release download "$tag" --repo "$repo" --pattern "$pattern" --dir "$pattern_dir" --clobber >/dev/null 2>&1 || true
  if [[ "$(find "$pattern_dir" -type f | wc -l | tr -d ' ')" -eq 0 ]]; then
    echo "FAIL: required release asset pattern '$pattern' matched no assets for $tag." >&2
    exit 1
  fi
  find "$pattern_dir" -type f -exec cp -f {} "$tmp_dir/" \;
  rm -rf "$pattern_dir"
}

download_optional_pattern() {
  local pattern="$1"
  local pattern_dir
  pattern_dir="$(mktemp -d "$tmp_dir/pattern.XXXXXX")"
  gh release download "$tag" --repo "$repo" --pattern "$pattern" --dir "$pattern_dir" --clobber >/dev/null 2>&1 || true
  if [[ "$(find "$pattern_dir" -type f | wc -l | tr -d ' ')" -eq 0 ]]; then
    echo "WARN: no release sidecar assets matched pattern '$pattern' for $tag" >&2
    rm -rf "$pattern_dir"
    return
  fi
  find "$pattern_dir" -type f -exec cp -f {} "$tmp_dir/" \;
  rm -rf "$pattern_dir"
}

for pattern in "${patterns[@]}"; do
  download_required_pattern "$pattern"
done

download_optional_pattern "*.sigstore.json"
download_optional_pattern "*.predicate.json"

while IFS= read -r -d '' asset; do
  case "$asset" in
    *.sigstore.json|*.predicate.json|*.asc|*.sha256)
      continue
      ;;
  esac

  downloaded=$((downloaded + 1))
  asset_name="$(basename "$asset")"
  safe_name="$(python3 - "$asset_name" <<'PY'
import re
import sys

print(re.sub(r"[^A-Za-z0-9._-]", "_", sys.argv[1]))
PY
)"
  bundle_path="$(find "$tmp_dir" -type f -name "${safe_name}.sigstore.json" -print -quit 2>/dev/null)"
  predicate_path="$(find "$tmp_dir" -type f -name "${safe_name}.predicate.json" -print -quit 2>/dev/null)"

  if [[ -z "$bundle_path" || ! -f "$bundle_path" ]]; then
    echo "FAIL: missing Sigstore bundle for $asset_name (${safe_name}.sigstore.json)." >&2
    exit 1
  fi
  if [[ -z "$predicate_path" || ! -f "$predicate_path" ]]; then
    echo "FAIL: missing release predicate for $asset_name (${safe_name}.predicate.json)." >&2
    exit 1
  fi

  verify_candidate() {
    local candidate_type="$1"
    cosign verify-blob-attestation \
      --bundle "$bundle_path" \
      --type "$candidate_type" \
      --certificate-identity "$certificate_identity" \
      --certificate-oidc-issuer "$certificate_issuer" \
      "$asset" >/dev/null || return 1

    python3 - "$asset" "$bundle_path" "$predicate_path" "$tag" "$version" "$repo" "$candidate_type" "$expected_runner_environment" <<'PY'
import base64
import hashlib
import json
import sys
from pathlib import Path

asset = Path(sys.argv[1])
bundle = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
sidecar_predicate = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
tag = sys.argv[4]
version = sys.argv[5]
repo = sys.argv[6]
predicate_type = sys.argv[7]
expected_runner_environment = sys.argv[8]
actual_sha256 = hashlib.sha256(asset.read_bytes()).hexdigest()


def decode_json_payload(value):
    if not isinstance(value, str):
        return None
    padded = value + ("=" * (-len(value) % 4))
    for kwargs in ({}, {"altchars": b"-_"}):
        try:
            raw = base64.b64decode(padded.encode("ascii"), validate=True, **kwargs)
            return json.loads(raw.decode("utf-8"))
        except Exception:
            continue
    return None


def candidate_payloads(node):
    if isinstance(node, dict):
        for key in ("dsseEnvelope", "DSSEEnvelope", "envelope", "Envelope"):
            envelope = node.get(key)
            if isinstance(envelope, dict):
                yield envelope.get("payload")
        payload = node.get("payload")
        if isinstance(payload, str) and "payloadType" in node:
            yield payload
        legacy_payload = node.get("Payload")
        if isinstance(legacy_payload, dict):
            yield legacy_payload.get("body")
        for value in node.values():
            yield from candidate_payloads(value)
    elif isinstance(node, list):
        for value in node:
            yield from candidate_payloads(value)


def signed_statement_from_bundle(bundle_json):
    if isinstance(bundle_json, dict) and "predicateType" in bundle_json:
        return bundle_json
    for encoded_payload in candidate_payloads(bundle_json):
        statement = decode_json_payload(encoded_payload)
        if isinstance(statement, dict) and "predicateType" in statement:
            return statement
    raise SystemExit(f"{asset.name}: verified Sigstore bundle did not contain a signed in-toto predicate payload")


statement = signed_statement_from_bundle(bundle)
statement_predicate_type = statement.get("predicateType")
if statement_predicate_type != predicate_type:
    raise SystemExit(
        f"{asset.name}: signed statement predicateType mismatch: got {statement_predicate_type!r}, want {predicate_type!r}"
    )

predicate = statement.get("predicate")
if isinstance(predicate, dict) and isinstance(predicate.get("Data"), dict) and "artifact" not in predicate:
    predicate = predicate["Data"]
if not isinstance(predicate, dict):
    raise SystemExit(f"{asset.name}: signed statement predicate is not a JSON object")
if predicate != sidecar_predicate:
    raise SystemExit(f"{asset.name}: release predicate sidecar does not match the signed Sigstore bundle payload")

expected = {
    "predicateType": predicate_type,
    "artifact.fileName": asset.name,
    "artifact.sha256": actual_sha256,
    "artifact.sizeBytes": asset.stat().st_size,
    "release.version": version,
    "release.tag": tag,
    "release.repository": repo,
    "release.ref": f"refs/tags/{tag}",
    "runner.environment": expected_runner_environment,
}

checks = {
    "predicateType": predicate.get("predicateType"),
    "artifact.fileName": predicate.get("artifact", {}).get("fileName"),
    "artifact.sha256": predicate.get("artifact", {}).get("sha256"),
    "artifact.sizeBytes": predicate.get("artifact", {}).get("sizeBytes"),
    "release.version": predicate.get("release", {}).get("version"),
    "release.tag": predicate.get("release", {}).get("tag"),
    "release.repository": predicate.get("release", {}).get("repository"),
    "release.ref": predicate.get("release", {}).get("ref"),
    "runner.environment": predicate.get("runner", {}).get("environment"),
}

for key, want in expected.items():
    got = checks.get(key)
    if got != want:
        raise SystemExit(f"{asset.name}: predicate {key} mismatch: got {got!r}, want {want!r}")
PY
  }

  verified_predicate_type=""
  for candidate_type in "${predicate_types[@]}"; do
    echo "==> verifying Sigstore blob attestation: $asset_name ($candidate_type)"
    if verify_candidate "$candidate_type"; then
      verified_predicate_type="$candidate_type"
      break
    fi
  done
  if [[ -z "$verified_predicate_type" ]]; then
    echo "FAIL: no permitted predicate identity verified for $asset_name on tag $tag." >&2
    exit 1
  fi
done < <(find "$tmp_dir" -type f -print0)

if [[ "$downloaded" -eq 0 ]]; then
  echo "FAIL: no release assets downloaded for $tag." >&2
  exit 1
fi

echo "PASS: verified Sigstore blob attestations for $downloaded release asset(s) from $tag"
