# BurnBar / OpenBurnBar SOTA Security Review — Executive Summary
**Date:** 2026-06-01 (orchestrator review as of June 1, 2026)
**Reviewer:** Grok 4.3 Security Swarm (elite multi-agent, evidence-driven, adversarial)
**Product:** BurnBar / BurnBar Cloud / BurnBar Cloud Pro (conversation-native AI agent operating layer, token tracking, cross-device comms via Iroh, Hermes/Mercury screen+control, remote agent oversight, local-first + opt-in cloud)

## Overall Security Grade: **B-**

**Rationale (evidence-based):**
Mature local-first design + explicit grant/escrow model + strong cloud authz layers (App Check + owner-scoped Firestore rules + secret denylist + high-risk callable wrappers) + detailed internal threat modeling + active May 2026 P0 remediation for the highest-risk privileged input surface (VirtualHID code-sign + capability tokens + kills-to-leaf + formal harness). Iroh E2EE foundation is solid per official docs. Supply-chain attestations (cosign + SBOM + VEX) and resilience CI enforcement are present. Pairing flows use short codes + multi-factor cloud gates + audits.

However, the privileged remote control / phone-as-controller / agent execution surface remains the largest blast radius (newest, highest privilege). Specific implementation drift and consistency gaps exist in the cloud API surface. Public transparency (VDP, precise claims, security.txt) is missing. Rate limiting and bespoke complex surfaces (Hermes Gateway) are under-hardened relative to risk. AI/agent prompt injection and tool agency controls are under-specified in evidence reviewed so far. Residual same-UID local risks are inherent and documented but must be clearly communicated.

**Not "unhackable" or "fully secure"** — precise, defense-in-depth engineering with acknowledged high-risk areas under active hardening.

## Launch Readiness: **Ready with Conditions**

**P0 Blockers (must resolve before public / broad launch):**
1. Verify + land all remaining items from the 2026-05-30 SOTA Privileged Input Remediation Plan (WS2 capability tokens constraining broad "input" op; universal attestation binding + strict TTL/counter/nonce on every phone-control envelope; kills reliably reach leaf under all crash/fork scenarios; red-team PoCs + invariant harness green in CI on every change). Cite: plans/2026-05-30-sota-security-remediation.md, docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md, current bridge/agent code + tests.
2. Close the 5-6 concrete Web/API findings below (especially routerRundown App Check drift, Hermes Gateway approve auth strength, CLI device-code brute-force surface, rate limiting breadth, gateway complexity review).
3. Public security transparency package (SECURITY.md + security.txt + VDP + responsible disclosure contact + trust-center outline) live and linked from website/README.
4. Explicit post-pairing Iroh app-layer authorization contracts + stolen/impersonated post-pairing artifact tests (beyond NodeId E2EE).
5. AI/agent high-impact tool confirmation policy + prompt injection defenses for logs/screenshots/web content in computer-use/RAG flows (minimum confirmation gates + sanitization).

**What is genuinely strong (evidence):**
- Local-first canonical state (daemon/SQLite) dramatically reduces cloud attack surface.
- Pairing design (short codes + SHA256 digest + App Check + entitlement + rate limits + audits + owner-scoped Firestore) — excellent.
- Firestore rules + storage rules + callable guards (owner namespace, no plaintext secrets ever, size/content limits, signed URLs with post-verify).
- Resilience wiring (providerFetch mandatory; CI script enforces no raw fetch).
- Supply-chain provenance on release lane (cosign + SBOM + OpenVEX).
- Detailed, self-critical internal threat models + formal safety invariants for CU.
- Iroh E2EE + relay metadata-only reality (per official docs).
- Multiple independent kill/panic paths + scope rules (deny wins) + budgets + Remote Config kill switch for remote control.

**What is fragile / highest risk (evidence):**
- Privileged input synthesis surface (VirtualHID + RemoteAccessAgent + CGEvent/AX) — even post-P0, any first-party-signed malware or compromised genuine paired phone remains high impact. WS2 not fully landed per reviewed code.
- Hermes Gateway custom HTTP/SSE/attachment surface (bespoke bearer, scopes, 50MB uploads, events) — complex attack surface with weaker grant approval auth than peer high-risk paths.
- CLI device-code public surface + hash-only poll protection (10m window, limited brute-force).
- Sparse rate limiting (lastSeenAt + caller windows; no general burst/distributed).
- AI/agent agency (prompt injection vectors via parsed logs, screenshots, webpages in CU; tool permission matrix and confirmation policy not fully evidenced in initial review).
- Relay metadata + cost exposure for high-bandwidth screen/control (volume/timing leaks possible; abuse potential without hard caps).
- Public claims vs. precise reality (E2EE transport is strong; app-layer authz, relay metadata, local same-UID risks, and remote control safety require careful wording).
- Documentation/transparency gaps (no security.txt/VDP; OpenAPI incomplete vs. actual callables + gateway).

**What must be fixed before public launch:** The P0 blockers + the 5-6 verified Web/API findings + transparency package + explicit Iroh post-pairing authz + AI confirmation gates.

**What can wait (90-day+ hardening):** Full SLSA L3 across every artifact/platform, comprehensive AI red-team corpus, advanced anomaly detection on relay volumes, self-hosted hardening guide v2, long-term key rotation/HSM for hosted secrets.

## Top 10 Risks (severity-normalized, with owners suggested)

1. **Remote control / privileged input escalation or replay from compromised genuine paired device or signed malware** (Critical) — Owner: Computer Use / Daemon team. Evidence: remediation plan V0/V1 + current bridge/validator code.
2. **Hermes Gateway device grant issuance with weaker auth than peer high-risk paths** (High) — Owner: Cloud / Hermes. Evidence: functions/src/callables/hermesGateway.ts:499 (standard enforce vs. enforceHighRiskComputerUseCallable).
3. **CLI device-code flow public surface + limited brute-force protection** (High) — Owner: Cloud. Evidence: functions/src/callables/cliLink.ts:30/82 (public onRequest start; hash-only poll).
4. **Sparse/naive rate limiting enabling pairing floods, grant spam, or budget exhaustion** (High) — Owner: Cloud + Quota. Evidence: shared.ts last-ts patterns + subagent analysis.
5. **Spec/implementation drift on public router rundown endpoint (App Check claimed but unenforced)** (Medium) — Owner: Cloud. Evidence: functions/src/routerRundown.ts:1054 + openapi.yaml claim.
6. **Post-pairing Iroh artifact theft/impersonation leading to unauthorized screen/control (app-layer authz gap)** (Critical) — Owner: Iroh / Hermes transport. Evidence: pairing docs + Arch subagent assumptions list.
7. **AI/agent prompt injection via logs/screenshots/webpages or excessive agency without confirmation** (Critical) — Owner: AI/Computer Use. Evidence: OWASP LLM 2025 + initial AI subagent scope.
8. **Relay metadata leakage + cost blowup for high-bandwidth Mercury streams** (High) — Owner: Iroh / Media. Evidence: Iroh official docs + media budget/monitoring.
9. **Supply-chain compromise of privileged release artifacts (DMG + entitlements)** (High) — Owner: Release / CI. Evidence: supply-chain-provenance.yml + Arch top assets.
10. **Missing public security transparency (VDP, security.txt, precise claims)** (Medium, but launch blocker for trust) — Owner: Docs / Legal / Website.

## Recommended Immediate Next Steps (48-hour / 7-day)
- Red-team the current post-P0 privileged sockets + "no input after panic" + phone replay scenarios (safe local harness only).
- Fix the 5-6 Web/API findings (start with routerRundown + Hermes Gateway approve + CLI Link + rate limiting).
- Stand up public SECURITY.md + security.txt + VDP.
- Complete WS2 capability tokens + universal attestation binding on controller paths.
- Add explicit AI high-impact confirmation gates + basic prompt sanitization for CU/RAG.
- Run the full minimum test list (pairing replay/expired/stolen/revoked, view→control escalation, signed upload abuse, prompt injection vectors, kill efficacy, relay flood, etc.) in staging + add to CI.

**This review followed the AGENTS.md completion bar:** full scope, evidence at file:line or doc section, subagent swarm, SOTA framework mapping (in progress), concrete fixes + tests for every finding, no vague "improve security."

Full deliverables (Architecture/Threat Report, complete Findings Register with all required fields, SOTA Gap Analysis vs NIST SSDF / OWASP ASVS 5.0 / API Top 10 / LLM 2025 / CISA SbD / SLSA/OpenSSF / Iroh expectations / remote control safety, BurnBar-Specific Requirements, Fix Roadmap 48h/7d/30d/90d, Reproducible Test Plan, Security Claims Rewrite) are in sibling files in this directory. Prioritized engineer checklist at end of master report.

**Confidence:** High on architecture, cloud API, privileged control, pairing (direct subagent + primary source reads). Medium on full cross-platform (Android E2E, hosted MCP, live kill drills) pending remaining subagent synthesis. All claims are traceable.

**Contact for this review:** Orchestrator (this session) + Alberto for sign-off on P0 gates.
