# Release Gate

## Ship / Do Not Ship / Ship with Conditions

**Verdict: SHIP WITH CONDITIONS**

The codebase is production-quality with strong defense-in-depth architecture. The single High finding (kill-switch watchdog socket) requires root access as a precondition and weakens only one of multiple safety layers. The documented invariants that are violated (phone downgrade-only, kill switch cannot be disarmed) should either be fixed or the claims adjusted before public security assertions.

## Blocking Issues (Must Fix Before Public Security Claims)

1. **FINDING-001 (High):** Kill-switch watchdog socket has no peer auth. Fix: add codesig gate. **Alternatively:** adjust public claims to not assert "cannot be disarmed by any local process."
2. **FINDING-003 (Medium-High):** Phone trust mode UI not downgrade-only. Fix: filter modes. **Alternatively:** stop claiming "phone can only downgrade trust."
3. **UNKNOWN-001:** Deployed Firestore rules must match this checkout.
4. **UNKNOWN-002:** TTL policies must be materialized in production.

## Non-Blocking Issues (Fix Soon)

1. **FINDING-002:** Local-auth-proof verifier dormant (defense-in-depth gap, not a direct exploit)
2. **FINDING-008:** chat_threads/cli_sessions global AAD (same-user boundary)
3. **FINDING-007:** App Check max-age 30 days (tighten post-launch)
4. **FINDING-009:** SSRF guard DNS gap (no user URL reaches fetch today)

## Claim Changes Required

- **STOP claiming:** "The phone can only downgrade trust; elevation requires the Mac" (until FINDING-003 is fixed)
- **STOP claiming:** "The kill switch cannot be disarmed" (until FINDING-001 is fixed)
- **START claiming (accurate):** "Multiple independent panic-halt paths reach the privileged input boundary"
- **CONTINUE NOT claiming:** Signal encryption is live, perfect forward secrecy for iroh, zero-knowledge

## Tests Required Before Ship

- All existing CI gates green (BOLA, privacy invariants, rules tests, function tests)
- Firestore rules `test:ci` (all 6 suites) passing
- `swift test --package-path OpenBurnBarDaemon` passing
- `swift test --package-path OpenBurnBarCore --filter CapabilityTokenVerifier` passing
- Secret scanning clean (`gitleaks detect`)

## Monitoring Required

- Firestore TTL policy state (run `verify-firestore-ttl-state.mjs` after deploy)
- Firestore rules drift (run `check-firestore-deploy-drift.mjs` after deploy)
- Post-deploy health gate (`post-deploy-health-gate.sh`)
- Sentry error rate after deploy
- Audit chain validation for first Computer Use sessions

## Rollback Considerations

- `scripts/rollback.sh` reads `functions/.env.burnbar.production` for source-safe rollback
- Sub-minute Functions revision rollback available
- Remote Config `computer_use_kill_switch` can halt all Computer Use sessions globally
- Firestore rules can be rolled back via `deploy-firebase-rules-releases.mjs` with release tagging
- App can be rolled back via Sparkle update feed (previous version appcast entry)
