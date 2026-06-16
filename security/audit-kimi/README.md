# OpenBurnBar Security Audit — Executive Summary

**Run mode:** FULL_BASELINE
**Commit:** `60faa7022767c7287458574765d71e4ecf5b83d9`
**Date:** 2026-06-16
**Auditor:** Kimi Code CLI (autonomous codebase-grounded review)
**Output directory:** `security/audit-kimi/`
**Repository state:** `security/run-09-privacy-invariants-hardening` with a large dirty working tree (uncommitted changes present). Audit evidence is drawn from the checked-in/tracked tree and the current working copy.

---

## Product Snapshot

**OpenBurnBar** is a native macOS menu-bar utility that reads local AI-agent session logs (Claude Code, Codex, Factory/Droid, Kimi, Grok, Cursor, etc.) and produces a live dashboard of token spend, cost estimates, and usage patterns. It ships with:

- a SwiftUI macOS app (`AgentLens/`)
- a local JSON-RPC daemon (`OpenBurnBarDaemon/`)
- shared Swift contracts/types (`OpenBurnBarCore/`)
- a VS Code/Cursor extension (`extensions/openburnbar/`)
- an iOS companion app (`OpenBurnBarMobile/`)
- an Android companion app (`android/`)
- Firebase Cloud Functions (`functions/`)
- a hosted Remote MCP service (`services/hosted-mcp/`)
- local helper tools/MCP servers (`tools/openburnbar-mcp/`)

The product is **local-first**: the canonical store is a local SQLite (GRDB) database. Optional cloud sync uses Firebase Auth + Firestore, with private content sealed via Cloud Vault / Signal-libsignal envelopes before upload. A paid "BurnBar Pro" tier adds hosted encrypted semantic search, hosted quota sync, and Computer Use features.

---

## Current Security Readiness Score

| Score | Value |
|---|---|
| Raw weighted score | **67** |
| Final score (after hard caps) | **59** |
| Confidence | Medium |
| Auditor readiness | Focused security review ready; not yet full external-audit ready |
| Highest applied cap | Major Claim Cap (max 59) |

The score is capped at **59** because several high-stakes claims (local database encryption, E2EE-style privacy for cloud sync, App Check enforcement, Computer Use approval ground truth) are either not fully evidence-backed in the current tree, depend on operational console settings, or lack complete adversarial test coverage. Without the cap the raw score would be **67**.

---

## Top 10 Risks

| Rank | ID | Title | Severity | Why it matters |
|---|---|---|---|---|
| 1 | FINDING-001 | Local SQLite database is plaintext by default | Critical | Core "local-first" privacy claim is undermined; any same-user process or filesystem access reads all usage, transcripts, and provider config. |
| 2 | FINDING-002 | App and daemon run unsandboxed with full home-directory access | Critical | A compromised app/daemon has full access to user data; the README explicitly admits this but it is still the single largest blast radius. |
| 3 | FINDING-003 | Computer Use/agent tool grants rely on scope rules and approval UI that are not fully adversarially tested | High | Browser/Mac input/AX tools can read/type across the OS; poisoning or UI bypass could cause unauthorized high-impact actions. |
| 4 | FINDING-004 | Prompt/RAG injection defenses are partial | High | Untrusted log content is retrieved into LLM prompts and tool results; delimiter wrappers were added but coverage and tests are not complete. |
| 5 | FINDING-005 | App Check enforcement for Firestore is documented but not enforced in code | High | Cloud sync security depends on Firebase console configuration; misconfiguration allows non-app clients to read/write owner-scoped data. |
| 6 | FINDING-006 | Cloud sync opt-in leaks routing/count metadata to Firestore | Medium | Sealed payloads protect content, but provider IDs, timestamps, costs, device IDs, and opaque hashes are server-readable and not E2EE. |
| 7 | FINDING-007 | Daemon RPC runs over a UNIX socket with a single auth token; same-user processes can connect | Medium | The threat model acknowledges this, but there is no second-factor or per-client capability isolation. |
| 8 | FINDING-008 | Local MCP server exposes raw search snippets to external agents without human gate | Medium | `tools/openburnbar-mcp/server.py` returns semantic-search snippets that can be poisoned or leak sensitive context. |
| 9 | FINDING-009 | Cursor connector Cloudflare quick tunnel exposes local router on a public URL | Medium | Short-lived token mitigates risk, but any public URL for a localhost service increases attack surface. |
| 10 | FINDING-010 | Release signing depends on GitHub secrets and runtime key injection; CI compromise could ship malicious binaries | Medium | Strong SLSA/cosign attestations exist, but CI still has broad secrets and writes signed update feeds. |

---

## Biggest Blockers to a Higher Score

1. **Plaintext local database** — the SQLCipher path is designed but not active in shipped builds (`docs/THREAT_MODEL.md` line ~130 admits this). This is a catastrophic cap risk if the product claims local privacy.
2. **Unsandboxed app/daemon** — required by design for log access, but means endpoint compromise = full user compromise.
3. **Operational dependencies** — App Check enforcement, Firebase rules deployment, and Apple JWS verification are outside the repo and must be verified in production.
4. **AI/agentic injection surface** — log ingestion → RAG → prompt is a high-volume indirect injection channel. Mitigations exist but are not uniformly applied or tested.
5. **Missing adversarial tests** for object auth, prompt injection, Computer Use scope bypass, and daemon RPC authorization.

---

## What Is Defensible Today

- **Firebase callable auth model** uses `assertOwnership` + App Check helper; Firestore rules are explicit and owner-scoped (`firestore.rules`).
- **Cloud Vault / Signal-libsignal sealing** for sensitive sync fields is implemented and tested cross-platform.
- **Hosted Remote MCP** uses audience-bound bearer tokens, entitlement rechecks, and hashed identifiers in logs.
- **Apple JWS entitlement pipeline** pins roots, binds tokens to UID, replays against Apple, and fails closed.
- **Release pipeline** produces SBOM, VEX, cosign attestations, checksums, signed appcast, and notarized DMG.
- **Logging redaction** in Cloud Functions masks tokens, emails, IPs, UIDs, and sensitive keys (`functions/src/logging.ts`).
- **Computer Use kill switch** has four independent paths (hotkey, phone gesture, auth gate, Remote Config).

---

## Immediate Next Actions

1. **Decide on the local database encryption launch posture.** Either ship SQLCipher end-to-end or stop claiming local data is protected.
2. **Verify production App Check enforcement** for Firestore and add a runtime probe.
3. **Add adversarial regression tests** for prompt/RAG injection, Computer Use scope bypass, and BOLA/IDOR across all callable functions.
4. **Complete the prompt/RAG untrusted-content wrapping** across all 17 parsers, `ContextBuilder`, `ChatSessionController`, and Computer Use tool-result paths.
5. **Document and test the daemon RPC authorization matrix** per method; add per-client capability tokens if feasible.
6. **Run the launch-blocker live proofs** listed in `docs/REMOTE_MCP_THREAT_MODEL.md` before enabling BurnBar Pro hosted MCP.

---

## Files in This Package

All deliverables are under `security/audit-kimi/`:

- `README.md` — this summary
- `audit-state.json` — machine-readable run state
- `repository-map.md` — repo structure and security-sensitive files
- `security-definition.md` — what "secure" means for users/product/business
- `architecture.md` — components, trust boundaries, data flows
- `assets.md` — asset and data inventory
- `security-claims.md` — claims matrix
- `authz-review.md` — authentication, authorization, identity
- `crypto-secrets-review.md` — cryptography, keys, secrets
- `app-api-review.md` — application/API validation
- `privacy-logging-review.md` — privacy, retention, logs
- `cloud-ops-review.md` — infrastructure and operations
- `supply-chain-review.md` — dependencies, CI/CD, release integrity
- `ai-agentic-review.md` — AI/LLM/agent/tool/memory risks
- `threat-register.md` and `threat-register.csv` — threat register
- `abuse-cases.md` — abuse cases and attack trees
- `findings.md` and `findings.json` — all findings
- `evidence-map.md` — claims/threats/findings → code/tests
- `security-test-plan.md` — existing and missing tests
- `remediation-roadmap.md` — prioritized roadmap
- `security-score.md` and `security-score.json` — score details
- `release-gate.md` — ship/no-ship judgment
- `auditor-brief.md` — external reviewer package
- `open-questions.md` — decisions needed
- `rerun-instructions.md` — how to re-run this audit
