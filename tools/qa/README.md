# OpenBurnBar QA tooling

Scripts that prepare a workstation (or a CI runner) to exercise the
auth-required QA flows in `.factory/skills/qa`.

## What lives here

| Script | Purpose |
|--------|---------|
| `provision-qa-firebase.js` | Create or rotate the dedicated Firebase Auth QA account (`qa+local@openburnbar.app`). Generates a shell-safe password, sets `{ qa: true, env: "local" }` custom claims, seals creds into `~/.openburnbar/qa.env` (chmod 0600) + macOS Keychain (`OpenBurnBar.QAFirebase`), and optionally mirrors them to GitHub repo secrets. |
| `inject-app-check-debug-token.sh` | Stamps a stable Firebase App Check debug token into `AgentLens/Resources/GoogleService-Info.plist` and `OpenBurnBarMobile/Resources/GoogleService-Info.plist`, persisting the token in `~/.openburnbar/qa.env` so subsequent runs reuse it. After running, register the token in the Firebase console under **App Check → Apps → Manage debug tokens**. |

Both scripts are idempotent and safe to re-run.

## First-time setup (one developer-laptop bootstrap)

```sh
# 1. Make sure Firebase Admin SDK is available
npm ci --prefix functions

# 2. Make sure Application Default Credentials are configured for project=burnbar
gcloud auth application-default login --quiet

# 3. Stamp the App Check debug token into the local plists.
#    Run this BEFORE building so the token is bundled into the .app/.ipa.
./tools/qa/inject-app-check-debug-token.sh

# 4. Register the token printed by step 3 in the Firebase console:
#    https://console.firebase.google.com/project/burnbar/appcheck/apps
#    → com.openburnbar.app → Manage debug tokens → Add debug token

# 5. Provision the QA Firebase Auth account.
GOOGLE_CLOUD_PROJECT=burnbar node tools/qa/provision-qa-firebase.js --sync-github
```

Step 5 writes the same secrets to:

* `~/.openburnbar/qa.env` (chmod 0600, gitignored — this whole directory is outside the repo)
* macOS Keychain: `service=OpenBurnBar.QAFirebase`, `account=qa+local@openburnbar.app`
* GitHub repo secrets: `QA_FIREBASE_EMAIL`, `QA_FIREBASE_PASSWORD`

## Sourcing the secrets locally

The QA skill (`.factory/skills/qa/SKILL.md`) reads these env variables. To
make them available in a shell:

```sh
set -a; . ~/.openburnbar/qa.env; set +a
```

The file is shell-safe (single-quoted values), so all special characters in
the generated password are preserved.

## Rotating

* App Check debug token — `./tools/qa/inject-app-check-debug-token.sh --rotate`
  (then re-register in the Firebase console).
* QA Firebase password — `node tools/qa/provision-qa-firebase.js --sync-github`
  (always rotates on every run).

## Cleanup / decommission

```sh
# Disable the QA user in Firebase Auth (does not delete it):
gcloud --project=burnbar firebase auth:export -  | jq '.users[] | select(.email=="qa+local@openburnbar.app")'
firebase auth:disable --uid <UID> --project burnbar

# Remove local secrets:
rm -f ~/.openburnbar/qa.env
security delete-generic-password -s OpenBurnBar.QAFirebase -a qa+local@openburnbar.app

# Remove GitHub secrets:
gh secret delete QA_FIREBASE_EMAIL
gh secret delete QA_FIREBASE_PASSWORD
```

## Why a dedicated QA account?

* Keeps QA flows out of the project owner's identity, so a destructive QA
  run never touches real user data.
* Custom claims `{ qa: true, env: "local" }` give server code a clean
  hook for QA-only relaxations if/when needed.
* Owner-scoped Firestore rules (`ownsUserNamespace`) automatically isolate
  the QA user from production users — verified by `qa-results/` runs.
