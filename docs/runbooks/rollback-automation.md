# Cloud Functions Rollback Runbook

## Overview

This runbook describes how to roll back the OpenBurnBar Cloud Functions deployment to a previous release in case of a production incident.

The rollback script is located at `scripts/rollback.sh`.

## Prerequisites

- Firebase CLI: `npm install -g firebase-tools && firebase login`
- Git tags synced: `git fetch --tags`
- Authenticated with Firebase project (`firebase use --add`)

## Quick Rollback (< 5 minutes)

```bash
# 1. Preview what will change (dry run)
./scripts/rollback.sh --dry-run

# 2. Roll back to the previous release tag
./scripts/rollback.sh

# 3. Roll back to a specific tag
./scripts/rollback.sh v0.1.2-beta.11
```

## Manual Rollback Steps

If the script fails, follow these manual steps:

1. **Identify the target version:**
   ```bash
   git tag --list "v*" --sort=-version:refname | head -10
   ```

2. **Checkout the target tag:**
   ```bash
   git checkout -b rollback/v0.1.2-beta.11 v0.1.2-beta.11
   ```

3. **Build and deploy:**
   ```bash
   npm ci --prefix functions
   npm run build --prefix functions
   firebase deploy --only functions --project openburnbar
   ```

4. **Verify health:**
   ```bash
   curl https://us-central1-openburnbar.cloudfunctions.net/healthCheck
   # Expected: { "status": "ok", ... }
   ```

## Verification After Rollback

```bash
# 1. Health check
curl https://us-central1-${PROJECT_ID}.cloudfunctions.net/healthCheck

# 2. Liveness probe
curl https://us-central1-${PROJECT_ID}.cloudfunctions.net/healthLive

# 3. Check Firebase Console logs for errors
firebase functions:log --limit 50 --project ${PROJECT_ID}

# 4. Monitor error rate for 10 minutes
```

## Rollback Decision Matrix

| Symptom | Action |
|---------|--------|
| 5xx error rate > 1% sustained | Roll back immediately |
| Cold start latency > 10s | Roll back if affecting users |
| Critical callable returning errors | Roll back immediately |
| Single quota function failing | Hotfix preferred over rollback |
| Firestore data corruption | Roll back + restore from backup |

## Post-Rollback

1. File a production incident in GitHub Issues with `P0 - Critical` + `area: functions` labels
2. Document root cause in `docs/runbooks/` as `incident-YYYY-MM-DD.md`
3. Create a hotfix PR targeting the rolled-back version
4. Do not merge new features until the hotfix is confirmed stable

## Related Runbooks

- [SLO thresholds](slos.md)
- [Computer Use budget](computer-use-budget.md)
- [Cloud Functions deployment](../OPENBURNBAR_RELEASE_ARCHITECTURE.md)
