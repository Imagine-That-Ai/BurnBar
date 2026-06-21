# Production Deploy Boundaries

Production Firebase deploys are split so Google/Firebase credentials are never
present in a process that can run repository-controlled npm lifecycle, build,
verify, or Firebase `predeploy` code.

## Invariant

- Build before auth. `npm ci`, `npm run build`, website verification, trust-copy
  drift checks, and Firebase CLI installation run before `google-github-actions/auth`.
- CI never deploys with raw `firebase.json`. Deploy jobs use generated
  `firebase-*.ci.json` files from `scripts/ci/write-firebase-hosting-ci-config.mjs`;
  those configs recursively reject `predeploy`.
- No npm after auth. Credentialed deploy steps invoke the prepared
  `FIREBASE_TOOLS_BIN` directly, with `--config` pointing at the generated CI
  config.
- Hosting uses `GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT`. Functions and Firestore keep
  `GCP_DEPLOY_SERVICE_ACCOUNT`. Do not reuse the shared deploy service account
  for Hosting.
- Logs may include artifact/config SHA-256 hashes and the Firebase CLI version.
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
   `node_modules`, verifies `SHA256SUMS`, installs the pinned Firebase CLI with
   `--ignore-scripts` before auth, authenticates as
   `GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT`, then deploys with:
   `FIREBASE_TOOLS_BIN deploy --only hosting --config firebase-hosting.ci.json`.
3. `hosting-smoke-result` has `issues:write` but no `id-token`. It runs the
   public hosting smoke and opens or closes the ops-failure issue.

## Functions And Firestore

`deploy-production.yml` builds Functions, runs deploy-auth verification, writes
`firebase-functions.ci.json`, and prepares the Firebase CLI before auth. The
credentialed step writes runtime env and deploys with the direct Firebase binary
against the generated config. The health gate runs afterward in a separate job
without WIF credentials.

`deploy-firestore.yml` installs dependencies, runs emulator tests, writes
`firebase-firestore.ci.json`, and prepares the Firebase CLI before auth. The
credentialed step deploys indexes with the direct binary and generated config;
rules release and drift readback scripts may use the WIF token but must not call
`npm`, `npx`, Firebase `predeploy`, or local GitHub actions.

## Guardrails

Required checks:

```bash
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
