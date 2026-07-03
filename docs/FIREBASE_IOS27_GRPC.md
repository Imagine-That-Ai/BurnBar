# Firestore on iOS 27 — source-built gRPC is REQUIRED

**TL;DR: always resolve SwiftPM with `FIREBASE_SOURCE_FIRESTORE=1` in the
environment. The prebuilt `grpc-binary` crashes every iOS 27 device the first
time Firestore connects.**

## The incident (2026-07-03)

- The prebuilt gRPC xcframework (`grpc-binary` 1.69.x, pulled in by
  firebase-ios-sdk 11.x **and** 12.x) faults on iOS 27 the first time
  Firestore opens its gRPC TLS channel:
  `EXC_BAD_ACCESS (SIGSEGV)` in `OPENSSL_sk_free` ←
  `ssl_credential_st::~ssl_credential_st` ← `ssl_cert_dup` ←
  `create_tsi_ssl_handshaker`, on a background connect thread. Verified
  on-device on iOS 27.0 GM with Firebase 12.15.0 (crash report
  `OpenBurnBarMobile-2026-07-03-051520.ips`).
- The old mitigation was `AppDelegate.disableFirestoreNetworkOnIncompatibleOSIfNeeded`,
  which turned Firestore's network OFF for every iOS 27+ user. That prevented
  the crash but silently killed all cloud data: the Pulse dashboard showed
  `$0.00`, quota showed "No quota signal yet", and the You tab showed
  "Mac last seen: never" — while Firebase **Auth** (REST, not gRPC) kept
  working, so the account looked signed-in and healthy. This was the root
  cause of "my iPhone and Mac are signed into the same account but nothing
  syncs".
- Building Firestore **from source** (`FIREBASE_SOURCE_FIRESTORE=1` swaps
  `grpc-binary` for the `grpc-ios` + `BoringSSL-SwiftPM` source packages,
  compiled with the current toolchain) eliminates the crash — verified
  on-device on the same iPhone/iOS 27.0: TLS handshake completes, rules
  round-trips succeed, data flows.

## What is in place now

1. `project.yml` pins `firebase-ios-sdk` `from: 12.15.0`.
2. The iOS 27 version-gated kill switch is **gone**. What remains is an
   explicit emergency escape hatch:
   `defaults write com.openburnbar.app OpenBurnBarDisableFirestoreNetwork -bool true`
   (`AppDelegate.firestoreNetworkKillSwitchDefaultsKey`). When it is active,
   the sync UI *says so* (`CloudSyncHealth.networkDisabledOnThisDevice`)
   instead of rendering empty data.
3. A pre-build tripwire on the `OpenBurnBarMobile` target fails the build if
   `Package.resolved` contains `grpc-binary`, so an accidental re-resolve
   without the env var becomes a build error instead of a shipped crash.

## Day-to-day workflows

- **CLI builds / CI**: `export FIREBASE_SOURCE_FIRESTORE=1` before
  `xcodebuild ... -resolvePackageDependencies` and builds.
- **Xcode GUI**: Xcode must inherit the variable when it resolves packages.
  Either `launchctl setenv FIREBASE_SOURCE_FIRESTORE 1` (per boot) or launch
  Xcode from a shell that exports it (`open -a Xcode`). If Xcode ever
  re-resolves without it, the tripwire build error tells you exactly what
  happened.
- First source build recompiles gRPC C-core + BoringSSL (~minutes); after
  that it is cached in DerivedData like any other target.

## Exit criteria for dropping this

When a firebase-ios-sdk release ships a `grpc-binary` built against the iOS 27
toolchain (watch the release notes for a grpc bump past 1.69.x), verify on a
physical iOS 27 device that the binary path no longer faults, then remove the
tripwire, the env-var requirement, and this doc in the same PR.
