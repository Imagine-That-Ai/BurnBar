# Security Readiness Score

## Q.1 Category Scores

| Category | Weight | Score | Weighted Contribution | Confidence | Main Reason |
|----------|--------|-------|----------------------|------------|-------------|
| Architecture and Threat Model | 10% | 82 | 8.2 | High | Clear trust boundaries, DFD, STRIDE mapping; watchdog socket gap |
| Security Claims and Evidence | 10% | 75 | 7.5 | High | Most claims backed by code+tests; phone trust claim broken; kill switch claim caveated |
| Auth, Authorization, and Identity | 12% | 85 | 10.2 | High | assertOwnership everywhere; 21 BOLA test files; attestation binding; att max-age gap |
| Crypto, Secrets, and Protocols | 10% | 88 | 8.8 | High | AEAD everywhere, path-bound AAD (partial), SQLCipher fail-closed, no hardcoded secrets |
| Application/API/Data Validation | 10% | 85 | 8.5 | High | Fail-closed parse guards, no injection, path validation, webhook verification |
| Cloud, Infrastructure, and Operations | 8% | 72 | 5.8 | Medium | WIF, drift checker, health gates; single region; live verification gaps |
| Privacy, Logging, and Data Governance | 8% | 82 | 6.6 | High | Scrubbed everywhere, TTL declared, account deletion comprehensive; Storage purge best-effort |
| Supply Chain and Secure SDLC | 8% | 90 | 7.2 | High | SHA-pinned Actions, SBOM+SLSA+cosign, triple scanning, live feed verification |
| Security Testing and Verification | 10% | 80 | 8.0 | High | 21 BOLA files, privacy invariants CI-enforced; missing tests for new findings |
| AI/Agentic Security | 10% | 75 | 7.5 | Medium-High | Deterministic gate, audit chain, kill switch; local-auth-proof dormant; prompt injection residual |
| Audit Readiness and Documentation | 4% | 78 | 3.1 | High | Architecture docs, threat model, claims matrix; live verification gaps |
| **Overall Raw Score** | **100%** | | **81.4 -> 72** | | (Raw adjusted down for conservative scoring) |

**Note:** Raw score adjusted to 72 for conservative posture: the raw category averages suggest ~81, but several unknowns (deployed state, live verification) and the dormant local-auth-proof warrant conservative scoring.

## Q.2 Hard Caps Applied

### Engineering Maturity Cap: Max 79

**Applied because:**
- Security control exists (local-auth-proof verifier) but is dormant in production (FINDING-002)
- Kill-switch watchdog lacks peer auth (FINDING-001)
- Several core unknowns remain (deployed rules, TTL materialization, shipped telemetry state)
- Privacy retention/deletion has best-effort gap (FINDING-013)
- Incident response monitoring for audit anomalies not configured

**Final Score = min(72, 79) = 72. But further adjusted to 71 for conservative margin.**

### Caps NOT Applied (verified clean)

- **Catastrophic Cap (Max 39):** NOT applied. No unauthenticated data access, no cross-tenant paths, no committed production secrets, no RCE, no hardcoded encryption keys.
- **Critical Cap (Max 49):** NOT applied. No broad plaintext compromise path, no unauthorized high-impact action (kill switch requires root + separate HID compromise), no private keys logged.
- **Major Claim Cap (Max 59):** NOT applied (borderline). E2E claim is evidence-backed for current writers; object-level authz is tested; high-impact actions have deterministic policy enforcement. The borderline items (FINDING-002 dormant verifier, FINDING-008 partial AAD) are not severe enough to trigger this cap.
- **Audit Readiness Cap (Max 69):** NOT applied. Architecture diagram, DFD, asset inventory, trust boundary analysis, claims matrix, threat register, evidence map, test plan, and remediation roadmap all exist.

## Q.3 Score Rationale

The score of 71 reflects a codebase with:
- **Strong crypto** (AEAD, path-bound AAD, SQLCipher fail-closed)
- **Comprehensive authorization testing** (21 BOLA files, CI-enforced coverage)
- **Mature supply chain** (SHA-pinned, SBOM, SLSA, triple scanning, live feed verification)
- **Sophisticated agentic security** (deterministic gate, audit chain, capability tokens, kill switch)

But penalized for:
- **Kill-switch watchdog socket** lacking peer auth (one of few new findings)
- **Local-auth-proof** dormant despite mechanism being complete
- **Phone trust mode UI** violating a documented invariant
- **Partial path-bound AAD** coverage (chat_threads, cli_sessions)
- **Live verification gaps** (deployed state, TTL materialization, shipped telemetry)
- **Several accepted risks** (iroh first-contact, CLI provenance, push metadata)

## Q.4 Confidence and Readiness

- **Confidence:** Medium-High (code analysis is thorough; live deployment state is unverified)
- **Auditor readiness:** Focused security review ready (can hand to external reviewer for specific areas: Computer Use, CloudVault, daemon, supply chain)

## Q.5 Score Movement

| Metric | Previous (2026-06-14) | Current (2026-06-16) | Delta |
|--------|----------------------|---------------------|-------|
| Prior score | Not scored (40 findings, no numeric) | 71 | N/A (first numeric score) |
| Critical findings | 0 | 0 | 0 |
| High findings | 0 (in prior remediation) | 1 (FINDING-001, new) | +1 |
| Medium findings | Several (M-008, M-018, M-021, M-030, M-031) | 9 | Refined |
| Fixed findings | 27 (M-002 through M-040) | 27 confirmed fixed | 0 |
| New findings | N/A | 3 (FINDING-001, 002, 003) | +3 |
