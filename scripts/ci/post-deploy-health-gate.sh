#!/usr/bin/env bash
# Post-deploy gate for Cloud Functions (production).
#
# Two independent signals (diligence 2026-06-11: conflating them made the
# nightly synthetic read "prod DOWN" for a compliance-metadata gap while both
# endpoints returned healthy 200s, guaranteeing red monitoring):
#   1. AVAILABILITY — status fields on healthLive/healthReady. Always fatal.
#   2. COMPLIANCE  — AGPL sourceMetadata in the health bodies. Fatal when
#      HEALTH_GATE_REQUIRE_SOURCE_METADATA=1 (the default, correct for
#      post-deploy lanes where the new code must serve it); a loud warning
#      when 0 (synthetic monitoring lanes, until the metadata-serving deploy
#      reaches prod — flip those lanes to 1 right after).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/ops/resolve-functions-base-url.sh
source "${ROOT}/scripts/ops/resolve-functions-base-url.sh"

RETRIES="${HEALTH_GATE_RETRIES:-12}"
SLEEP_SEC="${HEALTH_GATE_SLEEP_SEC:-10}"
LAST_HTTP_CODE=""
LAST_URL=""
LAST_BODY_SNIPPET=""
EXPECTED_SOURCE_URL="${OPENBURNBAR_CORRESPONDING_SOURCE_URL:-https://burnbar.ai/legal/source}"
REQUIRE_SOURCE_METADATA="${HEALTH_GATE_REQUIRE_SOURCE_METADATA:-1}"
SOURCE_METADATA_WARNINGS=0

source_metadata_ok() {
  local body_file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e \
      --arg sourceUrl "$EXPECTED_SOURCE_URL" \
      '.license == "AGPL-3.0-only"
        and .source.correspondingSource == $sourceUrl
        and (.source.repository | type == "string" and length > 0)
        and (.source.commit | type == "string" and length > 0)' \
      "$body_file" >/dev/null 2>&1
    return $?
  fi

  grep -q '"license"[[:space:]]*:[[:space:]]*"AGPL-3.0-only"' "$body_file" \
    && grep -q '"correspondingSource"[[:space:]]*:[[:space:]]*"'"$EXPECTED_SOURCE_URL"'"' "$body_file" \
    && grep -q '"repository"[[:space:]]*:[[:space:]]*"[^"]\+"' "$body_file" \
    && grep -q '"commit"[[:space:]]*:[[:space:]]*"[^"]\+"' "$body_file"
}

curl_health() {
  local label="$1"
  local url="$2"
  local expect_field="${3:-}"
  local snapshot_path="${4:-}"
  local attempt=1
  while [[ "$attempt" -le "$RETRIES" ]]; do
    LAST_URL="$url"
    local body_file="/tmp/ob-health.json"
    LAST_HTTP_CODE="$(curl -sS -o "$body_file" -w "%{http_code}" "$url" 2>/dev/null || echo "000")"
    if [[ "$LAST_HTTP_CODE" == "200" ]]; then
      if [[ -n "$expect_field" ]]; then
        local ok=false
        if command -v jq >/dev/null 2>&1 && jq -e "$expect_field" "$body_file" >/dev/null 2>&1; then
          ok=true
        elif [[ "$expect_field" == '.status == "alive"' ]] && grep -q '"status"[[:space:]]*:[[:space:]]*"alive"' "$body_file"; then
          ok=true
        elif [[ "$expect_field" == '.status == "ready"' ]] && grep -q '"status"[[:space:]]*:[[:space:]]*"ready"' "$body_file"; then
          ok=true
        fi
        if [[ "$ok" == true ]]; then
          if source_metadata_ok "$body_file"; then
            echo "OK ${label} (attempt ${attempt})"
          elif [[ "$REQUIRE_SOURCE_METADATA" != "1" ]]; then
            # Availability is healthy; compliance metadata is missing. Loud,
            # not red: a metadata gap must never be indistinguishable from an
            # outage in the monitoring lanes.
            echo "::warning title=AGPL source metadata missing::${label} is healthy but does not serve AGPL sourceMetadata yet (deploy pending). Flip HEALTH_GATE_REQUIRE_SOURCE_METADATA=1 once the metadata-serving functions deploy reaches prod."
            SOURCE_METADATA_WARNINGS=$((SOURCE_METADATA_WARNINGS + 1))
            echo "OK ${label} — availability only (attempt ${attempt})"
          else
            LAST_BODY_SNIPPET="$(head -c 256 "$body_file" 2>/dev/null || true)"
            echo "waiting for ${label} ${url} (healthy but missing AGPL sourceMetadata, attempt ${attempt}/${RETRIES})..." >&2
            sleep "$SLEEP_SEC"
            attempt=$((attempt + 1))
            continue
          fi
          cat "$body_file"
          if [[ -n "$snapshot_path" ]]; then
            cp "$body_file" "$snapshot_path"
          fi
          return 0
        fi
        LAST_BODY_SNIPPET="$(head -c 256 "$body_file" 2>/dev/null || true)"
      else
        echo "OK ${label} HTTP ${LAST_HTTP_CODE} (attempt ${attempt})"
        cat "$body_file"
        return 0
      fi
    else
      LAST_BODY_SNIPPET="$(head -c 256 "$body_file" 2>/dev/null || true)"
    fi
    echo "waiting for ${label} ${url} (HTTP ${LAST_HTTP_CODE}, attempt ${attempt}/${RETRIES})..." >&2
    sleep "$SLEEP_SEC"
    attempt=$((attempt + 1))
  done
  echo "FAIL: ${label} did not pass health gate (last URL=${LAST_URL}, HTTP=${LAST_HTTP_CODE})" >&2
  if [[ -n "$LAST_BODY_SNIPPET" ]]; then
    echo "last response snippet: ${LAST_BODY_SNIPPET}" >&2
  fi
  return 1
}

echo "==> healthLive (${FUNCTIONS_HEALTH_LIVE_URL})"
curl_health "healthLive" "$FUNCTIONS_HEALTH_LIVE_URL" '.status == "alive"' /tmp/ob-health-live.json

echo "==> healthReady (${FUNCTIONS_HEALTH_READY_URL})"
curl_health "healthReady" "$FUNCTIONS_HEALTH_READY_URL" '.status == "ready"' /tmp/ob-health-ready.json

if [[ -n "${DEPLOY_HEALTH_JSON:-}" ]]; then
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg generatedAt "$generated_at" \
      --arg project "$FIREBASE_PROJECT" \
      --arg region "$FUNCTIONS_REGION" \
      --arg baseUrl "$FUNCTIONS_BASE_URL" \
      --arg healthLiveUrl "$FUNCTIONS_HEALTH_LIVE_URL" \
      --arg healthReadyUrl "$FUNCTIONS_HEALTH_READY_URL" \
      --arg tag "${DEPLOY_TAG:-}" \
      --slurpfile live /tmp/ob-health-live.json \
      --slurpfile ready /tmp/ob-health-ready.json \
      '{generatedAt: $generatedAt, project: $project, region: $region, baseUrl: $baseUrl, healthLiveUrl: $healthLiveUrl, healthReadyUrl: $healthReadyUrl, tag: $tag, healthLive: $live[0], healthReady: $ready[0]}' \
      > "$DEPLOY_HEALTH_JSON"
  else
    printf '%s\n' "{\"generatedAt\":\"$generated_at\",\"project\":\"$FIREBASE_PROJECT\",\"baseUrl\":\"$FUNCTIONS_BASE_URL\",\"tag\":\"${DEPLOY_TAG:-}\"}" > "$DEPLOY_HEALTH_JSON"
  fi
  echo "Wrote ${DEPLOY_HEALTH_JSON}"
fi

if [[ "$SOURCE_METADATA_WARNINGS" -gt 0 ]]; then
  echo "PASS: post-deploy health gate (availability only — ${SOURCE_METADATA_WARNINGS} surface(s) missing AGPL sourceMetadata, see warnings)"
else
  echo "PASS: post-deploy health gate"
fi
