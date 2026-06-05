# Item 4 — native L41 client stores (X3DH/PQXDH + Double Ratchet)

Completes the CLIENT half of item 4 (the server half — publish/claim/session/rotation callables — landed earlier). These stores serve the **transport/session** path (real Signal sessions); the at-rest producers (item 3) use single-shot HPKE and do NOT need them.

## Build prerequisite
`Vendor/libsignal` was an empty submodule in this worktree. Symlinked from the main checkout (9.1 GB, can't copy): `Vendor/libsignal`, `Vendor/OpenBurnBarSignalFfi.xcframework`, `Vendor/OpenBurnBarIroh.xcframework`. Result: `swift build` → **Build complete (534 modules)**; existing `OpenBurnBarSignalCoreTests` **5/5**.

## Added (OpenBurnBarCore/Sources/OpenBurnBarSignalCore/)
- **`OBBSignalProtocolStore.swift`** — one class conforming to all five libsignal stores (`IdentityKeyStore`, `PreKeyStore`, `SignedPreKeyStore`, `KyberPreKeyStore`, `SessionStore`), mirroring the canonical `InMemorySignalProtocolStore`. EC/Kyber key records + trusted-identity TOFU persist in the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, namespaced accounts) exactly like `OpenBurnBarSignalIdentityKeyStore`; `SessionRecord`s persist as atomically-written files under `sessionDir`. Kyber replay guard mirrors the in-memory `(id<<32)|signedPreKeyId` base-key-seen check.
- **`OBBSignalPreKeyGenerator.swift`** — generates signed prekey + one-time prekey + mandatory Kyber prekey (each identity-signed) and assembles a public `PreKeyBundle`; `storePreKeys` persists the private halves.

## Verification
```bash
cd OpenBurnBarCore && swift test --filter OBBSignalProtocolStoreSessionTests
```
**2/2 PASS** on real libsignal 0.94.4:
- `testFullPQXDHSessionEncryptDecrypt` — Alice processes Bob's bundle (X3DH + PQXDH Kyber), Alice→Bob PreKey message decrypts, Bob→Alice whisper message decrypts (Double Ratchet both directions).
- `testSessionSurvivesStoreRoundTrip` — a fresh `OBBSignalProtocolStore` over the same Keychain service + session dir reloads the persisted session + identity and decrypts a new message.

## Boundary
The stores + generator + a proven in-process session are the client foundation. Wiring a live two-device session over the L41 server callables (publish → claim → processPreKeyBundle across real devices) is the activation-time, on-device step (shared-device blocked). The server callables + native stores are both proven independently.
