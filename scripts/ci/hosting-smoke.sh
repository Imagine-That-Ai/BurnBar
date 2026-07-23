#!/usr/bin/env bash
# Smoke Firebase Hosting after deploy: public hosts must return 200, expected
# page text, and a Content-Security-Policy header.
set -euo pipefail

RETRIES="${HOSTING_SMOKE_RETRIES:-8}"
SLEEP_SEC="${HOSTING_SMOKE_SLEEP_SEC:-10}"
DEPLOYMENT_IDENTITY_FILE=""
trap '[[ -z "$DEPLOYMENT_IDENTITY_FILE" ]] || rm -f "$DEPLOYMENT_IDENTITY_FILE"' EXIT

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
  local attempt=1
  local body_file http_code
  local -a tag_args=()
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' RETURN

  while [[ "$attempt" -le "$RETRIES" ]]; do
    : > "$body_file"
    # The identity must come directly from the canonical Console URL. Following
    # redirects would allow another origin to satisfy the deployment proof.
    http_code="$(curl -sS -o "$body_file" -w "%{http_code}" "$url" 2>/dev/null || echo "000")"
    tag_args=()
    if [[ -n "$expected_tag" ]]; then
      tag_args=(--tag "$expected_tag")
    fi
    if [[ "$http_code" == "200" ]] && node scripts/ci/create-domain-core-deployment-identity.mjs \
      --consumer console \
      --commit "$expected_commit" \
      "${tag_args[@]}" \
      --verify "$body_file" >/dev/null 2>&1; then
      DEPLOYMENT_IDENTITY_FILE="$(mktemp)"
      cp "$body_file" "$DEPLOYMENT_IDENTITY_FILE"
      echo "OK console deployment identity: ${url}"
      return 0
    fi
    echo "waiting for console deployment identity ${url} (HTTP ${http_code}, attempt ${attempt}/${RETRIES})..." >&2
    sleep "$SLEEP_SEC"
    attempt=$((attempt + 1))
  done

  echo "FAIL: console deployment identity does not match commit ${expected_commit} and tag ${expected_tag:-<none>}" >&2
  echo "Body snippet:" >&2
  head -c 400 "$body_file" >&2 || true
  echo >&2
  return 1
}

check_target "marketing" "${OPENBURNBAR_MARKETING_URL:-https://burnbar.ai/}" "${OPENBURNBAR_MARKETING_MARKER:-BurnBar}"
check_target "console" "${OPENBURNBAR_CONSOLE_URL:-https://app.burnbar.ai/}" "${OPENBURNBAR_CONSOLE_MARKER:-BurnBar}"
if [[ -n "${HOSTING_SMOKE_EXPECTED_COMMIT:-}" ]]; then
  check_console_deployment_identity \
    "${OPENBURNBAR_CONSOLE_IDENTITY_URL:-https://app.burnbar.ai/domain-core-deployment-identity.json}" \
    "$HOSTING_SMOKE_EXPECTED_COMMIT" \
    "${HOSTING_SMOKE_EXPECTED_TAG:-}"
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
  if [[ -z "${HOSTING_SMOKE_EXPECTED_COMMIT:-}" || -z "${HOSTING_SMOKE_EXPECTED_TAG:-}" || -z "$DEPLOYMENT_IDENTITY_FILE" ]]; then
    echo "FAIL: console deploy health evidence requires an exact stable tag, commit, and verified live identity." >&2
    exit 1
  fi
  python3 - \
    "$DEPLOYMENT_IDENTITY_FILE" \
    "$CONSOLE_DEPLOY_HEALTH_JSON" \
    "$HOSTING_SMOKE_EXPECTED_COMMIT" \
    "$HOSTING_SMOKE_EXPECTED_TAG" <<'PY'
import json
import sys
from pathlib import Path

identity_path, output_path, commit, tag = sys.argv[1:]
identity = json.loads(Path(identity_path).read_text(encoding="utf-8"))
output = {
    "schemaVersion": 1,
    "project": "burnbar",
    "tag": tag,
    "commit": commit,
    "checks": {
        "marketing": "ok",
        "console": "ok",
        "deploymentIdentity": "ok",
    },
    "deploymentIdentity": identity,
}
Path(output_path).write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
PY
  echo "Wrote ${CONSOLE_DEPLOY_HEALTH_JSON}"
fi

echo "PASS: hosting smoke"
