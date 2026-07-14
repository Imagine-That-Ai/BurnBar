#!/usr/bin/env bash
set -euo pipefail

consumer="${1:-}"
release_tag="${2:-}"
release_commit="${3:-}"
artifact_path="${4:-}"
evidence_dir="${5:-}"
repository="${GITHUB_REPOSITORY:-Imagine-That-Ai/BurnBar}"

if [[ "$consumer" != "apple" && "$consumer" != "android" ]]; then
  echo "usage: $0 <apple|android> <stable-tag> <commit> <artifact> <evidence-dir>" >&2
  exit 2
fi
if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "native domain-core evidence requires an exact stable tag" >&2
  exit 2
fi
if [[ ! "$release_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "native domain-core evidence requires a full lowercase release commit" >&2
  exit 2
fi
if [[ ! -f "$artifact_path" || -L "$artifact_path" || ! -d "$evidence_dir" || -L "$evidence_dir" ]]; then
  echo "native domain-core publication inputs are missing or unsafe" >&2
  exit 1
fi

manifest="$evidence_dir/$consumer-manifest.json"
if [[ ! -f "$manifest" || -L "$manifest" ]]; then
  echo "native domain-core evidence manifest is missing: $manifest" >&2
  exit 1
fi

work_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/domain-core-native-publish.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT
evidence_rows="$work_root/evidence-rows.tsv"
python3 - "$manifest" "$consumer" "$release_tag" "$release_commit" "$artifact_path" > "$evidence_rows" <<'PY'
import hashlib
import json
import os
import re
import sys

manifest_path, consumer, tag, commit, artifact_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
required = {"schemaVersion", "consumer", "artifactKind", "target", "artifact", "release", "domains"}
if set(manifest) != required or manifest.get("schemaVersion") != 1 or manifest.get("consumer") != consumer:
    raise SystemExit("native evidence manifest identity is invalid")
expected_identity = {
    "apple": ("macos-dmg", "macos-arm64"),
    "android": ("android-aab", "android-universal"),
}[consumer]
if (manifest.get("artifactKind"), manifest.get("target")) != expected_identity:
    raise SystemExit("native evidence manifest artifact identity is invalid")
release = manifest.get("release")
if not isinstance(release, dict) or set(release) != {"version", "tag", "commit"}:
    raise SystemExit("native evidence manifest release identity is invalid")
if release.get("tag") != tag or release.get("commit") != commit:
    raise SystemExit("native evidence manifest does not bind the release tag and commit")
artifact = manifest.get("artifact")
if not isinstance(artifact, dict) or set(artifact) != {"fileName", "sha256"}:
    raise SystemExit("native evidence manifest artifact digest is invalid")
if artifact.get("fileName") != os.path.basename(artifact_path):
    raise SystemExit("native evidence manifest artifact filename does not match")
digest = hashlib.sha256()
with open(artifact_path, "rb") as handle:
    while chunk := handle.read(1024 * 1024):
        digest.update(chunk)
actual_sha256 = digest.hexdigest()
if artifact.get("sha256") != actual_sha256:
    raise SystemExit("native evidence manifest artifact digest does not match")
domains = manifest.get("domains")
if not isinstance(domains, list):
    raise SystemExit("native evidence manifest domains must be an array")
allowed = {
    "apple": ["quota", "cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes", "pricing"],
    "android": ["cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes"],
}[consumer]
seen = []
last_index = -1
for item in domains:
    keys = {"domain", "publicProfileSha256", "predicateFileName", "bundleFileName"}
    if not isinstance(item, dict) or set(item) != keys:
        raise SystemExit("native evidence manifest domain entry is invalid")
    domain = item.get("domain")
    domain_index = allowed.index(domain) if domain in allowed else -1
    if domain_index < 0 or domain in seen or domain_index <= last_index:
        raise SystemExit("native evidence manifest domains are unknown, duplicated, or out of order")
    seen.append(domain)
    last_index = domain_index
    if not re.fullmatch(r"[0-9a-f]{64}", item.get("publicProfileSha256", "")):
        raise SystemExit("native evidence manifest profile digest is invalid")
    for key in ("predicateFileName", "bundleFileName"):
        name = item.get(key)
        if not isinstance(name, str) or os.path.basename(name) != name or name in (".", ".."):
            raise SystemExit("native evidence manifest contains an unsafe evidence filename")
    predicate_path = os.path.join(os.path.dirname(manifest_path), item["predicateFileName"])
    with open(predicate_path, encoding="utf-8") as handle:
        predicate = json.load(handle)
    if set(predicate) != {"schemaVersion", "consumer", "artifactKind", "target", "artifact", "release"}:
        raise SystemExit("native evidence predicate shape is invalid")
    if (
        predicate.get("schemaVersion") != 1
        or predicate.get("consumer") != consumer
        or (predicate.get("artifactKind"), predicate.get("target")) != expected_identity
        or predicate.get("artifact") != artifact
    ):
        raise SystemExit("native evidence predicate artifact identity is invalid")
    predicate_release = predicate.get("release")
    if not isinstance(predicate_release, dict) or set(predicate_release) != {
        "version", "tag", "commit", "publicProfileSha256"
    }:
        raise SystemExit("native evidence predicate release identity is invalid")
    if (
        predicate_release.get("version") != release.get("version")
        or predicate_release.get("tag") != tag
        or predicate_release.get("commit") != commit
        or predicate_release.get("publicProfileSha256") != item["publicProfileSha256"]
    ):
        raise SystemExit("native evidence predicate does not match its manifest domain")
    print("\t".join((domain, item["predicateFileName"], item["bundleFileName"])))
PY

release_json="$(gh api "repos/$repository/releases/tags/$release_tag")"
node -e '
  const release = JSON.parse(process.argv[1]);
  const tag = process.argv[2];
  if (release.tag_name !== tag || release.prerelease) process.exit(1);
' "$release_json" "$release_tag" || {
  echo "GitHub release is prerelease or does not match $release_tag" >&2
  exit 1
}

artifact_name="$(basename "$artifact_path")"

verify_bundle() {
  local bundle="$1"
  local predicate="$2"
  local verified
  verified="$work_root/verified-$(basename "$bundle")"
  gh attestation verify "$artifact_path" \
    --bundle "$bundle" \
    --repo "$repository" \
    --signer-workflow "$repository/.github/workflows/release.yml" \
    --source-digest "$release_commit" \
    --source-ref "refs/tags/$release_tag" \
    --signer-digest "$release_commit" \
    --cert-oidc-issuer https://token.actions.githubusercontent.com \
    --deny-self-hosted-runners \
    --predicate-type https://openburnbar.dev/attestations/domain-core-release-artifact/v1 \
    --format json > "$verified"
  python3 - "$verified" "$predicate" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    verified = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    expected = json.load(handle)
predicates = []
for result in verified if isinstance(verified, list) else []:
    verification = result.get("verificationResult") if isinstance(result, dict) else None
    statement = verification.get("statement") if isinstance(verification, dict) else None
    predicate = statement.get("predicate") if isinstance(statement, dict) else None
    if isinstance(predicate, dict):
        predicates.append(predicate)
if expected not in predicates:
    raise SystemExit("verified attestation does not contain the exact release predicate")
PY
}

existing_assets="$work_root/existing-assets.txt"
mkdir -p "$work_root/existing"
gh release view "$release_tag" --repo "$repository" --json assets --jq '.assets[].name' > "$existing_assets"
has_asset() {
  local expected="$1"
  grep -Fxq "$expected" "$existing_assets"
}

# A rerun may encounter a canonical artifact published by an older attempt.
# Compare it before adding any new custom bundle so a mismatched artifact
# cannot leave behind evidence that appears to authorize different bytes.
artifact_exists=false
if has_asset "$artifact_name"; then
  artifact_exists=true
  gh release download "$release_tag" --repo "$repository" --pattern "$artifact_name" --dir "$work_root/existing"
  if ! cmp -s "$artifact_path" "$work_root/existing/$artifact_name"; then
    echo "Refusing to replace non-identical immutable release asset $artifact_name" >&2
    exit 1
  fi
fi

# Bundles are always published before the artifact they authorize.
while IFS=$'\t' read -r domain predicate_name bundle_name; do
  predicate="$evidence_dir/$predicate_name"
  bundle="$evidence_dir/$bundle_name"
  if [[ ! -f "$predicate" || -L "$predicate" || ! -f "$bundle" || -L "$bundle" ]]; then
    echo "missing safe $consumer $domain predicate or attestation bundle" >&2
    exit 1
  fi
  verify_bundle "$bundle" "$predicate"
  if has_asset "$bundle_name"; then
    gh release download "$release_tag" --repo "$repository" --pattern "$bundle_name" --dir "$work_root/existing"
    verify_bundle "$work_root/existing/$bundle_name" "$predicate"
  elif ! gh release upload "$release_tag" "$bundle" --repo "$repository"; then
    rm -f "$work_root/existing/$bundle_name"
    gh release download "$release_tag" --repo "$repository" --pattern "$bundle_name" --dir "$work_root/existing"
    verify_bundle "$work_root/existing/$bundle_name" "$predicate"
  fi
done < "$evidence_rows"

if [[ "$artifact_exists" != "true" ]] && ! gh release upload "$release_tag" "$artifact_path" --repo "$repository"; then
  rm -f "$work_root/existing/$artifact_name"
  gh release download "$release_tag" --repo "$repository" --pattern "$artifact_name" --dir "$work_root/existing"
  if ! cmp -s "$artifact_path" "$work_root/existing/$artifact_name"; then
    echo "Concurrent immutable release asset differs from local artifact" >&2
    exit 1
  fi
fi

published="$work_root/published"
mkdir -p "$published"
gh release download "$release_tag" --repo "$repository" --pattern "$artifact_name" --dir "$published"
if ! cmp -s "$artifact_path" "$published/$artifact_name"; then
  echo "Published $consumer artifact bytes differ from the signed local artifact" >&2
  exit 1
fi
while IFS=$'\t' read -r domain predicate_name bundle_name; do
  gh release download "$release_tag" --repo "$repository" --pattern "$bundle_name" --dir "$published"
  verify_bundle "$published/$bundle_name" "$evidence_dir/$predicate_name"
done < "$evidence_rows"

echo "published immutable $consumer domain-core evidence for $release_tag"
