# BurnBar / OpenBurnBar SOTA Security Review — Second-Opinion Edition
**Date:** 2026-06-01
**Reviewer:** Claude (Sonnet 4.6) — independent second-opinion review, cross-referenced against the prior Grok 4.3 review at `security-review-2026-06-01/`.
**Methodology:** Multi-agent specialist swarm (8 parallel subagents) + primary-source code reading + cited SOTA framework research. Defensive only; safe local / emulator / staging evidence only. No production attacks.

## Purpose of this directory

This is a **second-opinion** review, intentionally **separate from** the prior `security-review-2026-06-01/` directory. The two should be **diffed** to:
- Cross-check that the prior review's claims are accurate against the *current* code (some mitigations have shipped since the prior review was started, per CLAUDE.md / git status).
- Surface any findings the prior review missed.
- Provide an independent severity grading for launch readiness.

The prior review is treated as **a candidate, not a verdict** — every Critical/High finding from it is re-verified here.

## Deliverables in this directory

| File | Purpose |
|---|---|
| `00-MASTER_INDEX.md` | This file. Index + reading order. |
| `01-EXECUTIVE_SUMMARY.md` | Grade, launch readiness, top risks, P0 blockers, what to ship. |
| `02-ARCHITECTURE_THREAT_MODEL.md` | System map, trust boundaries, assets, top abuse cases, assumptions. |
| `03-FINDINGS_REGISTER.md` | All findings in severity order with full required fields. |
| `04-PRIORITIZED_ENGINEER_CHECKLIST.md` | Hand-off artifact (P0/P1/P2/P3 + standing gates). |
| `05-TEST_PLAN.md` | Reproducible test plan. |
| `06-SECURITY_CLAIMS_REWRITE.md` | Precise, non-misleading language. |
| `07-RED_TEAM_KILL_CHAINS.md` | Top attack chains. |
| `08-SOTA_GAP_ANALYSIS.md` | Gap analysis vs. NIST SSDF, OWASP ASVS 5.0, OWASP API Top 10 2023, OWASP LLM Top 10 2025, CISA SbD/SbDemand, SLSA v1.1, Iroh, remote control safety. |
| `09-BURNBAR_SPECIFIC_REQUIREMENTS.md` | Normative product-specific security requirements. |
| `10-FIX_ROADMAP.md` | 48h / 7d / 30d / 90d with owners, dates, dependencies. |
| `11-FINAL_CLOSURE_REPORT.md` | Final Codex closure after follow-up verification, local fixes, and launch-readiness re-grade. |
| `iroh-crypto.md` | Iroh/Networking/Crypto specialist report. |
| `auth-authz.md` | Auth/Authz specialist report. |
| `supply-chain.md` | Supply Chain / Build specialist report. |
| `ai-llm-agent.md` | AI / LLM / Agent specialist report. |
| `privacy-data.md` | Privacy / Data specialist report. |
| `blue-team.md` | Blue Team / Detection / IR specialist report. |
| `clients.md` | Desktop / Mobile / Browser client specialist report. |
| `docs-claims.md` | Documentation / Claims / Trust specialist report. |
| `artifacts/*.json` | Machine-readable findings per specialist. |

## Specialist swarm (run in parallel)

| Specialist | Mandate | Output |
|---|---|---|
| Iroh / Networking / Crypto | Iroh tickets, NodeId, relay metadata, app-layer protocol, HermesRelayCrypto, BLAKE3 vs Bao, ticket lifetime, replay, browser/WASM, downgrade. | `iroh-crypto.md` + `artifacts/iroh-crypto.json` |
| Auth / Authz / Account | Firebase Auth, App Check, device-code, escrow device trust, RBAC, IDOR/BOLA/BFLA, passkeys, refresh tokens. | `auth-authz.md` + `artifacts/auth-authz.json` |
| Supply Chain / Build | Lockfiles, GitHub Actions, cosign, SBOM, VEX, KEV, Scorecard, unpinned Actions, dependency confusion, typosquatting, build cache poisoning, release signing keys. | `supply-chain.md` + `artifacts/supply-chain.json` |
| AI / LLM / Agent | OWASP LLM 2025, prompt injection, tool over-permissioning, memory poisoning, model-switch spoof, cost blowup, vision injection. | `ai-llm-agent.md` + `artifacts/ai-llm-agent.json` |
| Privacy / Data | Data inventory, retention, deletion/export, opt-in accuracy, E2EE claim accuracy, admin access. | `privacy-data.md` + `artifacts/privacy-data.json` |
| Blue Team / Detection / IR | Detection matrix, audit chain, log redaction, IR playbooks, OTS anchoring, forensics. | `blue-team.md` + `artifacts/blue-team.json` |
| Clients (mac/iOS/Android/extension) | Keychain, SQLCipher, daemon socket, URL schemes, ATS, pinning, deep links, OS permissions, custom URL schemes, hardened runtime. | `clients.md` + `artifacts/clients.json` |
| Docs / Claims / Trust | Overclaims, missing SECURITY.md/security.txt/VDP, trust center, claim accuracy. | `docs-claims.md` + `artifacts/docs-claims.json` |

## Verification status legend

Each finding carries a `verification_status`:
- **verified** — read the actual current code on disk; the issue is real today.
- **partial** — mitigations exist in the code or were shipped during the prior review; residual gap remains.
- **unverified** — couldn't reach the code or the dependency; analysis is best-effort and must be confirmed before landing a fix.

## How to use this review

1. **Diff** `03-FINDINGS_REGISTER.md` against the prior `security-review-2026-06-01/FINDINGS_REGISTER.md` — look for new findings (not in prior) and re-classified ones (severity or status changed).
2. **Hand** `04-PRIORITIZED_ENGINEER_CHECKLIST.md` to engineering; this is the actionable artifact.
3. **Apply** `06-SECURITY_CLAIMS_REWRITE.md` to public copy before any launch.
4. **Re-run** the test plan after every P0/P1 batch and update the register.

## Citation policy

Every finding cites file paths and line numbers from the current repo. External standards cite primary sources (OWASP, NIST, CISA, SLSA, Iroh, MITRE) via web research performed during this review. Where a claim depends on a vendor's published guidance, the source URL is recorded in the relevant specialist report.
