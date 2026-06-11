#!/usr/bin/env bash
# Smoke Firebase Hosting after deploy: public hosts must return 200, expected
# page text, and a Content-Security-Policy header.
set -euo pipefail

RETRIES="${HOSTING_SMOKE_RETRIES:-8}"
SLEEP_SEC="${HOSTING_SMOKE_SLEEP_SEC:-10}"

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

check_target "marketing" "${OPENBURNBAR_MARKETING_URL:-https://burnbar.ai/}" "${OPENBURNBAR_MARKETING_MARKER:-BurnBar}"
check_target "console" "${OPENBURNBAR_CONSOLE_URL:-https://app.burnbar.ai/}" "${OPENBURNBAR_CONSOLE_MARKER:-BurnBar}"

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

if [[ "${OPENBURNBAR_SKIP_DOWNLOAD_FEED_SMOKE:-0}" != "1" ]]; then
  download_values="$(
    node - <<'NODE'
const fs = require("fs");
const source = fs.readFileSync("website/src/data/site.ts", "utf8");
const read = (name, fallback = "") => {
  const match = source.match(new RegExp(`${name}:\\s*"([^"]+)"`));
  return match?.[1] ?? fallback;
};
console.log(read("macDownloadBaseUrl"));
console.log(read("macUpdateBaseUrl", read("macDownloadBaseUrl")));
console.log(read("macUpdateFeedFile", "latest-macos.json"));
console.log(read("macAppcastFile", "appcast.xml"));
NODE
  )"
  download_base_url="$(printf "%s\n" "$download_values" | sed -n "1p" | sed 's:/*$::')"
  update_base_url="$(printf "%s\n" "$download_values" | sed -n "2p" | sed 's:/*$::')"
  latest_file="$(printf "%s\n" "$download_values" | sed -n "3p")"
  appcast_file="$(printf "%s\n" "$download_values" | sed -n "4p")"
  if [[ -n "$update_base_url" ]]; then
    check_download_artifact "mac latest feed" "$update_base_url/$latest_file" '"sparkleEdSignature"[[:space:]]*:[[:space:]]*"[A-Za-z0-9+/=]+'
    check_download_artifact "mac appcast" "$update_base_url/$appcast_file" 'sparkle:edSignature="'
  fi
fi

echo "PASS: hosting smoke"
