# Evidence Map

Maps claims, threats, and findings to specific code and tests.

## Claims -> Evidence

| Claim | Status | Primary Evidence | Test Evidence | Confidence |
|-------|--------|-----------------|---------------|------------|
| CLAIM-001 (E2E encryption) | Defensible | `CloudVaultCrypto.swift`, `firestore.rules:validPathBoundSealedPayloadForUser` | CloudVault AAD rules tests, `signalAtRestWrite.test.ts` | High |
| CLAIM-002 (Object-level authz) | Defensible | `auth.ts:assertOwnership`, `firestore.rules:ownsUserNamespace` | `bola/*.bola.test.ts` (21 files), `bolaCoverage.test.ts` | High |
| CLAIM-003 (Audit chain) | Defensible | `ComputerUseAuditChain.swift` | Chain validation tests | High |
| CLAIM-004 (Panic-kill paths) | Defensible* | `ComputerUsePanicHaltCoordinator.swift` | Coordinator tests | High (*FINDING-001 caveat) |
| CLAIM-005 (No secrets) | Defensible | `.gitleaks.toml`, `.secrets.baseline`, `functions/.env.burnbar.production` | `check-no-committed-evidence.sh`, `scan-publishable-tree.sh` | High |
| CLAIM-006 (Supply chain) | Defensible | `.github/workflows/`, `verify-github-action-pins.mjs` | `workflow-lint.yml` | High |
| CLAIM-007 (High-risk nonce) | Defensible | `appCheckAttestation.ts:enforceHighRiskComputerUseCallableWithNonce` | `highRiskOwnerAction.test.ts`, `appCheckAttestation.test.ts` | High |
| CLAIM-008 (SQLCipher) | Defensible | `BurnBarDaemonDatabaseCipher.swift` | `BurnBarDaemonDatabaseCipherTests` | High |
| CLAIM-009 (Daemon 3-layer auth) | Defensible | `OpenBurnBarDaemonServer.swift`, `BurnBarDaemonPeerAuthenticator.swift`, `ConstantTimeCompare.swift` | Daemon socket tests | High |
| CLAIM-013 (Signal NOT live) | Not defensible | `signalSealingIsEnabled` requires registry + Remote Config flag (OFF) | `verify-signal-activation-parity.sh` | High |

## Threats -> Evidence

| Threat | Finding | Primary Evidence | Control Evidence |
|--------|---------|-----------------|-----------------|
| THREAT-001 (Kill switch disarm) | FINDING-001 | `PrivilegedInputKillSwitchWatchdogMain.swift:60-93` | Three other panic paths in `ComputerUsePanicHaltCoordinator.swift` |
| THREAT-002 (Grant without phone proof) | FINDING-002 | `OpenBurnBarDaemonMain.swift:69` (verifier=nil) | Peer codesig in `BurnBarDaemonPeerAuthenticator.swift`; capability gate in `VirtualHIDBridgeCapabilityGate.swift` |
| THREAT-003 (Trust mode elevation) | FINDING-003 | `PhoneControlOptionSheet.swift` (allCases) | Capability gate in `ComputerUseCapabilityGate.swift` |
| THREAT-004 (Ciphertext relocation) | FINDING-008 | `firestore.rules:ownerWritableChatThread` (global AAD) | `validPathBoundSealedPayloadForUser` on conversations |
| THREAT-005 (Cross-tenant) | N/A (mitigated) | `auth.ts:assertOwnership` | `bola/*.bola.test.ts`, `firestore.rules:ownsUserNamespace` |
| THREAT-006 (iroh MITM) | FINDING-005 | `IrohRelayPairing.swift` (safety-number not default) | Key-change pinning in `IrohPairingHostKeyPinStore.kt` |

## Findings -> Tests

| Finding | Regression Test | Test Status |
|---------|----------------|-------------|
| FINDING-001 | Not yet exists — needs: connect unsigned binary to watchdog, verify rejection | MISSING |
| FINDING-002 | Not yet exists — needs: submit grant without phone proof, verify rejection | MISSING |
| FINDING-003 | Not yet exists — needs: verify phone UI only shows downgrade modes | MISSING |
| FINDING-008 | `firestore-rules-tests/m007-path-bound-sealed-payload.test.js` exists for conversations/mobile_assistant_chats | EXISTS (partial) |
| M-005 (session log allowlist) | `firestore-rules-tests/session-log-backup.test.js` | EXISTS, PASSING |
| M-007 (path-bound AAD) | `firestore-rules-tests/` cloud-vault-aad tests | EXISTS, PASSING |
| M-025 (BOLA coverage) | `bolaCoverage.test.ts`, `endpointAuthorizationMatrix.test.ts` | EXISTS, PASSING |
| M-028 (capability token binding) | `CapabilityTokenVerifierTests`, `VirtualHIDBridgeCapabilityGateTests` | EXISTS, PASSING |

## M-Findings -> Fix Verification

| Prior Finding | Status | Evidence of Fix |
|--------------|--------|----------------|
| M-002 (high-risk nonce) | Fixed | `enforceHighRiskComputerUseCallableWithNonce` + `highRiskOwnerAction.test.ts` |
| M-005 (session log allowlist) | Fixed | `firestore.rules:validSessionLogManifestKeys()` is first conjunct of `validSessionLogManifestCore` |
| M-007 (path-bound AAD) | Partially fixed | `conversations` + `mobile_assistant_chats` path-bound; `chat_threads` + `cli_sessions` still global (FINDING-008) |
| M-016 (userId mutation) | Fixed | Firestore rules pin immutable fields; `computerUseQuota` derives uid from path |
| M-023 (raw logger path) | Fixed | `agentNotifications.ts` routes through scrubbed logging |
| M-025 (BOLA coverage) | Fixed | BOLA harness executes runtime cross-user proofs; `bolaCoverage.test.ts` validates completeness |
| M-038 (claimedBy spoofing) | Fixed | `respondMissionApproval` transactional ownership |
| M-040 (trusted agent CLI bypass) | Fixed | CLI argument gates, broker approval gaps, env stripping |
