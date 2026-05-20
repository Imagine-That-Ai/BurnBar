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
python3 -c "import base64; print(base64.b64encode(open('android/app/google-services.json','rb').read()).decode())"

# Add the output as a GitHub secret named GOOGLE_SERVICES_JSON_BASE64
```

The injection script is `scripts/ci/inject-firebase-config-android.sh`.

### git

`android/.gitignore` already excludes `google-services.json`.


## Java version

Android build requires **JDK 21** (Gradle 8.9 + AGP 8.7.3). On macOS:

```bash
brew install openjdk@21
export JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" # or /opt/homebrew/opt/openjdk@21 on system Homebrew installs
```

Verify: `java -version` should show `21.x.x`.

## Mercury Media follow-up (updated — 2026-05-18)

iOS and Mac have complete user-facing Mercury surfaces (Hermes Square "My Mac" tile + popover Mercury section). Android parity work currently tracks these checkpoints:

- **Kotlin `MercuryPeer` model.** Mirror `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryPeer.swift` as a Kotlin data class with the same `Feature` enum and forward-compatible unknown-capability filtering.
- **Three new frame-type enum cases.** `media.mirror.request`, `media.mirror.ack`, and `media.presence.heartbeat` are present in the Android `HermesRealtimeRelayFrameType` equivalent.
- **Android paired-Mac controls.** `PairedMacControlsScreen` exposes Ask to Mirror, Check Mercury, Send File, and Call Mac. Ask to Mirror, Send File, and Call Mac use real `media.control` transport paths; Call Mac sends `media.call.invite` and listens for `media.call.ack` from the Mac.
- **Android `MercuryPeerSource`.** Poll `MediaControlStreamCoordinator.phase` and Firestore `users/{uid}/devices` for the paired Mac display name. Wire into the Hermes Square pinned grid via `AgentIdentityRegistry` equivalent.
- **Outbound presence heartbeat.** Android `MediaControlStreamCoordinator` sends `media.presence.heartbeat` every 60s with paired-device identity and Mercury capabilities.

No new Cloud Function, no new ALPN. Keep future Android Mercury additions on the existing `media.control` stream unless the shared protocol changes first.
