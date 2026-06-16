# Security Scorecard

## Methodology

Starting baseline: **100**

| Adjustment | Value | Rationale |
|---|---|---|
| Critical findings open | -2 × 15 = -30 | Two critical findings; each capped at -15 to avoid over-penalty |
| High findings open | -3 × 4 = -12 | Three high findings |
| Medium findings open | -12 × 2 = -24 | Twelve medium findings |
| Low findings open | -5 × 1 = -5 | Five low findings |
| Strengths bonus | +38 | Strong authz, sealed envelopes, kill switches, release integrity, logging |
| **Raw score** | **67** | 100 - 30 - 12 - 24 - 5 + 38 |

## Hard Caps Applied

| Cap | Condition | Applied | Effect |
|---|---|---|---|
| Catastrophic Cap | Critical issue without remediation path | No | Plaintext DB has known remediation (SQLCipher) |
| Major Claim Cap | Multiple major claims depend on operational/console settings or lack complete evidence | **Yes** | Raw 67 → **Final 59** |

### Major Claim Cap Justification

The following high-stakes claims are not fully evidence-backed in the repo:

1. **CLAIM-013 Local database encrypted** — SQLCipher not active (FINDING-001).
2. **CLAIM-005 App Check enforcement** — depends on Firebase console (FINDING-005).
3. **CLAIM-007 Computer Use approval ground truth** — adversarial tests incomplete (FINDING-003).
4. **CLAIM-012 MCP scoped and safe** — local MCP lacks human gate (FINDING-008).
5. **CLAIM-003 Server cannot read content** — AAD partial (FINDING-015).

Because the product's core value proposition (local privacy) and high-risk features (Computer Use, cloud sync) depend on these claims, the score is capped at **59** until at least three of the five are fully evidenced and tested.

## Final Score

| Metric | Value |
|---|---|
| Raw weighted score | 67 |
| Final score | **59** |
| Grade | D+ / "Focused review ready; not yet external-audit ready" |

## Score Breakdown by Domain

| Domain | Score | Notes |
|---|---|---|
| Local platform security | 35/100 | Plaintext DB and unsandboxed app dominate |
| Cloud sync security | 70/100 | Strong rules/sealing; App Check unverified |
| Authentication / authorization | 75/100 | Good patterns; BOLA tests missing |
| AI / agentic security | 55/100 | Partial mitigations; tests incomplete |
| Computer Use safety | 50/100 | Strong controls but unproven under adversarial test |
| Cryptography | 70/100 | Good design; local and AAD gaps |
| Privacy / logging | 75/100 | Good redaction; free-form and metadata leaks |
| Supply chain / release | 80/100 | Strong attestations; CI secrets risk |
| Cloud operations | 65/100 | Rules, monitoring; rate limits and drift risk |

## Confidence

**Medium** — Audit is code-grounded but limited by:
- No dynamic testing of production Firebase console/App Check.
- No adversarial fuzzing performed (analysis only).
- Prior audit items assumed accurate where not re-verified.
