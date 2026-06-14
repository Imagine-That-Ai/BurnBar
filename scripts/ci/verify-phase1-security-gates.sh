#!/usr/bin/env bash
# Structural proof that Phase 1 security-register code debt is wired:
# LB-1 monitoring plane, LB-2 update channel, SOTA attestation infrastructure.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_pattern() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if ! rg -q "$pattern" "$file"; then
    fail "${label}: expected pattern '${pattern}' in ${file}"
  fi
  echo "OK ${label}"
}

echo "==> LB-1 monitoring plane wiring"
require_pattern "nightly AGPL metadata decoupled" \
  'HEALTH_GATE_REQUIRE_SOURCE_METADATA: "0"' \
  .github/workflows/nightly-e2e.yml
require_pattern "ops-confidence AGPL metadata decoupled" \
  'HEALTH_GATE_REQUIRE_SOURCE_METADATA: "0"' \
  .github/workflows/ops-confidence.yml
require_pattern "extension npm ci in test matrix" \
  'npm ci --prefix extensions/openburnbar' \
  .github/actions/openburnbar-test-matrix/action.yml
require_pattern "per-lane ops failure dedupe" \
  'lane:\$\{lane\}' \
  .github/actions/ops-failure-issue/action.yml
require_pattern "nightly privileged-socket red-team" \
  'privileged-socket-redteam-ci\.sh' \
  .github/workflows/nightly-e2e.yml
require_pattern "uptime check definitions" \
  'OPS_UPTIME_CHECKS' \
  functions/scripts/ops-uptime-check-definitions.mjs
require_pattern "health gate availability/compliance split" \
  'HEALTH_GATE_REQUIRE_SOURCE_METADATA' \
  scripts/ci/post-deploy-health-gate.sh

echo "==> LB-2 direct-download update channel wiring"
require_pattern "release live feed verification job" \
  'verify-live-update-feed' \
  .github/workflows/release.yml
require_pattern "release EdDSA feed verification" \
  'SUPublicEDKey' \
  .github/workflows/release.yml
require_pattern "in-app EdDSA verifier tests" \
  'DirectDownloadArtifactVerifierTests' \
  AgentLensTests/Active/DirectDownloadArtifactVerifierTests.swift
require_pattern "Sparkle public key in Info.plist" \
  'SUPublicEDKey' \
  AgentLens/Resources/OpenBurnBar-Info.plist
require_pattern "appcast generator script" \
  'generate-macos-appcast' \
  scripts/generate-macos-appcast.mjs

echo "==> SOTA release attestation infrastructure"
require_pattern "cosign attest in release lane" \
  'cosign attest' \
  .github/workflows/release.yml
require_pattern "release attestation verifier script" \
  'gh attestation verify' \
  scripts/ci/verify-release-attestations.sh
bash -n scripts/ci/verify-release-attestations.sh

echo "==> SOTA phone-control attestation readiness (code)"
require_pattern "server attestation RC param" \
  'COMPUTER_USE_PHONE_CONTROL_ATTESTATION_REQUIRED_PARAM' \
  functions/src/computerUseRemoteConfig.ts
require_pattern "attestation binding tests" \
  'computer_use_phone_control_attestation_required' \
  functions/src/__tests__/appCheckAttestationBinding.test.ts
require_pattern "iOS attestation reader" \
  'MobileAppCheckAttestationReader' \
  OpenBurnBarMobile/Services/ComputerUse/MobileAppCheckAttestationReader.swift
require_pattern "Android attestation reader" \
  'AndroidAppCheckAttestationReader' \
  android/app/src/main/java/com/openburnbar/data/computeruse/AndroidAppCheckAttestationReader.kt
require_pattern "phone control attestation policy" \
  'PhoneControlAttestationPolicy' \
  OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PhoneControlAttestationPolicy.swift

echo "==> C-3 iOS Cloud Vault rotation survivor pickup (T-PTR-02)"
require_pattern "iOS mobile rotation chain" \
  'pickUpPendingCloudVaultRotations' \
  OpenBurnBarMobile/Services/MobileCloudVaultRevocationRotation.swift
require_pattern "iOS mobile pickup lifecycle" \
  'CloudVaultRotationPickupLifecycle\.install' \
  OpenBurnBarMobile/App/AppDelegate.swift
require_pattern "iOS mobile pickup lifecycle service" \
  'UIApplication\.didBecomeActiveNotification' \
  OpenBurnBarMobile/Services/CloudVaultRotationPickupLifecycle.swift
require_pattern "iOS mobile post-revoke pickup trigger" \
  'openBurnBarDidRevokeDeviceTrust' \
  OpenBurnBarMobile/Services/LiveCloudReader.swift
require_pattern "iOS mobile post-revoke pickup observer" \
  'openBurnBarDidRevokeDeviceTrust' \
  OpenBurnBarMobile/Services/CloudVaultRotationPickupLifecycle.swift
require_pattern "iOS mobile list callable callerDeviceId" \
  'callerDeviceId' \
  OpenBurnBarMobile/Services/MobileCloudVaultRevocationRotation.swift
require_pattern "iOS mobile rotation pickup tests" \
  'MobileCloudVaultRotationPickupTests' \
  OpenBurnBarMobileTests/MobileCloudVaultRotationPickupTests.swift
require_pattern "Mac list callable callerDeviceId" \
  'listPendingCallablePayload' \
  AgentLens/Services/ComputerUse/ComputerUseSecurityCallableClient.swift
require_pattern "Android list callable callerDeviceId" \
  'callerDeviceId' \
  android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSecurityCallableClient.kt

echo "PASS: Phase 1 security gates structurally wired"