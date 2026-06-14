import FirebaseFirestore

// Retroactive `Sendable` conformance for the top-level Firestore SDK handle.
//
// `Firestore` (like `CollectionReference` / `DocumentReference` / `Query` /
// `WriteBatch`, already covered by the `firebase-sdk-handle` allowlist) is a
// thread-safe Firebase SDK type that dispatches its own work onto an internal
// serial queue, but the SDK ships without a `Sendable` annotation. Under Swift 6
// that makes passing a `Firestore` handle across an `await` (e.g. into the
// `MobileCloudVaultKeyAccess.keyForReading/keyForWriting` helpers) a hard error,
// even though every such hand-off is safe.
//
// This is the same situation — and the same fix — as the Foundation SDK shims in
// `AgentLens/Utilities/ParserDiskCache.swift`. Asserting the conformance once,
// module-wide, is the honest, irreducible resolution: we cannot annotate a type
// we do not own, and scattering provider-closure indirection across every call
// site would be working *around* a fact the codebase already documents in eight
// places. Remove this once the Firebase SDK declares `Firestore: Sendable`.
//
// sendable-allowlist: firebase-sdk-handle
extension Firestore: @retroactive @unchecked Sendable {}
