# OpenBurnBar domain core

Pure, duplicated OpenBurnBar business logic shared across native platforms.
The workspace deliberately excludes network acquisition, persistence, secrets,
UI, and operating-system integration.

## Packages

- `openburnbar-domain-core`: dependency-light Rust transformations.
- `openburnbar-domain-ffi`: versioned UniFFI records and functions.
- `openburnbar-domain-wasm`: browser bindings for byte-oriented portable logic.

The first migrated domain is quota parsing. CloudVault C1a-C1d additionally own
AAD and hashing, AES wire framing, recovery wrapping, P-256 escrow framing, and
typed whole-document envelope rewrap.
Their contracts live in `tests/fixtures/domain-core` at the repository root.

CloudVault C1c never receives a platform private key. Native and browser
adapters perform P-256 ECDH with their existing non-exportable key handles, then
pass only the resulting 32-byte shared secret, public X9.63 bytes, a
caller-generated nonce, and a complete payload across the boundary.

Document rewrap accepts one typed request per document. Platforms retain
dynamic Firestore mapping, timestamps, persistence, randomness, and rotation
orchestration; Rust validates and authenticates each envelope, sorts fields,
reseals with caller nonces, and returns typed field/update intents.

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

See `docs/architecture/014-shared-rust-domain-core.md` for the ownership rule and
`docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md` for rollout and deletion gates.
