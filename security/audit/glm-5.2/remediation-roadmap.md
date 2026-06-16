# Remediation Roadmap

## Must Fix Before Launch / Audit

### RM-001: Add peer authentication to kill-switch watchdog socket
- **Addresses:** FINDING-001 / THREAT-001
- **Severity:** High
- **Implementation:** Add `PrivilegedPeerAuthenticator` codesig gate to `PrivilegedInputKillSwitchWatchdogMain.swift handleClient()` before honoring activate/clear. Pattern exists in `PrivilegedInputExecutionSocketServer.validateSocketPeer()`.
- **Tests:** Connect with unsigned binary -> verify rejection
- **Effort:** Small
- **Expected score impact:** +5 (removes Engineering Maturity cap contributor)

### RM-002: Fix phone trust mode UI to downgrade-only
- **Addresses:** FINDING-003 / THREAT-003
- **Severity:** Medium-High
- **Implementation:** In `PhoneControlOptionSheet.swift`, filter `ComputerUseTrustMode.allCases` to only show modes with rawValue <= current mode. Add direction validation in `downgradeTrustMode`.
- **Tests:** Verify phone only shows eligible modes
- **Effort:** Small
- **Expected score impact:** +3

### RM-003: Migrate chat_threads and cli_sessions to path-bound AAD
- **Addresses:** FINDING-008 / THREAT-004
- **Severity:** Medium
- **Implementation:** (1) Update `ChatThreadSyncService.swift:106` to pass `aadContext` to `sealPayload`. (2) Update `CLIAgentSessionRecord.swift:438` similarly. (3) Tighten Firestore rules from `validSealedPayloadForUser` to `validPathBoundSealedPayloadForUser` for both collections.
- **Tests:** Extend `firestore-rules-tests/m007-path-bound-sealed-payload.test.js` with chat_threads and cli_sessions cases
- **Effort:** Medium
- **Expected score impact:** +2

## Should Fix Soon

### RM-004: Wire local-auth-proof verifier in production daemon
- **Addresses:** FINDING-002 / THREAT-002
- **Implementation:** Implement daemon-side pinned phone-key store; wire app-side proof population; flip `localAuthProofVerifier` from nil to active
- **Effort:** Medium (mechanism complete, needs key store + wiring)
- **Expected score impact:** +3

### RM-005: Tighten App Check attestation max-age
- **Addresses:** FINDING-007
- **Implementation:** Reduce `APP_CHECK_ATTESTATION_MAX_AGE_MS` to 7 days or make Remote Config configurable
- **Effort:** Small
- **Expected score impact:** +1

### RM-006: Live verification of deployed state
- **Addresses:** UNKNOWN-001 through UNKNOWN-006
- **Implementation:** Run `check-firestore-deploy-drift.mjs`, `verify-firestore-ttl-state.mjs`, read Sentry settings, inspect shipped artifacts, clean-Mac install proof
- **Effort:** Small (verification, not implementation)
- **Expected score impact:** +3 (resolves unknowns)

## Hardening

### RM-007: Add recursive Sentry scrubber to VS Code extension
- **Addresses:** FINDING-011
- **Effort:** Small
- **Expected score impact:** +0.5

### RM-008: Storage deletion reconciliation job
- **Addresses:** FINDING-013
- **Effort:** Medium
- **Expected score impact:** +0.5

### RM-009: Add explicit permissions to remaining workflows
- **Addresses:** FINDING-016
- **Effort:** Small
- **Expected score impact:** +0.5

## Fastest Path to +10 Points

| Fix | Score Gain | Effort |
|-----|-----------|--------|
| RM-001 (watchdog auth) | +5 | Small |
| RM-002 (phone trust UI) | +3 | Small |
| RM-006 (live verification) | +3 | Small (verification) |
| **Total** | **+11** | **~1 day** |

## Path to 80

1. RM-001: Watchdog auth (+5)
2. RM-002: Phone trust UI (+3)
3. RM-003: Path-bound AAD migration (+2)
4. RM-006: Live verification (+3)
5. RM-005: Att max-age (+1)
**Estimated score: ~81** (cap removal needed)

## Path to 90

1. Everything in Path to 80
2. RM-004: Wire local-auth-proof (+3)
3. Fix all Low findings (+3)
4. External security review commenced (+5)
5. Systematic adversarial prompt-injection test suite (+2)
**Estimated score: ~90**

## Path to 95+

1. Everything in Path to 90
2. Independent external audit completed
3. Critical/High findings remediated
4. Continuous security regression tests in CI
5. Public security claims precise and validated
**Estimated score: 95+**
