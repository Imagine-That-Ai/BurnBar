# Staging / pre-prod environment runbook

**Status:** FOUNDATION PROVISIONED; LIVE VALIDATION IN PROGRESS. The isolated
`burnbar-staging` GCP/Firebase project is billing-enabled and now has Firestore,
Firebase Storage, Firebase Authentication, and a Windows staging Web app. The
least-privilege deploy service account, repository-scoped GitHub OIDC provider,
and protected `staging` GitHub Environment remain in place. Rules deployment,
Desktop OAuth, real Windows TPM App Check verification, CloudVault, and staging
Functions are still fail-closed. Nothing here touches production (`burnbar`).

## Live provisioning snapshot - 2026-07-18

Read-only inspection produced this fail-closed state:

| Surface | Status |
| --- | --- |
| GCP project `burnbar-staging` | Active; Firebase APIs are attached |
| Deploy service account | `burnbar-staging-deployer` exists with all nine documented project roles |
| GitHub OIDC | `github-pool/github-provider` is active and repository-scoped |
| GitHub Environment | `staging` requires review and permits deployments from `main` only |
| Billing | Enabled through the approved company billing account |
| Firestore database | Native-mode `(default)` database active in `us-central1` |
| Firebase Storage bucket | `burnbar-staging.firebasestorage.app` active in `us-central1`; uniform bucket-level access and public-access prevention enforced |
| Firebase Authentication | Identity Platform initialized; only the staging Firebase domains are authorized |
| Registered Firebase apps | Active Web app `OpenBurnBar Windows Staging` |
| Deploy APIs | All APIs required by `deploy-staging.yml` are enabled |
| GitHub staging secrets | WIF provider, deploy service account, and Windows Firebase Web API key are set in the protected `staging` environment |
| GitHub staging variables | Windows App Check app id and `STAGING_ENABLED=true` are set in the protected `staging` environment; the project id override remains a repository variable |
| Rules deployment | Protected dry run `29655721165` passed: rules emulator tests and deploy-config checks succeeded; authentication and deployment were skipped by `dry_run=true` as designed |
| Windows Desktop OAuth | Pending creation of a staging-only Desktop OAuth client in Google Auth Platform |
| Windows App Check | Client TPM/CNG producer exists; the Functions backend still lacks the real TPM verifier and therefore cannot pass live physical attestation |
| Functions runtime config | Template only; no reviewed `functions/.env.burnbar-staging` |

Do not recreate the project, service account, OIDC pool/provider, GitHub
Environment, Firebase resources, or environment secrets. Resume with a
reviewed real rules deployment to staging. Keep Functions deployment disabled
until `functions/.env.burnbar-staging` is reviewed and every provider secret
points to a non-production or sandbox account.

## Why this exists

Historically `.firebaserc` exposed only the production project (`default:
burnbar`), so every Firestore rules / indexes / Storage rules / Cloud Functions
change went straight to real users. The repository now has a `staging` alias and
an isolated cloud project. Its foundation is usable; each remaining live
protocol stays fail-closed until its own evidence passes.

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

The point: **the diff you promote to prod is the diff you already proved in
staging.** Same source files, same pipeline shape, different project + creds.

---

## Finish provisioning (one-time)

You need `gcloud` + `firebase` CLIs authenticated as an owner of the GCP org/
billing account. Estimated time: ~15–20 minutes.

### 1. Create or finish the staging Firebase/GCP project

```bash
# Project id must match .firebaserc `staging` alias (or override via the
# STAGING_FIREBASE_PROJECT repo variable — see step 5).
# Skip project creation when `gcloud projects describe burnbar-staging`
# succeeds. The project already existed in the 2026-07-17 snapshot.
gcloud projects describe burnbar-staging >/dev/null 2>&1 || \
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

# Create the reserved Firebase default bucket through the Firebase Storage API;
# generic `gcloud storage buckets create` cannot claim this namespace.
curl --fail-with-body --silent --show-error \
  -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  --data '{"location":"us-central1"}' \
  "https://firebasestorage.googleapis.com/v1alpha/projects/burnbar-staging/defaultBucket"
gcloud storage buckets update "gs://burnbar-staging.firebasestorage.app" \
  --uniform-bucket-level-access \
  --public-access-prevention
gcloud storage buckets describe "gs://burnbar-staging.firebasestorage.app" \
  --project=burnbar-staging >/dev/null

# Initialize Firebase Authentication/Identity Platform, then register the
# Windows staging Web app. Create a separate Desktop OAuth client in Google Auth
# Platform for the Windows PKCE loopback flow; never reuse the production client.
curl --fail-with-body --silent --show-error \
  -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: burnbar-staging" \
  -H "Content-Type: application/json" \
  --data '{}' \
  "https://identitytoolkit.googleapis.com/v2/projects/burnbar-staging/identityPlatform:initializeAuth"
firebase apps:create WEB "OpenBurnBar Windows Staging" \
  --project=burnbar-staging
```

> If you pick a project id other than `burnbar-staging`, either edit the
> `staging` alias + `burnbar-staging` targets block in `.firebaserc`, **or**
> leave `.firebaserc` as-is and set the `STAGING_FIREBASE_PROJECT` repo variable
> (step 5) — the workflow reads `vars.STAGING_FIREBASE_PROJECT` and only falls
> back to `burnbar-staging`.

### 2. Create or verify the deploy service account (least privilege)

```bash
gcloud iam service-accounts describe \
  burnbar-staging-deployer@burnbar-staging.iam.gserviceaccount.com \
  --project=burnbar-staging >/dev/null 2>&1 || \
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

### 3. Create or verify Workload Identity Federation (no long-lived keys)

Production auths via OIDC WIF only (see `deploy-firestore.yml` /
`deploy-production.yml`). Staging must too — **do not create JSON SA keys.**

```bash
POOL=github-pool
PROVIDER=github-provider
PROJECT_NUMBER="$(gcloud projects describe burnbar-staging --format='value(projectNumber)')"
REPO="Imagine-That-Ai/BurnBar"   # canonical origin owner/repo

gcloud iam workload-identity-pools describe "$POOL" \
  --project=burnbar-staging --location=global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create "$POOL" \
    --project=burnbar-staging --location=global \
    --display-name="GitHub Actions pool"

gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project=burnbar-staging --location=global \
  --workload-identity-pool="$POOL" >/dev/null 2>&1 || \
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

**Environment secrets** (scope: protected `staging` environment):

| Secret | Value |
| --- | --- |
| `STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER` | the provider resource name printed in step 3 |
| `STAGING_GCP_DEPLOY_SERVICE_ACCOUNT` | `burnbar-staging-deployer@burnbar-staging.iam.gserviceaccount.com` |
| `STAGING_SENTRY_DSN_FUNCTIONS` | *(optional)* staging functions Sentry DSN |

**Environment variables** (scope: protected `staging` environment):

| Variable | Value | Effect |
| --- | --- | --- |
| `STAGING_ENABLED` | `true` | **Flips the workflow on.** Until this is `true`, the preflight job reports "not provisioned" and every deploy job is skipped. |

**Repository variable:**

| Variable | Value | Effect |
| --- | --- | --- |
| `STAGING_FIREBASE_PROJECT` | *(optional)* staging project id | Overrides the `burnbar-staging` default if you named the project differently. |

```bash
gh secret set STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER --env staging --repo Imagine-That-Ai/BurnBar
gh secret set STAGING_GCP_DEPLOY_SERVICE_ACCOUNT     --env staging --repo Imagine-That-Ai/BurnBar
gh variable set STAGING_ENABLED --env staging --body true --repo Imagine-That-Ai/BurnBar
```

The GitHub deploy workflow does not launch the Windows app, so do not invent
`STAGING_WINDOWS_*` aliases there. For a physical staging certification session,
set the exact runtime names consumed by `CloudAuthProductionComposition` and
`AppConfiguration` in that native Windows process:

```powershell
$env:OPENBURNBAR_FIREBASE_PROJECT_ID = 'burnbar-staging'
$env:OPENBURNBAR_FIREBASE_WEB_API_KEY = '<OpenBurnBar Windows Staging Web API key>'
$env:OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID = '<staging-only Desktop OAuth client id>'
$env:OPENBURNBAR_APPCHECK_APP_ID = '<OpenBurnBar Windows Staging Web app id>'
```

Keep the OAuth client and Web API key in the approved staging credential store
and inject them only into the authorized test session. Never place them in a
committed `.env` file or reuse production credentials.

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
