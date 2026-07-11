#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

release_out="${OPENBURNBAR_LINUX_RELEASE_OUT:-$repo_root/.linux-release}"
bucket="${OPENBURNBAR_R2_BUCKET:-openburnbar-downloads}"
public_base_url="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-https://downloads.burnbar.ai}"
feed="$release_out/latest-linux.draft.json"
signature="$release_out/sidecars/latest-linux.json.ed25519.sig"
verification="$release_out/release-verification.json"
public_key="packaging/linux/openburnbar-linux-ed25519.pub.pem"
repository_root="$release_out/repositories"
repository_closure="$repository_root/repository-closure.json"
repository_closure_signature="$repository_root/repository-closure.json.asc"
repository_lifecycle="$repository_root/repository-lifecycle.json"
version="$(node -e 'const value=require(process.argv[1]); if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(value.version ?? "")) process.exit(1); process.stdout.write(value.version)' "$feed")"
release_prefix="linux/releases/linux-v$version"

for required in \
  "$feed" \
  "$signature" \
  "$verification" \
  "$public_key" \
  "$repository_closure" \
  "$repository_closure_signature" \
  "$repository_lifecycle"; do
  if [[ ! -f "$required" ]]; then
    echo "required Linux release file is missing: $required" >&2
    exit 1
  fi
done

node -e '
  const fs = require("node:fs");
  const report = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (report.phase !== "final" || report.passed !== true || report.failures?.length) {
    throw new Error("Linux release verification is not final and green");
  }
' "$verification"

if [[ -n "${WRANGLER_BIN:-}" ]]; then
  wrangler=("$WRANGLER_BIN")
elif command -v wrangler >/dev/null 2>&1; then
  wrangler=(wrangler)
else
  wrangler=(npm exec --yes wrangler@latest --)
fi

content_type_for() {
  case "$1" in
    *.json) printf '%s\n' 'application/json; charset=utf-8' ;;
    *.repo|*.sources|*/Release|*/InRelease|*/Packages) printf '%s\n' 'text/plain; charset=utf-8' ;;
    *.xml) printf '%s\n' 'application/xml' ;;
    *.gz) printf '%s\n' 'application/gzip' ;;
    *.deb) printf '%s\n' 'application/vnd.debian.binary-package' ;;
    *.rpm) printf '%s\n' 'application/x-rpm' ;;
    *) printf '%s\n' 'application/octet-stream' ;;
  esac
}

put_object() {
  local file="$1"
  local key="$2"
  local cache_control="$3"
  "${wrangler[@]}" r2 object put "$bucket/$key" \
    --remote \
    --file "$file" \
    --content-type "$(content_type_for "$file")" \
    --cache-control "$cache_control"
}

declare -a release_artifacts=()
declare -a release_signatures=()
while IFS= read -r -d '' file; do release_artifacts+=("$file"); done \
  < <(find "$release_out/artifacts" -maxdepth 1 -type f -print0 | sort -z)
while IFS= read -r -d '' file; do release_signatures+=("$file"); done \
  < <(find "$release_out/sidecars" -maxdepth 1 -type f -name '*.ed25519.sig' -print0 | sort -z)
if [[ "${#release_artifacts[@]}" -ne 8 || "${#release_signatures[@]}" -ne 9 ]]; then
  echo "expected eight release artifacts and nine Ed25519 signatures, found ${#release_artifacts[@]} and ${#release_signatures[@]}" >&2
  exit 1
fi

node - "$feed" "$public_base_url/$release_prefix" <<'NODE'
const fs = require('node:fs');
const feed = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const prefix = `${process.argv[3]}/`;
const urls = [feed.signature?.url, ...(feed.artifacts ?? []).flatMap((artifact) => [artifact.url, artifact.signatureUrl])];
if (urls.some((url) => typeof url !== 'string' || !url.startsWith(prefix) || url.slice(prefix.length).includes('/'))) {
  throw new Error('signed Linux feed does not bind every artifact to the immutable R2 release prefix');
}
NODE

# Release artifacts and detached signatures are immutable and are the URLs
# authenticated by latest-linux.json. Publish and verify them before any
# mutable repository or feed pointer can advertise the release.
for file in "${release_artifacts[@]}" "${release_signatures[@]}"; do
  put_object "$file" "$release_prefix/$(basename "$file")" 'public, max-age=31536000, immutable'
done

declare -a repository_packages=()
declare -a repository_metadata=()
declare -a repository_pointer_signatures=()
declare -a repository_pointer_documents=()
declare -a repository_root_signatures=()
declare -a repository_root_documents=()
while IFS= read -r -d '' file; do
  relative="${file#"$repository_root"/}"
  case "$relative" in
    *.deb|*.rpm)
      repository_packages+=("$file")
      ;;
    apt/dists/*/Release.gpg|rpm/*/*/repodata/repomd.xml.asc)
      repository_pointer_signatures+=("$file")
      ;;
    apt/dists/*/InRelease|apt/dists/*/Release|rpm/*/*/repodata/repomd.xml)
      repository_pointer_documents+=("$file")
      ;;
    repository-closure.json.asc)
      repository_root_signatures+=("$file")
      ;;
    repository-closure.json)
      repository_root_documents+=("$file")
      ;;
    *)
      repository_metadata+=("$file")
      ;;
  esac
done < <(find "$repository_root" -type f -print0 | sort -z)

if [[ "${#repository_packages[@]}" -ne 4 ]]; then
  echo "expected four immutable apt/RPM repository packages, found ${#repository_packages[@]}" >&2
  exit 1
fi
if [[ "$((${#repository_pointer_signatures[@]} + ${#repository_pointer_documents[@]}))" -lt 7 ]]; then
  echo "signed apt/RPM repository pointer metadata is incomplete" >&2
  exit 1
fi

# Publish immutable package bytes first. Clients cannot observe a metadata
# pointer to a package that has not reached the origin yet.
for file in "${repository_packages[@]}"; do
  relative="${file#"$repository_root"/}"
  put_object "$file" "linux/$relative" 'public, max-age=31536000, immutable'
done

# Leaf metadata precedes signed pointer metadata. Root closure documents are
# last so an observer never sees a new closure before every referenced byte.
for file in \
  "${repository_metadata[@]}" \
  "${repository_pointer_signatures[@]}" \
  "${repository_pointer_documents[@]}" \
  "${repository_root_signatures[@]}" \
  "${repository_root_documents[@]}"; do
  relative="${file#"$repository_root"/}"
  cache_control='public, max-age=60, must-revalidate'
  case "$relative" in
    */by-hash/*|rpm/*/*/repodata/*-*) cache_control='public, max-age=31536000, immutable' ;;
  esac
  put_object "$file" "linux/$relative" "$cache_control"
done

# Publish detached signatures before the mutable document they authenticates.
put_object "$signature" 'latest-linux.json.ed25519.sig' 'public, max-age=60, must-revalidate'
put_object "$feed" 'latest-linux.json' 'public, max-age=60, must-revalidate'

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
verify_public_byte() {
  local source="$1"
  local key="$2"
  local destination="$tmp_dir/${key//\//__}"
  local cache_bust="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
  for attempt in 1 2 3 4 5 6; do
    if curl -fsS \
      -H 'Cache-Control: no-cache' \
      "$public_base_url/$key?openburnbar_verify=$cache_bust" \
      -o "$destination" \
      && cmp "$source" "$destination"; then
      return 0
    fi
    if [[ "$attempt" -eq 6 ]]; then
      echo "published Linux object did not match origin bytes: $key" >&2
      exit 1
    fi
    sleep 10
  done
}

for file in \
  "${release_artifacts[@]}" \
  "${release_signatures[@]}" \
  "${repository_packages[@]}" \
  "${repository_metadata[@]}" \
  "${repository_pointer_signatures[@]}" \
  "${repository_pointer_documents[@]}" \
  "${repository_root_signatures[@]}" \
  "${repository_root_documents[@]}"; do
  if [[ "$file" == "$repository_root"/* ]]; then
    relative="${file#"$repository_root"/}"
    verify_public_byte "$file" "linux/$relative"
  else
    verify_public_byte "$file" "$release_prefix/$(basename "$file")"
  fi
done
verify_public_byte "$signature" 'latest-linux.json.ed25519.sig'
verify_public_byte "$feed" 'latest-linux.json'

openssl pkeyutl -verify \
  -pubin \
  -inkey "$public_key" \
  -rawin \
  -in "$tmp_dir/latest-linux.json" \
  -sigfile "$tmp_dir/${release_prefix//\//__}__latest-linux.json.ed25519.sig"
node scripts/linux-port/check-linux-update-feed.mjs --url "$public_base_url/latest-linux.json"

echo "Linux release assets, apt/RPM repositories, and update feed published and byte-verified at $public_base_url"
