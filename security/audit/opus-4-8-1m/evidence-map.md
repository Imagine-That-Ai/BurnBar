# Evidence Map — Opus 4.8 1M lane

Maps claims/threats/findings to code + tests. All paths relative to repo root.

## Authorization / BOLA
- Owner-scoping: `firestore.rules:52-54,1436-1439` · tests: `firestore-rules-tests/*` (computer-use, escrow-grants, rr12)
- Endpoint catalog: `functions/src/security/endpointAuthorizationCatalog.generated.ts` (150) · gen `functions/scripts/generate-endpoint-catalog.mjs`
- Completeness test: `functions/src/__tests__/.../bolaCoverage.test.ts:44-49`
- Tier-2 BOLA harness: `functions/src/__tests__/bola/callableBolaHarness.ts:335-372` · 16 `*.bola.test.ts`
- CI: `fast-feedback.yml:69`, `openburnbar-pr-harness.yml:129`, `release.yml:214`

## Crypto / sealing
- AES-GCM seal: `OpenBurnBarCore/.../CloudVaultCrypto.swift:470,498,605,618` · AAD ctx `:735`
- Escrow ECIES: `CloudVaultCrypto.swift:1008-1046`
- session_logs allowlist (M-005 fix): `firestore.rules:549-591,651-660`
- Path-bound AAD: `firestore.rules:944,1563,1612,619`
- Backend KMS envelope: `functions/src/secrets.ts:103-122`
- Crypto policy gate: `scripts/ci/check_burnbar_crypto_architecture_policy.py` · `license-posture.yml:93`
- Collaboration plaintext (OPUS-F-001): `CollaborationSyncService.swift:1001-1003`, `CloudSyncSharedArtifactModels.swift:236-272,245`
- Local DB plaintext (OPUS-F-004): `DataStoreCoordinator.swift:216-261`

## Billing
- Apple JWS verifier: `functions/src/appstore/verifier.ts:85-107,276-282`
- Binding/replay: `functions/src/appstore/reconciler.ts:325-426,569-579`
- Downgrade/watermark fix: `functions/src/appstore/entitlements.ts:202-207,240-257,296-328`
- Stripe: `functions/src/stripe.ts:160-196,561,603-610`
- Entitlements server-only: `firestore.rules:3539-3559`

## Privacy / logging
- Invariant gate: `scripts/ci/check-privacy-invariants.mjs` (+ `.test.mjs`) · `fast-feedback.yml:704`
- Scrubber: `functions/src/logging.ts:16-44,69-105` · `loggingScrubber.test.ts:46-87`
- Push builders: `functions/src/callables/voipPush.ts:69-100` · `voipPushMetadata.test.ts`
- TTL: `firestore.indexes.json:1893-1909` · `scripts/ci/verify-firestore-ttl-state.mjs` · `deploy-firestore.yml:109`
- Sentry: `AgentLensApp.swift:1867,1889-1890` · `MobileSentryScrubberTests.swift` (macOS gap OPUS-F-002)
- Account deletion: `functions/src/accountDeletion.ts:41,100-158` (console.warn leak `:113,156`)

## Desktop / IPC / update
- Daemon socket auth: `OpenBurnBarDaemonServer.swift:411-428,782,7` · constant-time `ConstantTimeCompare.swift:13-26`
- Peer codesign: `BurnBarDaemonPeerAuthenticator.swift:99-108` · `PrivilegedSocketTrust.swift:44-198`
- Privileged input (P0-6 fix): `PrivilegedInputXPCConstants.swift:16-28`, `PrivilegedInputXPCClient.swift:237-248`, `PrivilegedSocketTrust.swift:87`
- Updater (LB-2 fix): `DirectDownloadArtifactVerifier.swift:95-101,134` · `OpenBurnBar-Info.plist:48-49`

## AI / agentic
- Approval gate: `ComputerUseCapabilityGate.swift:233,335,359-372` · coordinator `ComputerUseSessionCoordinator.swift:845,885-916`
- Panic paths: `ComputerUsePanicHaltCoordinator.swift:85-87,98-120,161-180` · leaf `MacActionDispatcher.swift:37`
- Untrusted wrap: `ContextBuilder.swift:11-42` · `AgentSecurityPolicy.swift:106-110`
- Gateway blind relay: `functions/src/hermesGatewayEnvelope.ts:28-90`
- MCP scope: `functions/src/.../mcp.ts:109-113` · `entitlements.ts:130-136`
- SSRF guard: `functions/src/ssrfGuard.ts:65,76`

## Supply chain
- Action pins: `scripts/ci/verify-github-action-pins.mjs:25-27` · `workflow-lint.yml:46`
- Secret scan: `security-pr.yml:63-79` · `.gitleaks.toml`
- Release signing/notary/EdDSA/SBOM: `release.yml:388-457,490-539,609-622,699-759`
- No-suppressions: `scripts/ci/check-no-suppressions.sh` · `fast-feedback.yml:695`
- Deploy submodule fix: `deploy-production.yml:46,68`
