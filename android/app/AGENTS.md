# Android App — Firebase Config

## google-services.json

The real `google-services.json` contains API keys. It is **never committed**.

### Local development

```bash
# 1. Register the Android app in Firebase Console (project: burnbar, package: com.openburnbar)
# 2. Download google-services.json
# 3. Copy it in place:
cp ~/Downloads/google-services.json android/app/google-services.json
```

The template at `android/app/google-services.json.template` is safe to commit — it contains only placeholder values.

### CI

CI injects the config from `GOOGLE_SERVICES_JSON_BASE64` (a GitHub Actions secret).

```bash
# Encode the real file for CI:
node -e "process.stdout.write(require('fs').readFileSync('android/app/google-services.json').toString('base64'))"

# Add the output as a GitHub secret named GOOGLE_SERVICES_JSON_BASE64
```

The injection script is `scripts/ci/inject-firebase-config-android.sh`. Release CI
sets `OPENBURNBAR_ANDROID_FIREBASE_STRICT=1`, which requires the real BurnBar
project (`burnbar`), app id (`1:246956661961:android:6ffe560abf1a583a480118`),
package (`com.openburnbar`), a non-placeholder API key, and at least one Android
OAuth certificate in `google-services.json`.

Before any Play Store release, verify the file locally:

```bash
node scripts/ci/verify-android-firebase-release-config.mjs --strict-release
```

The app Gradle build also runs the same release-grade validation for every
`Release` variant task, so `:app:bundleRelease` fails before packaging if the
Firebase file is missing, placeholder, or for the wrong app.

### Google sign-in

Android Google sign-in is Credential Manager only. `UserStore` reads
`R.string.default_web_client_id`, generated from the injected
`google-services.json`, and exchanges the returned Google ID token through
Firebase Auth. Do not hard-code OAuth client IDs or reintroduce the deprecated
`GoogleSignIn` intent flow; the release validator is the source of truth for
whether the shipped Firebase config can sign in.

### Play signing certificate parity

The Firebase Android app must keep both Play app signing and upload certificate
fingerprints registered. Check the live Firebase state before releasing:

```bash
firebase apps:android:sha:list 1:246956661961:android:6ffe560abf1a583a480118 --project burnbar
```

The Android API key must allow Firebase Auth and Secure Token
(`identitytoolkit.googleapis.com`, `securetoken.googleapis.com`). A Play build
that ships with the template file or an API key from another Firebase app will
fail sign-in with `api key not valid`.

### git

`android/.gitignore` already excludes `google-services.json`.


## Java version

Android build requires **JDK 21** (Gradle 9.4.1 + AGP 9.2.x). On macOS:

```bash
brew install openjdk@21
export JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" # or /opt/homebrew/opt/openjdk@21 on system Homebrew installs
```

Verify: `java -version` should show `21.x.x`.

The Android SDK path on this machine is `$HOME/Library/Android/sdk`:

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
```

AGP 9 provides built-in Kotlin, so Android modules must not apply
`org.jetbrains.kotlin.android` or use `android.kotlinOptions`. Room annotation
processing uses `com.android.legacy-kapt` until the KSP Gradle plugin supports
AGP built-in Kotlin; do not opt out with `android.builtInKotlin=false`.

## Mercury Media follow-up (updated — 2026-05-18)

iOS and Mac have complete user-facing Mercury surfaces (Hermes Square "My Mac" tile + popover Mercury section). Android parity work currently tracks these checkpoints:

- **Kotlin `MercuryPeer` model.** Mirror `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryPeer.swift` as a Kotlin data class with the same `Feature` enum and forward-compatible unknown-capability filtering.
- **Three new frame-type enum cases.** `media.mirror.request`, `media.mirror.ack`, and `media.presence.heartbeat` are present in the Android `HermesRealtimeRelayFrameType` equivalent.
- **Android paired-Mac controls.** `PairedMacControlsScreen` exposes Ask to Mirror, Check Mercury, Send File, and Call Mac. Ask to Mirror, Send File, and Call Mac use real `media.control` transport paths; Call Mac sends `media.call.invite` and listens for `media.call.ack` from the Mac.
- **Android `MercuryPeerSource`.** Poll `MediaControlStreamCoordinator.phase` and Firestore `users/{uid}/devices` for the paired Mac display name. Wire into the Hermes Square pinned grid via `AgentIdentityRegistry` equivalent.
- **Outbound presence heartbeat.** Android `MediaControlStreamCoordinator` sends `media.presence.heartbeat` every 60s with paired-device identity and Mercury capabilities.

No new Cloud Function, no new ALPN. Keep future Android Mercury additions on the existing `media.control` stream unless the shared protocol changes first.
