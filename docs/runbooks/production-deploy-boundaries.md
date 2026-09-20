# Production Deploy Boundaries

Production Firebase deploys are split so Google/Firebase credentials are never
present in a process that can run repository-controlled npm lifecycle, build,
verify, or Firebase `predeploy` code.

## Invariant

- Build before auth. `npm ci`, `npm run build`, website verification, and
  trust-copy drift checks run before `google-github-actions/auth`.
- CI never deploys with raw `firebase.json`. Deploy jobs use generated
  `firebase-*.ci.json` files from `scripts/ci/write-firebase-hosting-ci-config.mjs`;
  those configs recursively reject `predeploy`.
- No npm after auth. Credentialed deploy steps invoke only artifact-bundled
  deploy drivers with `--config` pointing at the generated CI config.
- Hosting uses `GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT`. Functions and Firestore keep
  `GCP_DEPLOY_SERVICE_ACCOUNT`. Do not reuse the shared deploy service account
  for Hosting.
- Logs may include artifact/config SHA-256 hashes and deploy driver summaries.
  Do not print tokens, credential file paths beyond presence checks, `.env`
  contents, or service-account JSON.

## Hosting Flow

`deploy-hosting.yml` has three jobs:

1. `build-hosting-artifacts` has `contents:read` only. It builds `website/dist`
   and `apps/console/out`, generates `firebase-hosting.ci.json`, writes
   `SHA256SUMS`, and uploads an artifact named for `github.sha`.
2. `deploy-hosting` has production environment access and `id-token:write`. It
   does not check out the repository. It downloads the artifact, rejects
   symlinks, hardlinks, special files, `.env`, credential-looking paths, and
   `node_modules`, verifies `SHA256SUMS`, authenticates as
   `GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT`, requests an ephemeral WIF access token,
   then deploys with the artifact-bundled REST driver:
   `node scripts/ci/deploy-firebase-hosting-rest.mjs --config firebase-hosting.ci.json --firebaserc .firebaserc`.
3. `hosting-smoke-result` has `issues:write` but no `id-token`. It runs the
   public hosting smoke and opens or closes the ops-failure issue.

## Functions And Firestore

`deploy-production.yml` builds Functions, runs deploy-auth verification, writes
`firebase-functions.ci.json`, and prepares the Firebase CLI before auth. The
credentialed step writes runtime env and deploys with the direct Firebase binary
against the generated config. The health gate runs afterward in a separate job
without WIF credentials.

### Nightly health scoreboard

`nightly-health.yml` publishes exactly six stable scheduled lanes:
`openburnbar-pr-harness`, `app-pr-gate`, `nightly-e2e`, `codeql`,
`linux-nightly`, and `codex-nightly-ci-repair`. It reads workflow runs,
run-scoped jobs, and Checks API metadata for `main`; missing runs, missing
identity, runs older than 24 hours, skipped/incomplete/unknown jobs, and API
errors are red infrastructure rather than implicit green. The DAST sandbox and deploy
observer remain separate scoreboards.

- The JSON/Markdown report is uploaded as a run artifact and appended to the
  workflow summary.
- A red or unavailable report exits non-zero, opens/updates the
  `nightly-health` issue, and closes that issue only after a fully green run.
- `failureClass: infra` identifies evidence/API/prerequisite failures;
  `failureClass: budget` identifies a completed lane's product or budget
  failure. The shared ops action pages eligible P0 issues once, then re-pages
  only after `paged:ops` at seven days.

### Scheduled lane-health exit paths

`deploy-lane-health.yml` is a scheduled/manual, observation-only workflow. It
checks the latest non-dry-run `deploy-production.yml` run and probes
`healthReady` plus `healthLive`; it never dispatches a deploy, changes traffic,
or retries a tag. The generated `deploy-lane-health.json` artifact is the
machine-readable scoreboard.

- **Green:** both the latest deploy and both public probes are successful.
- **Red or unavailable:** the workflow exits non-zero, records a
  `deploy-health` issue, and pages through the shared ops action when the
  configured webhook is available. A missing deploy run, skipped/cancelled run,
  API error, or failed probe is an explicit infrastructure blocker, not a
  green/no-op result. A failed deploy conclusion remains a product/deploy
  failure and is not relabeled as a healthy probe.
- **Human queue exit:** the release owner assigns the issue, records the
  blocker, owner, and expiry in the issue, and chooses either an approved
  main-only `existing_tag_retry` or the documented rollback path. Do not rerun
  an old tag workflow or mark the issue resolved until deploy and readback
  evidence are green.

`deploy-firestore.yml` installs dependencies, runs emulator tests, writes
`firebase-firestore.ci.json`, and prepares the Firebase CLI before auth. The
credentialed step deploys indexes with the direct binary and generated config;
rules release and drift readback scripts may use the WIF token but must not call
`npm`, `npx`, Firebase `predeploy`, or local GitHub actions.

## Guardrails

Required checks:

```bash
node scripts/ci/deploy-firebase-hosting-rest.test.mjs
node scripts/ci/verify-hosting-deploy-boundary.test.mjs
bash scripts/ci/verify-production-deploy-auth.test.sh
bash scripts/ci/verify-production-deploy-auth.sh
bash scripts/ci/verify-codeowners-security-trees.sh
node scripts/ci/write-firebase-hosting-ci-config.mjs --mode hosting --output /tmp/firebase-hosting.ci.json --manifest /tmp/firebase-hosting-public-dirs.json --check
```

The PR security workflow runs the first two commands on `pull_request`,
`merge_group`, and `push` to `main`.

## Rollback

Rollback a bad Hosting release through Firebase Hosting release history or:

```bash
firebase hosting:rollback --project burnbar --site burnbar
firebase hosting:rollback --project burnbar --site burnbar-console
```

Do not roll back by re-enabling raw `firebase.json` predeploy hooks, shared
hosting credentials, `FIREBASE_TOKEN`, service-account JSON, or source rollback
that rebuilds under production Google credentials.

## IAM

Provision `GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT` as a Firebase Hosting deployer for
`burnbar` and `burnbar-console` only, with minimal service-usage read. It must
not have Cloud Functions Admin, Firestore Admin, Secret Manager, Service Account
User/Token Creator, Editor, or Owner.
