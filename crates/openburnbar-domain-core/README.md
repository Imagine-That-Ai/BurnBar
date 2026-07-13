# OpenBurnBar domain core

Pure, duplicated OpenBurnBar business logic shared across native platforms.
The workspace deliberately excludes network acquisition, persistence, secrets,
UI, and operating-system integration.

## Packages

- `openburnbar-domain-core`: dependency-light Rust transformations.
- `openburnbar-domain-ffi`: versioned UniFFI records and functions.

Executable contracts live under `tests/fixtures/domain-core` at the repository
root. The current pure domains are provider quota transforms, CloudVault
deterministic primitives, and pricing/model compatibility rules. Native clients
use UniFFI; browser and Functions TypeScript use the generated WASM package.

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

See `docs/architecture/014-shared-rust-domain-core.md` for the ownership rule and
`docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md` for rollout and deletion gates.
