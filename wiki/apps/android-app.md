# Android companion app

The Android companion app delivers full parity with the iOS app as of 2026-05-16: Hermes chat (Hermes Square), messaging, iroh transport, Mercury Media (file transfer, screen-share viewer, 1:1 calls), and the Editorial Observatory Insights.

## Tech stack

| Layer | Technology |
|---|---|
| Language | Kotlin |
| UI | Jetpack Compose |
| Architecture | MVVM — `Store` (ViewModel subclass) + Firestore real-time listeners |
| Auth | Firebase Authentication |
| Database | Firestore (real-time sync) + DataStore Proto (local preferences) |
| Transport | iroh via `Vendor/openburnbar-iroh.aar` (UniFFI Kotlin bindings) |
| Push | Firebase Cloud Messaging (FCM) |
| Build system | Gradle (Java 21) |

## Directory layout

```
android/app/src/main/java/com/openburnbar/
  BurnBarApplication.kt      — Application class, DI wiring
  MainActivity.kt            — single-Activity host
  data/                      — models, parsers, Firestore stores
  ui/                        — Compose screens and components
  services/                  — MercuryFcmService, background workers
  menubar/                   — menu-bar-style quick-access UI
  util/                      — formatters, extensions
  wallpaper/                 — live wallpaper
  text/                      — text utilities
```

## Canonical schema

`functions/src/types.ts` is the canonical Firestore schema. Android models must match it exactly. Key mappings:

| TypeScript | Android (`data/models/`) | Firestore collection |
|---|---|---|
| `UsageEventDoc` | `TokenUsage` | `users/{uid}/usage/{doc}` |
| `UsageRollupDoc` | `UsageRollups` + `RollupSummary` | `users/{uid}/usage_rollups/{today,7d,30d,90d,all_time}` |
| `QuotaSnapshotDoc` | `ProviderQuotaSnapshot` + `QuotaBucket` | `users/{uid}/quota_snapshots/{provider}_{sourceId}` |
| `ProviderAccountDoc` | `ProviderAccount` | `users/{uid}/provider_accounts/{accountId}` |

Model conventions:
- `@IgnoreExtraProperties` on every data class.
- `@PropertyName` for keys that differ from Kotlin camelCase.
- Computed properties via `get()` in the class body, not in the primary constructor.
- Timestamps: `it.seconds * 1000 + it.nanoseconds / 1_000_000`.

Cloud Functions write **5 separate rollup documents** (`today`, `7d`, `30d`, `90d`, `all_time`). `mergeWindowDocs()` reads all 5 and merges them into a single `UsageRollups` client model.

## Store layer pattern

Each screen has a `*Store` (ViewModel subclass):
- `suspend` methods for one-shot fetch (`load()`, `refresh()`).
- `callbackFlow` + `addSnapshotListener` for real-time listening.
- Listener lifecycle managed by `viewModelScope`; cancelled on `stopListening()`.

## Mercury Media

### Incoming calls

`MercuryFcmService` handles high-priority FCM data messages with `media_incoming_call`:

1. Constructs `Notification.CallStyle.forIncomingCall(...)` targeting `IncomingCallActivity`.
2. `IncomingCallActivity` is declared `showOnLockScreen=true` + `turnScreenOn=true`.
3. `CallKitFacade` wraps a self-managed `ConnectionService` (Android equivalent of CallKit's `CXCallController`).
4. No bespoke ring sound — the system ringer handles it.
5. On Android 14+ without `USE_FULL_SCREEN_INTENT`, degrades to a heads-up with a settings deep link in `MediaSettingsView`.
6. Foreground service type: `microphone|camera|mediaProjection|phoneCall` (Android 14+ granular types).

### Audio

`MercuryAudioDatagramChannel` carries audio over the `openburnbar/mercury/audio/1` ALPN exposed by the Rust UniFFI surface in `crates/openburnbar-iroh/datagrams.rs`.

### File transfer save preferences

`MediaPartnerSavePreferenceStore` (DataStore Proto, keyed by peer `NodeId`):
- `SAVE_TO_PHOTOS` → `MediaStore.Images.Media` / `MediaStore.Video.Media` (scoped storage, API 29+).
- `SAVE_TO_FILES` → `ActivityResultContracts.OpenDocumentTree` once per partner, then `DocumentsContract.createDocument` for subsequent writes.
- Audio → `MediaStore.Audio.Media`.
- `forget(partnerId)` / `forgetAll()` for per-partner and full privacy wipe.

## iroh transport

`Vendor/openburnbar-iroh.aar` — built by `scripts/build-iroh-android-aar.sh`:
- `cargo-ndk` for four ABIs (arm64-v8a, armeabi-v7a, x86, x86_64)
- `uniffi-bindgen-kotlin` at the same `0.28.3` pinned for Swift
- Kotlin bindings identical in wire format to the Swift xcframework

The `:openburnbar-iroh-relay` Gradle module is a 1:1 port of Swift `OpenBurnBarIrohRelay`:
- Same wire format, ALPN `openburnbar/1`, big-endian u32 length prefix
- Same `HermesRealtimeRelayFrame` JSON envelope
- Ed25519 pairing signature verified via Tink (JDK Ed25519 only on API 31+)
- `OpenBurnBarIrohFfiBackend` reflection-bridge gates cleanly when the AAR is absent — falls back to loopback transport for dev or Firestore for prod.

## Insights — Editorial Observatory

`IntelligenceBriefScreen.kt` mirrors the iOS story arc:

- 22sp rounded-semibold headline + mono meta strip + mercury-gradient hairline with one-shot shimmer
- 01/02/03 Top Findings with mono ordinals, severity capsule, confidence dots, citation chips
- Horizontal `LazyRow` Anomaly Atlas with `Canvas`-drawn `ZScoreGauge`
- Recommendations with severity-aware ember seal and mono `↑`/`↓` impact arrow
- Cascade-in via `AnimatedVisibility` + `slideInVertically(8.dp)` + `fadeIn` at 40ms stagger
- Reduce-motion: `LocalAuroraReduceMotion` driven by `Settings.Global.animator_duration_scale==0`
- Font scale clamped to 1.15×

Tests: `IntelligenceBriefScreenTest` (Compose UI, 14/14), `IntelligenceBriefFormattingTest` (JVM, 5 cases).

## Build commands

```bash
# Debug APK
cd android && ./gradlew assembleDebug

# Clean build (errors only)
cd android && ./gradlew clean assembleDebug --no-daemon 2>&1 | grep "^e:\|BUILD"

# JVM unit tests (~253 tests)
cd android && ./gradlew :app:testDebugUnitTest --no-daemon

# iroh-relay unit tests
cd android && ./gradlew :openburnbar-iroh-relay:testDebugUnitTest --no-daemon
```

Prerequisites: Java 21, `ANDROID_HOME=$HOME/Library/Android`.

## Firebase config

- Real config: `android/app/google-services.json` — never committed.
- Template: `android/app/google-services.json.template` is safe in git.
- CI injection: `GOOGLE_SERVICES_JSON_BASE64` secret → `scripts/ci/inject-firebase-config-android.sh`.
- Local: download from Firebase Console → `cp ~/Downloads/google-services.json android/app/`.

## Related

- [iOS companion app](./ios-app/index.md)
- [Mercury media](../features/mercury-media.md)
- [Computer Use](../features/computer-use.md)
- [Hermes chat](../features/hermes-chat.md)
- `android/app/AGENTS.md` — Android-specific agent instructions
