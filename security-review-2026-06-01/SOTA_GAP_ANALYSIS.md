# BurnBar / OpenBurnBar SOTA Security Review — Gap Analysis vs. Frameworks (June 1, 2026)

**Date:** 2026-06-01
**Sources:** All completed subagents (Architecture, Web/API, Remote Control, Red Team, Auth/Authz) + primary code/docs + web research on official standards (NIST SSDF SP 800-218 v1.1, OWASP ASVS 5.0.0 May 2025, OWASP API Top 10, OWASP LLM/GenAI Top 10 2025, CISA Secure by Design 2023 + Secure by Demand, SLSA v1.0, OpenSSF Scorecard, Iroh official docs as of 2026, cross-device OAuth/device auth BCPs, remote desktop/control safety expectations).

This is a high-level but evidence-based gap analysis. Detailed per-requirement mapping would be a multi-week effort; this focuses on material gaps vs. state-of-the-art expectations for a product with remote privileged execution, cross-device control, AI agent tooling, and optional cloud collaboration.

## 1. NIST Secure Software Development Framework (SSDF) v1.1 (SP 800-218)

**Strong areas:**
- PS.1–PS.3 (Prepare the organization / secure development practices): Excellent internal threat modeling (THREAT_MODEL.md + dedicated privileged input model + May 2026 remediation plan with ranked vulns + workstreams). Formal safety invariants + harnesses for highest-risk surface.
- PW.1–PW.8 (Protect the software / secure development): Strong validation (shared/guards helpers), resilience wiring (CI-enforced providerFetch), no raw fetch in functions/src, signed uploads with post-verify, owner-scoped rules + secret denylist.
- RV.1–RV.3 (Respond to vulnerabilities): Existing red-team probes + invariant tests + audit chain + OpenTimestamps + Sentry auto-capture on callables. SOTA remediation plan shows self-critical response to identified issues.

**Material gaps:**
- PS.2.1 / PS.3.2 (threat modeling + supply chain risk management): Supply chain provenance (cosign + SBOM + VEX) exists on release lane but not uniformly applied to all artifacts (DMG, AAR, extensions, crates) at SLSA L3. Dependency review + OpenSSF Scorecard not enforced in fast-feedback.
- PW.4.1–4.4 (secure coding practices + review): 68 empty catch/745 try? debt noted in remediation plan (V2); negative authorization test coverage is sparse (Auth subagent finding).
- RV.2 (vulnerability disclosure): No public security.txt, SECURITY.md, or VDP (grep-confirmed gap).

**SOTA expectation vs. current:** Good internal process; external transparency and uniform supply-chain provenance lag.

## 2. OWASP ASVS 5.0.0 (May 2025, ~350 requirements / 17 chapters)

**Strong:**
- V2 (Authentication) / V3 (Session Management): Firebase Auth + App Check + attestation binding + high-risk wrappers + owner rules.
- V4 (Access Control): Explicit server-side ownership + escrow trusted-state checks on every grant/controller path; no client-controlled elevation.
- V5 (Validation / Sanitization): Pervasive boundedTrimmedString + hex/sealed parsers throwing HttpsError.
- V9 (Self-Contained Tokens) / V10 (OAuth/OIDC): High-risk callables use bound custom claims; device-code + MCP grants have scope + revocation paths.
- V13 (API Security): Strong callable authz + resilience + logging (Web/API subagent matrix).

**Gaps:**
- V2.1.5 / V2.6 (MFA / phishing-resistant): No passkeys or MFA found anywhere (Auth subagent).
- V4.2.2 / V4.3 (BOLA/BFLA negative testing + function-level): Mostly positive tests; explicit IDOR/BFLA negative cases missing (Auth + Web/API subagents).
- V11 (Business Logic): Limited coverage of race conditions in pairing/escrow/grant flows and revocation propagation windows.
- V14 (Configuration): OpenAPI incomplete vs. actual callables + gateway subpaths (Web/API finding).
- V17 (WebRTC / real-time): Limited (SSE in Hermes Gateway reviewed; full transport authz on iroh streams is Iroh specialist scope).

## 3. OWASP API Security Top 10 (2023) + LLM/GenAI Top 10 (2025)

**API Top 10:**
- Broken Object/Function Level Authorization: Strong in reviewed callables (Web/API subagent — no BOLA found). Daemon socket is the outlier (local, token-only).
- Unrestricted Resource Consumption: Sparse rate limiting (last-timestamp + caller windows only) — confirmed gap.
- Broken Authentication: Daemon socket + revocation propagation + MCP bearer lifetime.
- Improper Inventory Management: OpenAPI drift.
- SSRF / Injection: Well-mitigated (resilience wiring + bounded parsers).

**LLM/GenAI Top 10 2025 (prompt injection #1, sensitive disclosure #2, supply chain #3):**
- Prompt Injection / Indirect Injection: Major unaddressed surface (RAG of logs/screenshots/webpages into agent context; Red Team chain #4). No systematic sanitization or "untrusted evidence" markers evidenced.
- Excessive Agency / Tool Over-Permissioning: Confirmation gates exist for many paths (Remote Control subagent) but not uniformly proven for all BurnBarToolKind.computerUse* + shell/email/spend actions.
- Sensitive Data Disclosure / Insecure Output Handling: Audit chain helps forensics; RAG poisoning risk high.
- Supply Chain (models + tools): Playwright bridge + any hosted LLM fallbacks not deeply reviewed yet.

## 4. CISA Secure by Design / Secure by Default (2023 + 2024 updates)

**Strong:** Local-first reduces default attack surface; explicit consent + kill switches + audit for remote control (aligns with "take ownership of customer security outcomes"); no default passwords/creds.

**Gaps:**
- Phishing-resistant auth by default (passkeys emphasis in Secure by Demand): None found.
- Radical transparency: Missing public VDP, security.txt, precise claims (vs. overclaims), and uniform provenance.
- Least privilege on privileged binaries: Post-P0 code-sign + DR is excellent; daemon socket still token-only.

## 5. SLSA / OpenSSF Scorecard

**Current:** Cosign + SBOM (SPDX) + OpenVEX on release workflow (supply-chain-provenance.yml) — SLSA L1/L2-ish for some artifacts. Hardened runtime + library validation on privileged binaries (good for code-sign auth).

**Gaps:** Not L3 across all release artifacts (DMG, Android, extensions, crates). No Scorecard enforcement in CI. Dependency review not mandatory. Reproducible builds / full provenance for browser extension and MCP shims unknown.

## 6. Iroh Official Expectations (docs.iroh.computer + crates as of 2026)

- E2EE between endpoints + relays cannot decrypt payloads: Confirmed design + HermesRelayCrypto.
- Relays see metadata (NodeIds, connections, timing, volumes): Acknowledged in docs but not prominently called out in all public claims or high-bandwidth media flows.
- Tickets: Versioned; used for endpoint sharing. BurnBar uses short codes + signed records + NodeId exchange post-pairing — safer than raw long-lived tickets if app-layer authz is enforced (still under Iroh specialist verification).
- Browser/WASM: Supported with limitations (metadata/cost differences); any browser client paths must document this.
- Discovery / home relay trust: Production relay config + selection not fully reviewed here.

**Gap:** App-layer authorization on top of Iroh NodeId (post-pairing grants/escrow/scope) must be proven for every sensitive action (screen start, input, file transfer, agent grants).

## 7. Remote Desktop / Control Safety Expectations (2026 state-of-the-art)

- Explicit consent, view-only vs. control distinction, kill switches that reach the leaf and survive crashes, per-session trust, scope/deny rules, audit with completeness proofs: BurnBar has most of these (multiple kills including independent watchdog, consent sheets with screenshots, trust modes, scope/deny with precedence, anchored hash chain + signed head + OTS). Post-P0 privileged socket auth is a major SOTA win.
- Gaps vs. ideal: Full WS2 capability token wiring on every input path still completing; attestation binding not universally mandatory on high grants/intents in all mobile code; in-process CGEvent path (post-TCC) has weaker independent kill than privileged HID leaf; explicit "view-only escalation" + "silent start" regression tests not yet evidenced as permanent gates; revocation propagation to active iroh streams incomplete (Auth subagent).

## Overall Maturity Assessment

- **Above average / SOTA for consumer/pro tool with remote privileged execution:** Internal threat modeling, privileged input remediation, pairing design, cloud authz layers, audit proofs, and post-P0 socket hardening are genuinely strong.
- **Below SOTA / material gaps:** Supply chain provenance uniformity + Scorecard, public transparency (VDP + precise claims), negative test coverage (especially authz + revocation), AI/LLM prompt injection defenses for RAG/agent flows, rate limiting breadth, daemon local socket hardening (code-sign/UID), revocation propagation to transport sessions, passkeys/phishing-resistant auth, and full Iroh post-pairing app-layer authz proofs.

**Recommended immediate lift (P0/P1):** Address the daemon socket, revocation propagation, negative test coverage, RAG injection defenses, and public transparency items. These are the clearest gaps vs. the frameworks the product should be measured against given its capabilities.

This analysis will be expanded with remaining subagent outputs (Iroh, Supply, AI, etc.) into a more granular matrix if requested.
