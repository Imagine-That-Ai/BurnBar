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

native_manifest="$evidence_dir/$consumer-manifest.json"
if [[ ! -f "$native_manifest" || -L "$native_manifest" ]]; then
  echo "native domain-core evidence manifest is missing: $native_manifest" >&2
  exit 1
fi

publication_manifest="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/$consumer-domain-core-publication.json"
python3 - \
  "$native_manifest" \
  "$publication_manifest" \
  "$repository" \
  "$release_tag" \
  "$release_commit" \
  "$consumer" \
  "$artifact_path" <<'PY'
import json
import os
import sys

source_path, output_path, repository, tag, commit, consumer, artifact_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as handle:
    source = json.load(handle)
if not isinstance(source, dict) or source.get("consumer") != consumer:
    raise SystemExit("native evidence manifest consumer is invalid")
release = source.get("release")
if not isinstance(release, dict) or release.get("tag") != tag or release.get("commit") != commit:
    raise SystemExit("native evidence manifest release identity is invalid")
domains = source.get("domains")
if not isinstance(domains, list) or not domains:
    raise SystemExit("native evidence manifest has no Rust-authoritative domains")
root = os.path.dirname(os.path.abspath(source_path))
bundles = []
for entry in domains:
    if not isinstance(entry, dict):
        raise SystemExit("native evidence manifest domain entry is invalid")
    bundles.append(
        {
            "domain": entry.get("domain"),
            "assetName": entry.get("bundleFileName"),
            "bundlePath": os.path.join(root, str(entry.get("bundleFileName", ""))),
            "predicatePath": os.path.join(root, str(entry.get("predicateFileName", ""))),
        }
    )
manifest = {
    "schemaVersion": 1,
    "repository": repository,
    "tag": tag,
    "commit": commit,
    "consumer": consumer,
    "signerWorkflow": ".github/workflows/release.yml",
    "releaseAvailability": "draft-or-published",
    "artifactPath": os.path.abspath(artifact_path),
    "bundles": bundles,
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

node scripts/ci/publish-domain-core-release-evidence.mjs \
  --manifest "$publication_manifest"
