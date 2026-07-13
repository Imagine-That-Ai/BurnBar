# ADR 014: Shared Rust Domain Core

## Context

OpenBurnBar has several behavior-identical domains implemented separately for
native platforms. Quota payload parsing exists in Swift and C#. CloudVault
cryptography exists in Swift, Kotlin, and C#. Hermes relay cryptography exists
in Swift and Kotlin. Golden fixtures detect drift after the fact but do not
remove the repeated implementation cost.

Provider log parsing is not currently such a domain. The fifteen production
parsers live in `OpenBurnBarCore`; Windows loads that Swift engine through its
C ABI, Linux reads through the shared engine, and Android and Cloud Functions
do not parse local provider logs. Rewriting those parsers in Rust would replace
one implementation rather than consolidate several.

## Decision

OpenBurnBar owns pure, duplicated business logic in
`crates/openburnbar-domain-core`. The workspace has one dependency-light Rust
library plus an explicit UniFFI adapter. A WebAssembly adapter is added only
when a real TypeScript-owned domain migrates. CloudVault C1a is that first
adapter: it exposes deterministic AAD and hashing operations without accepting
browser `CryptoKey` handles or changing non-extractable key custody. Transport, persistence,
network acquisition, authentication, secret storage, UI, and operating-system
integration remain in their existing owners.

Every migration is contract-first. Existing implementations must consume the
same language-neutral fixtures before Rust is introduced. A migrated consumer
passes through legacy, shadow, and Rust-enforced modes. Shadow comparison logs
only mismatch categories and core version, never payloads, values, credentials,
or payload hashes. The legacy implementation is deleted after the evidence and
rollback gates in `docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md` are satisfied.

The crate on `main` is the integration point. Work proceeds through short-lived,
independently reviewable branches; there is no long-lived SharedRust branch.

The quota pilot is controlled by `OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE` with
`legacy`, `shadow`, and `rust` values. Missing or invalid values fail closed to
legacy behavior.

The initial quota surface is ABI 1. CloudVault C1a expands the generated
contract to ABI 2 and adds Android and Wasm packaging. Consumers must verify the
expected ABI before invoking Rust; release artifacts must prove native loading
on their supported architectures rather than relying on binding compilation.

CloudVault C1b keeps randomness and key custody with each platform while Rust
owns AES-256-GCM authentication and the canonical `nonce || ciphertext || tag`
wire shape. Native callers cross the boundary once per complete payload. The
browser adapter exposes byte-array KAT helpers, but production WebCrypto handles
remain non-extractable and are never exported merely to call Wasm.

CloudVault C1c owns recovery-key normalization, recovery HKDF and verification
hashes, recovery AES wrapping, P-256 X9.63 public-point validation, escrow HKDF,
and the exact `ephemeralPublic(65) || nonce(12) || ciphertext || tag(16)` wire.
It does not generate randomness or perform ECDH. Platforms retain private-key
handles in CryptoKit, Android Keystore/JCA, Windows CNG, or non-extractable
WebCrypto and pass only the 32-byte ECDH result to Rust. No C1c FFI or Wasm API
accepts a private scalar, private-key encoding, or `CryptoKey` export.
Independent review of the C1d stack also hardened inherited C1c cleanup paths:
invalid normalized recovery text, failed HKDF outputs, and authenticated
wrong-length recovered key plaintext are structurally zeroized before return.

CloudVault C1d owns whole-document envelope classification, validation,
authenticated open/reseal, lexicographic field ordering, and companion/metadata
update intents. The boundary is one FFI call per document. Callers provide a
complete top-level field-name set, typed payload/text/blob envelopes, and one
unique 12-byte nonce for each envelope Rust determines must be resealed. Dynamic
Firestore dictionaries, persistence, timestamps, rotation orchestration,
randomness, and platform key handles remain outside Rust. An already-new
payload is authenticated under the new key before it is reported as skipped;
malformed or tampered skip candidates fail closed.

## Consequences

- Quota parsing is the pilot because it removes real duplication with a small,
  pure input/output boundary.
- Swift, Kotlin, and C# use generated UniFFI bindings. Tauri may link the pure
  crate directly. Cloud Functions use a separately reviewed WASM adapter only
  for domains they actually execute.
- Existing iroh, remote, media, and libsignal crates remain separate ownership
  boundaries.
- FFI calls operate on complete payloads, files, or sessions rather than lines
  or fields.
- A domain does not move merely because it could be written in Rust. It moves
  only when at least two implementations exist or a measured platform/runtime
  constraint justifies replacing the current authority.
