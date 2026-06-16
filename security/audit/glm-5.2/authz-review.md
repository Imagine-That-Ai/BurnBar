# Authentication, Authorization, and Identity Review

## F.1 Auth Architecture

### Firebase Auth (Primary)
- **Providers:** Google, Apple, Passkeys (`@simplewebauthn/server`)
- **Token lifecycle:** Firebase SDK manages ID token (~1hr) and refresh token
- **Session:** Client-side only; no server-side session store

### App Check
- **Enforcement:** `assertAppCheck()` on callables; `enforceAppCheck: true` in production
- **Attestation binding:** High-risk callables require `obb_app_check` custom claim matching live `request.app.appId`
- **Max age:** 30 days (`APP_CHECK_ATTESTATION_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000`)
- **Firestore:** Console-only enforcement (rules do NOT use `request.app`) — documented limitation

### High-Risk Nonce
- **Evidence:** `appCheckAttestation.ts:enforceHighRiskComputerUseCallableWithNonce`
- **Flow:** Client calls `issueHighRiskActionNonce` -> server stores single-use nonce (2-min TTL) -> client presents nonce + attestation proof -> server consumes nonce
- **Endpoints using this:** `approveEscrowDeviceTrust`, `revokeEscrowDeviceTrust`, `publishPhoneControlAuthority`, `respondMissionApproval`, `respondHermesGatewayApproval`, CLI link operations

## F.2 Authorization Matrix (Key Endpoints)

| Endpoint | Trigger | Auth | Ownership Check | App Check | BOLA Test |
|----------|---------|------|-----------------|-----------|-----------|
| `connectProviderAccount` | callable | `assertAuth` | `assertOwnership(request, uid)` | required | `providerAccounts.bola.test.ts` |
| `deleteProviderAccount` | callable | `assertAuth` | `assertOwnership(request, uid)` | required | `providerAccounts.bola.test.ts` |
| `deleteUserCloudData` | callable | `assertAuth` | `assertOwnership(request, uid)` | required | `providerAccounts.bola.test.ts` |
| `approveEscrowDeviceTrust` | callable | `enforceHighRiskComputerUseCallableWithNonce` | ownership + nonce | required+attestation | `computerUse.bola.test.ts` |
| `revokeEscrowDeviceTrust` | callable | `enforceHighRiskComputerUseCallableWithNonce` | ownership + nonce | required+attestation | `computerUse.bola.test.ts` |
| `rotateCloudVaultKey` | callable | `assertAuth` | ownership + attestation | required | `cloudVault.bola.test.ts` |
| `burnBarHermesGateway` | callable | PoP envelope | token-bound identity | required | `hermesGateway.bola.test.ts` |
| `triggerVoIPCall` | callable | `assertAuth` | `assertOwnership(request, data.targetUid)` | required | `voipPush.bola.test.ts` |
| `stripeBurnBarProWebhook` | http | Stripe signature | N/A (webhook) | N/A | `stripeWebhookOrdering.test.ts` |
| `exportUserData` | callable | `assertAuth` | ownership | required | `bola/encryptedSearch.bola.test.ts` |
| `issueRemoteMcpGrant` | callable | `assertAuth` | ownership | required | `remoteMcp.bola.test.ts` |
| `searchEncryptedConversationIndex` | callable | `assertAuth` | ownership | required | `encryptedSearch.bola.test.ts` |
| `beginEncryptedSessionBlobUpload` | callable | `assertAuth` | ownership + path validation | required | `encryptedSearch.bola.test.ts` |

**BOLA coverage completeness:** `bolaCoverage.test.ts` validates that `endpointAuthorizationMatrix` covers every export in `index.ts`. Tests verify >=60 tier-2 victim-seeded isolation endpoints and >=5 P0 runtime cross-tenant proofs.

## F.3 Object-Level Authorization

### Firestore Rules (uid isolation)
Every collection under `users/{userId}/` enforces `ownsUserNamespace(userId)` which checks `request.auth.uid == userId`. This is consistent across all collections enumerated in the rules header comment.

### Callable Ownership
Every callable that accepts a `uid` parameter calls `assertOwnership(request, expectedUid)` which verifies `request.auth.uid === expectedUid`.

### Object-ID Authorization
Callables that accept object IDs (accountId, sessionId, connectionId) fetch the object from Firestore and verify the caller owns it before proceeding. BOLA tests prove this with victim-tenant seeding.

### Workspace Isolation
`callerOwnsWorkspacePath` is restored (M-024 fix) and enforces that workspaces paths match the caller's uid.

### Avatar Access
`storage.rules` now enforces owner-only avatar read (M-017 fix). Previously any authenticated user could read avatars.

## F.4 Specific Tests Verified

| Test | What It Covers | Status |
|------|---------------|--------|
| `bola/*.bola.test.ts` (21 files) | Cross-tenant authorization for all callables | Verified in CI |
| `bolaCoverage.test.ts` | Matrix completeness vs `index.ts` exports | CI-enforced |
| `endpointAuthorizationMatrix.test.ts` | Every endpoint has auth fields | CI-enforced |
| `phoneControlPairingBinding.test.ts` | Phone B cannot hijack phone A's pairing | Verified |
| `computerUse.bola.test.ts` | Computer use session userId isolation | Verified |
| `cloudVault.bola.test.ts` | Vault key rotation ownership | Verified |
| `hermesGateway.bola.test.ts` | Gateway client isolation | Verified |
| `escrowDeviceTrustChainSignature.test.ts` | Trust chain signature forgery | Verified |
| `trustedDeviceActionProof.test.ts` | Trusted device proof verification | Verified |

## F.5 Gaps

1. **FINDING-007:** App Check attestation max-age is 30 days — a stolen device retains high-risk callable access for up to 30 days between re-attestation
2. **Firestore App Check gap:** Firestore rules do not use `request.app`; enforcement is console-only. A non-app client with a valid Auth token could read Firestore directly (if App Check enforcement is not toggled in console).
3. **No admin panel:** No admin-only callable surface was found (correct for this product). Admin operations are Cloud Console / gcloud only.
