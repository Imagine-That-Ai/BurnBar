# `@unchecked Sendable` Remediation Registry

OpenBurnBar treats `@unchecked Sendable` as security-relevant concurrency debt. CI runs
[`scripts/debt/check-unchecked-sendable-budget.sh`](../../scripts/debt/check-unchecked-sendable-budget.sh)
and fails on any production conformance that does not carry a reviewed
`sendable-allowlist: <reason-id>` token.

Use an allowlist token only when the underlying value is an SDK/FFI/raw-pointer boundary
Swift cannot prove safe and the implementation owns synchronization explicitly. Prefer an
actor, a real `Sendable` payload, or a lock-guarded owned value whenever that is possible.

## Reason IDs

| Reason ID | Boundary | Required invariant |
|-----------|----------|--------------------|
| `iroh-ffi-handle` | Opaque UniFFI/Iroh handles | Wrapper owns lifecycle; mutable access is serialized by the backend contract. |
| `single-threaded-vector-builder` | Vector-index build helpers | Mutable state is used only during single-threaded build before immutable publication. |
| `sqlite-raw-pointer` | Raw SQLite `OpaquePointer` handles | All SQLite access is serialized by the owning queue or lock. |
| `corehid-backend` | CoreHID / virtual keyboard handles | Backend methods serialize platform calls; no shared mutable state escapes. |
| `process-handle` | Process/session handles | Mutable state is guarded by the owning lock or serial queue. |
| `firebase-sdk-handle` | Firebase SDK reference types | Firebase owns thread safety; wrapper does not expose unsynchronized mutable state. |
| `firestore-any-payload` | Firestore `[String: Any]` payloads | Payload is immutable after construction and read-only across concurrency boundaries. |
| `firestore-any-test-fake` | Firestore fake payloads | Test-only fake carries immutable untyped values. |
| `foundation-sdk-shim` | Foundation/Security SDK reference or untyped C-API shims | Wrapper serializes mutable access or transfers single-owned SDK objects. |
| `apple-media-buffer` | AVFoundation/CoreMedia buffers | Wrapper transfers a single-owned media buffer without concurrent mutation. |

## Current Handoff 2 Additions

`DatabaseEncryptionKeychainClient` and `DatabaseEncryptionKeychainClientBox` use
`foundation-sdk-shim` because Security.framework Keychain APIs require untyped
`[String: Any]` / `AnyObject` query payloads. The mutable injection point is isolated in
`DatabaseEncryptionKeychainClientBox` and protected by `NSLock`; callers copy the current
client while locked before invoking it.
