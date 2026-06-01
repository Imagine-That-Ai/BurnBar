# BurnBar / OpenBurnBar SOTA Security Review — Prioritized Engineer Checklist (Hand-Off Artifact)
**Date:** 2026-06-01
**Purpose:** Single page (or printable) action list. Every item is concrete, evidence-backed, and traceable to a specific file:line or doc section from the swarm review. "Do the whole thing" per AGENTS.md — no vague items.

Copy this into Linear/Jira/Notion. Assign owners + due dates. Re-run the full test plan (below) after each P0/P1 batch.

## P0 — Ship Before Any Public / Broad Launch (48-72 hours if possible)

1. **Verify + land remaining P0 items from 2026-05-30 SOTA Privileged Input Remediation Plan (WS2 full wiring + attestation universality).**
   - Confirm peer code-sign + DR (`PrivilegedPeerAuthenticator` + `OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement`) is live and enforced on *both* VirtualHID bridge and RemoteAccessAgent sockets (and XPC paths). Keep UID as cheap first gate.
   - Wire `VirtualHIDBridgeCapabilityGate` + token minting/verification on *every* "input" dispatch path (bridge adapter, keyboard engine, dispatch handler). Fail-closed for broad ops until tokens are universal.
   - Make attestation binding (`bindAppCheckAttestation` → bound `obb_app_check` claim) mandatory for all high-tier phone grants and every control intent envelope.
   - Evidence: plans/2026-05-30-sota-security-remediation.md (V0/V1 + WS2), docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md, Remote Control subagent (P0 closed on sockets, WS2 partial wiring), `OpenBurnBarDaemon/Sources/.../VirtualHID*` + `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/CapabilityToken*` + `AgentLens/Services/ComputerUse/PhoneControlAuthorityValidator.swift`.
   - **Test gate:** Red-team unsigned console-user probe must be rejected (existing `PrivilegedSocketRedTeamIntegrationTests` + probe); legitimate signed first-party + CU scenarios pass; `ComputerUseSafetyInvariantHarness` green.

2. **Iroh transport-layer rate limiting + freshness standardization (Iroh subagent + Red Team replay chains).**
   - Add per-connection / per-NodeId token-bucket or equivalent rate limiting + quotas *at the iroh transport layer* (before HermesRelayCrypto / classify) in `IrohRelayRequestHandler` (Mac) and equivalent Android/Swift send paths. Tie to existing budgets.
   - Standardize pairing record freshness to ≤5 minutes everywhere (current: ~3min Swift vs 24h Android/TS/legacy.ts — direct replay/stale record risk). Enforce server-side on publish where possible + client-side uniform constant.
   - Evidence: Iroh subagent (freshness discrepancy + "no transport-layer rate limiting visible at iroh layer"); `IrohRelayPairing.swift:74`, `legacy.ts:316`, Android `IrohRelayPairing.kt:68`; Rust send/recv paths in crates/openburnbar-iroh.
   - **Test:** Extend existing iroh e2e harnesses (`scripts/e2e/ios-iroh-gate*.sh`, `OpenBurnBarIrohRelayTests`) with stale record replay across platforms + volume flood from authenticated connection (assert rate limiting triggers before higher-layer budgets).

3. **Fix the 5-6 verified Web/API findings (direct code evidence).**
   - Add `assertAppCheck` (or full enforce) to `latestRouterRundown` (functions/src/routerRundown.ts:1054); update openapi.yaml if truly public.
   - Migrate `approveHermesGatewayDeviceGrant` (and similar gateway grant paths) to `enforceHighRiskComputerUseCallable` (functions/src/callables/hermesGateway.ts:499 vs. computerUseSecurity.ts + appCheckAttestation.ts).
   - Add rate limiting (per-IP/global short window with decay) on `startCliLink`/`pollCliLink` (functions/src/callables/cliLink.ts:30/82) + monitor guessing.
   - Add general burst/distributed rate-limit facade on pairing, grants, gateway enqueue, high-risk callables (shared.ts last-ts patterns are insufficient).
   - Formal review + nonce/exp/TTL/rotation on Hermes Gateway bearer tokens + scopes (hermesGateway.ts full multiplexer).
   - Evidence: Web/API subagent (66 tool calls, full inventory + matrix).
   - **Test:** Emulator + smoke curls for each; auth-bypass attempts on high-risk callables; concurrency floods on pairing/gateway; bearer replay/scope tests.

3. **Public security transparency package live.**
   - SECURITY.md + security.txt + VDP (vulnerability disclosure policy) + responsible disclosure contact (`security@` or dedicated) + trust-center outline (roadmap for SBOM/provenance/audit exports).
   - Link from website footer, README, pricing, and app Settings.
   - Evidence: Grep across repo/website found none at top level (only node_modules); Docs/Claims agent scope + website/CLAIMS.md.
   - **Test:** Public crawl + link check.

4. **Explicit post-pairing Iroh app-layer authorization contracts + stolen/impersonated artifact tests.**
   - After Hermes/Pi/escrow pairing completes (Firestore iroh_pairing + connection docs), every sensitive action (screen start, control input, file xfer, agent grant) must still enforce explicit grants/escrow trust/scope/revocation (not just possession of NodeId or endpoint).
   - Add regression tests: stolen post-pairing record / replayed connection → denied for control paths.
   - Evidence: Architecture + Iroh subagent scopes + functions/src/callables/hermes.ts + piAgent + escrow flows + IrohPairingRecordDoc signed verification.

5. **AI/agent high-impact tool confirmation gates + prompt injection defenses (Critical).**
   - Mandatory confirmation (or stronger policy) for high-impact BurnBarToolKind actions. Re-approve or gate *tool results* (large extracts, new domains, vision/AX/screenshots) that feed back into agent reasoning.
   - Enforce the `LLMSafeContent` + `<UNTRUSTED_CONTENT>` wrappers (shipped during this review) + strict "report injection" rules across *all* RAG evidence, CU tool feedback, focus, summaries, insights, and MCP paths. Add provenance markers.
   - Evidence: AI/LLM subagent (76 tool calls) + shipped changes in `ContextBuilder.swift`, `CLIArgumentBuilder.swift`, `insightsHostedAnswer.ts` + new `AgentLensTests/Security/PromptInjectionHardeningTests.swift` + `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md`. OWASP LLM 2025 #1.

## P1 — 7 Days (High-Impact Hardening)

- Complete WS3 (signed-head audit + max-index completeness proofs) wiring + CLI verifier + operator drill with published timings.
- Add the explicit "view-only → control escalation" and "silent control start" regression tests (mobile → Mac iroh paths) covering all consent surfaces (Remote Control subagent).
- Expand rate limiting + per-client caps on Hermes Gateway (events, attachments, SSE) + tie to entitlements.
- Run full minimum test list (see TEST_PLAN.md) in staging + add any new P0/P1 cases as permanent CI gates (use active `OpenBurnBarTests` / `OpenBurnBarDaemon` targets + `./scripts/test-*.sh`).
- Update all affected docs (THREAT_MODEL.md, PRIVILEGED_INPUT_THREAT_MODEL.md, SOTA_REMEDIATION_PROGRESS.md, CHANGELOG.md, runbooks/computer-use-*.md, website/CLAIMS.md) with current state (P0 closed, residual risks, exact test coverage).
- Initial SLSA provenance + cosign attestations expanded to all release artifacts (DMG, AAR/APK, extensions, crates) beyond current release-lane workflow.
- Privacy/claims audit: rewrite all public copy per SECURITY_CLAIMS_REWRITE.md (precise language only; no "impossible"/"fully secure").

## P2 — 30 Days

- Full SOTA gap closure vs. OWASP ASVS 5.0 (2025), NIST SSDF, CISA SbD (passkeys emphasis, default secure), SLSA L3 targets, OpenSSF Scorecard (run on repo + deps).
- Comprehensive AI red-team corpus (prompt injection via every untrusted channel: logs, screenshots, webpages, attachments, memory/RAG poisoning) + automated eval gates.
- Advanced detection (pairing abuse, anomalous relay volume/cost, high token burn, model-switch anomalies, new device/escrow, privilege escalation) wired to oncall + playbooks (Blue Team subagent scope).
- Self-hosted hardening guide v2 + documented local gateway attack surface + same-UID malware residual risks (clear user communication).
- Mobile (Android/iOS) parity on all phone-control attestation binding + grant issuance + kill paths.
- Dependency hygiene: pinned Actions + OIDC everywhere, no raw secrets in logs, abandoned/typosquat scan + KEV monitoring, full SBOM for all platforms.

## P3 / Long-Term (90+ Days + Roadmap)

- Hardware-backed key storage / HSM for hosted secrets where feasible.
- Formal (small TLA+/Alloy or exhaustive harness) proofs of pairing/grant/panic protocol as living docs (not gate).
- Continuous red-team program + external audit cadence for remote control surface.
- Trust-center public dashboard (provenance, audit exports, incident history, SLOs).
- Passkeys / phishing-resistant MFA as default (CISA emphasis) where Firebase paths allow.
- SLSA L3 + reproducible builds + full artifact signing across every platform + dependency review in every PR.

## Standing Gates (Never Regress)

- All P0 red-team probes + `ComputerUseSafetyInvariantHarness` + privileged socket tests + kill-switch tests must be green on every PR that touches daemon, computer-use, or pairing code.
- `bash scripts/ci/verify-resilience-wiring.sh` + `verify-ops-readiness.sh`.
- Fast-feedback (lint + typecheck + unit) <5 min; security-related failures block merge.
- App Check console enforcement + automated launch gate (WS4).
- No raw `fetch` outside resilience helpers in functions/src.

**Evidence sources for every item above:** Three completed subagents (Architecture/Threat 45 calls, Web/API 66 calls, Remote Control 73 calls) + primary source reads (remediation plan, threat models, firestore.rules, callables/*.ts, daemon + core Swift, etc.) + web research on standards (Iroh docs, OWASP 2025 LLM/API/ASVS 5.0, NIST SSDF, CISA SbD, SLSA, etc.).

**Owner for this checklist:** Alberto + security reviewer (this swarm session). Revisit after each P0 batch + full subagent synthesis.

Run the tests in TEST_PLAN.md after every batch. Update this checklist + the master report in security-review-2026-06-01/ as items close.

This is the permanent, shippable solve — no dangling threads.
