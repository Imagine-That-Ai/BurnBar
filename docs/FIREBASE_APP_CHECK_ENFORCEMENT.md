# Firebase App Check enforcement for Cloud Firestore

OpenBurnBar ships the **Firebase App Check** SDK and installs a provider **before** Firebase is configured (see `OpenBurnBarMobile/App/AppDelegate.swift`, `AgentLens/App/AgentLensApp.swift`, and Android `BurnBarApplication`). That alone does **not** protect Firestore: you must **enforce** App Check for **Cloud Firestore** in the Firebase project used by your Firebase config file.

Without enforcement, a caller who obtains a **valid Firebase Auth ID token** (e.g. from another signed-in context) can still use the Firestore API against your project, because your [firestore.rules](../firestore.rules) express **authentication, owner scoping, client-write limits, and server-only private paths**—not app attestation.

**Primary control:** [Enable App Check enforcement](https://firebase.google.com/docs/app-check/enable-enforcement) for **Cloud Firestore** in the Firebase console. The Firestore service then rejects traffic that is not accompanied by a valid App Check attestation, before (or in addition to) your security rules.

**Request metrics (before you enforce):** [Monitor App Check request metrics](https://firebase.google.com/docs/app-check/monitor-metrics) for Firestore until **verified** requests account for essentially all legitimate app traffic, then click **Enforce**. Enforcement can take up to about 15 minutes to apply everywhere.

**Older app builds** without the App Check integration will start failing against Firestore once enforcement is on—coordinate with release cadence.

## Operator checklist (production project)

1. **Firebase Console** → your project → **Build** (or **Security**) → **App Check**.
2. Register the **macOS** app with bundle ID `com.openburnbar.app` if needed.
3. For **Device attestation** on Apple platforms, use **App Check with App Attest** and/or **DeviceCheck** as configured for your distribution. A Firebase provider row is not enough: DeviceCheck must show a `keyId` and `privateKeySet=true` in the Firebase App Check API, and App Attest requires the Apple Bundle ID/provisioning profile to carry the App Attest entitlement before the app ships that provider.
4. **CI and local Apple debug:** Register a [debug provider](https://firebase.google.com/docs/app-check/ios/debug-provider) token in App Check for simulator/CI/physical Debug runs. The same token string must be what you inject via `FIREBASE_APP_CHECK_DEBUG_TOKEN` (GitHub Actions secret) and/or `FirebaseAppCheckDebugToken` in your local **gitignored** `GoogleService-Info.plist` (see [GoogleService-Info.plist.example](../AgentLens/Resources/GoogleService-Info.plist.example), [RELEASE_MACOS.md](RELEASE_MACOS.md) and `scripts/ci/inject-firebase-config.sh`). **Never commit** the real token in the repo.
5. **Internal iPhone/iPad TestFlight:** If Apple DeviceCheck/App Attest is not fully configured yet, build with `OPENBURNBAR_USE_DEBUG_APP_CHECK=YES` and provide `FIREBASE_APP_CHECK_DEBUG_TOKEN` from Secret Manager. The Xcode build injects that token into the built app bundle only, not the source plist, so Firestore App Check enforcement can remain on for internal testers.
6. **Android debug and release:** The Android app installs the Firebase App Check debug provider in Debug builds and the Play Integrity provider in Release builds. For a physical Android device running a local Debug build, copy the debug token printed by Firebase App Check logs into Firebase Console → App Check → Android app `com.openburnbar` → Manage debug tokens. For Firebase App Distribution or sideloaded release-style APKs, build with `OPENBURNBAR_USE_DEBUG_APP_CHECK=true` and `OPENBURNBAR_APP_CHECK_DEBUG_TOKEN` from Secret Manager. For Play Store production builds, leave both unset and use Play Integrity.
7. Open **App Check** → **APIs** (or the Firestore product card) for **Cloud Firestore** → review **metrics** (verified vs outdated/unknown/invalid).
8. When ready, **Enforce** App Check for **Cloud Firestore** and confirm.
9. Smoke-test: sign in, enable cloud sync, and confirm no `PERMISSION_DENIED` from Firestore in logs.

`scripts/commercial-launch-gate.mjs` reads the live Firebase App Check service
configuration through the Firebase App Check API and fails launch unless
`firestore.googleapis.com` reports `ENFORCED`.

## Security rules and App Check

The checked-in **Firestore rules** do not duplicate App Check: **enforcement is expected at the Firestore product** in App Check, as [documented by Firebase](https://firebase.google.com/docs/app-check/enable-enforcement). The rules file header in [firestore.rules](../firestore.rules) notes this, so a rules-only review is not misread as the full story.

Optional defense-in-depth in rules (e.g. `request.app`) is **not** used here by default, because support and behavior can vary; validate in a staging project before relying on it.

## See also

- [THREAT_MODEL.md](THREAT_MODEL.md) — cloud surfaces
- [README.md](../README.md) — cloud sync setup
- [RUNBOOK.md](RUNBOOK.md) — sync / permission denied triage
