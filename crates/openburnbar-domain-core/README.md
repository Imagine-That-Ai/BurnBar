# OpenBurnBar domain core

Pure, duplicated OpenBurnBar business logic shared across native platforms.
The workspace deliberately excludes network acquisition, persistence, secrets,
UI, and operating-system integration.

## Packages

- `openburnbar-domain-core`: dependency-light Rust transformations.
- `openburnbar-domain-ffi`: versioned UniFFI records and functions.
- `openburnbar-domain-wasm`: browser bindings for byte-oriented portable logic.

The first migrated domain is quota parsing. CloudVault C1a-C1c additionally own
AAD and hashing, AES wire framing, recovery wrapping, and P-256 escrow framing.
Their contracts live in `tests/fixtures/domain-core` at the repository root.

The CloudVault search core owns the complete deterministic v1 transform for
Unicode token analysis and token, index, query, and semantic trapdoor hashes.
Callers cross UniFFI or Wasm once per complete text/query. The core accepts at
most 1 MiB of UTF-8 text, 4,096 extracted tokens, and a requested limit of
1,024; zero and negative limits return an empty result as required by the v1
contract. Android production routing is selected with
`OPENBURNBAR_CLOUDVAULT_SEARCH_MODE`; it defaults to legacy, compares exact
ordered hashes in shadow, and never falls back from Rust-mode failures.

CloudVault C1c never receives a platform private key. Native and browser
adapters perform P-256 ECDH with their existing non-exportable key handles, then
pass only the resulting 32-byte shared secret, public X9.63 bytes, a
caller-generated nonce, and a complete payload across the boundary.

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo deny check
```

See `docs/architecture/014-shared-rust-domain-core.md` for the ownership rule and
`docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md` for rollout and deletion gates.
