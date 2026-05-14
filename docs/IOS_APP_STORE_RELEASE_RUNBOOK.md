# iOS App Store Release Runbook

This runbook captures the App Store Connect path for `OpenBurnBarMobile`
(`com.openburnbar.app`). It exists so the next release can be repeated from
repo commands plus a short web-only App Store Connect pass.

## Current App Store Connect Shape

- App: `OpenBurnBar`
- Apple app ID: `6766366964`
- iOS bundle ID: `com.openburnbar.app`
- iOS version: `1.0`
- iOS version state: `WAITING_FOR_REVIEW` as of 2026-05-12 after the build-9
  rejection repair and resubmission
- Linked build: `9`
- Hosted quota subscription product: `com.openburnbar.hostedQuotaSync.cloud.monthly`
- Subscription reference name: `Hosted Quota Sync Monthly`
- Subscription state: `DEVELOPER_ACTION_NEEDED` as of 2026-05-12. Apple's
  subscription validator reports this as a non-blocking warning after the app
  version resubmission; the subscription still has a rejected English
  localization that Apple's public API and web UI do not allow editing while in
  that state.
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
sandbox delivery, Firestore App Check enforcement, branch protection requiring
`openburnbar-pr` plus all CodeQL analysis jobs, the required `openburnbar-pr`
check on `origin/main`, the three CodeQL analysis jobs for the exact
`origin/main` commit, GitHub security settings and open security alerts, the
most recent merged PR gate, production Firebase Functions inventory, Cloud Run,
Redis, and quota-runner readiness. It also requires production App Store Server
Notifications delivery after the app is live. It prints
`WAITING_ON_APPLE`, `READY_FOR_MANUAL_RELEASE`, `READY_FOR_LIVE_PAID_PROOF`, or
`NO_GO` with the evidence that led to the verdict.

To preserve the launch gate JSON for handoff or review, capture it into the
local evidence bundle from a clean, updated `main` checkout:

```bash
scripts/capture-commercial-launch-evidence.mjs
```

The helper writes timestamped JSON plus `latest-commercial-launch-gate.json`
under `launch-evidence/`. That directory is ignored because later proof files
can include Firebase UIDs, App Store transaction IDs, and live notification
readbacks. Running the helper from a feature branch is still useful for capture
testing, but the gate will report `NO_GO` until the branch is merged to
`origin/main`.

Before final submission, the status output must show:

- `iosVersion.state` is `READY_FOR_REVIEW` before final submission.
- `iosVersion.releaseType` is `MANUAL`.
- `linkedBuild.processingState` is `VALID`.
- `linkedBuild.buildAudienceType` is `APP_STORE_ELIGIBLE`.
- `linkedBuild.version` matches the current `OpenBurnBarMobile`
  `CURRENT_PROJECT_VERSION` in `project.yml`.
- `linkedBuild.usesNonExemptEncryption` is `false`.
- `iosVersion.usesIdfa` is `false`; OpenBurnBar does not use the Advertising
  Identifier.
- `appReviewDetail.demoAccountRequired` is `true`.
- `appReviewDetail.demoAccountName` is `app-review@openburnbar.app`.
- `appReviewDetail.hasNotes` is `true`. App Store Connect does not echo the
  demo account password in status readback; `prepare-review-metadata` is the
  write gate for the password.
- Subscription state is `READY_TO_SUBMIT` before final submission.
- Subscription `hasReviewScreenshot` is `true`.

After final submission, the expected readback is:

- `iosVersion.state` is `WAITING_FOR_REVIEW` or another Apple review state.
- `npm --prefix tools/app-store-connect run review-submissions` shows the
  unresolved iOS submission in `WAITING_FOR_REVIEW` with one app-version item
  linked to the current iOS version.
- `asc validate subscriptions --app 6766366964 --pretty` has no blocking
  errors. The first subscription may still report `DEVELOPER_ACTION_NEEDED`
  until Apple processes the resubmitted app review.
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

1. Writes the App Information privacy-policy URL.
2. Writes iOS version metadata, including the Terms of Use and Privacy Policy
   links Apple requires for auto-renewable subscriptions.
3. Sets the linked build's `usesNonExemptEncryption` to `false`.
4. Sets the iOS Advertising Identifier answer to `false`.
5. Sets iOS release mode to `MANUAL`.
6. Writes App Review login credentials and notes, including the exact Hosted
   Quota Sync Monthly paths and the in-app account deletion path.
7. Prints a status readback.

If App Review rejects the build for missing subscription legal metadata,
unclear In-App Purchase discovery, or missing account deletion instructions,
use the explicit alias after shipping the matching app fix:

```bash
set -a
. /tmp/openburnbar-app-review-credentials.txt
set +a

npm --prefix tools/app-store-connect run fix-review-rejection
```

For Guideline 3.1.2(c), the in-app purchase flow must visibly show all five
Apple-required subscription fields before purchase: subscription title, length,
price, services provided during each period, and functional Privacy Policy /
Terms of Use links. The current purchase screen uses the
`cloudStore.subscriptionDisclosure` block for this; do not remove it without a
replacement that keeps those fields grouped together.

For any camera attachment changes, keep `NSCameraUsageDescription` in
`OpenBurnBarMobile/Info.plist` and `project.yml`. iOS terminates the app before
Swift can recover if the Take Photo flow reaches camera APIs without that key.

The corresponding in-app account deletion path is
**You -> Settings -> Account -> Delete account**. Record a physical-device
screen capture of sign-in, navigation to that row, the destructive confirmation,
and return to the signed-out state before replying to App Review.

Attach that recording to the current App Review detail before submission:

```bash
npm --prefix tools/app-store-connect run upload-review-attachment -- \
  /path/to/account-deletion-recording.mov
```

Then rerun `npm --prefix tools/app-store-connect run status` and confirm the
linked build is still the intended build before the web-only submission step.

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

Apple's App Store Connect API supports later subscription review submissions,
but Apple documents that the first auto-renewable subscription must be submitted
with an app binary through `appstoreconnect.apple.com`. For this first
`Hosted Quota Sync Monthly` subscription, do not treat a CLI-only run as
complete until the web UI shows the subscription in the draft review submission.

## Final Submission

`Submit for Review` is the official Apple submission action. Run it only after
an explicit action-time confirmation from the app owner:

```bash
export OPENBURNBAR_SUBMIT_APP_REVIEW="ios:9"
npm --prefix tools/app-store-connect run submit-review
```

The command sets the content-rights declaration, refreshes review metadata,
sets the Advertising Identifier answer, ignores detached draft review
submissions left by failed retries, and submits the linked iOS app version. It
does not keep creating duplicate raw subscription or subscription-group
submissions while the product is still `DEVELOPER_ACTION_NEEDED`; for the first
auto-renewable subscription, finish the subscription selection through App Store
Connect's web UI or an authenticated `asc web review subscriptions attach`
session.

If a web session is available, the CLI-only subscription attach shape is:

```bash
asc web auth login --apple-id "APPLE_ACCOUNT_EMAIL"
asc web review subscriptions attach \
  --app 6766366964 \
  --subscription-id 6768773163 \
  --confirm
```

If a subscription localization is rejected, `repair-subscription-localization`
can add a temporary replacement localization, but Apple may still reject
deleting or editing the original rejected English localization. Clean up any
temporary localization after the attempt:

```bash
npm --prefix tools/app-store-connect run cleanup-temp-subscription-localization
```

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

To capture the proof safely without committing it:

```bash
OPENBURNBAR_PROOF_UID="FIREBASE_UID" \
npm --prefix functions run prove:hosted-quota -- \
  --project burnbar \
  --environment Production \
  --original-transaction-id "APPLE_ORIGINAL_TRANSACTION_ID" \
  --require-backup \
  --require-hosted-quota \
  | scripts/capture-commercial-launch-evidence.mjs --kind paid-proof --input -
```
