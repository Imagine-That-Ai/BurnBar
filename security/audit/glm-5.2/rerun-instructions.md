# Re-Run Instructions

## How to Run This Audit Again

### Prerequisites
- Read access to the full repository
- Node.js 22+ for Functions tests
- Swift toolchain for daemon/core tests
- `gitleaks` installed for secret scanning

### Steps

1. **Read previous state:**
   ```bash
   cat security/audit/glm-5.2/audit-state.json
   cat security/audit/glm-5.2/findings.json
   ```

2. **Discover repository changes:**
   ```bash
   git log --oneline --since="<last audit date>" --all
   git diff --stat <last audit commit>..HEAD
   ```

3. **Run safe local checks:**
   ```bash
   # Functions security tests
   cd functions && npm run test:security

   # Firestore rules tests
   cd firestore-rules-tests && npm run test:ci

   # Privacy invariants
   node scripts/ci/check-privacy-invariants.mjs

   # BOLA coverage
   cd functions && npx vitest run src/__tests__/bolaCoverage.test.ts

   # Secret scanning
   gitleaks detect --config .gitleaks.toml .

   # Action pin verification
   node scripts/ci/verify-github-action-pins.mjs

   # Daemon crypto tests
   swift test --package-path OpenBurnBarDaemon 2>&1 | grep -E "error:|Test Suite|passed|failed"
   swift test --package-path OpenBurnBarCore --filter CapabilityTokenVerifier 2>&1 | tail -5
   ```

4. **Verify prior findings:**
   - For each finding in `findings.json`, check if the code evidence still exists
   - For "fixed" findings, verify regression tests still exist and pass
   - Mark as: still open, improved, fixed with test, fixed without test, worsened, reopened

5. **Check for new attack surface:**
   - New callable endpoints (diff `functions/src/index.ts`)
   - New Firestore collections (diff `firestore.rules` header comment)
   - New dependencies (diff lockfiles)
   - New CI workflows (diff `.github/workflows/`)
   - New privileged paths (diff `OpenBurnBarDaemon/Sources/`)

6. **Update score:**
   - Re-evaluate each category
   - Apply hard caps
   - Compare to previous score

## What to Compare

| Item | Previous Location | What to Check |
|------|------------------|---------------|
| Findings | `findings.json` | Status changes, new findings |
| Score | `security-score.json` | Score movement, cap changes |
| Claims | `security-claims.md` | New claims, changed statuses |
| Threats | `threat-register.csv` | New threats, changed likelihood |
| Tests | `security-test-plan.md` | New tests, still-missing tests |

## Gates to Enforce

1. **No score increase from documentation-only changes** unless docs resolve an audit-readiness cap
2. **No finding marked "fixed" without** either a regression test or explicit explanation + manual verification steps
3. **Preserve all finding IDs** from prior runs; append new IDs
4. **Flag any regression** where a previously-fixed finding's test is removed or disabled
5. **Confidence gate:** Audit is not mature until no unresolved Critical/High findings (unless explicitly accepted), core claims are evidence-backed, high-risk flows have tests, and sensitive logging is reviewed
