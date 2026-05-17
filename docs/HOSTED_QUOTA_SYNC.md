# Hosted Quota Sync and BurnBar Pro Cloud Services

This is the reference guide for the iOS/iPadOS quota-provider work and the
BurnBar Pro cloud-services bundle.

The short version: Hosted Quota is not being replaced. BurnBar Pro adds more
premium services on top of it: Hosted Quota, hosted MiniMax-backed Intelligence
Brief answers, encrypted searchable hosted session logs, and hosted Remote MCP
access to that sealed session memory. Existing Hosted Quota users remain
compatible through the legacy entitlement; new bundled premium access uses
`burnbar_pro`.

There is one important compliance distinction:

- **Codex** supports hosted and self-hosted remote quota sync in this codebase.
- **OpenCode** supports local and self-hosted remote quota sync in this
  codebase. Hosted OpenCode credential refresh is intentionally disabled
  because current OpenCode tooling exposes local `opencode stats`, not a stable
  public account quota API.
- **Claude Code** supports self-hosted remote quota sync only. OpenBurnBar does
  not collect Claude Code OAuth/setup tokens for the hosted service.

Those distinctions are intentional. Anthropic's current Claude Code legal
guidance says third-party developers may not offer Claude.ai login or route
Free, Pro, or Max credentials on behalf of users. OpenCode's current public
surface gives OpenBurnBar local cost history, not hosted account quota. A
user-controlled self-hosted runner keeps provider auth in the user's own
environment.

## What This Solves

Before this work, Claude Code and Codex quota was effectively desktop-led. The
Mac app could inspect local provider state and publish quota snapshots to cloud
sync. If the Mac app did not refresh, the mobile app had nothing new to show.

Now mobile has remote paths:

| Provider | Hosted mode | Self-hosted mode | Notes |
|---|---:|---:|---|
| Codex | Yes | Yes | Hosted uses OpenBurnBar's runner and Firebase Secret Manager |
| OpenCode | No | Yes | Self-hosted runner reads local OpenCode CLI stats |
| Claude Code | No | Yes | Hosted OAuth/setup-token collection is intentionally disabled |

Both paths are explicit and on demand. There is no scheduled polling, random
background refresh, hidden scraping, or cookie capture.

## BurnBar Pro Additions

BurnBar Pro supplements Hosted Quota with two additional hosted services:

- **Hosted MiniMax-backed Intelligence Brief answers.** The user can keep using
  their own model for free. If they use the BurnBar-hosted fallback, the
  callable requires active premium entitlement.
- **Encrypted searchable hosted session logs.** The Mac app encrypts session
  bodies, titles, previews, and snippets before upload. Firebase Storage stores
  encrypted bodies, while Firestore stores sealed metadata plus HMAC token
  hashes, keyed semantic hashes, and semantic posting edges. The server can
  keep the index fresh and cheaply jump to semantic candidates without seeing
  plaintext, embeddings, or the vault key; matched content is decrypted only on
  a trusted device or explicitly configured local MCP host.
- **Commit-time blob verification.** Cloud Functions only commits hosted search
  rows after the encrypted Storage object exists, matches the expected
  `application/octet-stream` content type, and has the encrypted byte count and
  path/body-hash shape issued in the upload ticket.
- **Generation-safe index freshness.** Each hosted search commit is stamped
  with an opaque commit ID. The active commit marker is written after the chunk
  and posting batches, and search ignores uncommitted or stale generations.
- **Server-only index writes.** Apps upload hosted search rows through the
  callable validation path. Firestore rules deny direct client writes to
  `cloud_search_*`, while still allowing users to read and delete their own
  mirrored data.
- **Hosted Remote MCP.** BurnBar Pro users can connect coding agents to
  `https://mcp.burnbar.ai/mcp` or use the local `openburnbar-mcp-remote`
  stdio shim. MCP access uses OpenBurnBar-issued short-lived bearer tokens,
  not Firebase ID tokens, and defaults to local device-side decrypt.

The cloud search index is intentionally not a plaintext Firestore transcript
database. It is a premium, encrypted mirror for signed-in users who want their
Mac, iPhone, iPad, Android app, and trusted MCP tools to search the same hosted
session corpus.

## In Practice

### Codex Hosted Mode

1. User opens the iOS/iPadOS app.
2. User adds Codex as a provider.
3. User chooses `Hosted`.
4. User subscribes to BurnBar Pro or the legacy hosted quota sync product.
5. User pastes the contents of `~/.codex/auth.json`, or a base64 encoded copy.
6. Mobile calls Firebase Functions to store the credential securely.
7. When the user taps refresh, Firebase Functions calls the hosted quota runner.
8. The hosted runner asks Codex for quota, normalizes the result, and returns only quota buckets.
9. Firebase writes the sanitized quota snapshot into the user's Firestore data.
10. iOS, iPadOS, and macOS all see the same cloud quota snapshot.

### Claude Code Self-Hosted Mode

1. User runs the `quota-runner` service in their own environment.
2. User configures that runner with Claude Code auth, for example `CLAUDE_CODE_OAUTH_TOKEN`.
3. User adds Claude Code in the mobile app.
4. Mobile shows `Self-hosted runner`; hosted mode is not offered.
5. User enters a runner URL and optional runner secret.
6. Mobile stores the runner URL in `UserDefaults` and the optional secret in Keychain.
7. When the user taps refresh, mobile calls the user's runner directly.
8. The runner returns a sanitized quota snapshot.
9. Mobile uploads that snapshot to Firebase with `uploadProviderQuotaSnapshot`.
10. iOS, iPadOS, and macOS all see the same cloud quota snapshot.

### Codex Self-Hosted Mode

The Codex self-hosted flow is the same as Claude Code self-hosted mode, except
the user's runner needs access to a signed-in `CODEX_HOME` or equivalent Codex
auth JSON in the user's own infrastructure.

### OpenCode Self-Hosted Mode

The OpenCode self-hosted flow is the same as Claude Code self-hosted mode,
except the user's runner needs access to a signed-in OpenCode CLI/data
directory (`~/.local/share/opencode/auth.json`) in the user's own
infrastructure. The runner reads exact 5-hour spend from
`~/.local/share/opencode/opencode.db`, then calls `opencode stats` for 7 and
30 days to normalize estimated 7-day and monthly plan-pressure buckets. If the
SQLite database is unavailable, the runner falls back to the 1-day stats output
for a clearly marked 5-hour warning bucket.

## What It Does Not Do

- It does not scrape Claude or OpenAI websites.
- It does not collect browser cookies.
- It does not bypass provider rate limits or pool quota across different
  provider families.
- It does not run on a timer.
- It does not refresh secretly in the background.
- It does not return raw CLI output to the app.
- It does not expose provider tokens in Firestore.
- It does not collect Claude Code OAuth/setup tokens for OpenBurnBar-hosted refresh.
- It does not use OpenCode auth JSON for OpenBurnBar-hosted quota refresh.
  Users can still add OpenCode Go auth JSON locally as a BurnBar routing
  credential for the `/zen/go/v1` proxy path.

The refresh path is user initiated. The collected output is quota status, not
private conversation content.

## User-Facing Mental Model

Use this wording when explaining it:

> The mobile app can now ask a quota runner to check Claude Code, Codex, or
> OpenCode for you. Codex can use OpenBurnBar hosted sync after subscription,
> or your own self-hosted runner. Claude Code and OpenCode use your own
> self-hosted runner. Either way, you tap refresh when you want fresh quota, and
> the result syncs across iPhone, iPad, and Mac.

## Provider Credential Inputs

### Claude Code

OpenBurnBar-hosted Claude Code credentials are not supported.

Self-hosted options:

- Paste no Claude credential into OpenBurnBar.
- Configure the user's runner environment with `CLAUDE_CODE_OAUTH_TOKEN`.
- Or run the runner in an environment where the Claude CLI is already signed in.
- Keep Claude auth inside the user's own infrastructure.
- Request-body Claude credentials are rejected by the runner; OpenBurnBar never
  forwards Claude Code OAuth/setup tokens.

### Codex

Hosted credential:

```bash
cat ~/.codex/auth.json
```

The user can paste the JSON directly, or paste a base64 encoded version of it.
The runner writes it into a temporary `CODEX_HOME/auth.json`, starts the Codex
app server over stdio, and reads account rate-limit data.

Self-hosted options:

- Mount a signed-in `CODEX_HOME` into the runner.
- Or pass the same auth JSON through the user's own infrastructure.

### OpenCode

OpenBurnBar-hosted OpenCode quota refresh is not supported until OpenCode
exposes a stable public account quota API. Do not ask users to paste
`~/.local/share/opencode/auth.json` into the hosted service. Local BurnBar may
store an OpenCode Go route credential in the user's own macOS Keychain so the
local gateway can proxy OpenCode Go models.

Self-hosted options:

- Run the runner where the OpenCode CLI is already signed in.
- Keep `~/.local/share/opencode/auth.json` inside the user's own
  infrastructure.
- OpenCode quota snapshots include an exact local 5-hour bucket from
  `~/.local/share/opencode/opencode.db` plus estimated 7d/monthly buckets from
  `opencode stats --days 7` and `opencode stats --days 30`.
- If the SQLite database cannot be read, the 5-hour bucket falls back to
  `opencode stats --days 1` and is explicitly marked as a 24-hour fallback.
- Cost-derived estimated buckets should warn rather than hard-block routing.

## Data Flow

### Hosted Refresh

```text
iOS/iPadOS refresh tap
        |
        v
refreshProviderAccountQuota callable
        |
        v
Firebase Auth + App Check + hosted entitlement check
        |
        v
Secret Manager credential read
        |
        v
Hosted quota runner /v1/quota/refresh (codex)
        |
        v
Sanitized ProviderQuotaSnapshot
        |
        v
Firestore users/{uid}/quota_snapshots/{provider}_{account}_{source}
        |
        v
iOS/iPadOS/macOS listeners update
```

### Self-Hosted Refresh

```text
iOS/iPadOS refresh tap
        |
        v
User runner /v1/quota/refresh
        |
        v
Sanitized ProviderQuotaSnapshot
        |
        v
uploadProviderQuotaSnapshot callable
        |
        v
Firestore users/{uid}/quota_snapshots/{provider}_{account}_{source}
        |
        v
iOS/iPadOS/macOS listeners update
```

## Billing

Current product ids:

```text
BurnBar Pro: com.openburnbar.pro.monthly
Legacy Hosted Quota Sync: com.openburnbar.hostedQuotaSync.cloud.monthly
```

Current intended price:

```text
$4.99/month
```

Both entitlement documents are accepted by hosted quota checks during the
compatibility window:

```text
users/{uid}/entitlements/burnbar_pro
users/{uid}/entitlements/hosted_quota_sync
```

`burnbar_pro` additionally advertises the bundled features:

```text
hostedQuota
hostedLLM
encryptedSessionLogBackup
cloudConversationSearch
```

### Server-side Apple JWS verification (v2)

Entitlement state is the result of **full Apple JWS chain verification**, not
a SHA-256 of a client-supplied token.

Trust pipeline (every entitlement write flows through it):

1. **Chain verification.** Cloud Functions decode the JWS using
   `@apple/app-store-server-library` against three vendored Apple root
   certificates pinned by SHA-256 fingerprint:
     - `AppleRootCA-G3.cer` — current EC root
     - `AppleRootCA-G2.cer` — RSA root for cross-signed chains
     - `AppleIncRootCertificate.cer` — legacy chain
   Fingerprints are checked at cold start. Mismatch refuses to start the
   function — see `functions/src/appstore/verifier.ts` (`ROOT_CERT_FILES`).
2. **Bundle / app id assertion.** The decoded JWS payload's `bundleId`
   must match `appStore.bundleId`. Production webhooks must additionally
   match the configured `appAppleId`.
3. **Live reconciliation.** The signed transaction's
   `originalTransactionId` is sent to the App Store Server API
   (`getAllSubscriptionStatuses`). Every JWS in that response is
   re-verified independently. The "winning" transaction is the one
   with the most recent `signedDate` matching the configured product
   id. Apple's view trumps the inbound JWS — a stale client cannot
   resurrect a revoked entitlement. If App Store Connect cannot be
   reached, the reconciliation fails closed and no entitlement write is
   made from the inbound JWS alone.
4. **UID binding via `appAccountToken`.** Before
   `Product.purchase()`, the iOS client calls
   `beginEntitlementBinding`, which mints a fresh UUID and writes
   `users/{uid}/entitlement_bindings/{token}` server-side. The token
   is set on the StoreKit purchase via
   `Product.PurchaseOption.appAccountToken`, so it appears verbatim
   inside the Apple-signed JWS. The reconciler reads
   `payload.appAccountToken`, looks it up in
   `entitlement_bindings`, and writes the entitlement to the
   matching UID. A token replayed under a different UID is rejected
   with `binding_mismatch`.
5. **Idempotent audit.** Every verified event is appended to
   `users/{uid}/entitlement_events/{eventId}` keyed on Apple's
   `notificationUUID` (S2S) or `transactionId.signedDate`
   (client-driven). Duplicates collapse via Firestore `create()` —
   the client-side `ALREADY_EXISTS` is treated as success.
6. **Server-to-server webhook.** A public
   `appStoreServerNotificationsV2` HTTPS endpoint accepts Apple's
   `signedPayload`, runs the same verification + reconciliation, and
   returns 200 only after the audit is appended. Apple retries are
   idempotent on `notificationUUID`.
7. **Daily reconciliation.** A scheduled function
   (`reconcileHostedEntitlementsDaily`) re-pulls
   `getAllSubscriptionStatuses` for every active entitlement so a
   missed webhook still converges within 24 hours.

**Schema versioning.** `HostedQuotaEntitlementDoc.schemaVersion = 2`,
`verificationVersion = 2`, `source = "apple_jws_verified"`. Older docs
written by the legacy SHA-256 path keep their `source` literal so
operators can audit migration progress.

Entitlement document:

```text
users/{uid}/entitlements/hosted_quota_sync
```

Users can read their entitlement. Clients cannot write entitlement documents
directly through Firestore rules. Entitlement writes go through Functions
exclusively (`firestore.rules` denies `write` on this path and on
`entitlement_events`; `entitlement_bindings` is server-only for both reads
and writes).

## Firebase Functions

### New Callable Surface

| Callable / endpoint | Purpose |
|---|---|
| `beginEntitlementBinding` | Mints an `appAccountToken` UUID before `Product.purchase()` so the resulting JWS can be attributed to the signed-in UID |
| `verifyHostedQuotaEntitlement` | Verifies a client-supplied StoreKit JWS against AppleRootCA + reconciles live state via App Store Server API |
| `restoreHostedQuotaEntitlement` | Re-runs live reconciliation for the signed-in user's known `originalTransactionID`; powers "Restore Purchases" |
| `appStoreServerNotificationsV2` (HTTPS) | Public endpoint Apple POSTs S2S notifications to. Verifies `signedPayload`, reconciles, idempotent on `notificationUUID` |
| `reconcileHostedEntitlementsDaily` (scheduled) | Daily reconciliation against ASC for every active entitlement to catch missed webhooks |
| `connectHostedQuotaAccount` | Stores hosted Codex credentials and creates a provider account |
| `connectSelfHostedQuotaAccount` | Creates a local-only/self-hosted Claude Code or Codex provider account |
| `refreshProviderAccountQuota` | Refreshes one account; hosted Codex routes through the hosted runner |
| `refreshProviderQuota` | Refreshes provider accounts where supported |
| `uploadProviderQuotaSnapshot` | Accepts sanitized self-hosted runner snapshots from mobile |
| `deleteHostedQuotaCredentials` | Deletes hosted Codex quota credentials for the signed-in user |

### Required Config

Production Functions v2 use environment params and Secret Manager bindings, not
legacy `functions.config()`. The deployed callable environment must include:

```text
KMS_KEY_NAME
HOSTED_QUOTA_RUNNER_URL
HOSTED_QUOTA_PRODUCT_ID=com.openburnbar.hostedQuotaSync.cloud.monthly
BURNBAR_PRO_PRODUCT_ID=com.openburnbar.pro.monthly
STRIPE_BURNBAR_PRO_PRICE_ID=price_...
GOOGLE_PLAY_PACKAGE_NAME=com.openburnbar
GOOGLE_PLAY_SUBSCRIPTION_PRODUCT_ID=com.openburnbar.pro.monthly
ENCRYPTED_SESSION_BLOB_MAX_BYTES=10485760
HOSTED_QUOTA_DAILY_REFRESH_LIMIT=30
HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT=300
ENFORCE_APP_CHECK=true
APP_STORE_BUNDLE_ID=com.openburnbar.app
APP_STORE_APPLE_APP_ID=6766366964
APP_STORE_ENV=Production
APP_STORE_AUTO_FALLBACK_ENV=true
APP_STORE_ENABLE_ONLINE_CHECKS=true
```

The runner bearer token is a Firebase Secret Manager secret and must be bound
to Functions that call the hosted runner:

```bash
firebase functions:secrets:set HOSTED_QUOTA_RUNNER_TOKEN
```

#### App Store JWS verification config

Apple JWS verification additionally requires:

```bash
# App Store Connect API key (sign in to App Store Connect → Users and Access →
# Keys → In-App Purchase). Provision as Firebase secrets:
firebase functions:secrets:set APP_STORE_ASC_KEY_ID         # e.g. "ABCDEF1234"
firebase functions:secrets:set APP_STORE_ASC_ISSUER_ID      # UUID
firebase functions:secrets:set APP_STORE_ASC_KEY_P8         # paste full PEM body

# Non-secret env params:
export APP_STORE_BUNDLE_ID=com.openburnbar.app
export APP_STORE_APPLE_APP_ID=6766366964                    # numeric appAppleId
export APP_STORE_ENV=Production                             # or Sandbox
export APP_STORE_AUTO_FALLBACK_ENV=true                     # auto-retry prod/sandbox env
export APP_STORE_ENABLE_ONLINE_CHECKS=true                  # OCSP/expiration checks
```

The three secrets are declared in
`functions/src/appstore/config.ts` and bound to every Apple-aware
callable via `APP_STORE_SECRETS`. Cold start re-reads them once per
instance.

The vendored Apple root certificates are checked into
`functions/src/appstore/certs/` and copied into the build output by
`scripts/copy-certs.mjs` (chained from `npm run build`). Each `.cer`
file's SHA-256 fingerprint is pinned in `verifier.ts:ROOT_CERT_FILES`;
swapping a root file without updating the pin fails cold start with
`Apple root certificate fingerprint mismatch …`.

### Important Files

- `functions/src/index.ts`
- `functions/src/quota.ts`
- `functions/src/config.ts`
- `functions/src/types.ts`
- `functions/src/appstore/`
  - `verifier.ts` — `AppleJWSVerifier` (cert pinning, environment
    auto-fallback, stable error codes)
  - `client.ts` — `AppStoreServerAPIClient` wrapper (cached per env)
  - `reconciler.ts` — single-writer entitlement merge, UID binding
  - `audit.ts` — append-only `entitlement_events` log
  - `notifications.ts` — public S2S webhook handler
  - `callable.ts` — three iOS-facing callables
  - `scheduled.ts` — daily reconciliation
  - `certs/` — vendored Apple root certificates
- `functions/scripts/test-appstore.mjs` — node:test regression suite
- `firestore.rules`

## Quota Runner

Runner directory:

```text
quota-runner/
```

Endpoints:

| Endpoint | Method | Purpose |
|---|---|---|
| `/readyz` | `GET` | Production readiness check |
| `/healthz` | `GET` | Local and legacy health check compatibility |
| `/v1/quota/refresh` | `POST` | Refresh Claude Code or Codex quota |

Optional auth:

```text
Authorization: Bearer RUNNER_SHARED_SECRET
```

Binding behavior:

- With `RUNNER_SHARED_SECRET`, the runner binds to `0.0.0.0` by default so it
  can run in Cloud Run or another container host.
- Without `RUNNER_SHARED_SECRET`, the runner binds to `127.0.0.1` by default so
  unauthenticated local development is not exposed on the network.
- Set `RUNNER_HOST` only when you intentionally need a different bind address.

### Deploy Hosted Runner

```bash
gcloud run deploy openburnbar-quota-runner \
  --source quota-runner \
  --region us-central1 \
  --set-secrets RUNNER_SHARED_SECRET=HOSTED_QUOTA_RUNNER_TOKEN:latest \
  --allow-unauthenticated
```

The hosted runner must only be called by Firebase Functions with the shared
secret. Hosted Functions currently permit Codex hosted refresh only.

The Docker image pins the globally installed Codex and Claude Code CLIs through
`OPENAI_CODEX_VERSION` and `ANTHROPIC_CLAUDE_CODE_VERSION` build args. Bump
those deliberately after testing `npm test --prefix quota-runner`; do not let
hosted deploys float to whatever npm publishes next.

### Run Locally

```bash
cd quota-runner
npm ci
RUNNER_SHARED_SECRET=dev-secret npm start
```

Health check:

```bash
curl http://localhost:8080/readyz
```

Self-hosted refresh example:

```bash
export RUNNER_SHARED_SECRET=dev-secret
curl -X POST http://localhost:8080/v1/quota/refresh \
  --oauth2-bearer "$RUNNER_SHARED_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"provider":"claude-code","accountID":"self_hosted"}'
```

## Firestore Writes

Quota snapshots are written here:

```text
users/{uid}/quota_snapshots/{provider}_{accountID}_{sourceId}
```

Provider accounts are written here:

```text
users/{uid}/provider_accounts/{accountID}
```

Hosted entitlement:

```text
users/{uid}/entitlements/hosted_quota_sync
```

Self-hosted upload validation checks that the uploaded snapshot belongs to a
provider account owned by the current Firebase user.

## Mobile App Behavior

Important files:

- `OpenBurnBarMobile/Views/AddProviderConnectionView.swift`
- `OpenBurnBarMobile/Models/ProviderConnectionStore.swift`
- `OpenBurnBarMobile/Models/HostedQuotaSubscriptionStore.swift`
- `OpenBurnBarMobile/Models/SelfHostedQuotaRunnerStore.swift`
- `OpenBurnBarMobile/Services/FunctionsRepository.swift`

Provider-add behavior:

- Codex shows `Hosted` and `Self-hosted`.
- Claude Code shows `Self-hosted runner`.
- All other providers stay on the standard credential flow.

Self-hosted runner URL validation:

- Deployed runners must use `https`.
- Local testing may use `http://localhost` or `http://127.0.0.1`.
- Other plain HTTP URLs are rejected.

## Claude UI Handoff

Claude should polish the UI, not change the data model.

Handoff doc:

```text
docs/CLAUDE_HOSTED_QUOTA_UI_HANDOFF.md
```

Claude-owned polish:

- Make Codex hosted vs self-hosted choice clearer.
- Make Claude Code self-hosted-only state feel intentional, not missing.
- Improve helper text for Codex auth JSON and self-hosted runner setup.
- Make subscription state feel native.
- Improve validation and error copy.
- Preserve the existing provider list and account row layout.

## Verification Commands

Runner:

```bash
npm test --prefix quota-runner
```

Functions:

```bash
npm --prefix functions run build
npm --prefix functions run lint
```

iOS/iPadOS simulator build:

```bash
xcodebuild -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBarMobile \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' \
  -derivedDataPath .derived-data-hosted-quota \
  build
```

Physical iPad build:

```bash
xcodebuild -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBarMobile \
  -destination 'id=00008132-001158191E9A401C' \
  -derivedDataPath .derived-data-hosted-quota-device \
  build
```

Physical iPad tests:

```bash
xcodebuild -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBarMobile \
  -destination 'id=00008132-001158191E9A401C' \
  -derivedDataPath .derived-data-hosted-quota-device \
  test
```

Known local verification note: the physical-device test command can emit
Xcode/CoreDevice diagnostic collection warnings after tests complete. Treat the
process exit code and XCTest results as the gate; diagnostic bundle collection
warnings are not test failures.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Hosted option missing for Claude Code | Expected behavior | Use self-hosted runner for Claude Code |
| Hosted connect says subscription required | StoreKit entitlement is missing or expired | Restore/purchase subscription, then retry entitlement sync |
| Hosted refresh fails before runner call | Firebase config missing runner URL/token/product ID | Set Functions config and redeploy |
| Hosted refresh says credential missing | Secret Manager credential was deleted or never stored | Reconnect the Codex provider account |
| Runner returns unauthorized | Missing or wrong bearer token | Match `RUNNER_SHARED_SECRET` with Functions/mobile runner secret |
| Claude refresh returns no buckets | Token invalid, runner not configured, or Claude CLI output changed | Recreate/configure auth in the self-hosted runner; inspect runner logs |
| Codex refresh returns auth error | Bad `auth.json` or expired Codex session | Re-auth Codex locally and reconnect |
| Self-hosted upload rejected | Account does not belong to current Firebase user | Recreate the self-hosted account from the signed-in mobile app |
| Mobile shows old quota | Refresh was not tapped or Firestore listener has not updated | Pull to refresh or reopen the quota view |

## Safety Checklist Before Release

- StoreKit product exists in App Store Connect.
- Server-side Apple JWS verification is wired with `@apple/app-store-server-library`
  v3 against pinned AppleRootCA-G3/G2/AppleInc roots. The pin SHA-256s in
  `functions/src/appstore/verifier.ts:ROOT_CERT_FILES` match the
  vendored `.cer` files.
- `beginEntitlementBinding`, `verifyHostedQuotaEntitlement`, and
  `restoreHostedQuotaEntitlement` callables are deployed; the
  `appStoreServerNotificationsV2` HTTPS endpoint URL is configured in
  App Store Connect → App → App Information → App Store Server
  Notifications → Production / Sandbox URL.
- `npm --prefix tools/app-store-connect run test-server-notifications -- sandbox`
  reports `delivered: true`. After App Store release,
  `npm --prefix tools/app-store-connect run test-server-notifications -- production`
  must also report `delivered: true`; Apple's production StoreKit API can
  return `401` while the app is still unreleased. `scripts/commercial-launch-gate.mjs`
  enforces sandbox notification delivery now and production notification
  delivery once App Store Connect reports the app as live.
- `reconcileHostedEntitlementsDaily` scheduled job is deployed.
- App Store Connect API secrets (`APP_STORE_ASC_KEY_ID`,
  `APP_STORE_ASC_ISSUER_ID`, `APP_STORE_ASC_KEY_P8`) are populated in
  Secret Manager.
- `npm test` (Functions) passes — covers root cert pinning,
  reconciler selection logic, audit redaction, and binding doc
  construction.
- Hosted runner is deployed with `RUNNER_SHARED_SECRET`.
- Functions config points at the hosted runner.
- Hosted runner abuse caps remain enabled (`30/day`, `300/month` per account by default)
  so the $4.99/month subscription remains profitable under on-demand use.
- Firebase App Check is enforced for callable access.
- Secret deletion callable works.
- Hosted credential values never appear in logs.
- Claude Code hosted OAuth/setup-token collection remains disabled.
- Self-hosted runner secret is stored in Keychain, not plain text.
- Claude Code refresh works through a self-hosted runner.
- Codex hosted refresh works with a fresh `~/.codex/auth.json`.
- Claude UI polish handoff has been completed or explicitly accepted as follow-up.

## Current Truth

The shipped implementation is intentionally hybrid:

- Codex hosted mode is the paid hosted path.
- Claude Code self-hosted mode is the compliant remote path.
- Self-hosted mode is the privacy/control path for both Claude Code and Codex.

## Production Proof Command

After a live buyer completes the StoreKit subscription flow, use the read-only
proof command to verify that the paid entitlement and Firestore evidence exist:

```bash
OPENBURNBAR_PROOF_UID="FIREBASE_UID" \
npm --prefix functions run prove:hosted-quota -- \
  --project burnbar \
  --environment Production \
  --require-backup \
  --require-hosted-quota
```

Use `--original-transaction-id APPLE_ORIGINAL_TRANSACTION_ID` when the operator
captured it from StoreKit or App Store Server API logs. Use only the evidence
flags the proof user actually exercised: `--require-backup` for paid chat /
conversation / session-log backup, and `--require-hosted-quota` for hosted
Codex quota refresh.

To prove the encrypted hosted search index itself, use:

```bash
OPENBURNBAR_PROOF_UID="FIREBASE_UID" \
npm --prefix functions run prove:cloud-search -- --project burnbar
```

That read-only proof checks the active entitlement, encrypted search documents,
search chunks with semantic hashes, semantic posting edges, active vault key
wrappers, and the absence of plaintext-looking fields.

The command fails unless the production user has an active, unexpired premium
entitlement. For new purchases that is
`users/{uid}/entitlements/burnbar_pro` with product
`com.openburnbar.pro.monthly`; legacy hosted quota verification still accepts
`users/{uid}/entitlements/hosted_quota_sync` with product
`com.openburnbar.hostedQuotaSync.cloud.monthly`. The entitlement must be backed
by a matching audit row and have any requested backup/quota evidence.
- Mac app refresh remains useful, but it is no longer required for Claude Code
  and Codex mobile quota updates.
- Refresh is on demand only.
