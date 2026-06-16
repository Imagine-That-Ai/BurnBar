# How to Re-Run This Audit

## Prerequisites

- macOS with `git`, `python3`, `node`, `npm`/`pnpm`, `gitleaks`, and project toolchains.
- Firebase project access for App Check console verification.
- Access to GitHub Actions logs for release workflow review.

## Automated Steps

1. **Secret scan**
   ```bash
   gitleaks detect --source . --verbose --config .gitleaks.toml > security/audit-kimi/gitleaks-report.json
   ```

2. **Dependency audit**
   ```bash
   bash scripts/supply-chain-audit.sh
   ```

3. **Fast feedback**
   ```bash
   make ci
   # or
   bash .github/workflows/fast-feedback.yml  # not directly runnable; use CI
   ```

## Manual Steps

1. Verify SQLCipher in Release build:
   ```bash
   # Build Release .app, then:
   sqlite3 ~/Library/Application\ Support/OpenBurnBar/*.sqlite
   PRAGMA cipher_version;
   ```

2. Verify App Check enforcement:
   - Open Firebase Console → App Check → Metrics.
   - Confirm Firestore shows "Enforced".
   - Run a non-attested REST probe.

3. Review Firestore rules drift:
   ```bash
   firebase firestore:rules:get > /tmp/deployed.rules
   diff firestore.rules /tmp/deployed.rules
   ```

4. Run adversarial tests:
   ```bash
   ./scripts/test-openburnbar-app.sh
   cd android && ./gradlew :app:testDebugUnitTest --no-daemon
   cd functions && npm test
   ```

5. Update score and findings:
   - Re-evaluate each finding against new evidence.
   - Update `security-score.json` and `findings.json`.

## Re-Generation Checklist

- [ ] Re-run `gitleaks` and update report.
- [ ] Re-verify App Check and Firestore rules.
- [ ] Re-run all unit tests and note failures.
- [ ] Update finding statuses and score.
- [ ] Update `audit-state.json` with new commit/date.
- [ ] Commit the regenerated `security/audit-kimi/` directory.
