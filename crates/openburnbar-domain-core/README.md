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

Document rewrap accepts one typed request per document. Platforms retain
dynamic Firestore mapping, timestamps, persistence, randomness, and rotation
orchestration; Rust validates and authenticates each envelope, sorts fields,
reseals with caller nonces, and returns typed field/update intents.

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo deny check
```

The bounded property smoke uses stable `proptest`, fixed 32-byte ChaCha seeds,
96 cases per domain, and shrinking without failure-file writes. It exercises
the exported UniFFI Rust functions so ownership conversion and secret cleanup
remain in the test path. This bounded PR smoke complements rather than replaces
long-running coverage-guided fuzzing and independent crypto review:

```bash
cargo test -p openburnbar-domain-ffi --test fuzz_smoke -- --test-threads=1
```

The release-mode performance smoke crosses each Rust API once per complete
quota response, search query, crypto payload, or typed document. Its thresholds
are deliberately loose catastrophic-regression guards, not the rollout's
platform-versus-legacy five-percent acceptance evidence:

```bash
cargo test --release -p openburnbar-domain-ffi \
  --test performance_smoke -- --ignored --nocapture --test-threads=1
```

See `docs/architecture/014-shared-rust-domain-core.md` for the ownership rule and
`docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md` for rollout and deletion gates.
