# Authentication, Authorization & Identity Review — Opus 4.8 1M lane

Verdict: **Strong, machine-enforced.** No Critical/High/Medium findings. Object-level authorization is deterministically catalogued **and** tested.

## F.1 Identity & auth surfaces
- **Client auth:** Firebase Auth (Google + Apple Sign-In); OAuth tokens managed by Firebase SDK. Mobile escrow uses durable P-256 device keypairs (private keys in platform Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- **Callable auth+attestation:** `enforceAuthAndAppCheck(request, uid)` → `assertOwnership` (`functions/src/auth.ts:22-31,69-73`) enforces `request.auth.uid === expectedUid`. App Check `assertAppCheck` (`auth.ts:53-61`) with `enforceAppCheck` defaulting **true** in prod and **failing closed at startup** if a prod project disables it (`config.ts:385,392-398`).
- **High-risk callables:** `enforceHighRiskComputerUseCallable` (`appCheckAttestation.ts:139-144`) + single-use nonce replay defense `requireHighRiskNonce` (default true in prod, `config.ts:418-421`, `appCheckAttestation.ts:179-207`).

## F.2 Authorization matrix (representative)

| Resource | Operation | Allowed actor | Check location | Owner check | Tenant check | Tested |
|---|---|---|---|---|---|---|
| `users/{uid}/**` | write | owner | `firestore.rules:52-54,1436-1439` (`ownsUserNamespace`) | yes | yes | rules emulator |
| `workspaces/workspace-{uid}/.../artifacts` | r/w | owner | `firestore.rules:1349-1367,4411-4421` (`callerOwnsWorkspacePath`) | yes (doc `ownerUserID`) | yes (path==`workspace-`+uid) | rules emulator |
| `entitlements` / `entitlement_bindings` / `entitlement_events` | write | **none (server-only)** | `firestore.rules:3539-3559` (`write: if false`) | n/a | n/a | rules emulator |
| `usage_rollups`, `provider_account_secret_refs`, `_rate_limits`, `high_risk_action_nonces`, `rollup_jobs` | write | **server-only** | `firestore.rules:3482-3514,1373-1375,4450-4452` | n/a | n/a | rules emulator |
| `ops/**` budget/rollup metrics | read | `burnbarOperator` claim; write server-only | `firestore.rules:3243-3254,4431-4440` | n/a | n/a | rules emulator |
| All 150 callable/HTTP endpoints | invoke | per-catalog | `endpointAuthorizationCatalog.generated.ts` | per-entry | per-entry | tier-2 BOLA |

## F.3 Object-level authorization (BOLA/IDOR)
- **Deterministic catalog:** `endpointAuthorizationCatalog.generated.ts` has **150 entries** (generator `functions/scripts/generate-endpoint-catalog.mjs`).
- **Completeness:** `bolaCoverage.test.ts:44-49` asserts a strict bijection `matrixNames === exported` (every `index.ts` export has an authorization classification — none can be added without one).
- **Tier-2 runtime proofs:** 16 `*.bola.test.ts` (~69 cases) + harness `__tests__/bola/callableBolaHarness.ts:335-372` seed a victim tenant (Bob), invoke as attacker (Alice), and assert **both** a denial code **and** `expectTenantPathsUnchanged` (zero side-effect writes). The branch's "BOLA tier-2 migration" aligned validators (`bolaCoverageValidators.ts:65-94`) with the generator.
- **CI:** runs in `fast-feedback.yml:69`, `openburnbar-pr-harness.yml:129`, `release.yml:214` (blocking). **This resolves prior M-025** ("no executing BOLA tests").

## F.4 Admin / operator
- `burnbarOperator` is **never minted in code** (repo-wide: no `setCustomUserClaims` sets it; the only in-code claim is `obb_app_check`, `appCheckAttestation.ts:91-94`). It is an out-of-band console/CLI grant → no client privilege-escalation path.
- Operator reads are limited to aggregate `ops/**` metrics (write-denied), no per-user PII. **Gap (OPUS-F-015, Info):** operator reads have no application-layer audit trail.

## F.5 Account deletion (`deleteUserCloudData`)
- Owner-only (uid from `request.auth.uid`, handler input `Record<string,never>`), `enforceHighRiskOwnerAction` (`providerAccounts.ts:359-368`).
- Completeness across collections: `provider_account_secret_refs`, root `voip_outbound`/`fcm_outbound`, `users/{uid}` subtree, `workspaces/workspace-{uid}`, storage `users/{uid}/`+`avatars/{uid}` (`accountDeletion.ts:100-158`). **Forward-maintenance gap (OPUS-F-014).**

## F.6 App Check provider (client)
- `OpenBurnBarAppCheckProviderFactory.swift`: `AppAttestProvider` (macOS 11+) / `DeviceCheckProvider` fallback; debug provider only when an explicit debug token is configured. Initialized before Firebase.
- **Deployment dependency (OPUS-U-002):** Firestore *direct* traffic attestation requires **console** App Check enforcement; code default + startup fail-closed covers callables, not console state.

## Specific tests present
IDOR/BOLA cross-user (tier-2), missing-authorization (catalog completeness), secret-field rejection (`computer-use.test.js:496-514`, `rr12-relay-and-root.test.js:180-189`), server-owned-field immutability, cross-user write denial (`escrow-grants.test.js:145-149`), operator-only ops reads, mass-assignment allowlists (`validRootUserProfileWrite` `firestore.rules:274-310`).
