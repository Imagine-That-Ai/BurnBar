#!/usr/bin/env bash
# Smoke Firebase Hosting after deploy: public hosts must return 200, expected
# page text, and a Content-Security-Policy header.
set -euo pipefail

RETRIES="${HOSTING_SMOKE_RETRIES:-8}"
SLEEP_SEC="${HOSTING_SMOKE_SLEEP_SEC:-10}"
DEPLOYMENT_IDENTITY_FILE=""
RUNTIME_MANIFEST_FILE=""
trap '[[ -z "$DEPLOYMENT_IDENTITY_FILE" ]] || rm -f "$DEPLOYMENT_IDENTITY_FILE"; [[ -z "$RUNTIME_MANIFEST_FILE" ]] || rm -f "$RUNTIME_MANIFEST_FILE"' EXIT

check_target() {
  local label="$1"
  local url="$2"
  local marker="$3"
  local attempt=1
  local body_file header_file http_code csp
  body_file="$(mktemp)"
  header_file="$(mktemp)"
  trap 'rm -f "$body_file" "$header_file"' RETURN

  while [[ "$attempt" -le "$RETRIES" ]]; do
    : > "$body_file"
    : > "$header_file"
    http_code="$(curl -L -sS -D "$header_file" -o "$body_file" -w "%{http_code}" "$url" 2>/dev/null || echo "000")"
    csp="$(grep -i '^content-security-policy:' "$header_file" | tail -n 1 | sed 's/\r$//' || true)"
    if [[ "$http_code" == "200" ]] && grep -qi "$marker" "$body_file" && [[ "$csp" == *"default-src"* ]]; then
      echo "OK ${label}: ${url}"
      echo "${csp}"
      return 0
    fi
    echo "waiting for ${label} ${url} (HTTP ${http_code}, marker=${marker}, csp=${csp:+present}, attempt ${attempt}/${RETRIES})..." >&2
    sleep "$SLEEP_SEC"
    attempt=$((attempt + 1))
  done

  echo "FAIL: ${label} hosting smoke failed for ${url}" >&2
  echo "HTTP: ${http_code}" >&2
  echo "CSP: ${csp:-missing}" >&2
  echo "Body snippet:" >&2
  head -c 400 "$body_file" >&2 || true
  echo >&2
  return 1
}

check_console_deployment_identity() {
  local url="$1"
  local expected_commit="$2"
  local expected_tag="$3"
  local profile_receipt="$4"
  local release_gate="$5"
  local attempt=1
  local body_file http_code
  local -a args
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' RETURN

  while [[ "$attempt" -le "$RETRIES" ]]; do
    : > "$body_file"
    # Do not follow redirects: another origin cannot satisfy production proof.
    http_code="$(curl -sS -o "$body_file" -w "%{http_code}" "$url" 2>/dev/null || echo "000")"
    args=(
      --consumer console
      --commit "$expected_commit"
      --profile-receipt "$profile_receipt"
    )
    [[ -z "$expected_tag" ]] || args+=(--tag "$expected_tag")
    [[ -z "$release_gate" ]] || args+=(--release-gate "$release_gate")
    if [[ "$http_code" == "200" ]] && node scripts/ci/create-domain-core-deployment-identity.mjs \
      "${args[@]}" --verify "$body_file" >/dev/null 2>&1; then
      DEPLOYMENT_IDENTITY_FILE="$(mktemp)"
      cp "$body_file" "$DEPLOYMENT_IDENTITY_FILE"
      echo "OK console deployment identity: ${url}"
      return 0
    fi
    echo "waiting for console deployment identity ${url} (HTTP ${http_code}, attempt ${attempt}/${RETRIES})..." >&2
    sleep "$SLEEP_SEC"
    attempt=$((attempt + 1))
  done

  echo "FAIL: console deployment identity does not match exact commit, tag, profile, and protected proof" >&2
  head -c 400 "$body_file" >&2 || true
  echo >&2
  return 1
}

check_console_runtime_artifact() {
  local base_url="$1"
  local expected_manifest="$2"
  local live_manifest manifest_files http_code
  live_manifest="$(mktemp)"
  manifest_files="$(mktemp)"
  trap 'rm -f "$live_manifest" "$manifest_files"' RETURN
  http_code="$(curl -sS -o "$live_manifest" -w "%{http_code}" "$base_url/domain-core-runtime-artifact-manifest.json" 2>/dev/null || echo "000")"
  [[ "$http_code" == "200" ]] || { echo "FAIL: Console runtime manifest returned HTTP $http_code" >&2; return 1; }
  cmp "$expected_manifest" "$live_manifest" \
    || { echo "FAIL: live Console runtime manifest differs from deployed immutable artifact" >&2; return 1; }
  if ! node - "$live_manifest" > "$manifest_files" <<'NODE'
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (manifest.schemaVersion !== 1 || manifest.manifestKind !== "domain-core-runtime-artifact" || manifest.consumer !== "console") throw new Error("invalid Console runtime manifest");
if (!Array.isArray(manifest.files) || manifest.files.length < 4) throw new Error("incomplete Console runtime manifest");
for (const file of manifest.files) {
  if (typeof file.path !== "string" || file.path.startsWith("/") || file.path.split("/").some((part) => !part || part === "." || part === "..") || !/^[0-9a-f]{64}$/.test(file.sha256)) throw new Error("unsafe Console runtime manifest file");
  process.stdout.write(`${file.path}\t${file.sha256}\n`);
}
NODE
  then
    echo "FAIL: invalid Console runtime manifest" >&2
    return 1
  fi
  while IFS=$'\t' read -r path expected_sha; do
    local body headers actual_sha location canonical_path
    body="$(mktemp)"
    headers="$(mktemp)"
    http_code="$(curl -sS -D "$headers" -o "$body" -w "%{http_code}" "$base_url/$path" 2>/dev/null || echo "000")"
    if [[ "$http_code" =~ ^30[1278]$ ]]; then
      location="$(awk 'tolower($1) == "location:" { sub(/\r$/, "", $2); print $2; exit }' "$headers")"
      canonical_path=""
      case "$path" in
        index.html) canonical_path="/" ;;
        */index.html) canonical_path="/${path%/index.html}" ;;
        *.html) canonical_path="/${path%.html}" ;;
      esac
      if [[ -z "$canonical_path" || "$location" != "$canonical_path" ]]; then
        rm -f "$body" "$headers"
        echo "FAIL: Console runtime file $path returned an unexpected redirect to ${location:-<missing>}" >&2
        return 1
      fi
      : > "$body"
      http_code="$(curl -sS -o "$body" -w "%{http_code}" "$base_url$canonical_path" 2>/dev/null || echo "000")"
    fi
    rm -f "$headers"
    [[ "$http_code" == "200" ]] || { rm -f "$body"; echo "FAIL: Console runtime file $path returned HTTP $http_code" >&2; return 1; }
    actual_sha="$(sha256sum "$body" | cut -d' ' -f1)"
    expected_file="$(dirname "$expected_manifest")/$path"
    if [[ "$actual_sha" != "$expected_sha" && "$path" == "robots.txt" ]]; then
      if ! node - "$body" "$expected_file" <<'NODE'
const fs = require("fs");
const [livePath, expectedPath] = process.argv.slice(2);
const live = fs.readFileSync(livePath, "utf8");
const expected = fs.readFileSync(expectedPath, "utf8");
if (!live.endsWith(expected)) process.exit(1);
const managedPrefix = live.slice(0, live.length - expected.length);
const beginMarker = "# BEGIN Cloudflare Managed content\n";
const endMarker = "\n# END Cloudflare Managed Content\n\n";
const beginIndex = managedPrefix.indexOf(beginMarker);
const endIndex = managedPrefix.lastIndexOf(endMarker);
// Cloudflare may prepend its legal content-signals preamble before the
// managed block. Require the block markers to be present and terminal, then
// validate the managed body itself for nested markers.
if (
  beginIndex < 0 ||
  endIndex < beginIndex ||
  endIndex + endMarker.length !== managedPrefix.length
) {
  process.exit(1);
}
const managedBody = managedPrefix.slice(
  beginIndex + beginMarker.length,
  endIndex,
);
if (
  managedBody.includes("# BEGIN Cloudflare Managed content") ||
  managedBody.includes("# END Cloudflare Managed Content")
) {
  process.exit(1);
}
NODE
      then
        rm -f "$body"
        echo "FAIL: live Console runtime file $path differs from manifest" >&2
        return 1
      fi
      echo "OK Console runtime file $path preserves exact app-owned suffix behind Cloudflare managed prefix"
    elif [[ "$actual_sha" != "$expected_sha" ]]; then
      rm -f "$body"
      echo "FAIL: live Console runtime file $path differs from manifest" >&2
      return 1
    fi
    rm -f "$body"
  done < "$manifest_files"
  RUNTIME_MANIFEST_FILE="$(mktemp)"
  cp "$live_manifest" "$RUNTIME_MANIFEST_FILE"
  echo "OK Console runtime manifest and every domain-core WASM/JS byte"
}

check_target "marketing" "${OPENBURNBAR_MARKETING_URL:-https://burnbar.ai/}" "${OPENBURNBAR_MARKETING_MARKER:-BurnBar}"
check_target "console" "${OPENBURNBAR_CONSOLE_URL:-https://app.burnbar.ai/}" "${OPENBURNBAR_CONSOLE_MARKER:-BurnBar}"
if [[ -n "${HOSTING_SMOKE_EXPECTED_COMMIT:-}" ]]; then
  if [[ -z "${HOSTING_SMOKE_PROFILE_RECEIPT:-}" ]]; then
    echo "FAIL: exact Console identity verification requires HOSTING_SMOKE_PROFILE_RECEIPT" >&2
    exit 1
  fi
  check_console_deployment_identity \
    "${OPENBURNBAR_CONSOLE_IDENTITY_URL:-https://app.burnbar.ai/domain-core-deployment-identity.json}" \
    "$HOSTING_SMOKE_EXPECTED_COMMIT" \
    "${HOSTING_SMOKE_EXPECTED_TAG:-}" \
    "$HOSTING_SMOKE_PROFILE_RECEIPT" \
    "${HOSTING_SMOKE_RELEASE_GATE:-}"
  if [[ -z "${HOSTING_SMOKE_RUNTIME_MANIFEST:-}" ]]; then
    echo "FAIL: exact Console identity verification requires HOSTING_SMOKE_RUNTIME_MANIFEST" >&2
    exit 1
  fi
  check_console_runtime_artifact \
    "${OPENBURNBAR_CONSOLE_URL:-https://app.burnbar.ai}" \
    "$HOSTING_SMOKE_RUNTIME_MANIFEST"
fi

# Feed enforcement knob (OPENBURNBAR_REQUIRE_DOWNLOAD_FEED):
#   warn (default) — a 404 (no published release/asset yet) emits a GitHub
#     warning annotation and does NOT fail the smoke. Every other failure mode
#     (unreachable host, 5xx, 200 with wrong/unsigned content) still fails.
#   1|true|require|enforce — fail-closed: the feed must be live, signed, and
#     well-formed. Flip the repo variable to this once the first release has
#     published the feed assets.
feed_enforcement_enabled() {
  case "$(printf "%s" "${OPENBURNBAR_REQUIRE_DOWNLOAD_FEED:-warn}" | tr '[:upper:]' '[:lower:]')" in
    1|true|require|enforce) return 0 ;;
    *) return 1 ;;
  esac
}

check_download_artifact() {
  local label="$1"
  local url="$2"
  local marker="$3"
  local attempt=1
  local body_file http_code
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' RETURN

  while [[ "$attempt" -le "$RETRIES" ]]; do
    : > "$body_file"
    http_code="$(curl -L -sS -o "$body_file" -w "%{http_code}" "$url" 2>/dev/null || echo "000")"
    if [[ "$http_code" == "200" ]] && grep -Eq "$marker" "$body_file"; then
      echo "OK ${label}: ${url}"
      return 0
    fi
    if [[ "$http_code" == "404" ]] && ! feed_enforcement_enabled; then
      # A 404 from the releases feed is conclusive (no release/asset yet) —
      # don't burn retries. Annotate loudly so the gap stays visible.
      echo "::warning::${label} feed is not published yet (HTTP 404 at ${url}). Tolerated until the first release ships; set repo variable OPENBURNBAR_REQUIRE_DOWNLOAD_FEED=1 to enforce fail-closed."
      echo "WARN ${label}: ${url} returned 404 (no published release yet)" >&2
      return 0
    fi
    echo "waiting for ${label} ${url} (HTTP ${http_code}, marker=${marker}, attempt ${attempt}/${RETRIES})..." >&2
    sleep "$SLEEP_SEC"
    attempt=$((attempt + 1))
  done

  echo "FAIL: ${label} download smoke failed for ${url}" >&2
  echo "HTTP: ${http_code}" >&2
  echo "Body snippet:" >&2
  head -c 400 "$body_file" >&2 || true
  echo >&2
  return 1
}

# The mac update feed smoke always runs; whether a missing feed fails the
# deploy is governed by OPENBURNBAR_REQUIRE_DOWNLOAD_FEED (see above).
download_values="$(
  node - <<'NODE'
const fs = require("fs");
const source = fs.readFileSync("website/src/data/site.ts", "utf8");
const read = (name, fallback = "") => {
  const match = source.match(new RegExp(`${name}:\\s*"([^"]*)"`));
  return match?.[1] ?? fallback;
};
console.log(read("macDownloadBaseUrl"));
console.log(read("macUpdateBaseUrl", ""));
console.log(read("macUpdateFeedFile", "latest-macos.json"));
console.log(read("macAppcastFile", "appcast.xml"));
NODE
)"
update_base_url="$(printf "%s\n" "$download_values" | sed -n "2p" | sed 's:/*$::')"
latest_file="$(printf "%s\n" "$download_values" | sed -n "3p")"
appcast_file="$(printf "%s\n" "$download_values" | sed -n "4p")"
if [[ -n "$update_base_url" ]]; then
  check_download_artifact "mac latest feed" "$update_base_url/$latest_file" '"sparkleEdSignature"[[:space:]]*:[[:space:]]*"[A-Za-z0-9+/=]+'
  check_download_artifact "mac appcast" "$update_base_url/$appcast_file" 'sparkle:edSignature="'
fi

if [[ -n "${CONSOLE_DEPLOY_HEALTH_JSON:-}" ]]; then
  if [[ -z "${HOSTING_SMOKE_EXPECTED_TAG:-}" || -z "$DEPLOYMENT_IDENTITY_FILE" || -z "$RUNTIME_MANIFEST_FILE" || -z "${HOSTING_DEPLOY_COORDINATES_JSON:-}" ]]; then
    echo "FAIL: Console release health evidence requires an exact stable tag, verified runtime manifest, and provider coordinates" >&2
    exit 1
  fi
  node - "$RUNTIME_MANIFEST_FILE" "$CONSOLE_DEPLOY_HEALTH_JSON" "$HOSTING_DEPLOY_COORDINATES_JSON" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const [manifestPath, outputPath, coordinatesJson] = process.argv.slice(2);
const bytes = fs.readFileSync(manifestPath);
const coordinates = JSON.parse(coordinatesJson);
if (coordinates.schemaVersion !== 1 || coordinates.project !== "burnbar" || !Array.isArray(coordinates.sites) || coordinates.sites.length !== 2) throw new Error("invalid Hosting provider coordinates");
const evidence = {
  provider: "firebase-hosting",
  project: "burnbar",
  environment: "production",
  status: "healthy",
  healthChecks: [
    "marketing-http-200-csp",
    "console-http-200-csp",
    "console-deployment-identity-no-redirect",
    "console-runtime-manifest-no-redirect",
    "console-runtime-files-sha256",
  ],
  deployedArtifact: {
    fileName: "domain-core-runtime-artifact-manifest.json",
    sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  },
  providerCoordinates: { sites: coordinates.sites.map(({ target, site, versionName, releaseName }) => ({ target, site, versionName, releaseName })) },
};
fs.writeFileSync(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, { flag: "wx", mode: 0o600 });
NODE
  echo "Wrote ${CONSOLE_DEPLOY_HEALTH_JSON}"
fi

echo "PASS: hosting smoke"
