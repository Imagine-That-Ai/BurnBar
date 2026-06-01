# BurnBar / OpenBurnBar SOTA Security Review — Fix Roadmap (June 1, 2026)

**Date:** 2026-06-01
**Basis:** All completed subagents (Architecture, Web/API, Remote Control, Red Team, Auth/Authz) + internal May 2026 remediation plan + primary source evidence.

Roadmap is phased, prioritized by severity + exploitability + blast radius (Critical/High first). Every item references specific evidence or prior finding.

## 48-Hour Emergency Fixes (P0 — before any public/broad exposure)

1. **Daemon UNIX socket auth hardening (Auth subagent Finding 1 + Red Team chain #3)**
   - Add peer UID + code-sign (or launchd entitlement) check in `OpenBurnBarDaemonServer` auth path (currently token string match only; peerPID logged but unenforced).
   - Rotate token on every daemon start/reinstall.
   - Evidence: OpenBurnBarDaemonServer.swift:328-346 + threat model residuals.
   - Owner: Daemon team. Test: Extend existing red-team probe + new "sameUIDMalwareDaemonRPC" case.

2. **Complete/verify remaining WS2 from 2026-05-30 remediation (Remote Control subagent + plan)**
   - Full capability token minting/verification on every "input" dispatch path (bridge, keyboard engine, dispatch handler).
   - Make attestation binding mandatory for all high-tier phone grants + every control intent.
   - Evidence: plans/2026-05-30-sota-security-remediation.md (V1-1, V1-3, WS2), current CapabilityGate + validator code.

3. **Fix verified Web/API findings (Web/API subagent)**
   - Add assertAppCheck (or enforce) to latestRouterRundown (routerRundown.ts:1054).
   - Migrate approveHermesGatewayDeviceGrant (and similar) to enforceHighRiskComputerUseCallable (hermesGateway.ts:499).
   - Add rate limiting on CLI device-code start/poll (cliLink.ts:30/82) + general burst facade on pairing/grants/gateway.
   - Owner: Cloud team. Test: Emulator auth-bypass + concurrency floods.

4. **Public transparency package**
   - SECURITY.md + security.txt + VDP + trust-center outline (links to this review artifacts once sanitized, current threat model summary, audit tools).
   - Evidence: Grep across repo/website (none at top level).

5. **RAG / prompt injection quick wins (Red Team chain #4 + AI scope)**
   - Add "untrusted evidence" markers or explicit sanitization step in ContextBuilder / LogParser paths for logs/screenshots/web content before LLM ingestion.
   - Gate any high-impact BurnBarToolKind (shell, file modify, send, spend) behind explicit confirmation in all flows.

## 7-Day Fixes (P0/P1 — high impact)

- Full revocation propagation: On escrow/peer revoke, fan out invalidation to active iroh streams, Hermes/Pi connections, and long-lived grants (Auth subagent Finding 2 + Red Team chain #5). Add explicit teardown or forced re-handshake.
- Negative authorization test coverage: Implement the 10 specific cases from Auth subagent (IDOR on high-risk callables, direct Firestore escrow elevation, daemon socket impersonation, revoked escrow replay, etc.) under active test targets. Gate on fast-feedback where possible.
- Red Team PoC #1-3 as permanent regression gates (privileged socket + daemon RPC abuse, view-only → control escalation, RAG poisoning harness).
- Claims rewrite application (SECURITY_CLAIMS_REWRITE.md) across website, README, docs, in-app copy.
- Expand supply-chain provenance (cosign + SBOM) to all release artifacts beyond current release lane.
- Update all affected docs (THREAT_MODEL.md, PRIVILEGED_INPUT_THREAT_MODEL.md, SOTA_REMEDIATION_PROGRESS.md, CHANGELOG, runbooks) with current state (P0 sockets closed, revocation gaps, test additions).

## 30-Day Hardening (P1/P2)

- Rate limiting breadth: Proper distributed/burst facade on all sensitive paths (pairing, grants, gateway enqueue, high-risk callables) tied to entitlements.
- Hermes Gateway formal review + token lifetime/nonce/rotation + stricter per-client caps.
- AI/agent confirmation policy: Mandatory gates + sanitization for all high-impact tool categories across browser CU, Mac system input, MCP, and hosted paths. Systematic prompt injection red-team corpus + automated evals.
- Iroh post-pairing app-layer authz proofs: Explicit contracts + tests that every sensitive action (screen start, input, file xfer, agent grants) requires grants/escrow/scope even after successful NodeId connection (Iroh specialist scope).
- Daemon socket full least-privilege (code-sign + UID + process entitlement where feasible) + short-lived tokens.
- Passkeys / phishing-resistant MFA exploration (CISA emphasis) where Firebase paths allow.
- Self-hosted / local gateway hardening guide v2 + documented same-UID residual risks.
- Scorecard + dependency review + KEV monitoring enforced in fast-feedback.

## 90-Day + Long-Term Roadmap

- SLSA L3 + reproducible builds + full artifact signing + dependency review for every platform (macOS, Android, extensions, crates, MCP shims).
- Comprehensive Blue Team detection matrix + playbooks (pairing abuse, anomalous relay volume/cost, high token burn, model switch anomalies, new device/escrow, privilege escalation, admin data access) wired to oncall + automated response where possible.
- External security audit (focus on privileged input, pairing/escrow, RAG/agent flows, supply chain).
- Trust center public dashboard (provenance, audit exports, incident history, SLOs).
- Continuous red-team program for remote control / AI agent surfaces.
- Hardware-backed / HSM options for hosted secrets where feasible.
- Formal (small) protocol verification (pairing/grant/panic) as living documentation.

**Tracking:** Use this file + the Prioritized Engineer Checklist as the single source of truth. Revisit after every P0 batch and before major releases. Update with evidence of completion (PR links, test results, doc updates).

This roadmap, combined with the existing May 2026 remediation plan, constitutes a credible path to materially higher security maturity aligned with the product's actual risk surface (remote privileged execution + AI agents + cross-device control).
