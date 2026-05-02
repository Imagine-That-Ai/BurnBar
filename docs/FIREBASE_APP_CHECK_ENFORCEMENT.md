# Firebase App Check enforcement for Cloud Firestore

OpenBurnBar ships the **Firebase App Check** SDK and installs a provider **before** `FirebaseApp.configure()` (see `OpenBurnBarAppCheckProviderFactory` and `AgentLensApp.swift`). That alone does **not** protect Firestore: you must **enforce** App Check for **Cloud Firestore** in the Firebase project used by your `GoogleService-Info.plist`.

Without enforcement, a caller who obtains a **valid Firebase Auth ID token** (e.g. from another signed-in context) can still use the Firestore API against your project, because your [firestore.rules](../firestore.rules) only express **authentication and owner scoping**—not app attestation.

**Primary control:** [Enable App Check enforcement](https://firebase.google.com/docs/app-check/enable-enforcement) for **Cloud Firestore** in the Firebase console. The Firestore service then rejects traffic that is not accompanied by a valid App Check attestation, before (or in addition to) your security rules.

**Request metrics (before you enforce):** [Monitor App Check request metrics](https://firebase.google.com/docs/app-check/monitor-metrics) for Firestore until **verified** requests account for essentially all legitimate app traffic, then click **Enforce**. Enforcement can take up to about 15 minutes to apply everywhere.

**Older app builds** without the App Check integration will start failing against Firestore once enforcement is on—coordinate with release cadence.

## Operator checklist (production project)

1. **Firebase Console** → your project → **Build** (or **Security**) → **App Check**.
2. Register the **macOS** app with bundle ID `com.openburnbar.app` if needed.
3. For **Device attestation** on Apple platforms, use **App Check with App Attest** and/or **DeviceCheck** as configured for your distribution (the app uses App Attest on macOS 11+ in release, with DeviceCheck fallback where applicable).
4. **CI and local debug:** Register a [debug provider](https://firebase.google.com/docs/app-check/ios/debug-provider) token in App Check. The same token string must be what you inject via `FIREBASE_APP_CHECK_DEBUG_TOKEN` (GitHub Actions secret) and/or `FirebaseAppCheckDebugToken` in your local **gitignored** `GoogleService-Info.plist` (see [GoogleService-Info.plist.example](../AgentLens/Resources/GoogleService-Info.plist.example), [RELEASE_MACOS.md](RELEASE_MACOS.md) and `scripts/ci/inject-firebase-config.sh`). **Never commit** the real token in the repo. Without registering the token in the console, debug/CI clients will be rejected after enforcement.
5. Open **App Check** → **APIs** (or the Firestore product card) for **Cloud Firestore** → review **metrics** (verified vs outdated/unknown/invalid).
6. When ready, **Enforce** App Check for **Cloud Firestore** and confirm.
7. Smoke-test: sign in, enable cloud sync, and confirm no `PERMISSION_DENIED` from Firestore in logs.

## Security rules and App Check

The checked-in **Firestore rules** do not duplicate App Check: **enforcement is expected at the Firestore product** in App Check, as [documented by Firebase](https://firebase.google.com/docs/app-check/enable-enforcement). The rules file header in [firestore.rules](../firestore.rules) notes this, so a rules-only review is not misread as the full story.

Optional defense-in-depth in rules (e.g. `request.app`) is **not** used here by default, because support and behavior can vary; validate in a staging project before relying on it.

## See also

- [THREAT_MODEL.md](THREAT_MODEL.md) — cloud surfaces
- [README.md](../README.md) — cloud sync setup
- [RUNBOOK.md](RUNBOOK.md) — sync / permission denied triage
