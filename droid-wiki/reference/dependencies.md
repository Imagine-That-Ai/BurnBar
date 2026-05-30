# Dependencies

Key runtime dependencies by platform. Full version pins are in `Package.resolved` (Swift) and `build.gradle` / `package.json` (Android / Functions).

## macOS / iOS (Swift)

| Library | Version | Purpose |
|---------|---------|---------|
| `GRDB` (grdb-sqlcipher fork) | 6.29.3 | SQLite ORM with SQLCipher encryption |
| `firebase-ios-sdk` | 11.15.0 | Firestore, Auth, App Check, FCM, Remote Config |
| `GoogleSignIn-iOS` | 8.0.0 | Google OAuth sign-in |
| `app-check` | 11.2.0 | Firebase App Check |
| `sentry-cocoa` | 8.58.3 | Error and performance monitoring |
| `swift-protobuf` | 1.38.0 | Protobuf encoding for daemon wire format |
| `swift-snapshot-testing` | 1.19.2 | Snapshot tests (test targets only) |
| `swift-custom-dump` | 1.6.0 | Richer assertion diffs (test targets only) |
| `ViewInspector` | 0.10.3 | SwiftUI view introspection in tests |
| `OpenBurnBarIroh.xcframework` | vendored | P2P transport (Rust, UniFFI-generated Swift bindings) |

The daemon target (`OpenBurnBarDaemon`) has a separate `Package.resolved` with a subset of the above plus:

| Library | Purpose |
|---------|---------|
| `grdb-sqlcipher` | 6.29.3 — same as app target |
| `sentry-cocoa` | 8.58.2 — error tracking in daemon process |

`swift-nio` is **not** a direct dependency — the daemon uses `Network.framework` and POSIX socket APIs directly.

## Android (Kotlin)

| Library | Purpose |
|---------|---------|
| Firebase Android SDK | Firestore, FCM, Auth, Remote Config |
| `openburnbar-iroh.aar` | P2P transport (Rust, UniFFI Kotlin bindings) |
| Tink | Ed25519 signature verification (required on API < 31; JDK Ed25519 ships API 31+) |
| Jetpack Compose | Declarative UI |
| DataStore Proto | Persistent per-partner save preferences |
| Sentry Android | Error monitoring |

Build the iroh AAR locally: `scripts/build-iroh-android-aar.sh` (requires NDK, cargo-ndk, Rust targets).

Build the Opus AAR locally: `scripts/build_opus_android.sh` (libopus 1.5, 4 ABIs).

## Firebase Functions (TypeScript / Node 22)

| Package | Version | Purpose |
|---------|---------|---------|
| `firebase-functions` | ^7.2.5 | Cloud Functions v2 runtime |
| `firebase-admin` | ^13.0.0 | Firestore, Auth, FCM admin access |
| `@apple/app-store-server-library` | ^3.0.0 | App Store receipt and notification verification |
| `stripe` | 19.3.0 | Stripe billing integration |
| `googleapis` | ^148.0.0 | Google APIs client |

`@google-cloud/secret-manager` is accessed through `firebase-admin` rather than as a direct dependency.

## Rust (iroh crate — `crates/openburnbar-iroh`)

| Crate | Purpose |
|-------|---------|
| `iroh` | P2P connectivity (hole-punching, relay fallback) |
| `uniffi` | FFI binding generation for Swift and Kotlin |
| `tokio` | Async runtime |
| `opus` | Audio codec for Mercury media (RTP over iroh datagrams) |

The Rust crate is compiled to `OpenBurnBarIroh.xcframework` (iOS/macOS) and `Vendor/openburnbar-iroh.aar` (Android) via CI. UniFFI version is pinned to `0.28.3` on both platforms.
