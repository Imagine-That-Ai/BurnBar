# OpenBurnBar MDASH Security Scan Report

**Date:** 2026-06-14  
**Repository:** `/Users/albertonunez/Documents/Windsurf/BurnBar`  
**Branch reviewed:** `security/iroh-host-key-pin-ttrn01` (working tree, uncommitted changes included)  
**Threat model source:** `docs/security/BurnBar-threat-model.md`, `docs/security/OPENBURNBAR_REPO_THREAT_MODEL_2026-06-14.md`  
**Claims register:** `docs/security/SECURITY_CLAIMS_REGISTER.md`  
**Methodology:** Repo mapping → threat-to-scan matrix → parallel specialist scans → skeptic/debate pass → exploitability review → deduped findings.

---

## 1. Executive Verdict

**Hold.** The repository has meaningful, code-backed controls for sealed current-write paths, Hermes Gateway PoP authentication, trusted-device gating, and provider-credential envelope encryption. However, the current working tree contains **three P0 launch blockers** in the Computer Use / Remote Unlock surface, **multiple P1 findings** where trust/data-destructive endpoints lack the high-risk Computer Use guard, **a P1 cross-platform parity gap** (Android iroh host-key pinning missing), and **a P1 Firestore rules gap** that allows same-account ciphertext transplant/replay on collections claimed to use path-bound AAD.

This is not a live deployment attestation. Firebase App Check enforcement, Remote Config, IAM/KMS bindings, deployed rules/functions, and production secret state still require independent verification against the live project.

---

## 2. Scope and Methodology

### Specialist scans executed

| Domain | Tooling | Evidence files |
|---|---|---|
| Firebase Functions auth / App Check / endpoint matrix | `Read`, `Grep`, `vitest` | `functions/src/auth.ts`, `config.ts`, `appCheckAttestation.ts`, `index.ts`, `security/endpointAuthorizationMatrix.ts` |
| Firestore / Storage rules | `Read`, `Grep`, `npm run test:ci` | `firestore.rules`, `storage.rules`, `firestore-rules-tests` |
| Hermes Gateway sealing / PoP / replay | `Read`, `Grep`, `vitest` | `functions/src/hermesGateway.ts`, `functions/src/callables/hermesGateway.ts`, relay-crypto Swift sources |
| CloudVault crypto / key management | `Read`, `Grep` | `OpenBurnBarCore/CloudVaultCrypto.swift`, `AgentLens/CloudVaultKeyAccess.swift`, `MobileCloudVaultKeyAccess.swift`, `android/CloudVaultCrypto.kt` |
| Computer Use / trusted device / privileged socket | `Read`, `Grep` | `functions/src/callables/computerUseSecurity.ts`, `AgentLens/Services/ComputerUse/*`, `OpenBurnBarDaemon/PrivilegedPeerAuthenticator.swift` |
| Local agent runtime / CLI bridge | `Read`, `Grep` | `AgentLens/Services/CLIBridge/*`, `ManagedRuntimeProcessRunner.swift` |
| Provider secrets / push / remote MCP | `Read`, `Grep` | `functions/src/secrets.ts`, `providerAccounts.ts`, `agentNotifications.ts`, `voipPush.ts`, `remoteMcp*.ts` |
| Iroh / relay / Signal / Android parity | `Read`, `Grep`, `swift test` | `IrohRelayTransport.swift`, `IrohHostKeyPinStore.swift`, Android relay transport, Signal at-rest sources |

### Tests run during review

| Test command | Result |
|---|---|
| `cd functions && npm run test:security` | **28/28 passed** |
| `cd firestore-rules-tests && npm run test:ci` | **passed** (computer-use 16/16, media-budget, rr12-relay-and-root 7/7) |
| `cd OpenBurnBarCore && swift test --filter IrohHostKeyPinStoreTests` | **9/9 passed** |

---

## 3. Threat-to-Scan Matrix

| Threat ID | Threat | Scanned surfaces | Key findings | Severity of top finding |
|---|---|---|---|---|
| TM-001 | Endpoint compromise exposes plaintext, SQLite, Keychain, workspace, agent sessions | Local runtimes, CLI bridge, sandboxing, Keychain usage, SQLite posture | Agent runtimes inherit full parent environment (secrets); sandboxed shell still inherits env; agent executables resolved from user-writable dirs without signature verification | P1 |
| TM-002 | BOLA/IDOR in callable/Admin SDK path bypasses Firestore rules | All callable handlers, endpoint matrix, Firestore rules | Multiple trust/data-destructive endpoints only require Auth+AppCheck; devices collection allows push-token injection; mission claiming spoofable; initial `cloud_vault_state` client-writable | P1 |
| TM-003 | Stolen Gateway token + signing key drives Hermes Gateway writes | Gateway auth, PoP, replay, envelope validation | Attachment init does not enforce `relayCapable`; PoP v2 query canonicalization may disagree with Python client on non-ASCII params | P2 |
| TM-004 | Computer Use grant/trust bootstrap bug enables execution without intended approval | Escrow trust, mission approval, phone control, grants, panic halt, privileged socket | P0: kill-switch flag and Remote Unlock ledger/issuer-trust paths use root-only filesystem paths from user process; P1: iroh host-key pin default-off; queued grants broken/deny first-time devices | P0 |
| TM-005 | Backend/IAM/KMS compromise decrypts hosted provider credentials | Provider secrets, Secret Manager/KMS, provider account callables | Provider-credential connect/update callables lack high-risk guard; deterministic secret-ref IDs | P1 |
| TM-006 | Client-direct Firestore write accepts malformed/plaintext mission/session data | Firestore rules, CloudVault validators | `sealedPayload`/`sealedText` rules accept global or regex-matching AAD instead of exact path-bound AAD; `cloud_vault_key_wrappers` allows direct client writes | P1 |
| TM-007 | Prompt injection through logs/RAG/browser/MCP causes unsafe tool use | Local agent runtime, prompt sanitizer | Full environment inheritance; CLI prompt sanitizer strips only narrow control-char range | P1 |
| TM-008 | Local daemon/gateway misconfiguration exposes same-user/network tool/credit surface | Daemon socket, HTTP gateway, privileged socket, Remote Unlock | P0 Remote Unlock ledger/issuer-trust path failures; capability tokens not bound to escrow/attestation | P0 |
| TM-009 | Metadata, indexes, push payloads, audit state leak behavioral information | Push notifications, search index, VoIP, devices collection | Devices push-token injection; VoIP `displayName` unbounded; agent-reply deep link exposes `threadId` | P1 |
| TM-010 | Rules/functions/config drift invalidates repo security claims | Config, endpoint matrix, claims register, CI gates | RR-13 claim drift: Cloud Functions still permit legacy HMAC token issuance; endpoint matrix mislabels triggers and lacks high-risk column | P1 |
| T-TRN-01 | iroh host-key substitution on control channel | iOS/Android iroh pairing providers, pin stores | iOS pinning implemented but default-off (TOFU); Android has no pinning and no `Source.SERVER` fetch | P1 |

---

## 4. Findings — Deduped and Ranked

### 4.1 P0 — Ship Blockers

#### P0-1. Computer Use panic kill switch is not wired to the root watchdog
- **Threat ID:** TM-004, TM-008
- **Evidence:** `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift:554-556` calls `PrivilegedInputKillSwitch.activate(reason:)` directly; `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PrivilegedInputKillSwitch.swift:8` sets `productionFlagPath = "/var/run/openburnbar-privileged-input-kill"`; `OpenBurnBarDaemon/Sources/OpenBurnBarPrivilegedInputKillSwitchWatchdog/PrivilegedInputKillSwitchWatchdogMain.swift:4` exists as a root LaunchDaemon but is never invoked by the app.
- **Issue:** A normal user Mac app cannot write `/var/run`. The direct `activate()` call fails silently (`fputs` to stderr). The Virtual HID bridge and privileged execution leaf never see the kill flag, so locked-screen input may continue after a panic.
- **Exploitability:** Operational failure, not remote exploit. A panic from the phone or global hotkey will not actually stop privileged input.
- **Fix:** Route `panicHalt()` through a small Unix-socket client to the root watchdog (`/var/run/openburnbar-killswitch-watch.sock`), or make the app write to a user-writable path the root bridge reads.

#### P0-2. Remote Unlock capability-token nonce ledger is written to `/var/run`
- **Threat ID:** TM-004, TM-008
- **Evidence:** `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/RemoteUnlockSetupProbe.swift:29` sets `capabilityTokenNonceLedgerPath = "/var/run/openburnbar-capability-token-nonces.json"`; `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/CapabilityTokenVerifier.swift:66` consumes it; `OpenBurnBarDaemon/Sources/OpenBurnBarRemoteAccessAgentCore/PrivilegedInputDispatchHandler.swift:19` gates input on nonce verification.
- **Issue:** The nonce ledger is owned by the user LaunchAgent `OpenBurnBarPrivilegedInputExecution`, not root. Writing to `/var/run` fails, `consume()` throws, and the verifier maps unknown errors to `.nonceReplay`, rejecting all Remote Unlock capability tokens.
- **Exploitability:** Remote Unlock is fail-closed broken in production. Users may fall back to a less-defensible Apple Remote Desktop path.
- **Fix:** Move the ledger to a user-writable, restricted directory (e.g., `~/Library/Application Support/OpenBurnBar/RemoteUnlock/` with mode `0700`) or have the root bridge own an atomic consumed-mark store.

#### P0-3. Remote Unlock issuer trust material is written to `/Library/Application Support`
- **Threat ID:** TM-004, TM-008
- **Evidence:** `RemoteUnlockSetupProbe.swift:26-27` sets `capabilityTokenIssuerTrustPath = "/Library/Application Support/OpenBurnBar/remote_unlock_capability_issuer_trust.json"`; `AgentLens/Services/ComputerUse/Mac/RemoteUnlockCapabilitySigningKeyStore.swift:35-42` publishes issuer trust from the user app.
- **Issue:** `/Library/Application Support/OpenBurnBar` is root-owned. The user app cannot create this file, so the offline leaf verifier has no issuer key and cannot verify tokens.
- **Exploitability:** Same as P0-2: Remote Unlock capability-token verification is non-functional in production.
- **Fix:** Publish issuer trust through a privileged helper, or write to a user-writable location the root bridge is configured to read, with correct installer ownership/ACLs.

### 4.2 P1 — High

#### P1-1. Trust/data-destructive callables lack the high-risk Computer Use guard
- **Threat ID:** TM-002, TM-004, TM-005, TM-009
- **Evidence:**
  - `functions/src/callables/hermesGateway.ts:1839-1877` — `approveHermesGatewayDeviceGrant` uses only `enforceAuthAndAppCheck`.
  - `functions/src/callables/providerAccounts.ts:43-115`, `121-162`, `168-242`, `255-320`, `448-524` — provider connect/update callables use only `enforceAuthAndAppCheck`.
  - `functions/src/callables/dataExport.ts:615-669` — `exportUserData` uses only `enforceAuthAndAppCheck`.
  - `functions/src/callables/providerAccounts.ts:631-665` / `functions/src/accountDeletion.ts:44-75` — `deleteUserCloudData` uses only `enforceAuthAndAppCheck`.
  - `functions/src/callables/panic.ts:152-227` — `revokeAllAccess` uses only `enforceAuthAndAppCheck`.
  - `functions/src/callables/remoteMcp.ts:89-104` — `revokeRemoteMcpClient` uses only `enforceAuthAndAppCheck`.
- **Issue:** These endpoints establish persistent agent-control channels, store live provider credentials, perform mass data exfiltration, or cause irreversible account destruction without a fresh high-risk nonce, App Check attestation binding, or trusted-device action proof. This contradicts the threat model and claims register, which state that high-risk trust actions require the hardened Computer Use flow.
- **Exploitability:** A stolen Firebase ID token + valid App Check token (phishing, malware same-user client, leaked session) can execute these actions.
- **Fix:** Route the listed callables through `enforceHighRiskComputerUseCallableWithNonce` and `requireTrustedDeviceActionProof` where applicable, mirroring `respondMissionApproval`, `approveEscrowDeviceTrust`, and `publishIrohPairingRecord`.

#### P1-2. Android iroh host-key pinning is missing (T-TRN-01 not closed on Android)
- **Threat ID:** T-TRN-01, TM-003, TM-004, TM-010
- **Evidence:**
  - iOS pins: `OpenBurnBarMobile/Services/IrohRelay/FirestoreIrohPairingPublicKeyProvider.swift:56-80` calls `IrohHostKeyPinStore.verifyOrPin(...)`.
  - Android does not pin: `android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesIrohRelayTransport.kt:528-539` decodes and returns the server-advertised key directly. No `IrohHostKeyPinStore` references exist in `android/app/src`.
  - Android uses cacheable fetch: same file uses `.get()` without `.source(Source.SERVER)`.
- **Issue:** A malicious/compromised Firestore backend or relay can substitute the host public key and a matching signed `iroh_pairing` record. Android verifies the attacker’s signature with the attacker’s key and dials the attacker endpoint, hijacking the control channel.
- **Exploitability:** Requires attacker control of the `iroh_pairing_keys/host` doc at first pairing or after cache clear. The doc is writable only via the high-risk `publishIrohPairingPublicKey` callable, but the threat model treats cloud substitution as in scope.
- **Fix:** Port `IrohHostKeyPinStore` to Android, persist pins with Keystore-wrapped storage, force `Source.SERVER`, and add adversarial key-swap tests.

#### P1-3. Firestore rules allow same-account transplant/replay of `sealedPayload`/`sealedText`
- **Threat ID:** TM-006, TM-010
- **Evidence:**
  - `firestore.rules:599-623` — `validCloudSealedPayload` accepts either the global AAD `"OpenBurnBar-CloudVaultSealedPayload-v2"` **or** any string matching the `validCloudVaultAAD` regex.
  - `firestore.rules:462-498` — `validCloudSealedText` accepts legacy no-AAD, schemaVersion 1 no-AAD, or schemaVersion ≥2 with any regex-matching AAD.
  - `firestore.rules:501-506` — `validCloudSealedTextAt` exists but is not used consistently across collections.
  - `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:617-623` — `openPayload` ignores a caller-supplied `aadContext` when `envelope.aad == sealedPayloadAADContext` (global).
  - Writers still emit global/no-AAD: `AgentLens/Services/CloudSync/ChatThreadSyncService.swift:106-110`, `AgentLens/Services/CloudSync/SessionLogSyncService.swift:271-291`, `AgentLens/Services/CloudBudgetService.swift:179-188`, `OpenBurnBarMobile/Services/RollbackService.swift:221`, `OpenBurnBarMobile/Views/Hermes/Square/AgentBrandZoneView.swift:1283-1286`.
- **Issue:** Same-user clients can write a `sealedPayload`/`sealedText` with the global AAD or a path-bound AAD for a different document/field. Because readers fall back to the global/no-AAD branch, the replayed ciphertext decrypts successfully. This undermines the claims register statement that high-risk/recall writers bind AES-GCM payloads to `uid+collection+doc+field`.
- **Exploitability:** Any authenticated same-user client. Allows same-account transplant, replay, and tampering across documents/fields/collections.
- **Fix:**
  1. Make `validCloudSealedPayload` require exact `aad == cloudVaultAADContext(userId, collection, docID, field)`.
  2. Replace `validCloudSealedText` with `validPathBoundCloudSealedText(expectedAAD)` for per-document fields.
  3. Update all current writers to pass explicit `CloudVaultAADContext`.
  4. Add negative rules tests rejecting global/mismatched AAD.
  5. Keep legacy read fallback only for genuine `schemaVersion == 1` migration documents.

#### P1-4. `users/{uid}/devices` is owner-writable and allows push-token injection
- **Threat ID:** TM-002, TM-009
- **Evidence:** `firestore.rules:2368-2371` allows `create, update` with only `ownerWritableNonSecret(userId)`; push fanout reads `fcm_token`/`voipDeviceToken` from this collection (`functions/src/agentNotifications.ts:345`, `functions/src/voipPush.ts:79-89`, `functions/src/callables/voipPush.ts:33-34`).
- **Issue:** Any authenticated owner can create/overwrite a device doc with attacker-controlled push tokens. Future agent-reply notifications are fanout-copied to the attacker, and `triggerVoIPCall` with the fake `deviceId` routes call invites to the attacker.
- **Exploitability:** Stolen owner session or malicious same-user client.
- **Fix:** Tighten `devices` rules to a strict allowlist excluding push-token fields; write push tokens only through a server-verified callable or store them in a server-only collection.

#### P1-5. Mission/agent-import claiming is spoofable via escrow device ID
- **Threat ID:** TM-002, TM-004
- **Evidence:** `firestore.rules:1507-1528` — `trustedMissionExecutorDevice` checks only that `claimedBy` points to a trusted macOS escrow device. No proof from the claiming Mac is required.
- **Issue:** A malicious same-user client can set `claimedBy` to a legitimate trusted Mac's device ID, then progress the mission and write mac-source `events`, bypassing the "only the paired Mac can claim and execute" invariant.
- **Exploitability:** Any authenticated owner with read access to `escrow_devices`.
- **Fix:** Make `claimedBy` server-stamped via a callable that verifies a Mac-signed claim proof or high-risk nonce + attestation; treat `claimedBy` as immutable/server-only in rules.

#### P1-6. Initial `cloud_vault_state/current` creation is client-writable and allows lockout
- **Threat ID:** TM-002, TM-006
- **Evidence:** `firestore.rules:2169-2207` allows the initial create when no current state exists, with only `ownerWritableNonSecret` and `validVaultKeyID` checks.
- **Issue:** A malicious same-user client can race the legitimate first device and create `cloud_vault_state/current` with an arbitrary `vaultKeyID`. The real device then sees `vaultKeyMismatch` and cannot establish CloudVault. Because delete is denied, recovery requires server intervention.
- **Exploitability:** Authenticated owner session before the legitimate device finishes first-time setup.
- **Fix:** Make initial creation server-only (callable) or gate it on an existing trusted escrow device and a vault-key-knowledge proof.

#### P1-7. RR-13 claim drift — legacy HMAC tokens still permitted in Cloud Functions issuers
- **Threat ID:** TM-003, TM-010
- **Evidence:**
  - `functions/src/remoteMcpOAuth.ts:27-42` uses Ed25519 if configured, otherwise falls back to HMAC.
  - `functions/src/callables/remoteMcp.ts:48-52` and `functions/src/callables/cliLink.ts:180-184` allow either secret to be present.
  - `services/hosted-mcp/src/server.ts:221-224` enforces production posture only for the verifier.
- **Issue:** `SECURITY_CLAIMS_REGISTER.md` RR-13 is marked **CLOSED (verified)** claiming production refuses to boot unless Ed25519 verification is configured and legacy HMAC is disabled. This is true only for the hosted MCP server, not for the Cloud Functions token issuers.
- **Exploitability:** If a production deployment still sets `REMOTE_MCP_TOKEN_HMAC_SECRET`, the system issues symmetric tokens valid for any uid/client against verifiers that accept them.
- **Fix:** Add `assertRemoteMcpTokenIssuerPosture()` in the Functions token issuers that, in production-looking projects, throws if HMAC is configured or Ed25519 is missing. Add unit tests and update/downgrade the claims register.

#### P1-8. Local agent runtimes inherit the full parent environment
- **Threat ID:** TM-001, TM-007
- **Evidence:** `AgentLens/Services/CLIBridge/CLIProcessStreamRunner.swift:174` sets `process.environment = invocation.environment`; `AgentLens/Services/CLIBridge/CLIExecutableResolver.swift:196` starts from `ProcessInfo.processInfo.environment`; `AgentLens/Services/ManagedAgentRuntime/ManagedRuntimeProcessRunner.swift:28` uses the same resolver.
- **Issue:** A prompt-injected or malicious agent can dump `OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN`, `OPENBURNBAR_GATEWAY_AUTH_TOKEN`, OAuth tokens, `SSH_AUTH_SOCK`, CI tokens, etc. The daemon intentionally keeps tokens in environment variables to keep them out of `ps aux`, then hands them to child agents.
- **Exploitability:** Requires a shell/workspace capability grant or trusted grant.
- **Fix:** Apply the allowlist pattern already used in `ClaudeInteractiveSessionExecutor.sanitizedEnvironment()` to all agent launches; pass only explicitly needed variables and strip `OPENBURNBAR_*` secrets.

#### P1-9. Sandboxed `shell_run` still inherits full environment
- **Threat ID:** TM-001, TM-007
- **Evidence:** `AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift:766-780` creates the process but leaves `process.environment` unset, so it inherits the parent environment.
- **Issue:** The Seatbelt sandbox confines filesystem writes but not environment reads. A restricted shell can run `env > workspace/leak.txt` to persist tokens for later exfiltration.
- **Exploitability:** Active `shell` capability grant or prompt injection.
- **Fix:** Set `process.environment` to an allowlist in `AgentToolBroker.runProcess` before launching `/usr/bin/sandbox-exec`; do the same for `shell_run_unrestricted`.

#### P1-10. iroh host-key safety-number confirmation is default-off (iOS TOFU)
- **Threat ID:** T-TRN-01, TM-004, TM-010
- **Evidence:** `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/IrohHostKeyPinStore.swift:205` sets `defaultEnabled = false`; `OpenBurnBarMobile/Services/IrohRelay/FirestoreIrohPairingPublicKeyProvider.swift:58-73` admits first-use keys unless the flag is enabled.
- **Issue:** A compromised cloud/relay at first pairing can substitute the host key. iOS pins and trusts it. Post-pairing key-change rejection is live, but the first-contact TOFU window remains open.
- **Exploitability:** Attacker control of directory response during first iOS→Mac pairing or re-pair.
- **Fix:** Enable `defaultEnabled = true` and wire the safety-number compare UI, or document as an accepted residual and add an explicit rollout milestone.

#### P1-11. Queued agent grants deny first-time devices and have no trust continuity
- **Threat ID:** TM-004
- **Evidence:**
  - `AgentLens/Services/ComputerUse/AgentCapabilityGrantQueueListener.swift:113` calls `apply(request)` with `macApprovalSatisfied: false`.
  - `AgentLens/Services/ComputerUse/AgentCapabilityGrantStore.swift:95-104` denies any grant beyond `.workspaceRead` without Mac approval.
  - `AgentLens/Services/ComputerUse/AgentCapabilityGrantQueueListener.swift:96-114` never re-checks the source escrow device's `trustState`.
- **Issue:** Queued high-risk grants from a trusted phone are silently denied because no Mac approval UI path exists for queued delivery. A revoked phone whose grant was already queued can still receive capabilities.
- **Exploitability:** Requires ability to write queued grant docs (owner session or compromised phone).
- **Fix:** Either (a) document that queued delivery supports only the Low preset, or (b) surface a Mac approval notification on reconnect and re-check `escrow_devices/{sourceDeviceId}.trustState` before applying.

#### P1-12. Single trusted device can rotate CloudVault key and lock out all others
- **Threat ID:** TM-001, TM-004
- **Evidence:** `functions/src/callables/cloudVaultRotation.ts:111-334` checks only that the caller is in the survivor set; there is no requirement to include all trusted devices or a server-generated rotation requirement.
- **Issue:** A compromised trusted device can rotate to a new vault key, pass only itself as survivor, and revoke wrappers for every other device.
- **Exploitability:** Requires compromised trusted device + valid high-risk nonce/App Check.
- **Fix:** Require a server-generated `cloud_vault_rotation_requirement` for all rotations, or require the survivor set to equal the current trusted-device set unless an explicit recovery flow is recorded.

#### P1-13. Accessibility revocation is not polled during active sessions
- **Threat ID:** TM-004
- **Evidence:** `AgentLens/Services/ComputerUse/ComputerUsePanicHaltCoordinator.swift:65-69` defines `accessibilityRevoked()` but no timer/polling source calls it.
- **Issue:** If a user revokes Accessibility in System Settings mid-session, the session is not halted until the next action fails. A phone/agent action could execute during the window.
- **Exploitability:** Requires user to revoke Accessibility mid-session.
- **Fix:** Add a 5-second timer in `ComputerUseRuntimeController` while a session is active; if `AXIsProcessTrusted()` becomes false, call `coordinator.panicHalt(source: .accessibilityRevoked)`.

#### P1-14. Remote Unlock credential ack is sent before authority validation
- **Threat ID:** TM-004
- **Evidence:** `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift:1536-1568` sends `.accepted` / `credential_received`, then validates authority/policy/session/recipient at line 1592.
- **Issue:** UI/phone may briefly show success before denial, enabling social engineering or confusion.
- **Exploitability:** Low — validation still runs, but UX can be abused.
- **Fix:** Validate the authority envelope and policy before emitting the accepted result.

### 4.3 P2 — Medium

#### P2-1. Endpoint authorization matrix mislabels trigger types
- **Threat ID:** TM-010
- **Evidence:** `functions/src/security/endpointAuthorizationMatrix.ts:33-117`. `startCliLink`/`pollCliLink` are `onRequest` HTTP endpoints, not callables; `onKnowledgeRepoPush` is an `onRequest` GitHub webhook; `sendVoIPOutbound`/`sendFcmOutbound` are `onDocumentCreated` triggers; `onUsageWritten` is `onDocumentWritten`.
- **Issue:** The matrix misleads auditors/operators about the actual attack surface.
- **Fix:** Correct the matrix entries and add a test asserting actual trigger metadata.

#### P2-2. Endpoint matrix lacks high-risk Computer Use enforcement column
- **Threat ID:** TM-004, TM-010
- **Evidence:** `functions/src/security/endpointAuthorizationMatrix.ts:8-18`.
- **Issue:** Cannot audit from the matrix which trust/data mutations meet the high-risk bar, enabling the P1-1 inconsistency.
- **Fix:** Add a `highRiskComputerUse: boolean` column and a test cross-referencing handler bodies for enforcement helpers.

#### P2-3. No systematic BOLA/cross-user negative tests despite matrix claiming them
- **Threat ID:** TM-002
- **Evidence:** `functions/src/security/endpointAuthorizationMatrix.ts:246` declares `negativeBolaTest: "endpoint-specific BOLA tests required"`; `functions/src/__tests__/endpointAuthorizationMatrix.test.ts:30-48` only checks the string is non-empty.
- **Issue:** Documentation of test requirement is not enforced.
- **Fix:** Add a CI gate requiring every `authScopedCallables` entry to point to a cross-user rejection test or justify in notes.

#### P2-4. `requireHighRiskNonce` production default is untested
- **Threat ID:** TM-010
- **Evidence:** `functions/src/config.ts:92-106` defaults `requireHighRiskNonce` to `looksProd`; `config_l3.test.ts` tests App Check default but not nonce default.
- **Fix:** Add a test asserting production-looking projects default `requireHighRiskNonce` to `true`.

#### P2-5. `completeHermesPairing` / `completePiAgentPairing` lack high-risk guard
- **Threat ID:** TM-004
- **Evidence:** `functions/src/callables/hermes.ts:100-239`, `functions/src/callables/piAgent.ts:102-258`.
- **Issue:** Pairing completion establishes a persistent agent connection with only Auth + App Check + pairing code.
- **Fix:** Require high-risk nonce and trusted-device proof, or document lower-risk rationale in the matrix.

#### P2-6. `session_logs` manifest rule exceeds Firestore's 1000-expression limit
- **Threat ID:** TM-010, TM-006
- **Evidence:** `firestore.rules:1921-1930`, `firestore.rules:357-421`; `firestore-rules-tests/session-log-backup.test.js` fails.
- **Issue:** Even valid encrypted manifests are rejected; chunks subcollection denies all create/update.
- **Fix:** Simplify validators or split validation between rules and callables; re-include the test in CI once it passes.

#### P2-7. `cloud_vault_key_wrappers` allows direct client writes with no writer/source binding
- **Threat ID:** TM-002
- **Evidence:** `firestore.rules:2209-2253`.
- **Issue:** Any entitled device can create/update wrappers for any trusted source/target pair, enabling DoS/misconfiguration.
- **Fix:** Make wrappers server-write-only or require a server-signed attestation/job ID.

#### P2-8. Android iroh host-key fetch uses cacheable Firestore source
- **Threat ID:** T-TRN-01, TM-010
- **Evidence:** `android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesIrohRelayTransport.kt:532-537` uses `.get()` without `.source(Source.SERVER)`.
- **Issue:** A poisoned cached key could become the trusted root.
- **Fix:** Force `Source.SERVER` and test cache-poisoning scenarios.

#### P2-9. VoIP/call push exposes unbounded `displayName`
- **Threat ID:** TM-009
- **Evidence:** `functions/src/voipPush.ts:42-58`, `functions/src/callables/voipPush.ts:39-76`.
- **Issue:** Arbitrary-length caller names flow to APNs/FCM.
- **Fix:** Bound and sanitize `displayName` (e.g., ≤ 120 UTF-16 code units).

#### P2-10. Agent notification reply callable writes schema version 1 while rules enforce version 2
- **Threat ID:** TM-006, TM-010
- **Evidence:** `functions/src/callables/agentNotifications.ts:56` hardcodes `sealedSchemaVersion: 1`; `firestore.rules:2412` requires `sealedSchemaVersion == 2`.
- **Issue:** Admin SDK bypasses rules, but the drift undermines the sealed-shape contract.
- **Fix:** Set `sealedSchemaVersion: 2`, restrict parsing to v2, and add rule/callable tests.

#### P2-11. Capability tokens are not bound to escrow device or attestation, `scopeHash` not verified
- **Threat ID:** TM-008
- **Evidence:** `AgentLens/Services/ComputerUse/RemoteUnlockCapabilityTokenBroker.swift:56`; `OpenBurnBarDaemon/Sources/OpenBurnBarRemoteAccessAgentCore/VirtualHIDBridgeCapabilityGate.swift:58-88`; `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/CapabilityTokenVerifier.swift:183-199`.
- **Issue:** A leaked token could be replayed by another first-party same-UID process for the allowed `actionKind`.
- **Fix:** Bind tokens to viewer/escrow `deviceId` and current App Check attestation hash; verify `scopeHash` at the leaf.

#### P2-12. `actionBudget` is checked but never decremented
- **Threat ID:** TM-004
- **Evidence:** `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/CapabilityTokenVerifier.swift:200-201`.
- **Issue:** Currently budget=1 and nonce uniqueness covers it, but future budgets >1 would not be enforced.
- **Fix:** Decrement `actionBudget` atomically in the nonce store or document the policy.

#### P2-13. Agent CLI executables resolved from user-writable dirs without signature verification
- **Threat ID:** TM-001, TM-007
- **Evidence:** `AgentLens/Services/CLIBridge/CLIExecutableResolver.swift:99-185`.
- **Issue:** A same-user attacker can drop a trojaned binary earlier in search order.
- **Fix:** Verify code signature/Team ID against an allowlist after resolution.

#### P2-14. Passkey assertion endpoints lack rate limiting
- **Threat ID:** TM-009
- **Evidence:** `functions/src/callables/passkey.ts:206-281`.
- **Fix:** Add per-IP/fingerprint rate limiting to `beginPasskeyAssertion`.

#### P2-15. Hermes attachment init does not enforce `relayCapable`
- **Threat ID:** TM-003
- **Evidence:** `functions/src/callables/hermesGateway.ts:1409-1444` vs. `handleMessageSend` at `1123-1125`.
- **Fix:** Add the same fail-closed `relayCapable` gate before envelope resolution.

#### P2-16. PoP v2 query canonicalization may disagree with Python client on non-ASCII params
- **Threat ID:** TM-003
- **Evidence:** `functions/src/callables/hermesGateway.ts:643-654` uses `localeCompare`; Python adapter uses UTF-16 code-unit sort.
- **Fix:** Pin to deterministic byte order and add contract tests.

### 4.4 P3 / Info

#### P3-1. Agent reply deep link encodes `threadId`
- **Threat ID:** TM-009
- **Evidence:** `functions/src/agentNotifications.ts:236`.
- **Issue:** Push metadata visible to APNs/FCM includes routing identifiers.
- **Disposition:** Consistent with accepted residual risk; document in production push inventory.

#### P3-2. Provider secret refs use deterministic global collection IDs
- **Threat ID:** TM-002, TM-005
- **Evidence:** `functions/src/quota.ts:71-75` builds `providerAccountSecretRefID = "${safeUid}_${safeAccountID}"`.
- **Issue:** If rules drift or Admin SDK misconfigures, IDs are enumerable.
- **Fix:** Add rules test asserting server-only access; consider random suffix.

#### P3-3. CLI prompt sanitizer strips only narrow control characters
- **Threat ID:** TM-007
- **Evidence:** `AgentLens/Services/CLIBridge/CLIArgumentBuilder.swift:14-27`.
- **Fix:** Strip ANSI escapes, Unicode directional overrides, and zero-width characters.

#### P3-4. `deleteHostedQuotaCredentials` defaults provider to `codex`, which is not a hosted provider
- **Threat ID:** TM-010
- **Evidence:** `functions/src/callables/providerAccounts.ts:401-404`.
- **Fix:** Make `provider` required or default to a valid hosted provider.

#### P3-5. `insightsHostedAnswer` uses non-standard auth pattern
- **Threat ID:** TM-002
- **Evidence:** `functions/src/insightsHostedAnswer.ts:456-467`.
- **Fix:** Replace with `enforceAuthAndAppCheck` for consistency.

#### Info-1. Legacy v1 no-AAD CloudVault envelopes remain accepted
- **Threat ID:** TM-006
- **Evidence:** `CloudVaultCrypto.swift` v1 branches in `openPayload`/`openBlob`/`openText`.
- **Disposition:** Confined to legacy migration; complete backfill and remove v1 acceptance behind migration flag.

---

## 5. Verified Sound Controls

| Control | Evidence | Test status |
|---|---|---|
| App Check production fail-closed | `functions/src/config.ts:68-84` | `config_l3.test.ts` |
| Hermes Gateway bearer + Ed25519 PoP + replay cache | `functions/src/callables/hermesGateway.ts:810-865`, `:693-772` | `hermesGatewayPopV2.test.ts` |
| New Gateway plaintext write rejection | `functions/src/callables/hermesGateway.ts:413-455`, `1116-1193`, `1409-1605` | `hermesGatewayAttachmentInit.test.ts` |
| High-risk Computer Use flows (where implemented) | `computerUseSecurity.ts:793-860`, `1177-1454`, `1964-2263` | `appCheckAttestationBinding.test.ts`, rules tests |
| Firestore server-owned trust roots | `firestore.rules:3314-3675`, `2470-2739` | `test:ci` |
| Provider Secret Manager/KMS envelopes | `functions/src/secrets.ts:98-153` | — |
| Agent reply push generic preview | `functions/src/agentNotifications.ts:310` | — |
| iOS iroh host-key pin logic | `OpenBurnBarCore/IrohHostKeyPinStore.swift` | 9/9 passed |
| Daemon socket peer authentication | `BurnBarDaemonPeerAuthenticator.swift` | `BurnBarDaemonServerPeerAuthEnforcementTests.swift` |
| Sentry scrubbing | `functions/src/sentry.ts:45-152` | `sentry.test.ts` |
| Signal at-rest default-off | `packages/data-domains/registry.json`, RC gates, `hermesGateway.ts:691-702` | `SignalAtRestFallbackPolicyTests` |

---

## 6. Recommendations

### Immediate (before any release)
1. Fix P0-1, P0-2, P0-3 — wire panic halt to the root watchdog and move Remote Unlock ledger/issuer-trust to user-writable or helper-mediated paths.
2. Fix P1-2 — port iroh host-key pinning to Android and force `Source.SERVER`.
3. Fix P1-1 — apply high-risk nonce + trusted-device proof to Gateway approval, provider credential mutations, account export/deletion, and revoke-all.
4. Fix P1-3 — tighten Firestore rules to enforce exact path-bound AAD for current `sealedPayload`/`sealedText` writes.
5. Fix P1-4 — lock down `users/{uid}/devices` push-token fields.

### Near-term
6. Fix P1-5 through P1-14 and P2-1 through P2-16 as prioritized in the finding table.
7. Update `SECURITY_CLAIMS_REGISTER.md` and `BurnBar-threat-model.md` to reflect iOS-only host-key pinning and any accepted residuals.
8. Add CI gates: high-risk enforcement column in endpoint matrix, systematic BOLA tests, issuer-side MCP token posture.
9. Run `scripts/ops/collect-firebase-security-evidence.mjs --strict` against the live project to verify deployed rules, App Check, and IAM/KMS posture.

---

## 7. Limitations and What This Review Did Not Prove

- **Not a live deployment attestation.** App Check enforcement, Remote Config values, IAM/KMS bindings, deployed Functions/rules versions, and production secret state were not verified against a running project.
- **Not a full penetration test.** Findings are code/config/static-analysis backed; dynamic exploitation against a live Firebase project was not performed.
- **Not a supply-chain audit.** Build pipeline, dependency integrity, and release artifact signing were not deeply inspected.
- **Not a cryptography audit.** Crypto primitives are reviewed against source evidence, but no formal analysis or test-vector validation was performed beyond existing unit tests.
