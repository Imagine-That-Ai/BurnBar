# BurnBar / OpenBurnBar — Product-Specific Security Requirements (Normative)
**Date:** 2026-06-01
**Reviewer:** Claude (Sonnet 4.6) second-opinion edition
**Status:** Provisional — these are normative requirements distilled from the SOTA gap analysis, the prior reviews, and the team's own threat models. They are the *bar* the product should ship against. Each requirement is a testable assertion.
**Cross-reference:** SOTA framework citations in `08-SOTA_GAP_ANALYSIS.md`; threat models in `docs/THREAT_MODEL.md` and `docs/security/*`; foundational SOTA work in `plans/2026-05-30-sota-security-remediation.md`.

## How to read this document

Each requirement is formatted as:
- **BR-NNN** — requirement ID
- **MUST / SHOULD / MAY** — RFC 2119 normative verbs
- **Statement** — the testable requirement
- **Rationale** — why it exists
- **Evidence / verification** — how to prove it's met
- **Source** — code:line or external citation

## BR-1 Pairing and device identity

**BR-1.1** The system MUST use short-lived pairing codes (≤6 characters) that are not derivable from any long-lived secret and are bound to a single device + session.
- *Rationale:* Brute-force window for short codes is small.
- *Verification:* Replay/expired/stolen code tests in `TEST_PLAN.md` §1.
- *Source:* `docs/HERMES_IROH_TRANSPORT.md`, `functions/src/callables/hermes.ts`, `piAgent.ts`, `cliLink.ts`.

**BR-1.2** The system MUST verify pairing codes server-side with at least: Firebase Auth, App Check, and entitlement check (where applicable).
- *Verification:* Call the pairing start/complete endpoints without each gate; expect denial.
- *Source:* `functions/src/computerUseSecurity.ts:140`, `appCheckAttestation.ts:120`.

**BR-1.3** The system MUST publish signed Iroh pairing records (`IrohPairingRecordDoc`) with Ed25519 signature, monotonic `publishedAt` field, and a freshness window enforced on the receiver side.
- *Verification:* Stale-record replay test across platforms (Swift, Android, TS).
- *Source:* `OpenBurnBarCore/Sources/OpenBurnBarCore/HermesIrohRelay*` (verify freshness constant is uniform).

**BR-1.4** Freshness window MUST be uniform across all platforms (≤5 minutes recommended).
- *Verification:* Constant cross-check; the prior review found ~3 min Swift vs 24h Android/TS/legacy.ts.
- *Source:* `legacy.ts:316`, `IrohRelayPairing.swift:74`, Android `IrohRelayPairing.kt:68`.

**BR-1.5** The system MUST publish post-pairing application-layer authorization contracts that explicitly state what a valid NodeId + signed pairing record grants — and what it does not.
- *Rationale:* E2EE between endpoints is necessary but not sufficient. App-layer authz must be explicit.
- *Verification:* Stolen post-pairing artifact test; spec doc.
- *Source:* SOTA Gap Analysis §8; this document §BR-5.

## BR-2 Key storage

**BR-2.1** All long-lived private keys (Iroh Ed25519, escrow P-256, signing identities) MUST be stored in the platform Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (macOS/iOS) or equivalent (Android Keystore with `setUserAuthenticationRequired` where appropriate).
- *Verification:* Static review of every `SecItemAdd` / `kSecClassKey` call.
- *Source:* `docs/THREAT_MODEL.md:248-250`, `iOSDeviceKeypair.swift`.

**BR-2.2** Key material MUST NOT be passed via process arguments, `argv`, or unencrypted log lines.
- *Verification:* `verify-resilience-wiring.sh` + dedicated redaction test.
- *Source:* `docs/THREAT_MODEL.md:75`, launchd `EnvironmentVariables` pattern.

**BR-2.3** Key rotation MUST be supported for all key types. Rotation MUST be exercised in a regression test at least once per quarter.
- *Verification:* Rotation drill in CI.
- *Source:* `docs/THREAT_MODEL.md:248-250`.

**BR-2.4** Encrypted backup keys MUST be device-held only (never server-side) when the backup is sealed (AES-GCM with device key).
- *Source:* `docs/THREAT_MODEL.md:135`.

## BR-3 Revocation

**BR-3.1** Revocation of an escrow device MUST cascade to all outstanding grants, active Iroh streams, and in-flight long-lived tokens within ≤30 seconds.
- *Verification:* End-to-end revocation drill.
- *Source:* `docs/THREAT_MODEL.md:238`, `escrow*` code.

**BR-3.2** Revocation of a paired device MUST invalidate the post-pairing Iroh record on the receiver within one heartbeat cycle.
- *Source:* `HermesIrohRelayHostClient.swift` heartbeat.

**BR-3.3** Revocation MUST be propagated to the phone authority validator state (monotonic `lastSeen` counter) so that an in-flight or replayed authority envelope is rejected.
- *Source:* `PhoneControlAuthorityValidator.swift`.

**BR-3.4** The system MUST emit an audit event for every revocation with reason + initiator + cascade target list.
- *Source:* `ComputerUseAuditChain.swift` extension required.

## BR-4 Team / workspace auth

**BR-4.1** Firestore rules MUST scope every read/write to the owning `uid` for `users/{uid}/**` paths and to the workspace members for `workspaces/{wsId}/**` paths.
- *Verification:* Negative authz test matrix in `TEST_PLAN.md` §3.
- *Source:* `firestore.rules`.

**BR-4.2** The system MUST reject client-writable documents that contain plaintext secret field names (`apiKey`, `token`, `refreshToken`, `accessToken`, `idToken`, `cookie`, `password`, `secret`, `secretVersionName`, `authorization`, `bearer`, `credential`).
- *Source:* `docs/THREAT_MODEL.md:240-244`, `firestore.rules`.

**BR-4.3** Workspace role escalation MUST be possible only via a high-risk callable (not direct Firestore write).
- *Source:* `functions/src/escrow*` callable pattern.

**BR-4.4** The system SHOULD offer passkeys / FIDO2 as the default MFA for team/workspace sign-in, per CISA Secure by Demand.
- *Status:* **Gap** — not yet implemented. See `auth-authz.md`.

## BR-5 Post-pairing Iroh app-layer authorization (the explicit contract)

**BR-5.1** Possession of a valid Iroh NodeId + signed pairing record MUST NOT, by itself, grant any application-layer permission. Sensitive actions MUST additionally require:
  - A valid capability token (domain-tagged, signed, single-use, short-TTL, scope-hashed), OR
  - An active escrow grant with explicit scope, OR
  - A live user approval (sheet, biometric, or per-action confirm).
- *Verification:* Stolen post-pairing artifact test (Red Team chain #1, #5).
- *Source:* `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/CapabilityToken*.swift`, `PhoneControlAuthorityValidator.swift`.

**BR-5.2** View-only mirror sessions MUST NOT allow control input or grant issuance even with a valid NodeId + signed pairing record.
- *Verification:* View-only → control escalation test (Red Team chain #2).
- *Source:* `ComputerUseSessionCoordinator.swift`, `Remote Control subagent` test corpus.

**BR-5.3** The app-layer protocol on top of Iroh MUST be versioned and MUST reject unknown or future protocol versions.
- *Verification:* Protocol-version fuzzing.
- *Source:* See `iroh-crypto.md` specialist report.

**BR-5.4** The system MUST apply rate limits at the Iroh transport layer (per-NodeId, per-stream) before app-layer handlers, to bound metadata-driven cost attacks and malformed-frame abuse.
- *Status:* **Gap** — transport-layer rate limiting not yet evidenced.
- *Source:* Red Team chain #6.

## BR-6 Screen-share and remote-control consent

**BR-6.1** The system MUST display a clear incoming-call sheet on the Mac before any view-only or control session is established.
- *Source:* `ComputerUseRunCoordinator.swift`, IncomingCallSheet.

**BR-6.2** The system MUST NOT auto-accept control. View-only is the default; control requires explicit user action.
- *Source:* Default trust mode = Manual; per-session trust.

**BR-6.3** The system MUST clearly distinguish view-only from control at all times, including in the menu bar / dock icon, in the in-app status, and in the screen-share overlay.
- *Source:* Status indicator spec.

**BR-6.4** Every screen-share and control session MUST be auditable (start, every input action, stop) in the tamper-evident audit chain.
- *Source:* `ComputerUseAuditChain.swift`, `ComputerUseAuditLogger.swift`.

**BR-6.5** The system MUST provide at least three independent kill paths that all reach the input leaf and survive app/daemon crash:
  1. Global hotkey (⌃⌥⌘.)
  2. Phone three-finger long-press
  3. NSWorkspace (loginwindow / SecurityAgent / screen sleep)
  4. Remote Config `computer_use_kill_switch`
  5. Watchdog LaunchDaemon that sets a leaf-side flag
- *Verification:* `PrivilegedInputKillSwitchTests` + `ComputerUseSafetyInvariantHarness`.
- *Source:* `docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md`, `PrivilegedInputKillSwitch.swift`.

**BR-6.6** The system MUST NOT allow clipboard synchronization without an explicit "Paste to Mac" / "Grab from Mac" UI action, AND it MUST NOT include passwords in clipboard/audit/agent paths (certified HID sequence only).
- *Source:* Remote Unlock spec.

**BR-6.7** Built-in deny rules (loginwindow, SecurityAgent, keychain prompts, password fields, Mail send) MUST take precedence over user allow rules (deny wins).
- *Source:* `ComputerUseDenyRegistry.swift`, `ComputerUseScopeLibrary.swift`.

## BR-7 Agent-action authorization (BurnBarToolKind)

**BR-7.1** Every `BurnBarToolKind.computerUseToolKinds` action MUST be categorized as one of: `read`, `mutate`, `privileged-mutate`, `external-send`, `spend`, `security-change`.
- *Source:* `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/AgentDesktopToolDefinitions.swift` (verify categorization).

**BR-7.2** `privileged-mutate`, `external-send`, `spend`, and `security-change` MUST require explicit per-action confirmation or a stronger policy (signed grant).
- *Verification:* Tool-broker regression test that asserts a prompt-injection-influenced agent cannot bypass confirmation.
- *Source:* OWASP LLM 2025 #6 (Excessive Agency), prior Finding C4 follow-up.

**BR-7.3** The system MUST tag every tool result (browser extract, AX tree, screenshot OCR, MCP response) as `<UNTRUSTED_CONTENT>` and MUST NOT let the result override system/developer instructions.
- *Source:* `LLMSafeContent` wrappers shipped during prior review (verify universal coverage in `ai-llm-agent.md`).

**BR-7.4** The system MUST enforce a hard per-user budget and a Remote Config kill switch for Computer Use actions; hourly eval MUST halt at the hard cap.
- *Source:* `functions/src/computerUseBudget.ts`, `computerUseRemoteConfig.ts`.

**BR-7.5** Model-switch events MUST be verifiable (server-authoritative) and MUST NOT be spoofable by the client.
- *Source:* `functions/src/piAgent.ts`, model routing.

## BR-8 Signed attachments and signed URLs

**BR-8.1** Signed upload URLs MUST be short-lived (≤15 minutes), scoped to a specific user path, and issued only after entitlement and ownership checks.
- *Source:* `functions/src/hermesGateway.ts` attachments/init, `assertUserStoragePath`.

**BR-8.2** Post-upload verification MUST enforce size, content type, and hash; mismatches MUST abort indexing.
- *Source:* Existing post-verify pattern.

**BR-8.3** The system MUST rate-limit attachment init and commit, and MUST detect replay.
- *Source:* H2 in prior review.

## BR-9 Relay usage and browser relay behavior

**BR-9.1** The system MUST publish the relay metadata reality (NodeIds, connection patterns, timing, volumes) in public copy, citing the Iroh official documentation.
- *Source:* This document §"Security Claims Rewrite" and `06-SECURITY_CLAIMS_REWRITE.md`.

**BR-9.2** The system SHOULD prefer direct P2P over relay when both are available; relay fallback MUST be explicit and rate-limited.
- *Source:* `IrohRelayPairing.swift` selection logic.

**BR-9.3** The system MUST NOT silently relay traffic from browser/WASM clients without user-visible disclosure (metadata + cost implications differ).
- *Source:* This document §"Security Claims Rewrite".

**BR-9.4** The system MUST cap relay bandwidth / duration per user, per session, and MUST alert on anomalous volume.
- *Source:* `functions/src/irohMonitoring.ts`, `mediaMonitoring.ts`.

## BR-10 Audit logs and incident response

**BR-10.1** Every privileged action MUST be appended to the audit chain within ≤1 second, with parent hash linking.
- *Source:* `ComputerUseAuditChain.swift`.

**BR-10.2** The audit chain MUST support offline "no actions after panic" completeness proofs via a signed head + max-index artifact.
- *Status:* WS3 in-flight per `plans/2026-05-30-sota-security-remediation.md`.

**BR-10.3** The audit chain MUST be anchored to OpenTimestamps at least once per session.
- *Source:* `ComputerUseOpenTimestampsClient.swift`, `functions/src/computerUseOpenTimestamps.ts`.

**BR-10.4** Sentry `beforeSend` and Cloud Logging filters MUST redact tickets, tokens, full prompts, screenshots, and PII beyond truncated UID.
- *Verification:* Negative log-leakage test in `TEST_PLAN.md` §7.

**BR-10.5** The system MUST publish a public-facing IR summary (without operational details) so users understand what to expect in case of an incident.
- *Status:* **Gap** — no public IR summary today.

**BR-10.6** The system MUST have a public VDP and `security.txt` at the well-known path.
- *Status:* **Gap** — not yet implemented.

## BR-11 Self-hosted and local-only deployments

**BR-11.1** The system SHOULD ship a documented self-hosted / CLI-only mode with a reduced attack surface (no cloud callables, no relays).
- *Source:* `docs/THREAT_MODEL.md:189-190` already mentions offline operation.

**BR-11.2** The local HTTP gateway MUST bind to 127.0.0.1 by default, MUST reject wildcard binds, and MUST require a bearer token for non-loopback binds.
- *Source:* `docs/THREAT_MODEL.md:62-63`.

**BR-11.3** The daemon UNIX socket MUST be 0600 and MUST require a per-launch token from launchd environment.
- *Source:* `docs/THREAT_MODEL.md:72-75`.

**BR-11.4** The system MUST clearly communicate the same-UID local malware residual risk to the user.
- *Source:* This document §"Security Claims Rewrite".

**BR-11.5** Daemon local socket SHOULD additionally validate peer code-sign on the Mac (per the May 2026 P0 pattern), to harden against same-UID malware.
- *Status:* **Gap** — not yet evidenced; this is the local socket's most material residual risk.

## BR-12 Cloud hardening

**BR-12.1** Production callables MUST use `onCallProduction` (logging + Sentry), and the CI MUST fail on any new `onCall` that does not use the wrapper.
- *Source:* `functions/src/logging.ts`, `verify-resilience-wiring.sh`.

**BR-12.2** App Check MUST be enforced for Firestore in production console configuration; the launch gate MUST verify this programmatically.
- *Source:* `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md`, `scripts/commercial-launch-gate.mjs`.

**BR-12.3** The system MUST use a resilience helper (`providerFetch`, `firestoreWithResilience`, `stripeWithResilience`, etc.) for every outbound HTTP and Firestore call. CI MUST fail on raw `fetch` in `functions/src/`.
- *Source:* `scripts/ci/verify-resilience-wiring.sh`.

**BR-12.4** Storage buckets and Cloud Functions MUST use least-privilege IAM, and the audit log MUST be checked quarterly.
- *Source:* `functions/src/adminRuntime.ts` and Storage bucket policies.

**BR-12.5** The system MUST publish a public cloud asset inventory (buckets, functions, IAM) at the level of granularity that lets a customer verify least privilege.
- *Status:* **Gap** — not yet published.

## BR-13 AI / agent safety (OWASP LLM 2025)

**BR-13.1** All untrusted content (log parsers, RAG, webpage extracts, screenshot OCR, MCP responses, hosted insight JSON) MUST be wrapped with `LLMSafeContent` + `<UNTRUSTED_CONTENT>` tags and MUST be structurally separated from system/developer instructions.
- *Source:* `AgentLens/Services/ContextBuilder.swift`, `LLMSafeContent` wrappers.

**BR-13.2** The system MUST have a public red-team corpus and MUST run automated adversarial evals in CI for known prompt-injection payloads.
- *Status:* **Gap** — no public corpus yet.

**BR-13.3** Memory / RAG MUST be isolated per user; cross-user retrieval MUST be impossible.
- *Source:* Local HNSW index, Firestore `users/{uid}/...` paths.

**BR-13.4** The system MUST have a model-switch event verification mechanism; the model a user sees as "current" MUST match the server-authoritative model in use.
- *Source:* `functions/src/piAgent.ts`, model routing.

**BR-13.5** The system MUST publish its tool permission matrix and confirmation policy in the public documentation.
- *Status:* **Gap** — should be in the trust center.

## BR-14 Supply chain and release

**BR-14.1** All release artifacts (DMG, ZIP, AAR, APK, extensions, crates, MCP shims, browser extension) MUST be cosign-attested with provenance in SLSA v1.1 format.
- *Status:* Uniform coverage is a gap; release lane has it.

**BR-14.2** Every release MUST publish an SPDX SBOM and OpenVEX sidecar.
- *Source:* `scripts/generate-sbom.py`, `scripts/supply-chain/generate-vex.py`.

**BR-14.3** GitHub Actions MUST be SHA-pinned; broad `permissions` MUST be avoided; OIDC MUST be used for signing.
- *Source:* `.github/workflows/*` review.

**BR-14.4** The repo MUST score ≥7.0 on OpenSSF Scorecard and MUST be re-scored on every major release.
- *Status:* **Gap** — Scorecard not yet enforced in fast-feedback.

**BR-14.5** The system MUST run CISA KEV and OSV-Scanner on every PR and MUST block merge on a known-exploited finding.
- *Status:* **Gap** — KEV scan not in fast-feedback.

## BR-15 Transparency and trust

**BR-15.1** The system MUST publish `SECURITY.md`, `.well-known/security.txt`, and a public trust center page.
- *Status:* **Gap** — none exist today.

**BR-15.2** The system SHOULD publish a yearly (or per-major-release) summary of the red-team / pen-test activity, with findings redacted as needed.
- *Status:* **Gap**.

**BR-15.3** The system MUST publish a precise security claims matrix (`website/CLAIMS.md` style) and MUST re-verify claims before any public launch.
- *Status:* Internal process exists; public version is a gap.

## How to use this document

- Every requirement is a testable assertion. The test plan in `05-TEST_PLAN.md` maps to these BRs.
- Every gap above is a candidate finding in `03-FINDINGS_REGISTER.md`. The orchestrator integrates them after specialist subagents return.
- This document SHOULD be reviewed and approved by engineering leadership before any public launch.
