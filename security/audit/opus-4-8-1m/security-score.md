# Security Readiness Score — Opus 4.8 1M lane

**Commit:** `60faa70227` · **Branch:** `security/run-09-privacy-invariants-hardening` · **Date:** 2026-06-16 · **Run mode:** FULL_BASELINE

This score measures **currently-implemented and verifiable** security readiness, not aspirations or deployed-state assumptions. Where a control is implemented in code but its operational effectiveness cannot be confirmed from the repository, it is scored conservatively.

## Q.4 Score table

| Category | Weight | Score | Weighted | Confidence | Main reason |
|---|---:|---:|---:|---|---|
| Architecture & Threat Model | 10% | 82 | 8.20 | high | Mature threat models (73KB BurnBar-threat-model, LLM/agentic, MCP), clear trust boundaries, DFDs; minor doc drift (OPUS-F-017). |
| Security Claims & Evidence | 10% | 70 | 7.00 | medium | Claims register is careful; "sealed before Firestore" holds **with narrowing** — shared artifacts plaintext (OPUS-F-001), partial AAD (OPUS-F-003); public-site wording unverified (OPUS-U-007). |
| AuthN / AuthZ / Identity | 12% | 85 | 10.20 | high | 150-endpoint deterministic authz catalog + bijection completeness test; tier-2 runtime BOLA proofs; owner-scoped rules + secret denylist; write-denied server-only collections; fail-closed prod App Check. |
| Cryptography, Secrets, Protocols | 10% | 74 | 7.40 | medium | AES-256-GCM sealing real + AAD-bound; ECIES-P256 escrow; KMS-envelope backend secrets; no hardcoded secrets; CI crypto-policy gate. Gaps: partial AAD (OPUS-F-003), local DB plaintext (OPUS-F-004), libsignal inert. |
| App / API / Data Validation | 10% | 77 | 7.70 | medium | Typed Codable/decode, input size caps, SSRF guard present; latent SSRF alt-encoding gap (OPUS-F-007, unreachable today). |
| Cloud, Infrastructure, Operations | 8% | 48 | 3.84 | low | Detection real in code, but alert deliverability (OPUS-U-003), live TTL state (OPUS-U-001), App Check console (OPUS-U-002), prod deploy currency (OPUS-U-004) unverifiable; single prod env, GCP_SA_KEY, laptop-deploy history (06-11). |
| Privacy, Logging, Data Governance | 8% | 77 | 6.16 | medium | run-09 invariants I1-I5 code-enforced + tested + gated (gates pass non-vacuously); complete account deletion. Residuals: OPUS-F-005 (uid console.warn), OPUS-F-006 (thread_id push), I6 live-state unverified. |
| Supply Chain & Secure SDLC | 8% | 78 | 6.24 | medium-high | 271/271 actions SHA-pinned (blocking verifier); layered secret scanning; CodeQL 4 langs + Rust; signed/notarized/EdDSA release + SBOM/VEX/cosign + auto-rollback; CG-1/qa.yml/submodule all fixed. Branch-protection ruleset unverified (OPUS-U-005). |
| Security Testing & Verification | 10% | 74 | 7.40 | medium | Strong: BOLA tier-2, rules emulator tests, privacy-gate self-tests, conformance vectors. Gaps: macOS scrubber test (OPUS-F-002), some Swift privileged-input red-team not in CI, session-log rules test non-blocking. |
| AI / Agentic Security | 10% | 83 | 8.30 | high | Approval enforced in code (not prompt); 4 panic-kill paths; deny-regions beat signed authority; tamper-evident audit-before-action; budget caps; blind E2EE relay; no L5 autonomy; provenance-wrapped untrusted content. |
| Audit Readiness & Documentation | 4% | 66 | 2.64 | medium | This package + existing docs supply the artifacts, but run-1 (no cross-run stability) and 7 operational unknowns keep full external-audit readiness out of reach. |
| **Overall Raw Score** | 100% | **75** | **75.08** | medium | Strong implemented baseline; operational-state and 2 Medium gaps. |
| **Final Score After Caps** | 100% | **73** | — | medium | Engineering Maturity Cap (79) is a non-binding ceiling; final held at 73 for run-1 confidence-gate + open Mediums + operational unknowns. |

## Q.3 Hard caps

| Cap | Max | Applied? | Reasoning |
|---|---:|---|---|
| Catastrophic | 39 | **no** | No unauthenticated sensitive-data access, no cross-tenant access (tier-2 tested), no committed production secrets (scanning + gate), no unauth RCE, no untrusted-content tool/shell exec (approval-gated), no hardcoded/shared keys, no silent broad admin access (operator reads = aggregate ops metrics only). |
| Critical | 49 | **no** | No high-confidence broad-plaintext-compromise path, no ATO path, no unauthorized high-impact action, no private-key/long-lived-token logging (uid leak ≠ key), revoked credentials re-checked, no low-friction CI-to-prod malicious-ship path (SHA-pinned + signed + scanned + no-suppressions gate). |
| Major Claim | 59 | **no** | Object-level authz **is** consistently tested; sensitive logging **has** been reviewed; high-impact AI/tool actions **have** deterministic policy enforcement; deletion/retention backed by code; replay/freshness clear (billing, App Check nonces). The encryption/privacy claim holds **with narrowing** (session_logs FIXED M-005; chat/conversations sealed) — the shared-artifacts plaintext path is a **disclosed** sync surface (threat model lists shared-artifact data as Firestore-readable), so it is a Medium finding, not a contradicted claim. |
| Audit Readiness | 69 | **no** | Architecture, DFDs, asset inventory, trust boundaries, claims matrix, threat register, evidence map, test plan, and remediation roadmap all present (this package + existing docs). |
| Engineering Maturity | 79 | **yes (ceiling)** | Some controls lack production-mode regression tests (macOS scrubber; privileged-input red-team not in CI); monitoring/alerting operational effectiveness unconfirmed (06-11 NXDOMAIN alert channel); multiple core deployment-state unknowns remain. Ceiling 79; raw already below it. |

## Q.5 Score movement

This lane has no prior run. Cross-lineage reference points (different methods/scopes, not directly comparable):

| Source | Score | Note |
|---|---|---|
| 06-11 internal diligence | 65/100 | Heavier ops/process weighting; pre-run-09. |
| 06-14 merged final | n/a (qualitative) | M-lineage; "does not certify a deployed system." |
| Concurrent lane (this dir's `security/audit/*`) | 71 (README) / 59 (score.md) | Internally inconsistent; different scope. |
| **This lane** | **73** | Current-branch code verification + conservative operational hold. |

## Paths to higher scores

**Path to 80** — resolve OPUS-U-001..005 with operator evidence (live TTLs ACTIVE, App Check enforced, alert channel deliverable, prod deploy current, branch protection on); close OPUS-F-001 (seal artifacts or document non-claim) and OPUS-F-002 (add macOS scrubber test). Achieve one stable re-run (lifts the run-1 hold).

**Path to 90** — Path to 80 + close OPUS-F-003 (path-bound AAD on all sealed surfaces), wire privileged-input red-team into a macOS nightly, make session-log rules test blocking, add adversarial prompt-injection / confused-deputy tests for Computer Use + MCP, and produce operator-attested incident-response + monitoring playbooks.

**Path to 95+** — Path to 90 + independent external security review (e.g., Cure53 / Trail of Bits / NCC), all Medium findings fixed-or-accepted with regression guards, continuous security regression in CI, and precise validated public security claims.
