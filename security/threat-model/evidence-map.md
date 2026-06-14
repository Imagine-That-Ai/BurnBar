> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish.

# Evidence Map

Traceability from each claim / domain / headline threat to the code that backs it. This is the “show your work” index — every row points at a real `file:line` an agent verified at HEAD. Raw per-claim evidence arrays live in [`_evidence/_claims.json`](_evidence/_claims.json); per-domain detail in [`_evidence/NN-*.md`](_evidence/); the full machine register in [`threat-register.csv`](threat-register.csv) (column `evidence`).

## How this was produced (chain of custody)

1. 14 domain agents read current HEAD code → wrote [`_evidence/01-…14-*.md`](_evidence/) + structured findings.
2. 14 adversarial verifiers tried to **refute** each headline claim → [`_evidence/_claims.json`](_evidence/_claims.json).
3. Structured findings consolidated → `_evidence/_threats.tsv` (88) + the two parser-harvested domains (`T-IOS`×11, `T-PRV`×7) → `threat-register.csv` (106) via `_evidence/gen_register.py`.
4. Claim matrix generated from the verifier JSON via `_evidence/gen_claims.py`.
5. Spine + cross-cutting synthesis: `_evidence/_INDEX.md`.

## Claim → code → confidence

| Claim | Status | Key evidence (file:line) | Tests cited | Confidence |
|---|---|---|---|---|
| C1 cloud can’t read current Gateway bodies | ✅ | `functions/src/hermesGateway.ts:188-190` (`gatewayPlaintextWriteAllowed`→false), `callables/hermesGateway.ts:439-446,1129-1136,2348-2395` (sealed-only), `:704-789` (shape-only gate), `HermesRelayCrypto.swift:493-514` (key wrapped to recipient pubkey) | gateway sealed-write CI | Med |
| C2 cloud can’t read CloudVault at-rest | 🟡 | `CloudVaultCrypto.swift:438,466,573,420,1426`, `firestore.rules:1274-1370,599,650,731`, `privacyBackfill.ts:95-159` (legacy plaintext caveat) | rules emulator tests | High |
| C3 attachments sealed pre-upload | 🟡 | `callables/hermesGateway.ts:1438-1472,1574-1604`, `hermesGateway.ts:712-792`, `privacyBackfill.ts:95-99,234-236` (legacy fileName), `storage.rules:5-28` | — | Med |
| C4 bearer alone insufficient (PoP) | ✅ | `callables/hermesGateway.ts:697-699,755-771,844-857,1782-1794,2217-2222`, `firestore.rules:2580-2582,4250-4251` | PoP v1→v2 downgrade test | High |
| C5 revoked device loses new material | 🟡 | `computerUseSecurity.ts:1456,1508-1557,1591`, `cloudVaultRotation.ts:104-237,294-309`, `CloudVaultKeyAccess.swift:173-198`, `cloudVaultRotationResilience.ts:214-215` (acknowledged window), `firestore.rules:52-54,1922,2210` | rotation vitest | High |
| C6 untrusted content can’t trigger high-impact action | 🟡 | `ComputerUseCapabilityGate.swift:335,362-363`, `ComputerUseRunCoordinator.swift:262-374`, `ComputerUseDenyRegistry.swift:88-162` (SSRF denies), `ContextBuilder.swift:8-50`, `ChatSessionController.swift:132-144` | PromptInjectionHardeningTests | High |
| C7 high-risk grants need single-use op-bound proof | 🟡 | `computerUseSecurity.ts:911-922,2105-2196,2268-2291`, `PhoneControlAuthorityValidator.swift:493-547`, `PhoneControlStepUpPolicy.swift:9-13,68-87` (SE exemption), `AgentCapabilityGrant.swift:40-50` | proof-replay test | Med |
| C8 only pinned paired devices exchange Gateway msgs | 🟡 | `callables/hermesGateway.ts:1240-1262` (immutable pin, `relay_key_change_rejected`), `HermesRelayCrypto.swift:484-487` (open binds pinned key) | — | Med |
| C9 iroh pairing records can’t be spoofed/replayed | 🟡 | `IrohRelayPairing.swift` (signed + freshness), `firestore.rules:2661-2665` (server-owned), **caveat** `FirestoreIrohPairingPublicKeyProvider.swift:27-47` (TOFU) | — | Med |
| C10 provider creds not in Firestore plaintext | ✅ | `functions/src/secrets.ts:98-122`, `providerAccounts.ts:168-249`, `shared.ts:1465-1607` (refs only) | — | High |
| C11 object-level authz (no cross-user) | 🟡 | `firestore.rules:52-54` (`ownsUserNamespace`), `auth.ts:22-72` (`assertOwnership`), **caveats** avatars public-read, `cloud_vault_key_wrappers` owner-delete, `users/{uid}` root gap | rules tests (thin) | Med |
| C12 old messages/codes can’t be replayed | 🟡 | `HermesRelayAuthenticatedRequest.swift:123-141` (counter+TTL cache), high-risk nonces, PoP nonce txn, **caveat** at-rest envelope freshness (RR-8) | replay tests | High |
| C13 logs/crash/push no plaintext bodies/secrets | 🟡 | `logging.ts:16-90` (server scrub), `agentNotifications.ts:21-327` (generic preview), **breaks** `AppDelegate.swift:53-85`, `AgentLensApp.swift:1168-1202` (client Sentry unscrubbed), `voipPush.ts:39-104` | server Sentry test | Med |
| C14 no production Signal E2EE claimed | ✅ | `SECURITY.md` Signal section, `packages/data-domains/registry.json` (no domain carries `signal-hpke-identity-seal-v1`), `verify-signal-activation-parity.sh` | activation-parity gate (verify wiring) | High |

## Domain → evidence file → confidence → headline finding

| Domain | Evidence file | Conf | Headline |
|---|---|---|---|
| Crypto & relay | [`01-crypto-relay.md`](_evidence/01-crypto-relay.md) | Med | Clean primitives; lane-wiring caveats (v3→v2 downgrade T-CRY-01, Pi-agent no sender-auth T-CRY-02) |
| CloudVault & Signal at-rest | [`02-cloudvault-signal.md`](_evidence/02-cloudvault-signal.md) | Med | AES-GCM + path-AAD sound; keys extractable on unlocked endpoint (T-CVS-03); Signal lane inert |
| Pairing/trust/revocation | [`03-pairing-trust-revocation.md`](_evidence/03-pairing-trust-revocation.md) | Med | Rotation now wired; TOFU host-key MITM (T-PTR-03); no claw-back |
| Transport (iroh) | [`04-transport-iroh.md`](_evidence/04-transport-iroh.md) | Med | **Cloud-substituted pairing key MITM (T-TRN-01, Critical)**; cloud-controlled allowlist; silent downgrade |
| Gateway PoP/replay | [`05-gateway-pop.md`](_evidence/05-gateway-pop.md) | High | Strongest cloud surface: sealed-only + PoP hold (C1, C4 ✅) |
| Cloud authz/rules | [`06-cloud-authz.md`](_evidence/06-cloud-authz.md) | Med | Owner-scoped; wrapper-delete, root-doc gap, avatars, Admin-SDK bypass; App Check console UNKNOWN |
| Daemon/priv-socket | [`07-daemon-privsocket.md`](_evidence/07-daemon-privsocket.md) | Med | Code-sign==authz (T-DMN-01); unsandboxed daemon (T-DMN-02) |
| Agent runtime/tools | [`08-agent-runtime-tools.md`](_evidence/08-agent-runtime-tools.md) | Med | **YOLO injection-to-RCE (T-TOOL-02, Critical)**; no in-process gate; revoke≠kill |
| Agentic prompt/memory/RAG | [`09-agentic-prompt-memory.md`](_evidence/09-agentic-prompt-memory.md) | Med | CU tool results + oracle unwrapped (T-AI-01/02); memory-write provenance gap |
| iOS MASVS | [`10-ios-masvs.md`](_evidence/10-ios-masvs.md) | Med | No app re-auth gate (T-IOS-02); vault keys not SE-bound (T-IOS-09); App-Group/pasteboard/push leaks |
| Android MASVS | [`11-android-masvs.md`](_evidence/11-android-masvs.md) | Med | Parity gaps (sender-auth, wire-approval, unlock cred) |
| Attachments/media | [`12-attachments.md`](_evidence/12-attachments.md) | Med | Sealed; Mercury size-DoS (T-ATT-01); legacy plaintext objects |
| Privacy/logging | [`13-privacy-logging.md`](_evidence/13-privacy-logging.md) | Med | Client Sentry unscrubbed (T-PRV-03); VoIP name + queue-erase gap (T-PRV-01/02) |
| Supply chain/CI | [`14-supply-chain.md`](_evidence/14-supply-chain.md) | Med | Mutable action tags (T-SC-01); no-op cargo-deny (T-SC-02); single CODEOWNER (T-SC-03) |

## MDASH 2026-06-14 follow-up evidence

| MDASH ID | Headline | Key evidence (file:line) | Severity |
|---|---|---|---|
| MDASH-001 | Panic kill switch not wired to root watchdog | `ComputerUseSessionCoordinator.swift:554-556`, `PrivilegedInputKillSwitch.swift:8,23-30`, `PrivilegedInputKillSwitchWatchdogMain.swift:4-9` | P0 |
| MDASH-002 | Remote Unlock nonce ledger at `/var/run` | `RemoteUnlockSetupProbe.swift:29`, `CapabilityTokenVerifier.swift:66`, `PrivilegedInputDispatchHandler.swift:19` | P0 |
| MDASH-003 | Remote Unlock issuer trust at `/Library/Application Support` | `RemoteUnlockSetupProbe.swift:26-27`, `RemoteUnlockCapabilitySigningKeyStore.swift:35-42` | P0 |
| MDASH-004 | Trust/data-destructive callables lack high-risk guard | `hermesGateway.ts:1839-1877`, `providerAccounts.ts:43-115,121-162,168-242,255-320,448-524`, `dataExport.ts:615-669`, `accountDeletion.ts:44-75`, `panic.ts:152-227`, `remoteMcp.ts:89-104` | P1 |
| MDASH-005 | Android iroh host-key pinning missing | `HermesIrohRelayTransport.kt:528-539` (no pin); `FirestoreIrohPairingPublicKeyProvider.swift:56-80` (iOS pin) | P1 |
| MDASH-006 | CloudVault AAD not path-bound in rules | `firestore.rules:599-623,462-498`, `CloudVaultCrypto.swift:617-623` | P1 |
| MDASH-007 | `users/{uid}/devices` push-token injection | `firestore.rules:2368-2371`, `agentNotifications.ts:345`, `voipPush.ts:79-89`, `callables/voipPush.ts:33-34` | P1 |
| MDASH-008 | Mission claiming spoofable via escrow device ID | `firestore.rules:1507-1528` | P1 |
| MDASH-009 | Initial `cloud_vault_state` client-writable | `firestore.rules:2169-2207`, `CloudVaultKeyAccess.swift:284-306` | P1 |
| MDASH-010 | RR-13 Remote MCP HMAC claim drift | `remoteMcpOAuth.ts:27-42`, `callables/remoteMcp.ts:48-52`, `callables/cliLink.ts:180-184`, `hosted-mcp/src/server.ts:221-224` | P1 |
| MDASH-011 / 012 | Local agent runtimes / sandboxed shell inherit full environment | `CLIProcessStreamRunner.swift:174`, `CLIExecutableResolver.swift:196`, `OpenAICompatibleChatGatewayClient.swift:766-780` | P1 |
| MDASH-013 | iOS host-key confirmation default-off | `IrohHostKeyPinStore.swift:205`, `FirestoreIrohPairingPublicKeyProvider.swift:58-73` | P1 |
| MDASH-014 | Queued grants broken / no trust re-check | `AgentCapabilityGrantQueueListener.swift:96-114`, `AgentCapabilityGrantStore.swift:95-104` | P1 |
| MDASH-015 | Single device can exclude others from rotation | `cloudVaultRotation.ts:111-334` | P1 |
| MDASH-016 | Accessibility revocation not polled | `ComputerUsePanicHaltCoordinator.swift:65-69` | P1 |
| MDASH-017 | Remote Unlock ack before validation | `ComputerUseSessionCoordinator.swift:1536-1568,1592` | P1 |
| MDASH-018–020 | Endpoint matrix drift / missing BOLA tests | `endpointAuthorizationMatrix.ts:33-117,246`, `endpointAuthorizationMatrix.test.ts:30-48` | P2 |
| MDASH-021 | `requireHighRiskNonce` default untested | `config.ts:92-106`, `config_l3.test.ts` | P2 |
| MDASH-022 | Pairing completion lacks high-risk guard | `callables/hermes.ts:100-239`, `callables/piAgent.ts:102-258` | P2 |
| MDASH-023 | `session_logs` 1000-expression limit | `firestore.rules:1921-1930,357-421`, `session-log-backup.test.js` | P2 |
| MDASH-024 | `cloud_vault_key_wrappers` direct client writes | `firestore.rules:2209-2253` | P2 |
| MDASH-025 | Android iroh fetch cacheable | `HermesIrohRelayTransport.kt:532-537` | P2 |
| MDASH-026 | VoIP `displayName` unbounded | `voipPush.ts:42-58`, `callables/voipPush.ts:39-76` | P2 |
| MDASH-027 | Agent notification reply schema drift | `callables/agentNotifications.ts:56`, `firestore.rules:2412` | P2 |
| MDASH-028–029 | Capability tokens not bound / budget not decremented | `RemoteUnlockCapabilityTokenBroker.swift:56`, `VirtualHIDBridgeCapabilityGate.swift:58-88`, `CapabilityTokenVerifier.swift:183-201` | P2 |
| MDASH-030 | Agent executables resolved without signature check | `CLIExecutableResolver.swift:99-185` | P2 |
| MDASH-031 | Passkey assertion rate limiting missing | `callables/passkey.ts:206-281` | P2 |
| MDASH-032–033 | Gateway attachment init / PoP v2 canonicalization | `callables/hermesGateway.ts:1409-1444,1123-1125,643-654` | P2 |
| MDASH-034–038 | Low/Info findings | `agentNotifications.ts:236`, `quota.ts:71-75`, `CLIArgumentBuilder.swift:14-27`, `providerAccounts.ts:401-404`, `insightsHostedAnswer.ts:456-467` | P3 |

## Confidence legend & caveats

- **Confidence** is about *our reading of the code*, not about deployment. Anything depending on deployed IAM/KMS/config/Remote Config is marked **UNKNOWN** and routed to [`open-questions.md`](open-questions.md).
- Two domains (`T-IOS`, `T-PRV`) were verified in the first run; their structured returns were re-harvested from the evidence `.md` files (the agents’ raw output) into the register — full fidelity, slightly different provenance path.
- One reading was limited by symbol-display mangling in this environment (the exact CU tool-result wrapping call site, C6 gap #3) — flagged for re-verification in `open-questions.md` §4.
- A prior/parallel draft of every deliverable (timestamped before this run) is preserved unmodified in [`_evidence/_prior-cut/`](_evidence/_prior-cut/) for diff/reference.
