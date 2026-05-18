# Android iroh transport runbook

Companion to `docs/runbooks/iroh-rollout-status.md`. This file is the
on-call playbook for Android's iroh transport — bring-up, key store,
pairing verifier, audit pipeline, and troubleshooting.

## Layers

The Android transport stack mirrors iOS exactly:

```
HermesService (chat + tools + outcomes)
        │
HermesCompositeRelayTransport
   ├─→ HermesIrohRelayTransport (preferred, QUIC + iroh-blobs)
   │       └─ IrohJniTransport
   │               └─ OpenBurnBarIrohFfiBackend (reflection over uniffi.openburnbar_iroh)
   │                       └─ Vendor/openburnbar-iroh.aar
   └─→ FirestoreRelayShim (fallback)
           └─ HermesRelayClient (Firestore-polling envelope, legacy)
```

Wire format is identical across iOS and Android: ALPN `openburnbar/1`,
big-endian u32 length prefix, `HermesRealtimeRelayFrame` JSON envelope
with `HermesRelayCrypto` AAD strings. Bytes are interchangeable.

## Binary pipeline

| Stage | Command | Output |
|---|---|---|
| Rust crate | `cargo test -p openburnbar-iroh` | host unit tests for the datagram + chat surface |
| AAR build (local) | `scripts/build-iroh-android-aar.sh` | `Vendor/openburnbar-iroh.aar` (arm64-v8a, x86_64, armeabi-v7a, x86) |
| AAR build (CI) | `.github/workflows/build-iroh-android-aar.yml` | uploaded as `openburnbar-iroh.aar` artifact + generated Kotlin bindings |
| Opus AAR | `scripts/build_opus_android.sh` | `Vendor/opus-android.aar` (4 ABIs, libopus 1.5) |
| App build | `./gradlew :app:assembleDebug` | links the AAR when present; falls back to loopback when absent |

The AAR script auto-installs the Android NDK (`ndk;26.3.11579264`)
via `sdkmanager`, installs `cargo-ndk` if missing, and adds the four
Rust Android targets via `rustup target add`. A clean CI host runs
the script with zero pre-installed Android NDK.

## Key store

`HermesRelayKeyStore` (`android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRelayKeyStore.kt`)
persists three secrets in shared preferences:

| Key | Use |
|---|---|
| `ec_private_v1` (redacted name) | P-256 PKCS#8 private key — ECDH per-request sealing |
| `ec_public_v1` (redacted name) | X9.63-encoded P-256 public key |
| `iroh_secret_v1` | 32-byte iroh secret key (Curve25519, surface form for `IrohSecretKeyMaterial`) |

The iroh secret is generated lazily on first use via `SecureRandom()`
and never reused for ECDH. Wipe by clearing app data (Settings → Apps
→ BurnBar → Storage → Clear).

## Pairing verifier

The Mac signs an `IrohPairingRecord` with its CryptoKit Curve25519
private key and publishes the record to
`users/{uid}/iroh_pairing/{connectionId}`. Android reads the record,
verifies the Ed25519 signature against the canonical payload, and
dials the resulting `IrohDialTarget`.

Verifier: `IrohPairingSignature.verify(...)` in
`android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/IrohRelayPairing.kt`.
Backed by Tink — the JDK's `java.security.Signature("Ed25519")`
provider doesn't ship until API 31, but Tink works back to our minSdk
(26).

Canonical payload (UTF-8, pipe-delimited, version-prefixed):

```
openburnbar.iroh.pairing.v1|<uid>|<connectionId>|<nodeId>|<relayURL>|<directAddresses>|<publishedAtMs>
```

`directAddresses` is the trimmed-deduplicated-sorted list joined with
`,`. Identical canonicalization runs in Swift, Kotlin, and TypeScript.

Verifier rejects:
- Wrong signature → `IrohPairingError.InvalidSignature`
- Wrong protocol version → `UnsupportedProtocolVersion`
- Records older than 24h → `Expired`
- Non-32-byte public key → `InvalidPublicKey`
- Base64-malformed signatures → `Malformed`

## Audit pipeline

`FirestoreIrohAuditLogger` (TODO: ships in the same `data/hermes/relay/`
package — wire it in when adding telemetry) writes one document per
event under `iroh_audit_events/{deviceId}/{timestamp}`. Same shape as
iOS so `functions/src/rollupIrohTransportDaily` picks Android up for
free.

Events emitted:

| Event | When |
|---|---|
| `iroh_pairing_verified` | After `IrohPairingSignature.verify` succeeds |
| `iroh_pairing_rejected` | On any signature / freshness / version failure |
| `iroh_stream_opened` | Once `transport.connect(target, timeout)` returns |
| `iroh_stream_closed` | On `response.complete` |
| `iroh_stream_failed` | On dial timeout / connection drop / decode error |
| `iroh_fallback_to_wss` | When the composite cascade falls through to Firestore |

## Composite cascade

`HermesCompositeRelayTransport` decides per request:

1. Read the remote-config kill switch (`hermes_iroh_transport_enabled`).
   Off → skip iroh, go straight to Firestore.
2. Try iroh. On `IrohRelayTransportError.{TimedOut, EndpointNotReady,
   Shutdown, StreamRejected}`, log `iroh_fallback_to_wss` and delegate
   to Firestore.
3. Other throwables propagate (server bugs, not transport drops).

The kill switch is mirrored from Firebase Remote Config; flip it via
the Firebase console for a staged rollout.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| App immediately falls back to Firestore on every request | `Vendor/openburnbar-iroh.aar` missing from the build → `OpenBurnBarIrohFfiBackend.isAvailable()` returns false | Run `scripts/build-iroh-android-aar.sh` (or pull from CI) |
| `IrohPairingError.InvalidSignature` in audit logs | Mac is signing with a stale keypair | Restart `HermesRelayHostService` on the Mac so it republishes |
| `IrohPairingError.Expired` | Mac last published > 24h ago | Mac's heartbeat is dead — restart the Mac host |
| Dial timeout (`IrohRelayTransportError.TimedOut`) on every request | NAT punching failing, no relay reachable | Check the user has the hosted relay URL set; flip to public relays as a quick probe |
| Crash on `Class.forName("uniffi.openburnbar_iroh.IrohEndpointHandle")` | AAR present but ABI mismatch (e.g., emulator on host arch) | Rebuild AAR with all 4 ABIs (`IROH_ANDROID_ABIS` default) |
| Build error: `cargo-ndk not found` (CI) | Cache miss | First run of `cargo install cargo-ndk` is slow; let it complete + re-prime cache |

## See also

- `docs/runbooks/iroh-rollout-status.md` — multi-platform rollout state
- `docs/runbooks/android-mercury-media.md` — Mercury Media on Android
- `docs/runbooks/iroh-secrets.md` — secret-key rotation policy
- `docs/runbooks/wss-retirement-checklist.md` — when WSS can be removed
- `crates/openburnbar-iroh/src/lib.rs` — Rust ALPN surface
- `crates/openburnbar-iroh/src/datagrams.rs` — Mercury audio datagram channel
