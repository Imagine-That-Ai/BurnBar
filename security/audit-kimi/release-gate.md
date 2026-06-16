# Release Gate Judgment

## Verdict: CONDITIONAL — Do Not Ship Without Addressing Phase 1

OpenBurnBar is **not ready for a broad production release** without addressing the Phase 1 remediation items. The product can ship to a limited beta or dogfood ring if the conditions below are met and accepted in writing by the security/product leads.

## Ship-Blocking Conditions

| # | Condition | Finding | Acceptable Evidence |
|---|---|---|---|
| 1 | Decide local database encryption posture | FINDING-001 | Either (a) SQLCipher enabled with migration tests, or (b) privacy/marketing claims updated to state local DB is plaintext and user accepts risk |
| 2 | Verify App Check production enforcement | FINDING-005 | Console screenshot/audit + non-attested probe + CI drift test |
| 3 | Add adversarial Computer Use tests | FINDING-003 | Merged test suite covering all 13 tool kinds and kill switch |
| 4 | Complete prompt/RAG injection hardening | FINDING-004 | Uniform wrappers + committed adversarial corpus + CI pass |

## Beta Ring Conditions

If shipping to a limited beta:

1. Disable Computer Use by default or force "Manual" approval mode.
2. Disable Remote MCP / hosted search for non-staff users.
3. Add in-app notice: "Local database is not yet encrypted."
4. Require explicit opt-in for cloud sync with metadata visibility disclosure.
5. Enable kill-switch telemetry and alerting.

## Accepted Risks for Beta

- FINDING-002 (unsandboxed app/daemon) — required by design.
- FINDING-006 (metadata visibility) — disclosed in privacy notice.
- FINDING-010 (CI secrets) — mitigated by attestations and maintainer discipline.

## Go/No-Go

| Gate | Status |
|---|---|
| Broad public release | **NO-GO** until Phase 1 complete |
| Limited beta with restrictions | **GO** if all beta conditions met |
| Internal dogfood | **GO** with security monitoring |
