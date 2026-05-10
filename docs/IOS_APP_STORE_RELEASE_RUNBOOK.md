# iOS App Store Release Runbook

This runbook captures the App Store Connect path for `OpenBurnBarMobile`
(`com.openburnbar.app`). It exists so the next release can be repeated from
repo commands plus a short web-only App Store Connect pass.

## Current App Store Connect Shape

- App: `OpenBurnBar`
- Apple app ID: `6766366964`
- iOS bundle ID: `com.openburnbar.app`
- iOS version: `1.0`
- iOS version state: `WAITING_FOR_REVIEW` as of 2026-05-09
- Linked build: `6`
- Hosted quota subscription product: `com.openburnbar.hostedQuotaSync.monthly`
- Subscription reference name: `Hosted Quota Sync Monthly`
- Subscription state: `WAITING_FOR_REVIEW` as of 2026-05-09
- App Store Server Notifications V2 URL:
  `https://us-central1-burnbar.cloudfunctions.net/appStoreServerNotificationsV2`

The iOS app is a companion app. It needs sign-in and cloud data to be useful.
For review, use the seeded Firebase review account and seeded Firestore usage,
quota, provider-account, device, and rollup data.

## ASC Helper Setup

The App Store Connect helper reads API credentials from environment variables.
For local operator runs, pull them from Firebase Secret Manager:

```bash
export APP_STORE_ASC_KEY_ID="$(firebase functions:secrets:access APP_STORE_ASC_KEY_ID --project burnbar)"
export APP_STORE_ASC_ISSUER_ID="$(firebase functions:secrets:access APP_STORE_ASC_ISSUER_ID --project burnbar)"
export APP_STORE_ASC_KEY_P8="$(firebase functions:secrets:access APP_STORE_ASC_KEY_P8 --project burnbar)"
```

Status readback:

```bash
npm --prefix tools/app-store-connect run status
```

App Store Server Notifications test readback:

```bash
npm --prefix tools/app-store-connect run test-server-notifications -- sandbox
```

Run the sandbox test before launch to prove the webhook accepts Apple's V2
`TEST` notification. After the app is released to the App Store, rerun with
`production`; Apple can return `401` for production App Store Server API calls
while an app is still unreleased.

Full commercial launch gate:

```bash
scripts/commercial-launch-gate.mjs
```

The gate reads live App Store Connect state, App Store Server Notifications
sandbox delivery, branch protection requiring `openburnbar-pr` plus all CodeQL
analysis jobs, the required `openburnbar-pr` check on `origin/main`, the three
CodeQL analysis jobs for the exact `origin/main` commit, GitHub security
settings and open security alerts, the most recent merged PR gate, production
Firebase Functions inventory, Cloud Run, Redis, and quota-runner readiness. It
also requires production App Store Server Notifications delivery after the app
is live. It prints
`WAITING_ON_APPLE`, `READY_FOR_MANUAL_RELEASE`, `READY_FOR_LIVE_PAID_PROOF`, or
`NO_GO` with the evidence that led to the verdict.

Before final submission, the status output must show:

- `iosVersion.state` is `READY_FOR_REVIEW` before final submission.
- `iosVersion.releaseType` is `MANUAL`.
- `linkedBuild.processingState` is `VALID`.
- `linkedBuild.buildAudienceType` is `APP_STORE_ELIGIBLE`.
- `linkedBuild.usesNonExemptEncryption` is `false`.
- `appReviewDetail.demoAccountRequired` is `true`.
- `appReviewDetail.demoAccountName` is `app-review@openburnbar.app`.
- `appReviewDetail.hasNotes` is `true`. App Store Connect does not echo the
  demo account password in status readback; `prepare-review-metadata` is the
  write gate for the password.
- Subscription state is `READY_TO_SUBMIT` before final submission.
- Subscription `hasReviewScreenshot` is `true`.

After final submission, the expected readback is:

- `iosVersion.state` is `WAITING_FOR_REVIEW` or another Apple review state.
- Subscription state is `WAITING_FOR_REVIEW` or another Apple review state.
- `iosVersion.releaseType` remains `MANUAL` so approval does not publish to
  customers automatically.

## Review Account

Seed the review account with:

```bash
OPENBURNBAR_REVIEW_EMAIL="app-review@openburnbar.app" \
OPENBURNBAR_REVIEW_PASSWORD="REDACTED_LOCAL_PASSWORD" \
node tools/app-store-connect/seed-review-account.js
```

Do not commit the password. Store the local copy outside the repo, for example
`/tmp/openburnbar-app-review-credentials.txt` with mode `0600`.

The seed script creates or updates the Firebase Auth user, verifies the email,
and seeds representative Firestore data:

- two devices (`Review MacBook Pro`, `Review iPad Pro`)
- Codex hosted quota account
- Claude Code self-hosted runner account
- OpenAI usage API account
- quota snapshots, usage rows, rollups, and sync status

Firebase Email/Password sign-in must stay enabled for App Review unless the
review account is moved to another supported sign-in method.

## Build Compliance And Review Metadata

The source plist contains:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

For the already-uploaded build, also patch and verify App Store Connect:

```bash
set -a
. /tmp/openburnbar-app-review-credentials.txt
set +a

npm --prefix tools/app-store-connect run prepare-review-metadata
```

That command:

1. Sets the linked build's `usesNonExemptEncryption` to `false`.
2. Sets iOS release mode to `MANUAL`.
3. Writes App Review login credentials and notes.
4. Prints a status readback.

## Web-Only App Store Connect Gates

Some gates are still safest in App Store Connect's web UI:

1. Open the iOS version page.
2. Confirm the build row no longer says `Missing Compliance`.
3. In **In-App Purchases and Subscriptions**, select
   `Hosted Quota Sync Monthly`.
4. In **App Information -> Content Rights**, choose:
   `No, it does not contain, show, or access third-party content`.
5. Confirm **App Store Version Release** is set to manual release.
6. Click **Add for Review**.
7. Confirm the draft drawer shows `Item Ready to Submit` for iOS app `1.0`.
8. Stop before **Submit for Review** unless the operator explicitly confirms
   the official Apple submission.

## Final Submission

`Submit for Review` is the official Apple submission action. Click it only
after an explicit action-time confirmation from the app owner.

After submission, rerun:

```bash
npm --prefix tools/app-store-connect run status
```

Expected state should move from `READY_FOR_REVIEW` to a review state such as
`WAITING_FOR_REVIEW`. Because release type is `MANUAL`, approval should not
automatically publish the app to customers.

## Manual Release After Approval

Apple's App Store Connect API exposes manual release through
`POST /v1/appStoreVersionReleaseRequests`, but only after review approval moves
the version to `PENDING_DEVELOPER_RELEASE`. Apple documents that this request
cannot be cancelled, so the repo helper refuses to run unless both conditions
are true:

- `iosVersion.state` is `PENDING_DEVELOPER_RELEASE`.
- `OPENBURNBAR_RELEASE_APPROVED_IOS` exactly matches
  `VERSION_STRING:APP_STORE_VERSION_ID`.

After App Store Connect shows approval, rerun status:

```bash
npm --prefix tools/app-store-connect run status
```

If status shows `PENDING_DEVELOPER_RELEASE`, publish with:

```bash
OPENBURNBAR_RELEASE_APPROVED_IOS="1.0:5bd7a32b-29ee-476a-8efa-ec0a9614ff6d" \
npm --prefix tools/app-store-connect run release-approved-ios
```

Immediately rerun status and then continue to the live paid proof below. Do not
run this command before the paid-proof operator is ready; the release request is
the real customer-facing publish action.

Then prove the production App Store Server Notifications URL:

```bash
npm --prefix tools/app-store-connect run test-server-notifications -- production
```

The command must report `delivered: true` for `Production` before the paid path
is called production-proven. If production still returns `401`, stop and verify
the bundle ID, App Store Server API key, and Apple release propagation before
testing paid users.

## Post-Approval Live Paid Proof

Do not call the paid path production-proven until a real StoreKit purchase has
created a server entitlement and unlocked paid Firestore backup for the buyer.
After Apple approves the app and the manual release is complete:

1. Install the App Store build, sign in with the paid-test Firebase user, and
   buy `Hosted Quota Sync Monthly` through StoreKit.
2. In the app, complete at least one paid backup action:
   - enable backed-up chat/session content, or
   - connect hosted Codex quota sync and run one hosted refresh.
3. Capture the Firebase UID. If available, also capture the StoreKit
   `originalTransactionID`.
4. Run the read-only production proof:

```bash
OPENBURNBAR_PROOF_UID="FIREBASE_UID" \
npm --prefix functions run prove:hosted-quota -- \
  --project burnbar \
  --environment Production \
  --original-transaction-id "APPLE_ORIGINAL_TRANSACTION_ID" \
  --require-backup \
  --require-hosted-quota
```

If the proof user only exercised paid backup content, omit
`--require-hosted-quota`. If the proof user only exercised hosted Codex quota,
omit `--require-backup`.

The command must print JSON with `ok: true`, the
`users/{uid}/entitlements/hosted_quota_sync` path, a matching
`entitlement_events` audit row, and the requested backup/quota evidence paths.
Attach that JSON to the launch evidence bundle. A green App Store status alone
is not enough.
