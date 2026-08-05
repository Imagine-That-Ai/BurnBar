# Staging / pre-prod environment runbook

**Status:** FOUNDATION PROVISIONED; LIVE VALIDATION IN PROGRESS. The isolated
`burnbar-staging` GCP/Firebase project is billing-enabled and now has Firestore,
Firebase Storage, Firebase Authentication, and a Windows staging Web app. The
least-privilege deploy service account, repository-scoped GitHub OIDC provider,
and protected `staging` GitHub Environment remain in place. Rules, indexes,
Storage rules, Desktop OAuth, and the isolated Windows TPM verifier are live.
The scoped App Check Functions deployment, CloudVault exercise, and complete
Windows client protocol remain fail-closed until their evidence passes. Nothing
here touches production (`burnbar`).

## Live provisioning snapshot - 2026-07-26

Read-only inspection produced this fail-closed state:

| Surface                       | Status                                                                                                                                                                                                                         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| GCP project `burnbar-staging` | Active; Firebase APIs are attached                                                                                                                                                                                             |
| Deploy service account        | `burnbar-staging-deployer` exists with all nine documented project roles; secret metadata access is granted only per deployed staging secret                                                                                   |
| GitHub OIDC                   | `github-pool/github-provider` is active and repository-scoped                                                                                                                                                                  |
| GitHub Environment            | `staging` requires review; candidate branches may enter only through the reusable deployment workflow pinned to `main`                                                                                                         |
| Billing                       | Enabled through the approved company billing account                                                                                                                                                                           |
| Firestore database            | Native-mode `(default)` database active in `us-central1`                                                                                                                                                                       |
| Firebase Storage bucket       | `burnbar-staging.firebasestorage.app` active in `us-central1`; uniform bucket-level access and public-access prevention enforced                                                                                               |
| Firebase Authentication       | Identity Platform initialized; only the staging Firebase domains are authorized                                                                                                                                                |
| Registered Firebase apps      | Active Web apps for Windows staging, Linux staging, and the staging marketing site                                                                                                                                             |
| Marketing Hosting             | `burnbar-staging.web.app` is deployed with staging-only Firebase/Auth/App Check identifiers; the trusted candidate-artifact promotion lane verifies exact deployed bytes and adds `X-Robots-Tag: noindex, nofollow, noarchive` |
| Deploy APIs                   | All APIs required by `deploy-staging.yml` are enabled                                                                                                                                                                          |
| GitHub staging secrets        | WIF provider, deploy service account, and Windows Firebase Web API key are set in the protected `staging` environment                                                                                                          |
| GitHub staging variables      | Windows App Check app id and `STAGING_ENABLED=true` are set in the protected `staging` environment; the project id override remains a repository variable                                                                      |
| Rules deployment              | Protected live run `29670689658` passed rules emulator tests, deployed Firestore/indexes/Storage rules, passed drift checks, and verified every declared TTL policy                                                            |
| Windows Desktop OAuth         | Staging-only Desktop client active in Google Auth Platform External/Testing; the approved test user is configured                                                                                                              |
| Windows App Check             | TPM/CNG client and Functions mint path exist; the isolated Azure `NCryptVerifyClaim` service is live and fail-closed; end-to-end hardware mint remains pending                                                                 |
| Functions runtime config      | Reviewed `functions/.env.burnbar-staging` contains public staging identifiers and fail-closed empty provider mappings; secrets remain in Secret Manager                                                                        |

Do not recreate the project, service account, OIDC pool/provider, GitHub
Environment, Firebase resources, or environment secrets. Deploy only explicit
Functions targets until each target's Secret Manager dependencies point to a
non-production or sandbox account. An empty `function_targets` input still means
"all Functions" and therefore requires the complete staging secret inventory.

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
2. **staging** — run `Build Staging Candidate` (`deploy-staging.yml`) to rehearse
   the _exact_ rules, optional marketing Hosting, and optional scoped Functions
   artifacts against `burnbar-staging`. Rules emulator tests, post-deploy drift,
   and any selected live website verification must be green.
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
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment,attribute.job_workflow_ref=assertion.job_workflow_ref" \
    --attribute-condition="assertion.repository=='${REPO}' && assertion.environment=='staging' && assertion.job_workflow_ref=='${REPO}/.github/workflows/deploy-staging-trusted.yml@refs/heads/main'"

# Converge existing providers too. The caller's `ref` may be a reviewed feature
# branch, so cloud trust binds to `job_workflow_ref`: the called reusable
# workflow definition must be the exact file on trusted `main`.
gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
  --project=burnbar-staging --location=global \
  --workload-identity-pool="$POOL" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment,attribute.job_workflow_ref=assertion.job_workflow_ref" \
  --attribute-condition="assertion.repository=='${REPO}' && assertion.environment=='staging' && assertion.job_workflow_ref=='${REPO}/.github/workflows/deploy-staging-trusted.yml@refs/heads/main'"

# The repository principal set is safe only because the provider above enforces
# the exact environment, ref, and workflow before issuing any federated identity.
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project=burnbar-staging \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

# The provider resource name is the STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER secret:
echo "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
```

### 4. Create the `staging` GitHub Environment

`Settings → Environments → New environment → staging`.

- Add yourself as a **required reviewer** (matches production's approval gate).
- Optionally restrict deployment branches to `main`.

### 5. Set the staging secrets + variables

**Environment secrets** (scope: protected `staging` environment):

| Secret                                   | Value                                                              |
| ---------------------------------------- | ------------------------------------------------------------------ |
| `STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER` | the provider resource name printed in step 3                       |
| `STAGING_GCP_DEPLOY_SERVICE_ACCOUNT`     | `burnbar-staging-deployer@burnbar-staging.iam.gserviceaccount.com` |
| `STAGING_SENTRY_DSN_FUNCTIONS`           | _(optional)_ staging functions Sentry DSN                          |

**Environment variables** (scope: protected `staging` environment):

| Variable          | Value  | Effect                                                                                                                        |
| ----------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `STAGING_ENABLED` | `true` | **Flips the workflow on.** Until this is `true`, the preflight job reports "not provisioned" and every deploy job is skipped. |

**Repository variables:**

| Variable                              | Value                                    | Effect                                                                                                 |
| ------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `STAGING_FIREBASE_PROJECT`            | _(optional)_ staging project id          | Overrides the `burnbar-staging` default if you named the project differently.                          |
| `STAGING_FIREBASE_PUBLIC_CONFIG_JSON` | Firebase web SDK config JSON for staging | Supplies public Auth and App Check identifiers to credential-free candidate builds and trusted checks. |

```bash
gh secret set STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER --env staging --repo Imagine-That-Ai/BurnBar
gh secret set STAGING_GCP_DEPLOY_SERVICE_ACCOUNT     --env staging --repo Imagine-That-Ai/BurnBar
gh variable set STAGING_ENABLED --env staging --body true --repo Imagine-That-Ai/BurnBar
firebase apps:sdkconfig WEB 1:1079930549647:web:85beff426331ab42e407fa \
  --project burnbar-staging \
  | gh variable set STAGING_FIREBASE_PUBLIC_CONFIG_JSON \
      --repo Imagine-That-Ai/BurnBar
```

The Firebase web SDK config and reCAPTCHA Enterprise site key are public client
identifiers, but keeping them in a repository variable avoids secret-shaped
literals in Git history while preserving credential-free candidate builds.

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
Manager (Stripe TEST secret key, APNs key, etc.) exactly as you did for prod;
they are never stored in the committed `.env`. Grant the deploy service account
secret metadata access and the Gen 2 runtime service account payload access only
for the exact secret each selected Function declares. For example:

The committed staging runtime config keeps `HOT_MIN_INSTANCES=0`; staging
rehearses the same handlers without paying for production's always-warm
revenue/control pool.

The Stripe and Google Play exports currently share one compiled module. Firebase
therefore requires an `AMPLITUDE_API_KEY` Secret Manager version to exist while
analyzing a scoped Stripe deploy even though the three Stripe handlers do not
bind that secret. To keep staging analytics disabled, create a staging-only
whitespace sentinel (the analytics loader trims it to empty); do not copy the
production Amplitude key:

```bash
gcloud secrets create AMPLITUDE_API_KEY \
  --project=burnbar-staging \
  --replication-policy=automatic
printf ' ' | gcloud secrets versions add AMPLITUDE_API_KEY \
  --project=burnbar-staging \
  --data-file=-
```

```bash
PROJECT_NUMBER="$(gcloud projects describe burnbar-staging --format='value(projectNumber)')"

gcloud secrets add-iam-policy-binding WINDOWS_TPM_VERIFIER_TOKEN \
  --project=burnbar-staging \
  --member='serviceAccount:burnbar-staging-deployer@burnbar-staging.iam.gserviceaccount.com' \
  --role='roles/secretmanager.viewer'

gcloud secrets add-iam-policy-binding WINDOWS_TPM_VERIFIER_TOKEN \
  --project=burnbar-staging \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role='roles/secretmanager.secretAccessor'
```

### 7. First deploy (rules/indexes/storage), then Hosting and Functions

```bash
# Dry run first (default): rules emulator tests + bounded artifact builds, no deploy.
gh workflow run deploy-staging.yml --repo Imagine-That-Ai/BurnBar \
  --ref "$FEATURE_BRANCH" -f dry_run=true

# Real rules/indexes/storage rehearsal from the feature branch. Candidate code
# receives no credentials; the deploy job is defined by the reusable workflow
# pinned to main and consumes the artifact only as bounded data.
gh workflow run deploy-staging.yml --repo Imagine-That-Ai/BurnBar \
  --ref "$FEATURE_BRANCH" -f dry_run=false

# Deploy the reviewed staging marketing build. The candidate artifact is built
# with the burnbar-staging Firebase/Auth/App Check identifiers. Trusted main
# first requires exactly the four reviewed marketing rewrite Functions to be
# ACTIVE, grants allUsers only roles/run.invoker on their resolved Cloud Run
# services, deploys only hosting:marketing, then compares the live
# Firebase-bearing assets byte-for-byte with the reviewed artifact and verifies
# CSP + noindex headers. On the first run, deploy the four rewrite targets in
# the same invocation:
gh workflow run deploy-staging.yml --repo Imagine-That-Ai/BurnBar \
  --ref "$FEATURE_BRANCH" \
  -f dry_run=false \
  -f deploy_hosting=true \
  -f deploy_functions=true \
  -f function_targets='functions:burnBarHermesGateway,functions:latestRouterRundown,functions:startCliLink,functions:pollCliLink'

# Deploy only the reviewed Windows App Check bootstrap targets. The selector is
# validated as a comma-separated functions:<exportName> allowlist before auth.
# When deploy_functions=true and function_targets is blank, the candidate is
# scoped to every reviewed target in functions/staging-deploy-targets.json;
# blank never falls back to the full production Functions export graph.
gh workflow run deploy-staging.yml --repo Imagine-That-Ai/BurnBar \
  --ref "$FEATURE_BRANCH" \
  -f dry_run=false \
  -f deploy_functions=true \
  -f function_targets='functions:issueWindowsAppCheckChallenge,functions:mintWindowsAppCheckToken'

# Deliberately deploy every Function only after every staging secret exists:
gh workflow run deploy-staging.yml --repo Imagine-That-Ai/BurnBar \
  --ref "$FEATURE_BRANCH" \
  -f dry_run=false -f deploy_functions=true -f function_targets=''
```

Approve the `staging` environment when prompted. Confirm the run's summary shows
the rules emulator tests, post-deploy drift check, live TTL verification, and
any selected exact website deployment verification green.

### 8. Exercise the complete Stripe test lifecycle

After the three Stripe Functions and the staging test-mode webhook are deployed,
run the guarded lifecycle proof from an authenticated operator workstation:

```bash
CANDIDATE_SHA="$(git rev-parse HEAD)"
node scripts/e2e/staging-stripe-lifecycle.mjs \
  --confirm burnbar-staging-commercial-lifecycle \
  --expected-sha "$CANDIDATE_SHA"
```

The runner refuses every project/account except `burnbar-staging` and
`acct_1REg6cCFamvUJU7y`. Before any mutation it refuses a dirty checkout and
requires the Checkout, Portal, and Webhook Functions to be ACTIVE with
`OPENBURNBAR_SOURCE_COMMIT` and `FUNCTION_VERSION` matching the full
`--expected-sha`. It temporarily enables anonymous sign-in for one synthetic
staging user while keeping App Check enforcement on, registers a short-lived
App Check debug token, and then verifies:

1. the deployed checkout callable creates a test-mode subscription Checkout
   Session for exactly USD $7.99 with the `cloud` / `monthly` /
   `burnbar_pro` metadata contract;
2. Stripe completes payment with its test card path;
3. the registered remote webhook records a processed event and writes an active
   `burnbar_pro` Firestore entitlement;
4. the deployed portal callable creates a billing-portal session;
5. cancellation is scheduled at period end, the matching
   `customer.subscription.updated` webhook is processed, and the paid-through
   entitlement remains active with that event as its source;
6. a full refund is delivered, writes a durable
   `stripe_payment_reversals/{subscriptionID}` marker, and immediately makes
   the entitlement inactive with `rawStatus: active:payment_reversed`;
7. only after the reversal is proven, the subscription is deleted as cleanup
   and the terminal cancellation webhook keeps the entitlement inactive; and
8. the synthetic Auth user, App Check debug token, Stripe customer, and
   Firestore customer/user records are deleted, with the original anonymous
   sign-in setting restored in `finally`.

On success the runner writes a private (`0700` directory / `0600` files),
digest-sealed result under `launch-evidence/`. The record binds every tested
Function revision and the lifecycle result to the exact candidate SHA and Git
tree while hashing Stripe object/event identifiers instead of persisting them
in plaintext. `launch-evidence/` remains gitignored.

The runner uses Stripe **test mode only** and requires the already paired
`openburnbar` Stripe CLI profile. A failed assertion still runs the reversible
cleanup path; inspect and clean any reported provider artifact before retrying.

---

## How to rehearse a rules change (the core use case)

1. Edit `firestore.rules` (and/or `firestore.indexes.json` / `storage.rules`) on
   a branch.
2. `npm --prefix functions run test:firestore-rules` locally against the emulator.
3. Push the branch, then dispatch `deploy-staging.yml` at that exact branch with
   `dry_run=false`. The branch builds and tests bounded artifacts without
   credentials. `deploy-staging-trusted.yml@main` verifies those artifacts,
   obtains WIF credentials, deploys them to **staging**, drift-checks the live
   project, and verifies every declared `ttl:true` override.
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
- **WIF/OIDC only:** no long-lived JSON keys. Cloud trust requires the protected
  `staging` environment and the `job_workflow_ref` claim for
  `deploy-staging-trusted.yml@refs/heads/main`; a candidate cannot replace the
  credentialed job definition.
- **Predeploy stripped:** trusted main generates rules, Hosting, and Functions
  configs without `predeploy` hooks and rechecks every generated Firebase config
  before authentication, so candidate-controlled lifecycle code never runs
  under staging deploy credentials.
- **Environment-gated:** the `staging` GitHub Environment provides an approval
  gate. Its deployment branch policy must allow reviewed rehearsal branches;
  reusable-workflow identity, not the caller ref, is the immutable code boundary.
- **Candidate code stays uncredentialed:** candidate jobs run tests/builds,
  validate explicit function targets, and upload short-lived bounded artifacts.
  The trusted workflow verifies path, size, file count, SHA-256, and
  candidate-SHA bindings before authentication, deploys only
  `hosting:marketing`, and installs Functions production dependencies with npm
  lifecycle scripts disabled. Scoped Functions artifacts include the reviewed,
  locked `functions/vendor/openburnbar/*` packages required by their
  `file:` dependencies. Their deployment-only `package.json` has every npm
  script removed before upload, so Cloud Build cannot execute repo-only
  `postinstall`, build, test, or release hooks.
- **Exact website receipt:** after Hosting deploy, the trusted workflow retries
  through CDN propagation, verifies `/subscribe` security/noindex headers, and
  requires every Firebase-bearing asset to match the reviewed candidate's
  SHA-256 exactly. It also probes the router rundown, CLI link start/poll, and
  Hermes Gateway rewrites through the staging Hosting origin and requires their
  expected application statuses (404, 400, 400, and 404 respectively).
- **No dangling rewrites:** Hosting promotion fails unless every Function named
  by a marketing rewrite is already ACTIVE in staging (or is deployed earlier
  in the same trusted run). The trusted workflow rejects any rewrite outside the
  four reviewed Functions and grants public invocation only as
  `allUsers -> roles/run.invoker` on their resolved Cloud Run services.
- **Isolated blast radius:** every credentialed step targets the staging project
  via `--project`; production (`burnbar`) is never referenced by this workflow.

## Teardown

To pause staging deploys without deleting anything: set `STAGING_ENABLED=false`
(or delete the variable). To decommission: `gcloud projects delete
burnbar-staging` and remove the `staging` environment/secrets.
