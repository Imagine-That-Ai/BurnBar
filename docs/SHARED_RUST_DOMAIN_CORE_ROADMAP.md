# Shared Rust Domain Core Roadmap

**Status:** active program
**ADR:** [ADR 014](architecture/014-shared-rust-domain-core.md)
**Source inventory:** [Shared Rust Domain Inventory](SHARED_RUST_DOMAIN_INVENTORY.md)
**First contract:** [`tests/fixtures/domain-core/quota/v1/`](../tests/fixtures/domain-core/quota/v1/)
**CloudVault contract:** [`tests/fixtures/domain-core/cloudvault/v1/`](../tests/fixtures/domain-core/cloudvault/v1/)
**Hermes contract:** [`tests/fixtures/domain-core/hermes/v1/`](../tests/fixtures/domain-core/hermes/v1/)

The pilot is implemented behind `OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE`. Its
accepted values are `legacy` (default), `shadow`, and `rust`.
Hermes relay and ratchet byte transforms use
`OPENBURNBAR_DOMAIN_CORE_HERMES_MODE` with the same values.

## Invariants

- The Rust workspace owns pure transformations only. Platform adapters own I/O,
  persistence, credentials, process execution, UI, and release integration.
- One short-lived branch produces one reviewable result. The merged crate on
  `main` is the only integration branch.
- Contract fixtures precede implementation. Rust and every active consumer must
  emit the same normalized result.
- Migration modes are `legacy`, `shadow`, and `rust`. Shadow mode never changes
  the user-visible result.
- No sensitive input, output, value, credential, or stable payload hash is
  emitted by mismatch telemetry.
- FFI boundaries are payload-sized. Parsers never call Rust once per line.

## Delivery waves

| Wave | Domain | Current duplication | Exit condition |
|---|---|---|---|
| Q1 | Claude statusline quota | Swift + C# | Rust enforced on Apple/Windows; legacy parsers deleted |
| Q2 | Codex, Cursor, Anthropic quota | Swift + C# | Four quota mechanisms share Rust parsing |
| C1 | CloudVault primitives and envelopes | Swift + Kotlin + C# + browser TypeScript | KAT/cross-open clean; duplicated portable crypto copies deleted without exporting browser non-extractable keys |
| C2 | Hermes relay crypto and ratchet byte transforms | Swift + Kotlin | Existing wire vectors pass through Rust; P-256 custody and state mutation remain platform-owned |
| P1 | Model pricing and cost arithmetic | Swift + TypeScript | Integer nano-USD Rust/WASM path enforced |

Provider log parsing remains in Swift until a second real implementation exists,
Android becomes a local log-reading peer, or Windows/Linux Swift runtime evidence
justifies replacement.

CloudVault C1 is split by security boundary. C1a owns deterministic AAD
canonicalization, SHA-256, 32-byte vault-key IDs, and fixed-purpose HKDF/HMAC.
It ships through UniFFI ABI 2, a four-ABI Android AAR, and a deterministic browser
Wasm package. C1b owns AES-256-GCM detached/combined framing, strict UTF-8 and
canonical RFC 4648 Base64, with caller-generated 12-byte nonces and payload-sized
FFI calls. Apple, Android, Windows, and Wasm execute the same AES KAT, including
valid empty plaintext. C1c adds recovery and
P-256 escrow: canonical recovery normalization, recovery HKDF and verification,
strict on-curve 65-byte X9.63 validation, escrow HKDF from caller-provided ECDH
output, and exact public-key-plus-AES wire assembly. Random nonces and P-256
private-key operations remain platform-owned; no private key crosses UniFFI or
Wasm. C1d adds typed whole-document rewrap after those primitives: Rust owns
bounded envelope validation, exact authentication, deterministic field order,
reseal, and update intents, while callers own dynamic document mapping,
persistence, timestamps, orchestration, and nonce generation. Its contract is
`cloudvault-document-rewrap-contract.json`; production Swift/Kotlin flips remain
separate rollout PRs. Search normalization remains last. Browser device
private keys stay non-extractable WebCrypto handles throughout.

Hermes C2 shares relay AAD, v1/v2 wrap-info construction, HPKE v3 info,
SHA-256/safety codes, HKDF/HMAC, AES-GCM payload framing, and ratchet envelope
AAD through ABI 2. CryptoKit/JCA continue to own P-256 private keys, ECDH,
secure random generation, and ratchet state mutation.

## Rollout and deletion gates

Quota migrations require the complete fixture corpus, native binding load tests,
at least 14 days and 10,000 internal or beta shadow parses, zero unexplained
mismatches, and no p95 latency regression above five percent. The legacy mode
remains available for one stable release after Rust enforcement, then is deleted.

Crypto migrations additionally require deterministic KATs, bidirectional
cross-open coverage for every supported envelope version, tamper/wrong-key/AAD
rejection, fuzzing, and independent security review. Authentication failures
remain fail-closed and never trigger automatic legacy fallback.

## Required CI

- `cargo fmt --check`, Clippy with warnings denied, and Rust unit/adversarial
  parser tests. Add continuous fuzz smoke before any parser reaches `rust` mode.
- Generated binding drift checks against the pinned UniFFI toolchain for every
  enabled consumer. The pilot enables Swift and C#; Kotlin is added with its
  first Android-owned domain.
- Apple XCFramework, Android AAR, Windows x64/ARM64 DLL, and Linux x64/ARM64
  library load tests when those consumers are enabled.
- Focused platform contract tests plus release checks for core/binding ABI
  agreement, checksums, SBOM, provenance, and AGPL source completeness.
