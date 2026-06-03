# Cloud Functions Rollback Runbook

## Overview

This runbook describes how to roll back the OpenBurnBar Cloud Functions deployment to a previous release in case of a production incident.

There are **two** rollback paths. Reach for the fast one first.

| Path | Script | What it does | MTTR |
|------|--------|--------------|------|
| **Fast revision-pin** (primary) | `scripts/ops/rollback-revision.sh` | Flips 100% of traffic back to a previous-good Cloud Run revision. No git checkout, no build, no redeploy. | **sub-minute** |
| Full source rollback (fallback) | `scripts/rollback.sh` | Checks out a release tag, rebuilds Functions, and runs `firebase deploy`. | **tens of minutes** |

**Why the fast path works:** Gen2 Cloud Functions ARE Cloud Run services. Every deploy creates an immutable Cloud Run *revision*, and traffic is a separate, instantly re-routable pointer. Rolling back a bad deploy is just pointing traffic at the prior revision — no artifact rebuild required. Prefer this for any deploy-introduced regression where a known-good revision still exists.

**When to fall back to source rollback:** the bug is in committed source you must actually revert, the prior revisions were pruned/garbage-collected, or no good revision exists. Expect tens of minutes of MTTR because it rebuilds and redeploys.

## Prerequisites

**Fast revision-pin:**

- gcloud CLI: installed and authenticated (`gcloud auth login`, or ADC)
- Caller has `roles/run.admin` (or `run.services.update` + `run.revisions.list`)

**Full source rollback:**

- Firebase CLI: `npm install -g firebase-tools && firebase login`
- Git tags synced: `git fetch --tags`
- Authenticated with Firebase project (`firebase use --add`)

## Fast Revision-Pin Rollback (sub-minute — PRIMARY)

```bash
# 1. Preview the plan + the exact gcloud command (changes nothing)
./scripts/ops/rollback-revision.sh <cloud-run-service> --dry-run

# 2. Roll back to the most recent revision NOT currently serving 100% traffic
./scripts/ops/rollback-revision.sh <cloud-run-service>

# 3. Roll back to a specific revision, non-interactive (CI / paged at 3am)
./scripts/ops/rollback-revision.sh <cloud-run-service> <revision> --yes
```

The script lists revisions newest-first, picks the previous-good one (unless you
name one), prints the plan, flips traffic, then health-checks the service URL
(non-2xx is a warning, not a failure). Region defaults to `us-central1`; project
defaults to the `.firebaserc` default (`burnbar`). Override with `--region` /
`--project`.

The exact command it runs under the hood:

```bash
gcloud run services update-traffic <cloud-run-service> \
  --region us-central1 \
  --project burnbar \
  --to-revisions=<revision>=100
```

To list candidate revisions by hand:

```bash
gcloud run revisions list \
  --service <cloud-run-service> \
  --region us-central1 \
  --project burnbar \
  --sort-by='~metadata.creationTimestamp'
```

## Full Source Rollback (slow — FALLBACK)

Use only when no good revision exists (see "When to fall back" above).

```bash
# 1. Preview what will change (dry run)
./scripts/rollback.sh --dry-run

# 2. Roll back to the previous release tag
./scripts/rollback.sh

# 3. Roll back to a specific tag
./scripts/rollback.sh v0.1.2-beta.11

# 4. Non-interactive (skip confirmation)
./scripts/rollback.sh --yes
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
