# Dependencies

Key runtime dependencies by platform. Full version pins are in `Package.resolved` (Swift), `Cargo.toml` (Rust), `build.gradle.kts` / `gradle/libs.versions.toml` (Android), and `package.json` (Cloud Functions).

## macOS / iOS (Swift)

### Core app dependencies

| Library | Version | Purpose | Why pinned |
|---------|---------|---------|------------|
| `GRDB` (via `grdb-sqlcipher` fork) | `6.29.3` (exact) | SQLite ORM with SQLCipher at-rest encryption | Exact pin prevents SQLCipher ABI drift between the app target and the daemon target, which share the same encrypted database file |
| `firebase-ios-sdk` | `11.15.0` (approx) | Firestore, Auth, App Check, FCM, Remote Config, Crashlytics | Major-line pin ensures App Check attestation compatibility across iOS, iPadOS, and macOS builds |
| `GoogleSignIn-iOS` | `8.0.0` | Google OAuth sign-in | Major-line pin for stable auth flow behavior |
| `sentry-cocoa` | `8.58.3` | Error and performance monitoring, ANR detection, breadcrumbs, release health | Pin prevents symbolication regressions on macOS menu-bar apps |
| `swift-protobuf` | `1.38.0` | Protobuf encoding for daemon wire format and gRPC-style messages | Exact pin keeps generated proto stubs compatible with runtime |
| `swift-snapshot-testing` | `1.19.2` | Snapshot tests for UI and data fixtures | Test-only; exact pin for reproducible image diffs |
| `swift-custom-dump` | `1.6.0` | Richer assertion diffs in XCTest | Test-only |
| `ViewInspector` | `0.10.3` | SwiftUI view introspection in unit tests | Test-only; fragile across SwiftUI OS versions |

### Daemon target (`OpenBurnBarDaemon/Package.swift`)

The daemon is a separate Swift Package Manager product with its own `Package.resolved`:

| Library | Version | Purpose |
|---------|---------|---------|
| `GRDB` (via `grdb-sqlcipher`) | `6.29.3` (exact) | Same encrypted SQLite as the app target |
| `sentry-cocoa` | `8.58.2` | Error tracking in the daemon process |

The daemon does **not** depend on `swift-nio` — it uses `Network.framework` and POSIX socket APIs directly for the Unix socket and HTTP gateway.

### Vendored binary frameworks

| Framework | Source | Purpose |
|-----------|--------|---------|
| `OpenBurnBarIroh.xcframework` | `scripts/build-iroh-ios.sh` / CI | P2P QUIC transport (Rust iroh crate compiled for Apple platforms, UniFFI-generated Swift bindings) |
| `opus-ios.xcframework` | `scripts/build_opus_ios.sh` | Audio codec for Mercury media real-time calls |

## Android (Kotlin / Gradle)

| Library | Version | Purpose | Why pinned |
|---------|---------|---------|------------|
| `openburnbar-iroh.aar` | vendored | P2P QUIC transport (same Rust crate as iOS, UniFFI-generated Kotlin bindings) | Must match the Swift iroh crate wire-for-wire; built via `scripts/build-iroh-android-aar.sh` |
| `tink-android` | `1.15.0` | Ed25519 signature verification for iroh pairing and phone-control intents | The JDK `Ed25519` provider only ships on API 31+; Tink provides a portable verifier for all supported Android versions |
| Firebase Android BOM | `33.7.0` | Firestore, Auth, App Check, FCM, Crashlytics, Functions, Messaging | BOM pins the entire Firebase surface to a consistent major line |
| `firebase-appcheck-playintegrity` | BOM | Play Integrity attestation for production builds | Replaced by `firebase-appcheck-debug` in App Distribution builds via `OPENBURNBAR_USE_DEBUG_APP_CHECK` |
| `firebase-appcheck-debug` | BOM | Debug provider for CI/simulator/physical debug builds | Always linked; activated at runtime only when debug token is present |
| Jetpack Compose BOM | `2024.12.01` | Declarative UI (Material 3, animations, foundation) | BOM prevents transitive Compose version skew |
| `navigation-compose` | `2.8.5` | Navigation graphs and deep-linking | Pin for stable back-stack behavior |
| `kotlinx-serialization-json` | `1.7.3` | JSON serialization for network and Firestore models | Major-line pin for generated serializer stability |
| `okhttp` | `4.12.0` | HTTP client for Hermes webapi and gateway calls | Stable line with known behavior on Android |
| `vico:compose-m3` | `2.1.2` | Compose-first chart library for Insights widgets | Pin for API stability across chart types |
| `sentry-android` | `8.13.2` | Error tracking, ANR detection, breadcrumbs | Matches Sentry org project configuration |
| `billing-ktx` | `8.3.0` | Google Play Billing for BurnBar Pro and Cloud Pro subscriptions | Major-line pin for purchase-flow stability |
| CameraX | `1.4.0` | Local camera capture pipeline for Mercury media HEVC encoder | First 1.x line with `LENS_FACING_FRONT` support across all `minSdk` targets |
| Room | `2.6.1` | Local SQLite persistence (cache, offline quota) | Stable line; kapt-generated code is sensitive to minor bumps |
| `work-runtime-ktx` | `2.10.0` | Widget snapshot refresh scheduling | Pin for doze-mode behavior stability |
| `datastore-preferences` | `1.1.1` | Persistent per-partner save preferences (MediaStore / SAF) | Pin for proto schema stability |
| `coil-compose` | `2.7.0` | Image loading for chat attachments and avatars | Stable line |
| `credentials-play-services-auth` | `1.3.0` | Credential Manager for Google Sign-In | Modern auth path replacing legacy `play-services-auth` |

### Vendored binary libraries

| Library | Source | Purpose |
|---------|--------|---------|
| `openburnbar-iroh.aar` | `scripts/build-iroh-android-aar.sh` | Rust iroh crate compiled for all 4 Android ABIs, with UniFFI Kotlin bindings |
| `opus-android.aar` | `scripts/build_opus_android.sh` | libopus 1.5 compiled for 4 ABIs; audio codec for Mercury media RTP over iroh datagrams |

## Firebase Cloud Functions (TypeScript / Node 22)

| Package | Version | Purpose | Why pinned |
|---------|---------|---------|------------|
| `firebase-functions` | `^7.2.5` | Cloud Functions v2 runtime (onCall, onRequest, onSchedule, onDocumentWritten) | Major-line pin for stable callable behavior and emulator compatibility |
| `firebase-admin` | `13.10.0` | Firestore, Auth, FCM admin access, App Check verification | Exact pin for server-side App Check verify API stability |
| `@apple/app-store-server-library` | `^3.0.0` | App Store receipt validation, Server-to-Server notification verification | Required for Cloud Pro subscription entitlement checks |
| `stripe` | `19.3.0` | Stripe billing integration (checkout sessions, subscriptions, webhooks) | Exact pin for webhook signature verification stability |
| `googleapis` | `173.0.0` | Google Play Developer API for Android subscription verification | Pin for API surface stability |
| `cockatiel` | `3.2.1` | Circuit-breaker and retry policies for provider quota adapters | Pin for resilience behavior consistency |
| `@sentry/node` | `8.55.2` | Server-side error tracking and performance monitoring | Exact pin for trace propagation format |
| `vitest` | `4.1.8` | Unit test runner (dev-only) | Exact pin for test reporter compatibility |
| `knip` | `5.88.1` | Unused-dependency and export analysis (dev-only) | Pin for CLI behavior stability |
| `typescript` | `^5.9.3` | Type checking and emit | Latest stable line |

### Bridge scripts

| Script | Runtime | Purpose |
|--------|---------|---------|
| `openburnbar-playwright-bridge.js` | Node.js + `playwright@1.49.1` | Browser Computer Use driver (Phase 9); pinned to avoid Chromium/Playwright API drift |

Playwright is installed globally via `scripts/install-playwright.sh` which enforces the exact version pin. The bridge is loaded by `OpenBurnBarPlaywrightLifecycle` at runtime.

## Rust (`crates/openburnbar-iroh`)

| Crate | Version | Purpose | Why pinned |
|-------|---------|---------|------------|
| `iroh` | `=1.0.0-rc.0` | P2P QUIC connectivity, hole-punching, relay fallback | Exact pin for bit-stable xcframework builds; planned upgrade cycles validate against Swift integration tests before bumping |
| `iroh-dns` | `=1.0.0-rc.0` | DNS resolution for iroh relay URLs | Locked to same minor as `iroh` |
| `iroh-blobs` | `0.101.0` | Content-addressed BLAKE3 file transfer (Mercury Phase 1) | Must stay in lockstep with `iroh` major line; mismatched versions produce duplicate endpoint types that UniFFI cannot safely mix |
| `iroh-services` | `=1.0.0-rc.0` | iroh service helpers | Locked to same minor as `iroh` |
| `uniffi` | `0.28` (features: `cli`, `build`) | FFI binding generation for Swift and Kotlin | UniFFI is pinned to `0.28.3` on both Apple and Android to ensure identical UDL-less proc-macro ABI |
| `tokio` | `1` (rt-multi-thread, macros, sync, time, io-util) | Async runtime | Stable 1.x line |
| `tokio-stream` | `0.1` | Stream utilities | Stable line |
| `serde` | `1` (derive) | JSON serialization for the relay wire format | Stable line |
| `jni` | `0.22` | JNI bridge for Android AAR surface | Pin for JNI env pointer stability |
| `thiserror` | `1` | Ergonomic error types | Stable line |

The Rust crate is compiled to:
- `OpenBurnBarIroh.xcframework` (iOS/macOS) via `scripts/build-iroh-ios.sh`
- `Vendor/openburnbar-iroh.aar` (Android) via `scripts/build-iroh-android-aar.sh`

Both use the same `Cargo.toml` and must be rebuilt together when the Rust source changes.

## Notable absence

- **No `swift-nio`** — the daemon uses `Network.framework` and POSIX sockets directly.
- **No `grpc-swift`** — all inter-process communication is JSON-RPC 2.0 over Unix domain sockets or raw HTTP/1.1 on `Network.framework`.
- **No `RxJava` / `RxKotlin`** — Android uses Kotlin Coroutines (`kotlinx-coroutines-android:1.9.0`) and Compose `State`/`Flow` exclusively.

## Related pages

- [Configuration](configuration.md) — environment variables that select dependency versions at build time (e.g. `OPENBURNBAR_USE_DEBUG_APP_CHECK`)
- [Data models](data-models.md) — schemas serialized by these dependencies
- [RPC surface](rpc-surface.md) — surfaces built on `Network.framework`, `tokio`, and `okhttp`
