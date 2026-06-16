# Findings

## FINDING-001: Kill-switch watchdog socket has no peer authentication
- **Severity:** High
- **Category:** Availability / Safety Control Bypass
- **Affected component:** `PrivilegedInputKillSwitchWatchdogMain.swift`
- **Affected asset:** ASSET-009 (Privileged Input Kill Switch)
- **Description:** The kill-switch watchdog listens on `/var/run/openburnbar-killswitch-watch.sock` with 0600 root-only permissions but performs NO peer authentication. Any root process can send `{"action":"clear"}` to disarm the kill switch or `{"action":"activate"}` to false-arm it (DoS).
- **Evidence:** `PrivilegedInputKillSwitchWatchdogMain.swift:60-93` — `handleClient()` decodes JSON and dispatches `activate`/`clear`/`health` without any UID check, PID check, or code-signature validation.
- **Exploitability:** Requires root on the Mac (high bar). Combined with a separate HID compromise, could allow agent actions to continue after user panic.
- **Impact:** Safety control disarmed. One of multiple independent panic paths weakened.
- **Likelihood:** Low
- **Existing controls:** File permissions 0600 root; three other independent panic paths (hotkey, auth gate, remote kill switch, AX revocation)
- **Recommendation:** Add `PrivilegedPeerAuthenticator` codesig gate to the watchdog socket handler before honoring activate/clear. The pattern already exists in `PrivilegedInputExecutionSocketServer.validateSocketPeer()`.
- **Acceptance criteria:** Watchdog socket rejects connections from non-first-party-signed processes; test proves rejection.
- **Regression test:** Connect to watchdog socket with unsigned binary, verify rejection.
- **Owner suggestion:** Daemon/HID team
- **Status:** Open
- **First seen:** 2026-06-16
- **Last seen:** 2026-06-16
- **Related threats:** THREAT-001
- **Related claims:** CLAIM-004, CLAIM-015
- **Score impact:** Caps score at 79 (Engineering Maturity)

## FINDING-002: Local-auth-proof verifier dormant in production daemon
- **Severity:** Medium
- **Category:** Authorization / Defense-in-Depth Gap
- **Affected component:** `OpenBurnBarDaemonMain.swift`, `BurnBarDaemonServer+RPCComputerUse.swift`
- **Affected asset:** ASSET-008 (Capability Tokens), Computer Use privileged input
- **Description:** `DaemonLocalAuthProofVerifier` is fully implemented (Ed25519 signature, single-use replay, op-hash binding, pinned-key resolution) but hardcoded to `nil` in production. The `enforceLocalAuthProof` gate returns nil (no-op) for `computerUseSessionStart` and `computerUseInvoke` RPCs.
- **Evidence:** `OpenBurnBarDaemonMain.swift:69` — `let localAuthProofVerifier: DaemonLocalAuthProofVerifier? = nil`; `BurnBarDaemonServer+RPCComputerUse.swift:129-131` — `guard let verifier = localAuthProofVerifier else { return nil }`
- **Exploitability:** Requires compromising a first-party signed process that passes the peer codesig gate.
- **Impact:** If signed process is compromised, fabricated computer-use grants reach daemon without phone-proof re-verification.
- **Likelihood:** Low
- **Existing controls:** Peer codesig gate, capability token binding, kill switch
- **Recommendation:** Implement daemon-side pinned phone-key store and app-side proof population, then wire the verifier.
- **Acceptance criteria:** `localAuthProofVerifier` is non-nil in production daemon; RPCs enforce phone proof.
- **Regression test:** Submit computer-use grant without valid phone proof, verify rejection.
- **Status:** Open (tracked as Deferred in code comments)
- **First seen:** 2026-06-16
- **Score impact:** -3 points

## FINDING-003: Phone-side trust mode picker presents all modes
- **Severity:** Medium-High
- **Category:** Authorization Bypass
- **Affected component:** `PhoneControlOptionSheet.swift`
- **Description:** The phone-side trust mode UI iterates `ComputerUseTrustMode.allCases` (all three modes: manual, step, trusted) without filtering. `downgradeTrustMode(mode)` calls `state.setTrustMode(mode)` without direction validation. A compromised phone can attempt elevation to Trusted mode.
- **Evidence:** `PhoneControlOptionSheet.swift` — `ForEach(ComputerUseTrustMode.allCases, id: \.self) { mode in ... onTrustMode(mode) }`; `AgentWatchReceiver.swift:102-103` — `func downgradeTrustMode(_ mode: ComputerUseTrustMode) { state.setTrustMode(mode) }`
- **Impact:** Violates documented invariant "phone can only downgrade trust; elevation requires the Mac."
- **Likelihood:** Medium (requires phone access)
- **Existing controls:** Capability gate still enforces scope rules in Trusted mode; budget caps still apply
- **Recommendation:** Filter `ComputerUseTrustMode.allCases` to only show modes with rawValue <= current mode rawValue.
- **Acceptance criteria:** Phone UI only shows modes that are <= current trust level.
- **Regression test:** Start session in Manual mode, verify phone only shows Manual. Start in Trusted, verify phone shows all three.
- **Status:** Open
- **First seen:** 2026-06-16
- **Score impact:** -3 points

## FINDING-004: CloudVault first-vault creation not server-mediated (M-008 residual)
- **Severity:** Medium
- **Status:** Accepted risk (product decision)
- **Description:** First-vault creation and rotation do not require a server-mediated survivor quorum. A single trusted device can create or rotate the vault without other devices confirming.
- **Evidence:** `callables/cloudVaultRotation.ts` — rotation is client-driven with server-monotonic generation
- **Score impact:** -2 points

## FINDING-005: iroh first-contact safety-number not default-on (M-018 residual)
- **Severity:** Medium
- **Status:** Accepted risk (product decision)
- **Description:** Key-change pinning is active on all platforms, but first-contact safety-number confirmation is not default-on. A relay operator could substitute keys during first pairing.
- **Evidence:** `IrohRelayPairing.swift`, `IrohPairingHostKeyPinStore.kt`
- **Score impact:** -2 points

## FINDING-006: CLI executable provenance without signing policy (M-030 residual)
- **Severity:** Medium
- **Status:** Accepted risk (design tradeoff)
- **Description:** Agent CLI executables (codex, claude) are resolved from user-writable directories without code-signature verification. A higher-priority malicious shim could replace a legitimate CLI.
- **Evidence:** `CLIExecutableResolver` still resolves user-managed paths by design
- **Score impact:** -2 points

## FINDING-007: App Check attestation max-age is 30 days (M-031 residual)
- **Severity:** Medium
- **Status:** Open
- **Description:** `APP_CHECK_ATTESTATION_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000` (30 days). A stolen device retains high-risk callable access for up to 30 days.
- **Evidence:** `appCheckAttestation.ts:43`
- **Recommendation:** Tighten to 7 days or make configurable via Remote Config.
- **Score impact:** -1 point

## FINDING-008: Path-bound AAD not enforced on chat_threads and cli_sessions (M-007 partial)
- **Severity:** Medium
- **Status:** Open
- **Description:** `conversations` and `mobile_assistant_chats` enforce path-bound AAD (`validPathBoundSealedPayloadForUser`), but `chat_threads` and `cli_sessions` still use `validSealedPayloadForUser` (global AAD). Ciphertext relocation is possible within the same vault key.
- **Evidence:** `firestore.rules` — `ownerWritableChatThread -> validChatThreadSealedContent -> validSealedPayloadForUser` (global); compare with `conversations -> validPathBoundSealedPayloadForUser`
- **Recommendation:** Migrate `ChatThreadSyncService.swift:106` and `CLIAgentSessionRecord.swift:438` to emit path-bound AAD, then tighten Firestore rules.
- **Note:** Cannot tighten rules until client writers emit path-bound AAD (would brick existing writes).
- **Score impact:** -2 points

## FINDING-009: SSRF guard does not pin DNS (TOCTOU / DNS rebinding / redirect gap)
- **Severity:** Medium (latent — no user URL reaches fetch today)
- **Status:** Open
- **Description:** `assertOutboundFetchTarget` checks hostname against block lists but does not resolve DNS. Node's `fetch()` resolves DNS separately, creating a TOCTOU window. Also does not re-check on redirect.
- **Evidence:** `ssrfGuard.ts:88-118` — hostname string check only; `resilienceHelpers.ts:36-40` — calls `fetch(url)` after guard
- **Current risk:** LOW — all fetch targets are hardcoded provider hosts or config URLs
- **Recommendation:** When a user-URL feature lands, resolve DNS and pin IP before fetch; disable redirect following or re-check on redirect.
- **Score impact:** -1 point (latent)

## FINDING-010: Stable APNs/FCM routing IDs visible to push providers (M-021 residual)
- **Severity:** Medium
- **Status:** Accepted risk
- **Description:** Display-name/control-field abuse is fixed, but stable routing IDs remain visible to APNs/FCM as necessary metadata for delivery.
- **Score impact:** -1 point

## FINDING-011 through FINDING-017 (Low/Informational)

| ID | Severity | Title | Status | Score Impact |
|----|----------|-------|--------|-------------|
| FINDING-011 | Low | Extension `beforeSend` lacks recursive payload scrubber | Open | -0.5 |
| FINDING-012 | Low | `androidDeviceId` persisted in `fcm_outbound` docs (15-min TTL) | Open | -0.5 |
| FINDING-013 | Low | Account-deletion Cloud Storage purge is best-effort | Open | -0.5 |
| FINDING-014 | Low | Audit chain dual-file naming (`head.json` vs `signed_head.json`) | Open | -0.5 |
| FINDING-015 | Low | `pop_nonces` relies solely on TTL for reaping | Open | -0.5 |
| FINDING-016 | Info | Two workflows lack explicit permissions block | Open | -0.5 |
| FINDING-017 | Info | Branch protection is operator-only to verify/enable | Open | -0.5 |
