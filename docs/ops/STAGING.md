# Staging / pre-prod environment runbook

**Status:** SCAFFOLD. The staging project does **not** exist yet. This repo ships
the wiring (`.firebaserc` `staging` alias, `.github/workflows/deploy-staging.yml`,
`functions/.env.burnbar-staging.example`) so the staging deploy lane is a **safe
no-op** until you complete the provisioning steps below. Nothing here touches
production (`burnbar`).

## Why this exists

Today `.firebaserc` has exactly one project (`default: burnbar`). Every Firestore
rules / indexes / Storage rules / Cloud Functions change is deployed straight to
the single production project. A bad rules edit, a missing composite index, or a
functions regression has no rehearsal surface — it lands on real users. The
diligence review flagged this single-project setup as the highest-probability
source of a self-inflicted incident.

Staging fixes that: an isolated Firebase/GCP project (`burnbar-staging`) that is
byte-for-byte the same `firestore.rules` / `firestore.indexes.json` /
`storage.rules` / `functions` source, deployed with the **same** WIF/OIDC,
predeploy-stripped, drift-checked safety pipeline as production — just pointed at
the staging project and gated behind a `staging` GitHub Environment.

## Promotion flow (dev → staging → prod)

```
 local emulator            staging project              production project
 (firebase emulators)  →   burnbar-staging          →   burnbar
 functions/*, rules,       deploy-staging.yml            deploy-firestore.yml
 indexes tested            (manual dispatch,             (push to main)
 against emulator          gated by STAGING_ENABLED)     deploy-production.yml
                                                         (v* release tags)
```

1. **dev** — iterate locally against the Firebase emulator suite
   (`npm --prefix functions run test:firestore-rules`, emulators for functions).
   `FIREBASE_PROJECT_ID=openburnbar-dev` in `functions/.env.example` is the local
   dev handle; no cloud project is required for emulator work.
2. **staging** — run `Deploy Staging (Firestore + Functions)` (this workflow) to
   rehearse the *exact* files against `burnbar-staging`. Rules emulator tests and
   the post-deploy drift check must be green.
3. **prod** — only after staging is green, land the same files on `main`
   (`deploy-firestore.yml` deploys rules/indexes/storage on push) and cut a `v*`
   release tag (`deploy-production.yml` deploys functions).

The staging Functions config must set `APP_CHECK_STANDARD_WEB_APP_IDS` to the
exact staging browser Firebase app ID shipped through
`NEXT_PUBLIC_FIREBASE_APP_ID` / `PUBLIC_FIREBASE_APP_ID`. Do not reuse the
production ID or any Linux/Windows desktop ID. Until
`functions/.env.burnbar-staging.example` is copied, filled, reviewed, and
renamed, the staging lane remains intentionally unavailable.

The point: **the diff you promote to prod is the diff you already proved in
staging.** Same source files, same pipeline shape, different project + creds.

---

## What Alberto must provision (one-time)

You need `gcloud` + `firebase` CLIs authenticated as an owner of the GCP org/
billing account. Estimated time: ~15–20 minutes.

### 1. Create the staging Firebase/GCP project

```bash
# Project id must match .firebaserc `staging` alias (or override via the
# STAGING_FIREBASE_PROJECT repo variable — see step 5).
gcloud projects create burnbar-staging --name="BurnBar Staging"
gcloud billing projects link burnbar-staging \
  --billing-account="<YOUR_BILLING_ACCOUNT_ID>"

# Add Firebase to the GCP project + enable the APIs the deploy lane needs.
firebase projects:addfirebase burnbar-staging
gcloud services enable \
  firestore.googleapis.com \
  firebaserules.googleapis.com \
  firebasestorage.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com \
  cloudtasks.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project=burnbar-staging

# Create the Firestore database (Native mode) in the accepted production region.
gcloud firestore databases create --location=us-central1 --project=burnbar-staging

# Create the Firebase Storage default bucket in the same region. Use Firebase
# Console → Build → Storage → Get started if your local Firebase CLI cannot
# create the default bucket non-interactively; the bucket name must be the modern
# default, not the legacy appspot.com bucket.
gcloud storage buckets create "gs://burnbar-staging.firebasestorage.app" \
  --project=burnbar-staging \
  --location=us-central1 \
  --uniform-bucket-level-access || true
gcloud storage buckets describe "gs://burnbar-staging.firebasestorage.app" \
  --project=burnbar-staging >/dev/null
```

> If you pick a project id other than `burnbar-staging`, either edit the
> `staging` alias + `burnbar-staging` targets block in `.firebaserc`, **or**
> leave `.firebaserc` as-is and set the `STAGING_FIREBASE_PROJECT` repo variable
> (step 5) — the workflow reads `vars.STAGING_FIREBASE_PROJECT` and only falls
> back to `burnbar-staging`.

### 2. Create the deploy service account (least privilege)

```bash
gcloud iam service-accounts create burnbar-staging-deployer \
  --display-name="BurnBar Staging Deployer" \
  --project=burnbar-staging

SA="burnbar-staging-deployer@burnbar-staging.iam.gserviceaccount.com"

# Rules + indexes + storage + functions deploy. Mirror production's least-
# privilege intent; scope to staging only.
for ROLE in \
  roles/firebaserules.admin \
  roles/datastore.indexAdmin \
  roles/cloudfunctions.developer \
  roles/cloudbuild.builds.editor \
  roles/artifactregistry.admin \
  roles/run.admin \
  roles/iam.serviceAccountUser \
  roles/firebasestorage.admin \
  roles/serviceusage.serviceUsageConsumer ; do
  gcloud projects add-iam-policy-binding burnbar-staging \
    --member="serviceAccount:${SA}" --role="${ROLE}"
done
```

### 3. Wire Workload Identity Federation (no long-lived keys)

Production auths via OIDC WIF only (see `deploy-firestore.yml` /
`deploy-production.yml`). Staging must too — **do not create JSON SA keys.**

```bash
POOL=github-pool
PROVIDER=github-provider
PROJECT_NUMBER="$(gcloud projects describe burnbar-staging --format='value(projectNumber)')"
REPO="Imagine-That-Ai/BurnBar"   # canonical origin owner/repo

gcloud iam workload-identity-pools create "$POOL" \
  --project=burnbar-staging --location=global \
  --display-name="GitHub Actions pool"

gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
  --project=burnbar-staging --location=global \
  --workload-identity-pool="$POOL" \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository=='${REPO}'"

# Let the deploy SA be impersonated ONLY from this repo (optionally pin a ref).
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project=burnbar-staging \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

# The provider resource name is the STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER secret:
echo "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
```

> Harden later by narrowing the `principalSet` / attribute condition to a
> specific ref (e.g. `attribute.ref=='refs/heads/main'`) once the flow works.

### 4. Create the `staging` GitHub Environment

`Settings → Environments → New environment → staging`.
- Add yourself as a **required reviewer** (matches production's approval gate).
- Optionally restrict deployment branches to `main`.

### 5. Set the staging secrets + variables

**Environment secrets** (scope: `staging` environment):

| Secret | Value |
| --- | --- |
| `STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER` | the provider resource name printed in step 3 |
| `STAGING_GCP_DEPLOY_SERVICE_ACCOUNT` | `burnbar-staging-deployer@burnbar-staging.iam.gserviceaccount.com` |
| `STAGING_SENTRY_DSN_FUNCTIONS` | *(optional)* staging functions Sentry DSN |

**Repository variables** (`Settings → Secrets and variables → Actions → Variables`):

| Variable | Value | Effect |
| --- | --- | --- |
| `STAGING_ENABLED` | `true` | **Flips the workflow on.** Until this is `true`, the preflight job reports "not provisioned" and every deploy job is skipped. |
| `STAGING_FIREBASE_PROJECT` | *(optional)* staging project id | Overrides the `burnbar-staging` default if you named the project differently. |

```bash
gh secret set STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER --env staging --repo Imagine-That-Ai/BurnBar
gh secret set STAGING_GCP_DEPLOY_SERVICE_ACCOUNT     --env staging --repo Imagine-That-Ai/BurnBar
gh variable set STAGING_ENABLED --body true --repo Imagine-That-Ai/BurnBar
```

### 6. Staging functions runtime config (only if deploying functions)

```bash
cp functions/.env.burnbar-staging.example functions/.env.burnbar-staging
# Edit: replace every <STAGING-…> placeholder with the staging project's public
# IDs/URLs. Prefer Stripe TEST-mode price IDs and App Store/APNs Sandbox.
git add functions/.env.burnbar-staging && git commit  # reviewed PR, like prod
```

Also set the staging functions' real secrets in the **staging** project's Secret
Manager (Stripe TEST secret key, APNs key, etc.) exactly as you did for prod —
they are never stored in the committed `.env`.

### 7. First deploy (rules/indexes/storage), then functions

```bash
# Dry run first (default): rules emulator tests + config checks, no deploy.
gh workflow run deploy-staging.yml --repo Imagine-That-Ai/BurnBar -f dry_run=true

# Real rules/indexes/storage deploy to staging:
gh workflow run deploy-staging.yml --repo Imagine-That-Ai/BurnBar -f dry_run=false

# Include functions once functions/.env.burnbar-staging exists:
gh workflow run deploy-staging.yml --repo Imagine-That-Ai/BurnBar \
  -f dry_run=false -f deploy_functions=true
```

Approve the `staging` environment when prompted. Confirm the run's summary shows
the rules emulator tests, post-deploy drift check, and live TTL verification
green.

---

## How to rehearse a rules change (the core use case)

1. Edit `firestore.rules` (and/or `firestore.indexes.json` / `storage.rules`) on
   a branch.
2. `npm --prefix functions run test:firestore-rules` locally against the emulator.
3. Push the branch, then run `deploy-staging.yml` with `dry_run=false` — this
   deploys the branch's rules/indexes to **staging**, drift-checks them against
   the live staging project, and verifies every declared `ttl:true` override is a
   live TTL policy.
4. Exercise the change against `burnbar-staging` (console client pointed at the
   staging project, or ad-hoc reads/writes) to confirm intended allow/deny.
5. Only then merge to `main`. `deploy-firestore.yml` promotes the identical files
   to production on push.

## Safety properties (mirrors production)

- **Safe no-op until provisioned:** the `preflight` job gates on
  `STAGING_ENABLED == 'true'` **and** the presence of the two `STAGING_GCP_*`
  secrets. Missing any → deploy jobs skipped, workflow succeeds with a
  "not provisioned" summary. It cannot fail against a non-existent project.
- **Manual trigger only:** no `push`/tag trigger, so staging never fires
  unexpectedly. `dry_run` defaults to `true`.
- **WIF/OIDC only:** no long-lived JSON keys, same as production.
- **Predeploy stripped:** reuses `scripts/ci/write-firebase-hosting-ci-config.mjs
  --check` and the `grep -q '"predeploy"'` guard, so no repo-controlled predeploy
  hook runs under staging deploy credentials.
- **Environment-gated:** the `staging` GitHub Environment provides an approval
  gate and (optionally) branch restrictions, mirroring `environment: production`.
- **Isolated blast radius:** every credentialed step targets the staging project
  via `--project`; production (`burnbar`) is never referenced by this workflow.

## Teardown

To pause staging deploys without deleting anything: set `STAGING_ENABLED=false`
(or delete the variable). To decommission: `gcloud projects delete
burnbar-staging` and remove the `staging` environment/secrets.
