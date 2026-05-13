# Android Closed Testing Demo Data

BurnBar Android is a companion app: the real production path is Mac/iOS clients
syncing usage, quota, provider account, and project data into Firestore, then
Android reading those owner-scoped documents.

Closed testers may not have macOS hardware. To keep the Play Console closed
test legitimate without sharing fake Google accounts, Android now supports a
seeded demo workspace for each tester's own Google SSO account.

## Tester Workflow

1. Open the Google Play closed-testing opt-in link with the tester Gmail account.
2. Install BurnBar from Play.
3. Sign in with Google SSO in BurnBar.
4. On the empty Pulse or Burn screen, tap **Load demo data**.
5. Verify the seeded Android surfaces:
   - Pulse dashboard totals, forecast, recent sessions, and trend cards.
   - Burn quota rings and provider quota details.
   - Streams sessions, models, and projects.
   - You/settings account state.
6. Keep the app installed and open it during the 14-day closed-test window.

## What Gets Seeded

The callable `seedAndroidDemoAccount` writes only under the authenticated user:

- `users/{uid}/usage/demo_android_*`
- `users/{uid}/usage_rollups/{today,7d,30d,90d,all_time}`
- `users/{uid}/quota_snapshots/demo_android_*`
- `users/{uid}/provider_accounts/demo_android_*`
- `users/{uid}/projects/demo_android_*`

All seeded documents are clearly marked with `demo: true` or a
`demo_android_` document ID prefix. The callable deletes and replaces only
previous demo documents; real usage, quota, provider account, and project
documents remain untouched.

## Why This Is the Right Test Path

- Testers use their own Google accounts, so Firebase Auth/App Check/Firestore
  owner rules are exercised exactly like production.
- No shared credentials are distributed.
- Android screens receive realistic Firestore data shapes that match
  `functions/src/types.ts`, the canonical schema.
- The demo can be reloaded idempotently if a tester needs to reset their sample
  workspace.

## Debajit Instructions

Send testers this concise version:

> Please opt in with the Gmail address you provided, install BurnBar from the
> Play link, sign in with Google, then tap **Load demo data** on the empty Pulse
> or Burn screen. This loads sample sessions and quotas into your own test
> account so you can verify the Android app without a Mac. Please keep the app
> installed and open/check it during the 14-day closed-testing period.
