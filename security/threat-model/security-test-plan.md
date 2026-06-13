> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish. Generated — see `_evidence/` for raw findings.

# Phase 13 — Security Test Plan

This plan converts the threat model into executable verification. Every test maps to a **canonical threat id** (`T-…`), the **claim** it backstops (`C1`–`C14`), and a **component**/**boundary** (`C1`–`C16` / `B1`–`B9`). Each entry names an **existing repo test** (cited file/path where known) when one exists, or is marked **MISSING — recommend**. CI-gated items are flagged so reviewers know which checks already run on every PR.

CODE is source of truth. Tests assert the *current* HEAD behavior including the documented gaps — a "secure result" below is the behavior the system **must not regress from**, not an aspiration. Where the evidence files rate a control **Partial/NotDefensible**, the test pins the *known-safe* boundary and a companion negative test pins the *known-unsafe* boundary so neither silently changes.

Severity, threat, claim, component, and boundary ids are reused verbatim from `_evidence/_INDEX.md`, `_evidence/_threats.tsv`, and `_evidence/_claims.json`. Nothing is renumbered.

External-scope handoff: see **§13.3** and `cure53-audit-brief.md`.

---

## 13.0 Test taxonomy & existing-coverage map

| Lane | Runner | Where | CI workflow (gate) |
|---|---|---|---|
| Cloud Functions / authz / gateway / pairing | `node --test` (TS/JS) | `functions/src/__tests__/`, `functions/lib/__tests__/` | `security-pr.yml`, `fast-feedback.yml` |
| Firestore/Storage rules | `@firebase/rules-unit-testing` | `firestore-rules-tests/` | `security-pr.yml` (rules job), `deploy-firestore.yml` |
| Swift core / crypto / CU / pairing | `swift test` (XCTest) | `AgentLensTests/`, `OpenBurnBarMobileTests/`, `OpenBurnBarDaemon/Tests/` | `openburnbar-pr-harness.yml`, `fast-feedback.yml` |
| Android parity | JUnit / instrumented | `android/app/src/test`, `android/app/src/androidTest` | `fast-feedback.yml`, `build-iroh-android-aar.yml` |
| Browser SSRF / DNS-rebind | `node` policy harness + Chromium | `scripts/test-playwright-bridge-guard.mjs` | `security-pr.yml` (Browser Target Policy), `computer-use-loopback-test.yml` |
| Hosted-MCP isolation | `node --test` + live prove | `services/hosted-mcp/`, `scripts/prove-hosted-mcp-live.mjs` | `security-pr.yml` (Hosted MCP Isolation Proofs) |
| Signal non-activation | shell parity assertion | `scripts/ci/verify-signal-activation-parity.sh` | `security-pr.yml` (Signal Activation Parity) |
| Confidentiality (no internal content leaks) | node scanner | `scripts/security/scan-internal-content.mjs` | `confidentiality-guard.yml` |
| Supply chain | gitleaks / OSV / dep-review | `security-pr.yml`, `supply-chain-provenance.yml`, `rust-sast.yml` | per workflow |

**Already-green CI gates that cover plan items (do not re-build):** Signal Activation Parity (A23), Browser Target Policy / SSRF (A12.b / M6), Hosted-MCP isolation (A11), Secret Detection / gitleaks (A18 / supply chain), Dependency Review + OSV (A19 / supply chain), Confidentiality Guard (M11), `endpointAuthorizationMatrix.test.ts` (A1), `hermesGatewayKeyImmutability.test.ts` (A10), `irohPairingFreshness.test.ts` (A3), `rr12-relay-and-root.test.js` (A1/A9).

---

## 13.1 Automated tests

Each row: **precondition → steps → expected (secure) result → threat id → existing test / MISSING + recommend → CI**.

### A1 — Authorization boundaries (object-level / BOLA / BFLA)
- **Threat:** T-AZ-05, T-AZ-02, T-AZ-07 · **Claim:** C11 · **Component:** C8 · **Boundary:** B2
- **Precondition:** Two authenticated tenants `alice`, `mallory`; emulator with deployed `firestore.rules` + the 100 onCall handlers.
- **Steps:** (1) `mallory` reads/writes every `users/{alice}/**` collection via SDK; (2) `mallory` calls each callable with a body-supplied `uid=alice`; (3) `mallory` writes `workspaces/workspace-alice/.../artifacts` with `ownerUserID=mallory`.
- **Expected:** All cross-tenant reads/writes denied at rules (`ownsUserNamespace`, `firestore.rules:52-54`); every callable re-derives uid from the token and `assertOwnership` throws `permission-denied` (`auth.ts:22-31`). Known residual to assert as *current*: the workspace-artifact write path is **not** uid-bound (T-AZ-02, `firestore.rules:1073-1080`) so the planted doc is accepted but **unreadable** by the victim — pin that the victim cannot read it.
- **Existing:** `functions/src/__tests__/endpointAuthorizationMatrix.test.ts` (per-handler ownership matrix); `firestore-rules-tests/rr12-relay-and-root.test.js:143-201` (cross-user/anon read denial); `firestore-rules-tests/computer-use.test.js:189`.
- **MISSING — recommend:** a rules test that binds `workspaceId`→uid (T-AZ-02 has **zero** rules coverage today); a structural lint asserting all 100 callables call `assertOwnership`/`assertUserStoragePath` before Admin-SDK I/O (T-AZ-05). **CI:** green (A1 matrix runs in `security-pr.yml`).

### A2 — Device revocation (severance + rotation requirement)
- **Threat:** T-PTR-01, T-PTR-02 · **Claim:** C5 · **Component:** C8 + C1 · **Boundary:** B3
- **Precondition:** Three trusted escrow devices; one targeted for revoke; a surviving Mac online.
- **Steps:** Call `revokeEscrowDeviceTrust`; assert in one batch: `trustState→revoked`, active `cloud_vault_key_wrappers` revoked, iroh controllers + `agent_grant_authority` deleted, Signal sessions revoked, **and** a `cloud_vault_rotation_requirements/{id}` doc created with `status=pending` + `survivorDeviceIds`. Then drive survivor pickup and assert `rotateCloudVaultKey` advances generation by exactly one and revokes all old-key wrappers.
- **Expected:** Revoke is atomic (`computerUseSecurity.ts:1456,1508,1535-1557`); after a survivor completes rotation, new writes seal under the new `vaultKeyID` the revoked device cannot derive (`cloudVaultRotation.ts:185,299-307`). Negative-boundary assertion: **before** rotation completes, new material is still sealed under the old key and the revoked Firebase session retains read access (no claw-back) — pin this *known window* so a regression that silently claims instant cut-off is caught.
- **Existing:** `functions/src/__tests__/cloudVaultRotationNonRevokerSurvivor.test.ts` (+ `functions/lib/__tests__/`); `cloudVaultRotationResilience.test.ts`; Swift `AgentLensTests/Active/Security/CloudVaultRotationPickupTests.swift`, `ComputerUseSecurityCallableClientTests.swift`; Android `AndroidCloudVaultRevocationRotationTest.kt`.
- **MISSING — recommend:** a test for the `no_surviving_trusted_device` branch (old key never retired, `computerUseSecurity.ts:1558-1562`); an iOS-survivor starvation test (T-PTR-02 — iOS has no rotate-pickup trigger). **CI:** green (functions tests in `security-pr.yml`/`fast-feedback.yml`).

### A3 — Pairing replay (freshness window)
- **Threat:** T-TRN-05, T-PTR-05 · **Claim:** C9, C12 · **Component:** C6 · **Boundary:** B3 / B2-iroh
- **Precondition:** A valid signed iroh pairing record at known `publishedAtMillis`.
- **Steps:** (1) Re-present the record at `now > publishedAt + 180s` → must reject; (2) re-present inside the window after the NodeId is reassigned → assert the *current* behavior (honored within ~3 min, no per-record nonce); (3) feed a future-dated record (no lower bound today) → record current behavior.
- **Expected:** `IrohRelayPairing.verify` enforces Ed25519 sig + 180s age cap (`IrohRelayPairing.swift:133-168`, `:69-75`); stale records fail closed and the phone does not dial. Pin the **known gap (T-TRN-05)**: there is no per-record nonce / monotonic counter / future-date floor, so an in-window replay is accepted — assert this boundary so adding a nonce is a deliberate change, not an accident.
- **Existing:** `functions/src/__tests__/irohPairingFreshness.test.ts` (+ `functions/lib/__tests__/irohPairingFreshness.test.js`); Android `IrohRelayPairingTest.kt`, `IrohPairingSelectionTest.kt`.
- **MISSING — recommend:** a future-dated-record rejection test and an explicit in-window-replay assertion (freshness only bounds the upper edge today). **CI:** green.

### A4 — Message tampering (sender-auth, AAD relocation)
- **Threat:** T-CRY-01 (downgrade), C8-break (relay impersonation) · **Claim:** C1, C8 · **Component:** C3/C6/C9 · **Boundary:** B5
- **Precondition:** A pinned v3 HPKE-Auth relay session.
- **Steps:** (1) Flip one ciphertext/AAD byte → `open` must fail (GCM tag); (2) move a sealed key/payload to a different AAD slot/lane label → must fail (domain-separated AAD, `HermesRelayCrypto.swift:149-304`); (3) present a v3 frame whose wire `senderPublicKey` differs from the pinned key → `senderKeyUntrusted` (`HermesRelayAuthenticatedRequest.swift:224-227`); (4) attempt v3→v2 on the realtime/iroh lane → `senderAuthRequired` (no fallback, `:195-208`).
- **Expected:** All four denied. Pin the **gateway-lane caveat** separately (see A4b/A23): the gateway message/event lane *does* still accept v2 when the server advertises only v2 (T-CRY-01, `HermesGatewayAPI.swift:890-897,1229-1230`) — assert v2 stays sender-authenticated (no plaintext/forgery downgrade) so the residual is "weaker primitive", not "forgeable".
- **Existing:** Android `HermesRelayCryptoHpkeV3Test.kt`, `HermesRelayWireVectorTest.kt`, `HermesGatewayV2VectorTest.kt`, `HermesGatewayRelayEnvelopeCodecTest.kt`; Swift `IrohRelayRequestHandlerTests.swift`; `functions/src/__tests__/hermesGatewaySealedEvent.test.ts`.
- **MISSING — recommend (A4b):** a negative test that a **cross-lane relocated** ciphertext fails on the Swift host opener; a downgrade-floor test asserting "once v3 negotiated, a later v2 seal on the gateway lane is refused" — there is **no version floor today** (T-CRY-01, `_emit_version_or_refuse` unmerged), so this stays a red test until the floor lands. **CI:** Android/Swift crypto vectors run in PR harness.

### A5 — Attachment tampering (manifest binding, size lie)
- **Threat:** T-ATT-01, T-ATT-04, T-ATT-05 · **Claim:** C3 · **Component:** C12/C3 · **Boundary:** B5/B7
- **Precondition:** A Mercury (iroh blob) transfer with attacker-controlled manifest.
- **Steps:** (1) Advertise `manifest.size=1KB` but commit a multi-GB blob → assert receiver caps/rejects; (2) flip filename/mime in the unsigned manifest → assert displayed identity not trusted for execution; (3) finalize a sealed GCS object and tamper ciphertext → sha256 finalize gate rejects.
- **Expected:** GCS lane enforces `size==manifest` at finalize (`MacFileTransferService.swift:1570`) and ciphertext sha256 (`hermesGateway.ts` finalize `:507`). Pin the **known gap (T-ATT-01, High)**: the **iroh/Mercury** path has *no streaming byte ceiling and no post-fetch `size==manifest` reject* (`blobs.rs:258-284`) → a red test must demonstrate the oversize download is currently accepted, so adding the ceiling is tracked.
- **Existing:** `AgentLensTests/Active/Security/MacFileTransferSecurityTests.swift`; `OpenBurnBarMobileTests/Media/MediaAttachmentManifestStoreTests.swift`; `AgentLensTests/Active/ChatSessionControllerAttachmentTests.swift`; `functions/src/__tests__/hermesGatewayAttachmentInit.test.ts`; `firestore-rules-tests/media-budget.test.js`; `functions/src/__tests__/mediaBudgetFailClosed.test.ts`.
- **MISSING — recommend:** a Mercury oversize/decompression-bomb test (T-ATT-01, no equivalent of the GCS finalize check); a manifest-identity-confusion test (`.jpg` name on executable bytes, T-ATT-05). **CI:** Mac file-transfer security tests run in PR harness.

### A6 — Nonce uniqueness (PoP + high-risk)
- **Threat:** T-GW-03, T-CRY-03 · **Claim:** C4, C12 · **Component:** C9 · **Boundary:** B5
- **Precondition:** A paired gateway client with a pinned signing key.
- **Steps:** Replay the same PoP nonce twice (same and swapped method/path/body); replay a high-risk callable nonce.
- **Expected:** Second use → `pop_nonce_replay` via create-if-absent txn (`hermesGateway.ts:758-771`); swapped request fails signature *before* nonce consume (`:755`); high-risk nonce single-use+TTL (`appCheckAttestation.ts:179-207`).
- **Existing:** `functions/src/__tests__/hermesGateway.test.ts`, `hermesGatewayPopV2.test.ts`; `appCheckAttestation.test.ts`, `appCheckAttestationBinding.test.ts`.
- **MISSING — recommend:** a Swift test that deleting the local replay-cache JSON (`authenticated-request-replay-cache.json`) resets `maxCounter`→-1 and permits bounded replay (T-CRY-03, `HermesRelayAuthenticatedRequest.swift:148-156`) — assert tamper-detection is absent today (documents the file-anchor gap). **CI:** green.

### A7 — Malformed ciphertext (fail-closed open paths)
- **Threat:** T-CRY-04, T-CVS-06 · **Claim:** C1, C2 · **Component:** C3 · **Boundary:** B5/B2
- **Precondition:** Fuzz corpus of malformed base64 / wrong-length keys / truncated tags / wrong-AAD envelopes.
- **Steps:** Feed each to `openBase64`, `openKeyV3`, CloudVault open, Signal at-rest open.
- **Expected:** Every malformed input returns a single typed error and **re-throws** (no catch-and-continue, `HermesRelayCrypto.swift:548-556`); Signal at-rest fails closed on forged/stripped/binding-mismatch (`SignalAtRestSealer`/`SignalAtRestFallbackPolicy`). Pin the legacy v1 no-AAD open path as a known soft-spot (T-CVS-06, `CloudVaultCrypto.swift:605-606`): v1-schema envelopes open under the no-AAD branch — assert it still requires the correct vault key.
- **Existing:** `OpenBurnBarMobileTests/EscrowCryptoRoundTripTests.swift`, `CloudVaultGatewayErrorTests.swift`; `functions/src/__tests__/signalAtRestWrite.test.ts`; Android `CloudVaultSignalSenderAuthTest.kt`, `CloudVaultAadParityTest.kt`.
- **MISSING — recommend:** a property/fuzz harness over all `open*` entrypoints asserting no panic / no plaintext on malformed input. **CI:** crypto round-trip tests run in PR harness.

### A8 — Expired tokens / grants
- **Threat:** T-GW (bearer expiry), T-TOOL-03 · **Claim:** C4 · **Component:** C9 + C1 · **Boundary:** B5/B6
- **Precondition:** An expired bearer token; an expired/revoked capability grant mid-run.
- **Steps:** (1) Use expired bearer → `expired_bearer_token` (`hermesGateway.ts:838-839`); (2) let a grant expire while an in-app broker tool loops → `grantStillActive` re-check denies (`OpenAICompatibleChatGatewayClient.swift:130-135`); (3) revoke a grant while a **CLI** subprocess runs.
- **Expected:** Bearer + broker fail closed. Pin the **known gap (T-TOOL-03)**: the spawned CLI `Process` is **not** terminated by `revokeDesktopControl` (`ChatSessionController.swift:382`) and does not re-check expiry mid-run — a red test must show the subprocess keeps running, tracking the kill-switch gap.
- **Existing:** `functions/src/__tests__/hermesGateway.test.ts`; `functions/src/__tests__/paidEntitlementDowngrade.test.ts`.
- **MISSING — recommend:** a Swift test asserting `revokeDesktopControl` terminates an in-flight CLI process (currently it does not — T-TOOL-03); MAS-build kill-path coverage (T-TOOL-04, panic coordinator compiled out). **CI:** functions only.

### A9 — Signed-URL scope (IDOR on download/upload)
- **Threat:** T-AZ-05, T-AZ-01 · **Claim:** C3, C11 · **Component:** C8 · **Boundary:** B7
- **Precondition:** Authenticated `mallory`.
- **Steps:** Mint a signed URL for `users/alice/...`; finalize an upload to a path outside `users/mallory/`.
- **Expected:** `assertUserStoragePath` rejects when `parts[1] !== uid` (`shared.ts:514-541`); URLs are v4, 10–15 min TTL, uid-scoped (`encryptedSearch.ts:87-141`, `dataExport.ts:240`). Pin the **accepted weakness (T-AZ-01)**: `avatars/{userId}/profile.jpg` is cross-tenant readable (`storage.rules:19`) — a test must assert this is the *only* cross-read and that it is intentional, so an accidental broadening elsewhere fails.
- **Existing:** `functions/src/__tests__/dataExport.test.ts`, `dataExportFailClosed.test.ts`; `firestore-rules-tests/session-log-backup.test.js`.
- **MISSING — recommend:** a per-handler signed-URL path-scope test across every URL-minting callable (only `encryptedSearch`/`dataExport` spot-checked in evidence). **CI:** functions in `security-pr.yml`.

### A10 — WebSocket / relay auth (pinned key, PoP, no-impersonation)
- **Threat:** T-GW-01, C8-break · **Claim:** C4, C8 · **Component:** C9/C6 · **Boundary:** B5
- **Precondition:** A relay/data-plane actor with no device private key.
- **Steps:** (1) Replay a captured bearer without PoP → `legacy_pop_required`/`bad_pop_signature`; (2) attempt to re-publish a **differing** relay/agent key → dropped + `relay_key_change_rejected` / `agent_relay_public_key_immutable`; (3) relay-only actor seals a forged v3 frame → rejected (no sender private key).
- **Expected:** Every authenticated route runs `verifyGatewayRequestPoP` (`hermesGateway.ts:693-757`, `:845`); pinned keys immutable (`:1240-1262`). Pin the **C8 break**: `FirestoreHermesRelaySenderTrustResolver` (`HermesRelaySenderTrustResolver.swift:59-104`) trusts cloud-written `relay_sender_keys`/`trustState` **without** local trust-chain re-verification — a `MISSING` test must assert that wiring `CloudVaultTrustedDeviceChainVerifier` into the relay path rejects a cloud-substituted pinned key.
- **Existing:** `functions/src/__tests__/hermesGatewayKeyImmutability.test.ts` (+ `functions/lib/__tests__/`); `functions/src/__tests__/hermesGateway.test.ts`; `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarHTTPGatewayServerTests.swift`, `BurnBarGatewayMetricsTests.swift`.
- **MISSING — recommend:** relay-trust-resolver chain-verification test (C8); rate-limit test on the HTTP edge (`checkHermesGatewayBearerRateLimit`). **CI:** key-immutability green.

### A11 — Tenant isolation (cloud + hosted MCP)
- **Threat:** T-AZ-03, T-AZ-05, T-AZ-07 · **Claim:** C11 · **Component:** C8/C11 · **Boundary:** B2
- **Precondition:** Two tenants; hosted-MCP with two sessions.
- **Steps:** Attempt cross-session read in hosted MCP; attempt operator-claim escalation to read another tenant's `ops/*`.
- **Expected:** Hosted MCP has no decrypt path and isolates sessions (proofs in `services/hosted-mcp/`); `isOperator()` gates only `ops/*` aggregate metrics (`firestore.rules:38-40`), never user content. Pin T-AZ-03 metadata leakage as *accepted* (counts/timestamps/deviceIds cleartext by design); pin T-AZ-07 (operator claim issuance custody UNKNOWN).
- **Existing:** `services/hosted-mcp/` `npm test` isolation proofs + `scripts/prove-hosted-mcp-live.mjs --local`; `apps/console/test/escrow.test.ts`; `functions/src/__tests__/callableSharedEntitlements.test.ts`.
- **MISSING — recommend:** explicit `burnbarOperator` claim-issuance custody test (issuance path unverified, T-AZ-07). **CI:** green (Hosted MCP Isolation Proofs in `security-pr.yml`).

### A12 — Prompt-injection regression (CU tool results + oracle + CLI lane)
- **Threat:** T-AI-01, T-AI-02, T-TOOL-05 · **Claim:** C6 · **Component:** C10/C1 · **Boundary:** B6
- **Precondition:** Attacker-controlled file/page/process content + a poisoned local conversation log.
- **Steps (a CU/oracle):** (1) Agent calls a non-allowlisted tool (`read_file`/`run_terminal`/`browser_screenshot`) on attacker content → assert result is wrapped `<UNTRUSTED_CONTENT>`; (2) trigger the oracle "authoritative findings" path with a poisoned indexed snippet.
- **Steps (b CLI):** Place an injection in a workspace file the CLI agent ingests; assert it is tagged untrusted.
- **Expected:** `browser_extract` + `mac_inspect_accessibility` results ARE wrapped (`OpenAICompatibleChatGatewayClient.swift:529`). Pin the **known gaps**: file/shell/screenshot/clipboard results are **unwrapped** (T-AI-01, allowlist is not default-deny, `:1165-1169`); the oracle injects snippets **unwrapped** framed "authoritative" (T-AI-02, `ChatSessionController.swift:1609-1614`); the CLI lane wraps only the chat user turn (T-TOOL-05, `CLIArgumentBuilder.swift:248`). These are `MISSING` red tests until wrapping is default-deny.
- **Existing:** `AgentLensTests/Active/Security/PromptInjectionHardeningTests.swift` (delimiter-breakout defang at `:23-39`); `OpenBurnBarMobileTests/ChartStudioPromptEngineTests.swift`.
- **MISSING — recommend:** assertions that **all** content-returning CU tool results are wrapped (default-deny), that the oracle path routes through `wrapUntrusted`, and that CLI-ingested files are tagged — directly closes RR-15's remaining surface. **CI:** prompt-injection hardening runs in PR harness.

### A13 — Tool-policy enforcement (capability gate)
- **Threat:** T-TOOL-01, T-TOOL-07, T-TOOL-08 · **Claim:** C6 · **Component:** C1 · **Boundary:** B6
- **Precondition:** Grants at each preset (read-only / workspace / all / YOLO).
- **Steps:** For each tool, assert `grant.supportsAll(requiredCapabilities)` gating; assert deny-region beats allow rules and signed phone authority; assert no-grant forces read-only/plan CLI flags.
- **Expected:** In-app broker enforces per-tool caps (`OpenAICompatibleChatGatewayClient.swift:136-139`); deny registry not editable (`ComputerUseDenyRegistry.swift:13`); deny region wins (`ComputerUseCapabilityGate.swift:335`). Pin the **CLI-lane gap (T-TOOL-01)**: external CLI agents have **no in-process gate** after spawn (`CLIArgumentBuilder.swift:47-103`) — a red test must show OpenBurnBar cannot intercept a CLI tool call. Pin T-TOOL-08: path denies (`/admin`,`/billing`) are heuristic window-title regex.
- **Existing:** `AgentLensTests/Active/Security/ComputerUseSecurityCallableClientTests.swift`; `functions/src/__tests__/computerUseSecurity.test.ts`, `agentGrantAuthority.test.ts`; Android `ComputerUseSecurityCallableClientTest.kt`.
- **MISSING — recommend:** a deny-region-beats-trusted-scope unit test; a path-deny SPA-evasion test (T-TOOL-08). **CI:** functions green; Swift gate test in harness.

### A14 — High-impact action approval (manual vs trusted)
- **Threat:** T-TOOL-02, T-AI-07 · **Claim:** C6, C7 · **Component:** C1 · **Boundary:** B6
- **Precondition:** Sessions in `.manual`, `.step`, `.trusted`.
- **Steps:** Emit a high-impact action (typing/shortcut/shell) in each mode; in trusted mode emit an action matching an active scope allow rule.
- **Expected:** Manual/step **block** on human approve/reject with no auto-approve fallback (`ComputerUseRunCoordinator.swift:280-343`, `ComputerUseDaemonApprovalPresenter.swift:119-152`); entering trusted requires local-auth (`AgentCapabilityGrant.swift:39`). Pin the **known caveat (C6 Partial)**: in trusted mode a scope-allowed high-impact action auto-dispatches with **no per-action approval** (`ComputerUseCapabilityGate.swift:362-363`, `ComputerUseRunCoordinator.swift:262-269`) — assert this boundary so the absent "re-approve on new domain / >N chars" control is tracked (unimplemented per evidence).
- **Existing:** `AgentLensTests/Active/Security/ComputerUseSecurityCallableClientTests.swift`; `functions/src/__tests__/computerUseSecurity.test.ts`, `appendAuditEventRequired.test.ts`, `panic.test.ts`, `phoneControlAuthorityKeyKind.test.ts`.
- **MISSING — recommend:** the threat-model-prescribed "re-approve high-impact even in trusted/step on new domain or large output" control + its test (unimplemented); an SE-P256 vs ed25519 proof-divergence test (C7 SE exemption, `PhoneControlAuthorityValidator.swift:493-503`). **CI:** functions green.

### A15 — Memory poisoning (RAG provenance)
- **Threat:** T-AI-03 · **Claim:** C6 · **Component:** C10 · **Boundary:** B6
- **Precondition:** A third-party-influenced agent CLI log on disk.
- **Steps:** Ingest the log through `LogParser/*`; retrieve it later; assert provenance/quarantine.
- **Expected:** Retrieval output is wrapped at `formatPack` (`ContextBuilder.swift:146`). Pin the **gap**: there is **no write-time validation, no provenance trust tier, no poisoned-chunk quarantine** (T-AI-03) and the same chunk reaches the model **unwrapped** via the oracle path — `MISSING` red tests.
- **Existing:** `AgentLensTests/Active/OpenBurnBarRetrievalReplayGoldenTests.swift` (retrieval golden); `OpenBurnBarMobileTests/PensieveMemorySearchSignalTests.swift`.
- **MISSING — recommend:** a write-time provenance-tier test and a poisoned-chunk deletion/quarantine workflow test. **CI:** retrieval golden in harness.

### A16 — Malicious tool output (chaining into shell)
- **Threat:** T-AI-01 → T-AI-07, T-TOOL-02 · **Claim:** C6 · **Component:** C1/C10 · **Boundary:** B6
- **Precondition:** Trusted/YOLO session enabled.
- **Steps:** Have a tool return attacker content instructing `shell_run_unrestricted`; assert what executes.
- **Expected:** Non-YOLO: `shell_run` is `sandbox-exec`-confined (`OpenAICompatibleChatGatewayClient.swift:344-357,662`), network denied. Pin **T-TOOL-02/T-AI-07 (Critical)**: under `.trusted`+`.shellUnrestricted`, `runShellUnrestricted` (`:367`) runs `/bin/zsh` unsandboxed with **only a SHA-256 audit, no per-N-action re-auth** (TODO `:381`) — a red test must show injection-to-RCE is reachable when YOLO is opted in, and that MAS build blocks `.shellUnrestricted` but **not** the CLI `--dangerously-skip-permissions` flags.
- **Existing:** `AgentLensTests/Active/Security/PromptInjectionHardeningTests.swift`; `functions/src/__tests__/panic.test.ts`.
- **MISSING — recommend:** an injection-to-RCE drill harness (also see M13) and a MAS-vs-non-MAS YOLO-flag parity test. **CI:** prompt-injection hardening in harness.

### A17 — Unsafe output rendering (insecure output handling)
- **Threat:** T-AI-05, T-ATT-08 · **Claim:** C6 · **Component:** C8/C12 · **Boundary:** B6
- **Precondition:** Hosted analyst JSON with a hostile `missionCandidate`; a legacy non-octet attachment download.
- **Steps:** Render `InsightAnalysisResult` recommendations; serve a gateway attachment download URL.
- **Expected:** Strict JSON envelope, bounded sizes, digest-only input (`insightsHostedAnswer.ts:301-308,330`). Pin gaps: no semantic safety validation of recommended missions (T-AI-05); download URL lacks forced `Content-Disposition: attachment` (T-ATT-08, `handleHermesGatewayAttachmentDownloadUrl:1653-1658`) — sealed objects are octet-stream so impact is low, but assert the disposition header is set for legacy objects.
- **Existing:** `functions/src/__tests__/misc.test.ts` (analyst envelope shape adjacent).
- **MISSING — recommend:** a `responseDisposition=attachment` test on the download-URL handler (T-ATT-08); a mission-candidate safety-validation test (T-AI-05). **CI:** none specific.

### A18 — Log redaction (no plaintext bodies/secrets)
- **Threat:** T-AND-06, C13-break · **Claim:** C13 · **Component:** C8/C5/C4 · **Boundary:** B2/B1
- **Precondition:** Errors/breadcrumbs carrying user text + known secret shapes.
- **Steps:** Drive `logCallableFailure` with an `Error.message` embedding a body; emit client `silentFailure` with an error description; emit a server crash event.
- **Expected:** Server scrubs known secret shapes + truncates UID (`logging.ts:16-29,75-81`); Sentry strips request body (`sentry.ts:41-141`); client `AppLogger.sanitizeMetadata` redacts `message/content/body/prompt` and uses `.private(mask:.hash)` (`AppLogger.swift:45-103`). Pin the **gaps (C13 Partial)**: free-form `Error.message` and `silentFailure`'s un-redacted `error` key (`AppLogger.swift:149`) are pattern-checked only; client Sentry inits set **no** `beforeSend`/`maxBreadcrumbs` — red tests for those residual paths.
- **Existing:** `functions/src/__tests__/logging.test.ts`, `sentry.test.ts`, `callable-sentry.test.ts`.
- **MISSING — recommend:** a client-side `beforeSend`/breadcrumb-scrub test (no hook today); an `error`-key redaction test for `silentFailure`. **CI:** server logging/sentry tests green; **Confidentiality Guard** (M11) covers tracked-tree content leaks.

### A19 — API rate limits
- **Threat:** T-GW-01, T-AZ-08, T-TRN-06 · **Claim:** C4 · **Component:** C9/C8 · **Boundary:** B5/B2
- **Precondition:** A valid bearer; an anonymous client hitting public endpoints; a flood of iroh dials.
- **Steps:** Exceed per-bearer gateway limit; flood `latestRouterRundown`/`healthLive`; flood iroh `accept_one`.
- **Expected:** `checkHermesGatewayBearerRateLimit` throttles (`hermesGateway.ts:1119`). Pin gaps: public HTTP endpoints have **no per-IP rate limit** (T-AZ-08, cost/DoS only); iroh `accept_one` has **no connection-rate / concurrent-handshake cap** (T-TRN-06, `lib.rs:450`) — red tests document the amplification surface.
- **Existing:** `functions/src/__tests__/publicRateLimit.test.ts`, `routerRundownEndpoint.test.ts`.
- **MISSING — recommend:** an iroh connection-flood test in the Rust crate (T-TRN-06); a per-IP throttle test for public endpoints. **CI:** rate-limit tests green.

### A20 — File-upload restrictions (size/type/seal)
- **Threat:** T-ATT-02, T-ATT-06, T-ATT-07 · **Claim:** C3 · **Component:** C12 · **Boundary:** B7
- **Precondition:** Inbound media on iOS and Mac.
- **Steps:** Receive media with no seal key; receive an oversize inbound; upload a denylisted content type via legacy path.
- **Expected:** Sealed writes force octet-stream; finalize checks size+sha256. Pin gaps: iOS stores received media **plaintext** with no capability-gate/seal/quarantine (T-ATT-02, `iOSFileTransferService.handleAdvertise`); Mac seal-at-rest **fails open** when no session key (T-ATT-06, `MacFileTransferService.swift:420-422`) — red tests for both; legacy content-type denylist is dead but incomplete (T-ATT-07).
- **Existing:** `AgentLensTests/Active/Security/MacFileTransferSecurityTests.swift`; `OpenBurnBarMobileTests/Media/MediaAttachmentManifestStoreTests.swift`; `functions/src/__tests__/hermesGatewayAttachmentInit.test.ts`.
- **MISSING — recommend:** an iOS inbound-seal/quarantine parity test (T-ATT-02); a Mac fail-open-vs-refuse test when seal key absent (T-ATT-06). **CI:** Mac file-transfer tests in harness.

### A21 — Local agent sandboxing
- **Threat:** T-DMN-02, T-TOOL-10, T-DMN-04 · **Claim:** C6, C7 · **Component:** C2/C1 · **Boundary:** B1/B4
- **Precondition:** A sandboxed `shell_run`; the daemon RPC surface.
- **Steps:** From inside `shell_run`, attempt network egress, write outside workspace, read `~/.ssh`/`~/.aws`/keychains/app state; from the app, attempt a privileged daemon RPC and assert the daemon's own gate.
- **Expected:** `restrictedShellSandboxProfile` denies network + write-confines + deny-reads secret stores (`OpenAICompatibleChatGatewayClient.swift:662-723`). Pin gaps: `(allow default)` reads outside the curated deny list (T-TOOL-10, `:723`, deny-list not allow-list); the **daemon runs unsandboxed** as the login user (T-DMN-02) and does **not** cryptographically re-verify the phone single-use proof (T-DMN-04) — red tests documenting blast radius.
- **Existing:** `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/*` (gateway/server); `AgentLensTests/Active/Security/MacEscrowCredentialProducerTests.swift`.
- **MISSING — recommend:** a `shell_run` egress/secret-read deny suite; a daemon-side proof-verification test (T-DMN-04, daemon does not hold the phone verifying key). **CI:** daemon tests in harness.

### A22 — Pairing-key pinning (T-TRN-01)
- **Threat:** **T-TRN-01 (Critical)**, T-PTR-03 · **Claim:** C9, C8 · **Component:** C6 · **Boundary:** B2-iroh
- **Precondition:** A cold-start iOS session; a cloud/admin able to write `users/{uid}/iroh_pairing_keys/host` + a matching signed record at an attacker NodeId.
- **Steps:** Serve a swapped host pairing key on first fetch; assert whether iOS pins, persists, or surfaces a safety code before dialing.
- **Expected (target):** iOS pins the host key (Keychain) + compares an out-of-band safety code before dial, symmetric with the Keychain-pinned Mac→phone controller key. Pin the **current Critical gap**: `FirestoreIrohPairingPublicKeyProvider.swift:27-47` caches the host key **in-memory only**, never persisted/pinned, so a cloud-substituted key is TOFU-trusted on a cold session → MITM/redirect of the iroh control channel (payload confidentiality survives via the independent E2E relay layer). This is a **MISSING** red test that must fail until Keychain pinning + safety-code land.
- **Existing:** `OpenBurnBarMobileTests/EscrowCryptoRoundTripTests.swift` (escrow trust-chain adjacent); Android `PairedMacIdentityTest.kt`, `IrohRelayPairingTest.kt`.
- **MISSING — recommend (priority):** an iOS host-key-pinning + safety-code test asserting a swapped cold-start key is **rejected** (closes T-TRN-01); a parity test confirming Mac→phone vs phone→Mac pinning symmetry. **CI:** none today — this is the headline Critical with no direct gate.

### A23 — Signal non-activation / downgrade floor
- **Threat:** T-CVS-01, T-CVS-02, T-CRY-01 · **Claim:** C14, C1 · **Component:** C8/C3 · **Boundary:** B2
- **Precondition:** Committed registry + Remote Config defaults.
- **Steps:** Assert no domain carries `signal-hpke-identity-seal-v1`, the gateway production Signal set is empty, no committed flag flips Signal on; assert read path fails closed on forged/stripped sender-auth, fails open only to AES-GCM legacy (never plaintext).
- **Expected:** Parity holds (`scripts/ci/verify-signal-activation-parity.sh`; gateway set empty `hermesGateway.ts:152`). Pin latent T-CVS-01/02: a server stripping `signalEnvelope` forces legacy unauthenticated decode — a test must assert the legacy floor is still AES-GCM path-AAD sealed (no plaintext) and flag that the sender-auth bypass bites once Signal is live.
- **Existing:** `functions/src/__tests__/signalActivationReadiness.test.ts`, `signalAtRestWrite.test.ts`, `hermesGatewaySignalEnvelope.test.ts`, `signalEnvelopeExport.test.ts`; Android `AndroidSignalProducerInstrumentedTest.kt`, `CloudVaultSignalSenderAuthTest.kt`, `AndroidSignalInteropKatTest.kt`.
- **MISSING — recommend:** an explicit `signalEnvelope`-strip→legacy-floor test asserting no plaintext exposure (T-CVS-01). **CI:** green (Signal Activation Parity in `security-pr.yml`).

---

## 13.2 Manual tests

These require human judgment, physical devices, hostile-content fixtures, or out-of-band channels. Each: **precondition → steps → expected (secure) result → threat id → existing test ref / MISSING + recommend**.

### M1 — Pairing ceremony UX / safety-code
- **Threat:** T-PTR-04, T-TRN-01 · **Claim:** C8, C9 · **Boundary:** B3
- **Precondition:** Fresh device approval flow on Mac + phone.
- **Steps:** Approve a new escrow device; observe whether an out-of-band safety code is presented and compared at approval time.
- **Expected (secure):** Operator compares a matching OOB safety code before trust is granted. **Current:** `EscrowDeviceSafetyCode.swift:202 defaultEnabled=false` — the approve-time compare UI is **OFF by default** (T-PTR-04). **MISSING — recommend:** enable approve-time safety-code compare by default + manual UX verification.
- **Existing:** none (UX); `apps/console/test/escrow.test.ts` covers server-side approval logic only.

### M2 — Device spoofing
- **Threat:** T-PTR-04, T-TOOL-06 · **Claim:** C8 · **Boundary:** B3
- **Precondition:** A second account / write-capable Firestore access.
- **Steps:** Pre-seed an `agent_grant_authorities/{deviceId}` key before first pin; attempt to enroll a device the human never visually confirmed.
- **Expected:** Controller pin (`validator.registerPeer`) rejects a key differing from the operator-pinned key; trust-chain XEdDSA fails closed server-side (`computerUseSecurity.ts:1396-1423`). Pin the **TOFU window**: the cloud doc is the first-pin trust root (T-TOOL-06). **MISSING — recommend:** OOB confirmation at first pin.

### M3 — Relay-compromise simulation
- **Threat:** T-TRN-03, T-TRN-04, C8-break · **Claim:** C1, C8 · **Boundary:** B5/B7
- **Precondition:** A controllable malicious relay / on-path adversary.
- **Steps:** (1) Drop/blackhole iroh dials and observe silent fallback to Firestore long-poll; (2) attempt to read sealed payloads; (3) correlate NodeIds/relay URL/direct IPs.
- **Expected:** Payloads stay E2E-sealed; fallback is **audited** (`HermesCompositeRelayTransport.swift:134-148`). Pin gaps: control-plane + CLI streams **silently downgrade** to the more-observable Firestore path (T-TRN-03, no fallback-rate alarm); raw NodeIds/relay URL/IPs are cleartext in pairing/audit docs (T-TRN-04). **MISSING — recommend:** a fallback-rate alarm + a metadata-minimization review.
- **Existing:** Android `HermesCompositeRelayTransportTest.kt`, `HermesIrohRelayTransportTest.kt` (transport selection, not adversarial drop).

### M4 — Malicious attachment
- **Threat:** T-ATT-01, T-ATT-05 · **Claim:** C3 · **Boundary:** B5/B7
- **Precondition:** A peer sending a lied-about Mercury manifest + a `.jpg`-named executable.
- **Steps:** Send a manifest claiming 1KB but committing a multi-GB blob; send mismatched filename/mime; open the received file on Mac.
- **Expected:** Mac quarantine xattr gates Gatekeeper on open. Pin gaps: no streaming byte ceiling on the iroh path (T-ATT-01 disk-fill DoS); content-type trusted from sender extension (T-ATT-05). **MISSING — recommend:** Mercury streaming size ceiling + receiver content sniffing.
- **Existing:** `MacFileTransferSecurityTests.swift` (automated portion); manual disk-fill drill MISSING.

### M5 — Malicious retrieved document (RAG)
- **Threat:** T-AI-03, T-AI-02 · **Claim:** C6 · **Boundary:** B6
- **Precondition:** A poisoned agent log / indexed document with embedded instructions.
- **Steps:** Index it; ask a question that retrieves it; observe whether the model treats the snippet as instructions, especially via the oracle "authoritative" path.
- **Expected:** RAG snippets wrapped at `formatPack`. Pin: oracle path injects the same snippet **unwrapped** framed authoritative (T-AI-02). **MISSING — recommend:** route oracle context through `wrapUntrusted`.
- **Existing:** `OpenBurnBarRetrievalReplayGoldenTests.swift` (golden, not adversarial steer).

### M6 — Malicious webpage (browser SSRF / rebind)
- **Threat:** T-AI-04 · **Claim:** C6 · **Boundary:** B6
- **Precondition:** A page that 302/meta-refresh/JS-redirects to `169.254.169.254` or a public hostname resolving to a private IP.
- **Steps:** `goto` the public host; let it redirect; `browser_click` an internal link; `browser_extract`.
- **Expected:** Initial `goto` host policy blocks loopback/metadata/file:// (`OpenBurnBarBrowserTargetPolicy.swift:52`, enforced `ComputerUseRunCoordinator.swift:785`). Pin gaps: **no per-navigation/redirect re-validation, no resolved-IP (post-DNS) enforcement** (T-AI-04) — internal/metadata exfil into context is reachable via redirect/click. **MISSING — recommend:** per-navigation + post-DNS re-check.
- **Existing:** `scripts/test-playwright-bridge-guard.mjs` (initial-URL policy, **CI-gated** Browser Target Policy in `security-pr.yml`); `computer-use-loopback-test.yml`. Redirect/rebind manual drill MISSING.

### M7 — Agent tool misuse
- **Threat:** T-TOOL-01, T-TOOL-07 · **Claim:** C6 · **Boundary:** B6
- **Precondition:** A `.workspace` (non-trusted) grant.
- **Steps:** Drive an external CLI (codex `--sandbox workspace-write`, droid `--auto medium`) to perform autonomous in-workspace shell actions.
- **Expected:** Default read-only when no grant. Pin gap: a non-trusted `.workspace` grant authorizes **autonomous shell** relying only on the CLI's own sandbox; OpenBurnBar cannot verify the CLI honors it (T-TOOL-01, T-TOOL-07, `CLIArgumentBuilder.swift:89-91,124-126`). **MISSING — recommend:** per-action interposition or a vetted CLI-sandbox attestation.

### M8 — Local priv-esc
- **Threat:** T-DMN-01, T-DMN-03, T-DMN-05 · **Claim:** C6 · **Boundary:** B1
- **Precondition:** Same-uid attacker on the Mac.
- **Steps:** (1) Inject into the signed app and exercise main-socket RPC; (2) swap the user-writable daemon binary between validate and launchd exec (TOCTOU); (3) set `OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1`.
- **Expected:** Hardened runtime + library validation block non-first-party dylib injection; live socket peer code-sig gate. Pin gaps: code-signature == authorization with **no capability attenuation** (T-DMN-01); pre-exec check is TOCTOU + launchd does not re-verify (T-DMN-03); a same-uid env override disables the peer gate (T-DMN-05, `OpenBurnBarDaemonMain.swift:76`). **MISSING — recommend:** capability attenuation + remove the env escape hatch from release builds.

### M9 — Desktop IPC abuse
- **Threat:** T-DMN-06, T-DMN-07, T-DMN-04 · **Claim:** C6 · **Boundary:** B1/B4
- **Precondition:** A root process / a process forging first-party identity on the HID bridge.
- **Steps:** Drive locked-screen input via the privileged input socket; exercise the XPC audit-token path.
- **Expected:** Full DR + CD-flag check on the root peer (`PrivilegedInputExecutionSocketServer.swift:231`); fail-closed when the private audit-token selector is unavailable (`PrivilegedInputXPCPeerValidator.swift:25`). Pin: HID root peer trusted by code-sig alone (T-DMN-06, accepted — root already wins); SPI fragility (T-DMN-07). **MISSING — recommend:** none beyond monitoring SPI availability.

### M10 — Mobile deep-link abuse
- **Threat:** T-AND-03, T-AND-02 · **Claim:** C13 · **Boundary:** B4 (Android)
- **Precondition:** A malicious co-installed Android app.
- **Steps:** Fire `burnbar://` intents and AppWidget broadcasts; attempt HTTP to a non-deny-listed host on a hostile network.
- **Expected:** Deep-link is navigation-only, no auto-submit (`MainActivityIntentActions.kt`); backend hosts hard-denied cleartext. Pin gaps: deep-link input still parsed in release, receivers lack signature permission (T-AND-03); base-config cleartext permits HTTP to non-deny-listed hosts (T-AND-02, `network_security_config.xml:33`). **MISSING — recommend:** signature-permission on receivers + LAN-only TLS migration.
- **Existing:** Android `PairedMacControlsScreenSupportTest.kt` (UI support, not deep-link fuzz).

### M11 — Crash / log privacy
- **Threat:** T-AND-06, C13-break · **Claim:** C13 · **Boundary:** B2/B1
- **Precondition:** A forced crash with prompt/credential fragments in memory.
- **Steps:** Trigger a crash/ANR on Android and a Sentry event on Mac/iOS; inspect the uploaded payload + breadcrumbs.
- **Expected:** FLAG_SECURE limits screen capture; DSN injected only in CI/non-debug. Pin gaps: no reviewed PII-scrubbing/`beforeSend` on Android Sentry (T-AND-06); client iOS/Mac Sentry inits set no `beforeSend`/`maxBreadcrumbs` (C13). **MISSING — recommend:** `beforeSend` scrubbers on all client Sentry inits.
- **Existing:** **CI-gated** `confidentiality-guard.yml` (tracked-tree content scan); server `sentry.test.ts`. Live crash-payload inspection is manual + MISSING.

### M12 — Admin access abuse (Admin-SDK / IAM)
- **Threat:** T-AZ-05, T-AZ-06, C8-break · **Claim:** C2, C8, C11 · **Boundary:** B2
- **Precondition:** Deployed GCP project (out-of-band; not provable from repo).
- **Steps:** Enumerate which service accounts hold `cloudkms.cryptoKeyDecrypter` + `secretmanager.secretAccessor`; confirm whether the relay data-plane SA can write `relay_sender_keys`/`escrow_devices`; confirm console App Check enforcement, PITR/backups.
- **Expected:** Least-privilege IAM; relay data-plane cannot write trust roots; App Check enforced; PITR on. Pin: Admin SDK structurally bypasses rules (T-AZ-05); App Check console enforcement **UNKNOWN from repo** (T-AZ-06); the C8 break is reachable only if relay + control-plane share admin creds. **MISSING — recommend:** deployed IAM + App Check + PITR review (this is a Cure53 / live-config item — see §13.3).

### M13 — YOLO injection-to-RCE drill
- **Threat:** **T-TOOL-02 / T-AI-07 (Critical/High)** · **Claim:** C6 · **Boundary:** B6
- **Precondition:** A user has opted a session into `.trusted` + `.shellUnrestricted` (YOLO), non-MAS build.
- **Steps:** Plant an indirect injection in a tool result / workspace file instructing `shell_run_unrestricted "<payload>"`; let the model obey; observe whether `/bin/zsh` runs the payload unsandboxed at user privilege with no per-action approval.
- **Expected (target):** A per-N-action re-auth or per-action approver gate stops the payload. **Current:** `runShellUnrestricted` (`OpenAICompatibleChatGatewayClient.swift:367`) executes with only a SHA-256 audit and **no per-action re-auth** (TODO `:381`) → injection-to-RCE is reachable. This drill must demonstrate the gap and be the regression guard once per-N-action re-auth lands. **MISSING — recommend:** implement per-N-action re-auth; add an automated injection-to-RCE harness (links A16).
- **Existing:** `PromptInjectionHardeningTests.swift` (wrapping only), `panic.test.ts` (kill path). End-to-end RCE drill MISSING.

---

## 13.3 External scope pointer (Cure53)

Items that **cannot be settled from the repo** and require live infrastructure, physical devices, or adversarial pentest are scoped to the external engagement. See **`cure53-audit-brief.md`** for the authoritative external scope. The hand-off set, by priority:

| Priority | Item | Why external | Threat / Claim |
|---|---|---|---|
| P0 | **iOS host-pairing-key pinning (T-TRN-01)** — verify a cloud-substituted host key on cold start | Needs adversarial cloud + device; no CI gate exists (A22/M1) | T-TRN-01 / C9, C8 |
| P0 | **YOLO injection-to-RCE drill (M13)** — end-to-end injection→`/bin/zsh` | Needs hostile-content + opted-in trusted device | T-TOOL-02, T-AI-07 / C6 |
| P0 | **Admin-SDK / IAM & App Check enforcement (M12)** — KMS/Secret-Manager decrypter scope, relay-vs-control-plane creds, console App Check, PITR | Deployed GCP state, not in repo | T-AZ-05/06, C8 / C2, C8, C11 |
| P1 | **Prompt-injection default-deny wrapping (A12)** — CU tool results + oracle + CLI lane | Model-in-the-loop adversarial eval | T-AI-01/02, T-TOOL-05 / C6 |
| P1 | **Relay-compromise / metadata correlation (M3)** | Needs controllable malicious relay | T-TRN-03/04 / C1, C8 |
| P1 | **Mercury oversize / decompression DoS (A5/M4)** | Live blob transfer | T-ATT-01 / C3 |
| P2 | **Browser redirect / DNS-rebind SSRF (M6)** | Live network + DNS control | T-AI-04 / C6 |
| P2 | **Gateway v3→v2 downgrade floor (A4b)** — `_emit_version_or_refuse` unmerged | Live deployed gateway version advertisement | T-CRY-01 / C1 |
| P2 | **Provider retention / no-train posture** — does the local gateway / OpenRouter retain? | Deployment-dependent, UNKNOWN from code | T-AI-06 / C2 |

Deployed-config open questions feeding the brief (from `_evidence/*` "Open questions / UNKNOWN"): `ENFORCE_APP_CHECK`, `REQUIRE_HIGH_RISK_NONCE`, `OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED`, Firestore TTL on `pop_nonces`/`high_risk_nonces`, PITR/backups, `burnbarOperator` claim issuance custody, and whether escrow revoke invalidates the device's Firebase session.

---

## Appendix — Threat → test cross-reference

| Threat id | Severity | Automated | Manual | Existing test? |
|---|---|---|---|---|
| T-TRN-01 | Critical | A22 | M1 | partial (Android pairing) — iOS pin test MISSING |
| T-TOOL-02 / T-AI-07 | Critical/High | A14, A16 | M13 | wrapping only; RCE drill MISSING |
| T-PTR-03 | High | A22 | M1 | MISSING |
| T-TRN-02 / T-TRN-03 | High | A19 | M3 | partial (transport selection) |
| T-DMN-01 / T-DMN-02 | High | A21 | M8 | partial (daemon tests) |
| T-TOOL-01 / T-TOOL-03 / T-TOOL-05 | High | A8, A12, A13 | M7 | partial; CLI kill + default-deny MISSING |
| T-AI-01 / T-AI-02 | High | A12 | M5 | partial (hardening, golden) |
| T-CVS-03 | High | A7 | M12 | partial (crypto round-trip) |
| T-ATT-01 | High | A5 | M4 | automated portion; oversize MISSING |
| T-SC-01 / T-SC-02 / T-SC-03 | High/Med | (supply-chain CI) | M12 | gitleaks/OSV/dep-review green; cargo-deny no-op MISSING |
| T-AZ-* | Low–Med | A1, A9, A11, A19 | M12 | matrix + rr12 green |
| T-CRY-01..05 | Med–Info | A4, A6, A7 | M3 | crypto vectors green |
| T-PTR-01 / T-PTR-02 / T-PTR-04 / T-PTR-05 | Med | A2, A3 | M1, M2 | rotation/pairing tests green |
| T-AI-03..06 | Med | A12, A15, A17 | M5, M6 | retrieval golden + SSRF guard |
| T-AND-01..06 | Med–Low | A18, A20 | M10, M11 | partial (Android stores/signal) |
| T-TRN-04..07 | Med–Low | A19 | M3 | partial |
| C14 (non-claim) | — | A23 | — | Signal Activation Parity green (CI) |
