/**
 * @fileoverview Computer Use / escrow high-risk callables (WS4 cloud defense-in-depth).
 *
 * Trust elevation and grant-adjacent mutations route through App-Check-enforced
 * callables with attestation-bound Auth custom claims instead of direct client
 * Firestore writes to `trustState: trusted`.
 *
 * U6 split: this module is now a thin aggregator. The callables, codecs, crypto,
 * and Firestore-bound helpers live in sibling modules and are re-exported here so
 * every existing `import ... from "./computerUseSecurity.js"` keeps resolving
 * byte-identically. Editing behavior happens in the sibling modules.
 */

import {
  P256_X963_PUBLIC_KEY_BYTE_LENGTH,
  TRUSTED_DEVICE_ACTION_PROOF_DOMAIN,
  parseTrustedDeviceActionProof,
  verifyEd25519RawSignature,
  verifyPhoneControlAuthoritySignature,
} from "./computerUseSecurityCodecs.js";
import {
  CLOUD_VAULT_DEVICE_TRUST_CHAIN_DOMAIN,
  ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED,
  agentGrantAuthoritySignablePayload,
  agentGrantLocalAuthProofSignablePayload,
  agentGrantRequestHashHex,
  buildCloudVaultDeviceTrustChainCanonicalBytes,
  buildTrustedDeviceActionCanonicalBytes,
  canonicalAgentGrantRequestJSON,
  evaluateEscrowFingerprintBinding,
  montgomeryUToCompressedEdwards,
  parseAgentGrantLocalAuthProof,
  queuedAgentGrantDeliveryRequiresMacApproval,
  queuedAgentGrantRequiresLocalAuthProof,
  queuedAgentGrantRequiresMacApproval,
  recomputeEscrowFingerprint,
  verifyAgentGrantLocalAuthProof,
  verifyCloudVaultDeviceTrustChainSignature,
  verifyTrustedDeviceActionSignature,
  verifyXEdDSACurve25519Signature,
} from "./computerUseSecurityCrypto.js";
import { requireTrustedDeviceActionProof } from "./computerUseSecurityFirestore.js";

export { requireTrustedDeviceActionProof } from "./computerUseSecurityFirestore.js";
export {
  bindAppCheckAttestation,
  issueHighRiskActionNonce,
  registerEscrowDevice,
  approveEscrowDeviceTrust,
  revokeEscrowDeviceTrust,
} from "./escrowDeviceCallables.js";
export {
  publishIrohPairingPublicKey,
  publishIrohPairingRecord,
  revokeIrohPairingRecord,
  publishPhoneControlAuthority,
  publishRelaySenderKey,
} from "./phoneControlCallables.js";
export { publishAgentGrantAuthority } from "./agentGrantAuthorityCallable.js";
export {
  issueIrohControllerRouteChallenge,
  registerIrohControllerRoute,
  revokeIrohControllerRoute,
  resolveActiveIrohControllerRoutes,
} from "./irohControllerRouteCallables.js";
export { queueAgentCapabilityGrantRequest, respondMissionApproval } from "./agentGrantCallables.js";

/**
 * Test-only surface for the pure Stream 6 fingerprint-binding helpers (no
 * Firestore). The capability flag is exposed read-only so tests can assert it
 * ships OFF (inert) without flipping production behavior.
 */
export const __testing__ = {
  ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED,
  P256_X963_PUBLIC_KEY_BYTE_LENGTH,
  recomputeEscrowFingerprint,
  evaluateEscrowFingerprintBinding,
  canonicalAgentGrantRequestJSON,
  agentGrantRequestHashHex,
  agentGrantAuthoritySignablePayload,
  agentGrantLocalAuthProofSignablePayload,
  parseAgentGrantLocalAuthProof,
  verifyAgentGrantLocalAuthProof,
  queuedAgentGrantRequiresLocalAuthProof,
  queuedAgentGrantRequiresMacApproval,
  queuedAgentGrantDeliveryRequiresMacApproval,
  verifyEd25519RawSignature,
  verifyPhoneControlAuthoritySignature,
  buildCloudVaultDeviceTrustChainCanonicalBytes,
  buildTrustedDeviceActionCanonicalBytes,
  verifyXEdDSACurve25519Signature,
  verifyCloudVaultDeviceTrustChainSignature,
  verifyTrustedDeviceActionSignature,
  parseTrustedDeviceActionProof,
  requireTrustedDeviceActionProof,
  montgomeryUToCompressedEdwards,
  CLOUD_VAULT_DEVICE_TRUST_CHAIN_DOMAIN,
  TRUSTED_DEVICE_ACTION_PROOF_DOMAIN,
};
