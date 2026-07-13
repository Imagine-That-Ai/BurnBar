# OpenBurnBar domain core

Pure, duplicated OpenBurnBar business logic shared across native platforms.
The workspace deliberately excludes network acquisition, persistence, secrets,
UI, and operating-system integration.

## Packages

- `openburnbar-domain-core`: dependency-light Rust transformations.
- `openburnbar-domain-ffi`: versioned UniFFI records and functions.

The first migrated domain is Claude statusline quota parsing. Its contract lives
in `tests/fixtures/domain-core/quota/v1` at the repository root.

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

See `docs/architecture/014-shared-rust-domain-core.md` for the ownership rule and
`docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md` for rollout and deletion gates.
