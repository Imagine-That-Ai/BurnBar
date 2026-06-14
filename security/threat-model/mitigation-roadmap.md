> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish.

# Mitigation Roadmap

Prioritized by the package’s risk ordering: (1) issues that break a core security claim; (2) plaintext compromise; (3) unauthorized tool-execution / RCE; (4) cross-user access; (5) device impersonation; (6) persistent memory/context poisoning; (7) IR-blocking gaps; (8) indefensible claims. Threat IDs map to [`threat-register.csv`](threat-register.csv); claim IDs to [`security-claims.md`](security-claims.md). Effort: S ≤2d · M ≤1wk · L ≤3wk.

## A. Must fix before external audit

### A1 — Pin the iOS host-pairing key (kill cloud-MITM of the control channel)
- **Risk / threat:** T-TRN-01, T-PTR-03 (Critical); claim C8/C9. Cloud-substituted iroh host key MITMs/redirects the control channel; trust is in-memory TOFU.
- **Component:** `FirestoreIrohPairingPublicKeyProvider.swift:27-47`, `HermesIrohRelayTransport.swift:385`.
- **Mitigation:** Persist the host pairing key on first use (Keychain), pin thereafter, and reject silent key changes (mirror the Keychain-pinned Mac→phone controller key and the Gateway `relay_key_change_rejected` pattern). Add an out-of-band **safety-number / QR proximity** verification for first pairing so first-pairing trust is not solely cloud-relayed.
- **Acceptance:** a changed host key after first pairing is dropped + audited; a unit/integration test proves a substituted Firestore key is rejected; pairing UX shows a comparable safety number on both devices.
- **Tests:** new `IrohPairingKeyPinningTests` (substitution rejected); manual relay-MITM simulation (test-plan T-TRN). **Owner:** Transport/Identity. **Effort:** M. **Deps:** pairing UX.

### A2 — Contain the CLI / shell / YOLO lane (injection-to-RCE)
- **Risk / threat:** T-TOOL-02, T-AI-07 (Critical), T-TOOL-01/03/05 (High); claim C6/C7. `--dangerously-skip-permissions` + unsandboxed `runShellUnrestricted` with no per-action approval.
- **Component:** `CLIArgumentBuilder.swift:52,87,168,189,215`, `OpenAICompatibleChatGatewayClient.runShellUnrestricted:367-381`.
- **Mitigation:** (a) Put a **deterministic in-process policy gate** in front of every CLI tool dispatch (not just at grant mint). (b) Add **per-N-action re-auth** for shell/desktop_system_input/workspace_write (the TODO at `:381`). (c) **Sandbox** the shell lane (seatbelt profile / restricted PATH / no network unless granted). (d) Make `runShellUnrestricted` unavailable without a fresh, per-burst OS-auth proof; remove the dangerous flags or gate them behind the same proof. (e) On grant revoke, **terminate the in-flight subprocess** and re-check expiry mid-run.
- **Acceptance:** an injected instruction in Trusted mode cannot reach `zsh` without a fresh approval; revoke kills a running CLI agent within N seconds; a sandbox profile is applied (verify with a deny test).
- **Tests:** YOLO injection-to-RCE drill (test-plan T-TOOL); revoke-kills-agent test. **Owner:** AgentLens (CLIBridge/ComputerUse). **Effort:** L. **Deps:** approval UX, sandbox profile.

### A3 — Finish untrusted-content wrapping (RR-15 closure)
- **Risk / threat:** T-AI-01, T-AI-02, T-TOOL-05 (High); claim C6. CU tool results, the chat oracle “authoritative findings”, and the CLI lane inject untrusted content unwrapped.
- **Component:** `OpenAICompatibleChatGatewayClient` tool-loop / `AgentToolBroker.payload`; `ChatSessionController` oracle path; `CLIArgumentBuilder.combinedPrompt`.
- **Mitigation:** Route **every** tool result and oracle/RAG snippet through `LLMSafeContent.wrapUntrusted` (provenance + “data, never instructions”) at the exact point they re-enter model context; make the CU tool allowlist **default-deny**; tag oracle findings as untrusted-with-provenance rather than “authoritative.”
- **Acceptance:** a grep proves no tool-result/oracle path returns raw to context; `PromptInjectionHardeningTests` extended with CU-result + oracle + CLI payloads.
- **Tests:** prompt-injection regression suite. **Owner:** AgentLens (Context/Chat). **Effort:** M.

### A4 — Client crash-report scrubbing + consent (stop PII egress)
- **Risk / threat:** T-PRV-03 (High); claim C13. iOS/macOS Sentry has no `beforeSend`, no `sendDefaultPii:false`, no consent.
- **Component:** `OpenBurnBarMobile/App/AppDelegate.swift:53-85`, `AgentLens/App/AgentLensApp.swift:1168-1202`.
- **Mitigation:** add a recursive `beforeSend`/`beforeBreadcrumb` scrubber (mirror server `sentry.ts`), set `sendDefaultPii:false`, disable network/URL breadcrumbs, add an in-app consent toggle, and stop seeding the user id from `NSFullUserName()`. Do this **before** any production DSN is provisioned.
- **Acceptance:** a forced crash in a chat path uploads no prompt text / paths / tokens (verified against a test DSN); consent defaults off.
- **Tests:** crash/log-privacy manual test (test-plan T-PRV). **Owner:** Mobile + Mac. **Effort:** S.

### A5 — Align user-facing copy to the safe wording
- **Risk:** indefensible claims (business + audit-visible). Several website/wiki strings overclaim (unqualified E2EE, “API keys never leave the device”, etc.).
- **Mitigation:** apply the **safe wording** in [`security-claims.md`](security-claims.md) to website/app-store/wiki copy; keep the repo’s honesty-copy CI gates as the enforcement.
- **Acceptance:** `verify-signal-honesty-copy.sh` + license-posture gates pass and cover the changed surfaces; no banned phrasing remains. **Owner:** Product/Eng. **Effort:** S.

## B. Should fix before launch

| ID | Title | Threat | Mitigation sketch | Acceptance | Effort |
|---|---|---|---|---|---|
| B1 | SE/biometry-bind iOS vault & escrow keys | T-IOS-09, T-CVS-03 | Wrap the 32-byte vault key + P-256 escrow key with a Secure-Enclave key, `.biometryCurrentSet` (reuse the CU-signing-key pattern) | vault decrypt requires SE/biometry; raw `kSecValueData` no longer holds the key | M |
| B2 | Daemon sandbox + capability attenuation | T-DMN-01/02 | Apply a seatbelt sandbox + entitlement minimization; attenuate per-RPC capability instead of code-sign==authz; consider `SMAppService` | daemon cannot exercise broad FS/cred reach beyond its needs; a deny test passes | L |
| B3 | App-level re-auth gate (iOS/Android) | T-IOS-02 | Optional Face ID/passcode gate to enter app / reveal chat+vault; app-wide app-switcher blur + FLAG_SECURE on sensitive screens | unlocked-but-unattended device cannot read chat/vault without re-auth | M |
| B4 | VoIP push minimization + queue TTL + erase coverage | T-PRV-01/02 | Drop `displayName` (resolve client-side) / generic “Incoming call”; add `ttl:true` + index to `voip_outbound`/`fcm_outbound`; enumerate them in `eraseUserCloudData` | account-erase removes call metadata; pushes carry no caller name | M |
| B5 | Mercury media streaming byte-ceiling | T-ATT-01 | Enforce a download byte ceiling on the iroh blob path + post-fetch `size==manifest.size` reject (mirror the GCS finalize check); quarantine xattr on received files | oversized/lying manifest is rejected before disk-fill | S |
| B6 | Cloud authz tightening | T-AZ | Deny owner-delete of `cloud_vault_key_wrappers`; add secret-field allowlist to `users/{uid}` root doc; add rules-tests for the sealed-collection matrix | rules-tests cover wrapper-delete + root-doc; emulator green | M |
| B7 | SHA-pin actions + make cargo-deny run + 2nd reviewer | T-SC-01/02/03 | Pin all GitHub Actions to commit SHAs (+ Dependabot for actions); fix `run-ecosystem-deny-checks.sh` so `cargo deny` actually runs; add a second CODEOWNER/required reviewer | provenance gate fails on a planted dep; no mutable tag remains | M |

## C. Important hardening

- **C1** Atomic Firebase session/token revocation tied to escrow revoke (`revokeRefreshTokens`) so a revoked device loses *read* access, not just future wraps (T-PTR / C5).
- **C2** Server-side check that blocks old-key writes once a rotation requirement is pending; surface “revocation did not re-key (no surviving trusted device)” to the user (C5).
- **C3** Allowlist-model log scrubber (drop-by-default; cover numeric/edge fields and new provider key formats) (T-PRV-04).
- **C4** Pasteboard `expirationDate`/`localOnly` + clearing; Notification Service Extension to fetch/decrypt push bodies client-side (T-IOS-04/05).
- **C5** Add at-rest envelope **freshness/sequence** binding (doc-id+revision) to defeat same-path replay/rollback by a malicious storage service (RR-8).
- **C6** Provenance on memory **writes** (not just retrieval); quarantine suspicious session logs before indexing into RAG (T-AI memory poisoning).
- **C7** Android parity: at-rest sender-auth verify, wire-approval (not local-only), enforce attestation, OS-auth-bind saved unlock credential (RR-7 residuals).

## D. Documentation needed

- Document the iOS jailbreak/runtime-integrity assumption explicitly (T-IOS-10) and the B1 same-user trust model.
- Reconcile the doc-drift items (retired Redis/WSS relay still cited; SQLCipher prose; F7 default state; activation-parity CI wiring) — see Cure53 package Appendix E.
- Record the SE-P256 vs ed25519 step-up divergence (C7) and the Trusted-mode auto-dispatch behavior (C6) as **stated design**, not silent gaps.

## E. Future architecture work

- True process sandbox for local agent runtimes (the structural answer to T-TOOL / T-DMN).
- Forward secrecy / PCS on the relay + gateway lanes (PQXDH / hybrid-KEM) — currently a stated non-goal.
- Per-tenant Pensieve basis + noise to reduce vector-geometry linkability (RR-19, accepted residual today).
- Staging Firebase project + second operator to retire the solo-operator and single-project accepted risks.

## Prioritized order (one line)

**A1 → A2 → A4 → A3 → A5** (audit blockers), then **B5 → B6 → B7 → B4 → B1 → B3 → B2**, then C, then D/E. Items A1–A4 each break or materially caveat a headline claim and/or enable plaintext/RCE; they should land (or be explicitly risk-accepted in writing) before Cure53 starts.
