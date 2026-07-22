#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-appcheck-provider-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin"

cat > "$fixture/bin/gcloud" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "projects describe") printf '246956661961\n' ;;
  "auth print-access-token") printf 'fixture-access-token\n' ;;
  *) exit 2 ;;
esac
SH

cat > "$fixture/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
  */services/firestore.googleapis.com)
    printf '{"enforcementMode":"ENFORCED"}\n'
    ;;
  */services/firebasestorage.googleapis.com)
    printf '{"enforcementMode":"ENFORCED"}\n'
    ;;
  */deviceCheckConfig)
    if [[ "${MOCK_DEVICECHECK_CONFIG:-missing}" == "configured" ]]; then
      printf '{"keyId":"DEVICE1234","privateKeySet":true,"tokenTtl":"3600s"}\n'
    else
      printf '{"tokenTtl":"3600s"}\n'
    fi
    ;;
  *) exit 22 ;;
esac
SH

chmod +x "$fixture/bin/gcloud" "$fixture/bin/curl"

common_env=(
  env -i
  HOME="${HOME}"
  PATH="$fixture/bin:/usr/bin:/bin"
  OPENBURNBAR_FIREBASE_PROJECT=burnbar
)

if "${common_env[@]}" bash "$repo_root/scripts/ops/verify-firestore-app-check-enforcement.sh" \
  >"$fixture/missing.out" 2>"$fixture/missing.err"; then
  echo "expected missing DeviceCheck credentials to fail" >&2
  exit 1
fi
grep -Fq 'Apple DeviceCheck provider is incomplete' "$fixture/missing.err"

"${common_env[@]}" MOCK_DEVICECHECK_CONFIG=configured \
  bash "$repo_root/scripts/ops/verify-firestore-app-check-enforcement.sh" \
  >"$fixture/configured.out" 2>"$fixture/configured.err"
grep -Fq 'PASS: Apple DeviceCheck provider has a key' "$fixture/configured.out"

echo "PASS: App Check verifier rejects missing DeviceCheck credentials and accepts a complete provider."
