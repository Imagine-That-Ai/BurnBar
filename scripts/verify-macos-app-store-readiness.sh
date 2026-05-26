#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

derived_data="${OPENBURNBAR_MAS_DERIVED_DATA:-build/macos-app-store-readiness-derived}"
log_path="${OPENBURNBAR_MAS_LOG_PATH:-/tmp/openburnbar-macos-app-store-readiness.log}"
entitlements="AgentLens/Resources/OpenBurnBarMAS.entitlements"
direct_entitlements="AgentLens/Resources/OpenBurnBarRelease.entitlements"

require_entitlement_bool() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: $file must set $key to $expected; found '${actual:-missing}'." >&2
    exit 1
  fi
}

if [[ ! -f "$entitlements" ]]; then
  echo "ERROR: Missing Mac App Store entitlements at $entitlements." >&2
  exit 1
fi

require_entitlement_bool "$entitlements" "com.apple.security.app-sandbox" "true"
require_entitlement_bool "$entitlements" "com.apple.security.network.client" "true"

if [[ -f "$direct_entitlements" ]]; then
  require_entitlement_bool "$direct_entitlements" "com.apple.security.app-sandbox" "false"
fi

if [[ "${OPENBURNBAR_MAS_CLEAN:-1}" == "1" ]]; then
  rm -rf "$derived_data"
fi
mkdir -p "$(dirname "$log_path")"

set -o pipefail
xcodebuild build \
  -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="$entitlements" \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) DISTRIBUTION_MAS=1' \
  OTHER_SWIFT_FLAGS='$(inherited) -D DISTRIBUTION_MAS' \
  2>&1 | tee "$log_path" | tail -120

echo "Mac App Store readiness build passed."
echo "Log: $log_path"
